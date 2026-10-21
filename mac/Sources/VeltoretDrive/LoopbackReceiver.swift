import Foundation
import Darwin

/// The redirect target of the installed-app flow (RFC 8252): listens on http://127.0.0.1:{free port}/ for the one
/// request the browser makes after the Google screen, answers it with a small page, and hands back its query.
/// A plain BSD socket on the loopback address (no entitlement or firewall prompt for 127.0.0.1).
public final class LoopbackReceiver: @unchecked Sendable {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var cancelled = false

    public let port: Int
    public var redirectUri: String { "http://127.0.0.1:\(port)/" }

    public struct SocketError: Error, LocalizedError, CustomStringConvertible {
        public let message: String
        public var errorDescription: String? { message }
        public var description: String { message }
    }

    public init() throws {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 { throw SocketError(message: String(cString: strerror(errno))) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 || listen(s, 8) != 0 {
            let msg = String(cString: strerror(errno))
            Darwin.close(s)
            throw SocketError(message: msg)
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        port = Int(UInt16(bigEndian: out.sin_port))
        fd = s
    }

    deinit { close() }

    public func close() {
        lock.lock()
        let s = fd
        fd = -1
        cancelled = true
        lock.unlock()
        if s >= 0 { Darwin.close(s) }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Waits for the redirect and returns its query parameters. Requests without code/error (a favicon, a
    /// prefetch) get a 404 and are ignored. `pageFor` builds the HTML reply from the parameters.
    /// Throws `CancellationError` when the task is cancelled (or the receiver closed).
    public func waitForRedirect(_ pageFor: @escaping @Sendable ([String: String]) -> String) async throws -> [String: String] {
        let state = WaitState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
                let thread = Thread { [self] in
                    let result: Result<[String: String], Error> = Result { try self.acceptLoop(pageFor, state) }
                    c.resume(with: result)
                }
                thread.name = "Veltoret loopback"
                thread.start()
            }
        } onCancel: {
            state.cancel()
        }
    }

    final class WaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private func acceptLoop(_ pageFor: ([String: String]) -> String, _ state: WaitState) throws -> [String: String] {
        while true {
            if state.cancelled || isCancelled { throw CancellationError() }
            lock.lock(); let s = fd; lock.unlock()
            if s < 0 { throw CancellationError() }
            var p = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 200)
            if ready <= 0 { continue }
            let client = accept(s, nil, nil)
            if client < 0 { continue }
            defer { Darwin.close(client) }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // A broken or slow connection: wait for the next one.
            guard let target = Self.readRequestTarget(client) else { continue }
            let query = Self.parseQuery(target)
            if query["code"] == nil && query["error"] == nil {
                Self.respond(client, 404, "Not found", "")
                continue
            }
            Self.respond(client, 200, "OK", pageFor(query))
            return query
        }
    }

    private static func readRequestTarget(_ client: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var total = 0
        while total < buffer.count {
            let n = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress! + total, $0.count - total, 0) }
            if n <= 0 { break }
            total += n
            if String(decoding: buffer[0..<total], as: UTF8.self).contains("\r\n\r\n") { break }
        }
        let text = String(decoding: buffer[0..<total], as: UTF8.self)
        let line = text.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        if parts.count < 2 || parts[0] != "GET" { return nil }
        return String(parts[1])
    }

    public static func parseQuery(_ target: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let q = target.firstIndex(of: "?") else { return result }
        for pair in target[target.index(after: q)...].split(separator: "&") where !pair.isEmpty {
            let s = String(pair)
            let unescape: (String) -> String = { raw in
                let plus = raw.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            if let eq = s.firstIndex(of: "=") {
                result[unescape(String(s[..<eq]))] = unescape(String(s[s.index(after: eq)...]))
            } else {
                result[unescape(s)] = ""
            }
        }
        return result
    }

    private static func respond(_ client: Int32, _ code: Int, _ reason: String, _ html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var all = Data(head.utf8)
        all.append(body)
        all.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(client, raw.baseAddress! + sent, raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
        shutdown(client, SHUT_WR)
    }

    static func htmlEncode(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// The page the browser shows after Google sends it back.
    public static func page(_ title: String, _ text: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Veltoret</title><style>" +
            "body{margin:0;background:#0B0B0D;color:#F3EFE6;font-family:Inter,-apple-system,sans-serif;display:flex;" +
            "align-items:center;justify-content:center;min-height:100vh}" +
            "div{max-width:440px;padding:32px;border:1px solid #2C2C35;border-radius:16px;background:#15151A}" +
            "h1{font-size:22px;margin:0 0 12px;color:#E8A33D}p{margin:0;color:#9C9AA3;line-height:1.5}</style></head>" +
            "<body><div><h1>\(htmlEncode(title))</h1><p>\(htmlEncode(text))</p></div></body></html>"
    }
}
