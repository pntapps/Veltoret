import Foundation
import Darwin
import XCTest
@testable import VeltoretDrive

/// A one-shot HTTP server on 127.0.0.1 that answers each connection with a canned response.
private final class CannedServer: @unchecked Sendable {
    let fd: Int32
    let port: Int
    private let response: Data

    init(_ response: Data) throws {
        self.response = response
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.port = Int(UInt16(bigEndian: out.sin_port))
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    private func serve() {
        let c = accept(fd, nil, nil)
        if c < 0 { return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var buf = [UInt8](repeating: 0, count: 8192)
        _ = recv(c, &buf, buf.count, 0)
        response.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(c, raw.baseAddress! + sent, raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
        Darwin.close(c)
    }

    func stop() { Darwin.close(fd) }
}

final class URLSessionTransportTests: XCTestCase {
    func testOpenStreamsALargeBodyWithBackPressure() async throws {
        let body = randomBytes(21, 9 * 1024 * 1024 + 7)
        var raw = Data("HTTP/1.1 206 Partial Content\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        raw.append(body)
        let server = try CannedServer(raw)
        defer { server.stop() }

        let transport = URLSessionTransport()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/file")!)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let response = try await transport.open(request)
        XCTAssertEqual(response.status, 206)
        // Let the buffer fill past the high-water mark so the task is suspended, then drain it.
        try await Task.sleep(nanoseconds: 300_000_000)
        var got = Data()
        while true {
            let d = try await response.body.read(max: 300_000)
            if d.isEmpty { break }
            got.append(d)
        }
        XCTAssertEqual(got.count, body.count)
        XCTAssertEqual(got, body)
    }

    func testResumeIncompleteIsNotFollowed() async throws {
        let server = try CannedServer(Data("HTTP/1.1 308 Resume Incomplete\r\nRange: bytes=0-9\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/session")!)
        request.httpMethod = "PUT"
        request.httpBody = Data(count: 10)
        let response = try await URLSessionTransport().send(request)
        XCTAssertEqual(response.status, 308)
        XCTAssertEqual(response.header("range"), "bytes=0-9")
    }
}
