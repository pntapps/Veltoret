import Foundation
import Network

/// A network failure (the C# IOException): connect refused or timed out, the peer closed early, a read timed out.
public struct NetIOError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// async/await over one NWConnection (TCP, optionally TLS). Reads and writes may be awaited from any task.
final class NetConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var eof = false
    private let lock = NSLock()

    init(_ connection: NWConnection, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.queue = queue ?? DispatchQueue(label: "veltoret.net")
    }

    /// Plain TCP (or TLS accepting any certificate, for Cast devices' self-signed ones).
    static func parameters(tlsAcceptingAny: Bool, ipv4Only: Bool = false) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let params: NWParameters
        if tlsAcceptingAny {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) },
                                                  DispatchQueue.global())
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        if ipv4Only, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        return params
    }

    /// Connects or throws within `timeoutMs` (a refused connection counts as a failure, not "waiting").
    static func connect(host: String, port: Int, tls: Bool = false, timeoutMs: Int) async throws -> NetConnection {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw NetIOError("Bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: parameters(tlsAcceptingAny: tls))
        let nc = NetConnection(conn)
        try await nc.start(timeoutMs: timeoutMs)
        return nc
    }

    func start(timeoutMs: Int) async throws {
        let once = Once()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if once.fire() { cont.resume() }
                    case .failed(let e):
                        if once.fire() { cont.resume(throwing: NetIOError("\(e)")) }
                    case .waiting(let e):
                        if once.fire() { self?.connection.cancel(); cont.resume(throwing: NetIOError("\(e)")) }
                    case .cancelled:
                        if once.fire() { cont.resume(throwing: NetIOError("Cancelled")) }
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
                    if once.fire() { self?.connection.cancel(); cont.resume(throwing: NetIOError("Connect timed out")) }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    /// Up to `max` bytes (at least 1), or empty at EOF.
    func receive(max: Int = 64 * 1024) async throws -> Data {
        let buffered: Data? = lock.withLock {
            if !buffer.isEmpty {
                let n = min(max, buffer.count)
                let out = Data(buffer.prefix(n)); buffer.removeFirst(n)
                return out
            }
            return eof ? Data() : nil
        }
        if let buffered { return buffered }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { [weak self] data, _, complete, error in
                if let data, !data.isEmpty {
                    if complete { self?.markEof() }
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: NetIOError("\(error)"))
                } else {
                    self?.markEof()
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private func markEof() { lock.withLock { eof = true } }

    /// Puts bytes back to be read first (read too far while looking for the end of a head).
    func unread(_ data: Data) {
        lock.withLock { buffer = data + buffer }
    }

    /// Exactly `count` bytes, or throws at EOF.
    func receiveExactly(_ count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            let chunk = try await receive(max: count - out.count)
            if chunk.isEmpty { throw NetIOError("The connection closed") }
            out.append(chunk)
        }
        return out
    }

    /// Everything until the peer closes.
    func receiveAll(limit: Int = 32 * 1024 * 1024) async throws -> Data {
        var out = Data()
        while out.count < limit {
            let chunk = try await receive()
            if chunk.isEmpty { break }
            out.append(chunk)
        }
        return out
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: NetIOError("\(error)")) } else { cont.resume() }
            })
        }
    }

    /// Sends a FIN after everything queued.
    func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func cancel() { connection.cancel() }
}

/// Fires once (continuations must resume exactly once).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Runs `body` but throws `NetIOError(message)` after `ms`.
func withTimeout<T>(_ ms: Int, _ message: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            throw NetIOError(message)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// IP address helpers (the C# IPAddress checks).
public enum IPAddressUtil {
    /// 4 or 16 bytes for an IPv4 / IPv6 literal (IPv6 may carry a "%scope"), else nil.
    public static func bytes(_ text: String) -> [UInt8]? {
        var s = text
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    public static func string(_ b: [UInt8]) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if b.count == 4 {
            var a = in_addr(); withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: b) }
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        } else {
            var a = in6_addr(); withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: b) }
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
        }
        return String(cString: buf)
    }

    /// Only devices on the home network (and this Mac) may stream: private IPv4, link-local, loopback, IPv6
    /// link-local / site-local / unique local (fc00::/7). IPv4-mapped IPv6 is checked as IPv4.
    public static func isHomeNetwork(_ input: [UInt8]) -> Bool {
        var b = input
        if b.count == 16 && b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { b = Array(b[12..<16]) }
        if b.count == 4 {
            return b[0] == 10
                || (b[0] == 172 && (b[1] & 0xF0) == 16)
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
                || b[0] == 127
        }
        if b.count == 16 {
            let loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
            let linkLocal = b[0] == 0xFE && (b[1] & 0xC0) == 0x80
            let siteLocal = b[0] == 0xFE && (b[1] & 0xC0) == 0xC0
            return loopback || linkLocal || siteLocal || (b[0] & 0xFE) == 0xFC
        }
        return false
    }

    public static func isHomeNetwork(_ text: String) -> Bool {
        guard let b = bytes(text) else { return false }
        return isHomeNetwork(b)
    }

    /// This Mac's address on the network `receiver` is on (a UDP "connect" picks the interface).
    public static func addressFacing(_ receiver: String) -> String? {
        guard let b = bytes(receiver) else { return nil }
        if b.count == 4 {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(8009).bigEndian
            withUnsafeMutableBytes(of: &addr.sin_addr) { $0.copyBytes(from: b) }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard ok == 0 else { return nil }
            var local = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            guard got == 0 else { return nil }
            return string(withUnsafeBytes(of: &local.sin_addr) { Array($0) })
        } else {
            let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(8009).bigEndian
            withUnsafeMutableBytes(of: &addr.sin6_addr) { $0.copyBytes(from: b) }
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            guard ok == 0 else { return nil }
            var local = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let got = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            guard got == 0 else { return nil }
            return string(withUnsafeBytes(of: &local.sin6_addr) { Array($0) })
        }
    }
}
