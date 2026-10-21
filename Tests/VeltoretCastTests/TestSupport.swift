import Foundation
import Network
import Security
import XCTest
@testable import VeltoretCast

/// A loopback TCP (optionally TLS) server for fakes: each connection is handed to `handle`.
final class LoopbackServer: @unchecked Sendable {
    let listener: NWListener
    let port: Int

    init(identity: SecIdentity? = nil, handle: @escaping @Sendable (NetConnection) async -> Void) throws {
        let tcp = NWProtocolTCP.Options()
        let params: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            let nc = NetConnection(conn)
            Task.detached {
                do { try await nc.start(timeoutMs: 10_000) } catch { return }
                await handle(nc)
                nc.finish()
                try? await Task.sleep(nanoseconds: 100_000_000)
                nc.cancel()
            }
        }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        _ = ready.wait(timeout: .now() + 5)
        port = Int(listener.port?.rawValue ?? 0)
    }

    func stop() { listener.cancel() }

    /// A self-signed identity made with /usr/bin/openssl and imported in memory only (nothing lands in the Keychain).
    static func selfSignedIdentity() throws -> SecIdentity {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw XCTSkip("openssl failed: \(args.first ?? "")") }
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "k.pem", "-out", "c.pem", "-days", "2", "-subj", "/CN=fake-cast"])
        try run(["pkcs12", "-export", "-inkey", "k.pem", "-in", "c.pem", "-out", "id.p12", "-passout", "pass:test"])
        let data = try Data(contentsOf: dir.appendingPathComponent("id.p12"))
        var options: [String: Any] = [kSecImportExportPassphrase as String: "test"]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else { throw XCTSkip("PKCS12 import failed: \(status)") }
        return identity as! SecIdentity
    }
}

/// One raw HTTP request over loopback; returns the head (without the blank line) and the body bytes.
func rawHttp(_ url: String, range: String? = nil, method: String = "GET") async throws -> (head: String, body: Data) {
    let u = URL(string: url)!
    let conn = try await NetConnection.connect(host: u.host!, port: u.port!, timeoutMs: 5_000)
    defer { conn.cancel() }
    let req = "\(method) \(u.path) HTTP/1.1\r\nHost: \(u.host!):\(u.port!)\r\n" + (range.map { "Range: \($0)\r\n" } ?? "") + "Connection: close\r\n\r\n"
    try await conn.send(Data(req.utf8))
    let all = try await withTimeout(10_000, "timeout") { try await conn.receiveAll() }
    let marker = all.range(of: Data("\r\n\r\n".utf8))!
    return (String(data: all[..<marker.lowerBound], encoding: .isoLatin1)!, Data(all[marker.upperBound...]))
}

func waitFor(_ timeoutMs: Int = 5_000, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    var waited = 0
    while !condition() && waited < timeoutMs {
        try? await Task.sleep(nanoseconds: 50_000_000)
        waited += 50
    }
    XCTAssertTrue(condition(), file: file, line: line)
}

func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}
