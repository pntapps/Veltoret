import Foundation

/// One HTTP/1.1 request to a Veltoret mini-server (TV link, "Use your phone"), byte for byte as the Android
/// clients send it (WIRE §0.2). The server closes after replying; the whole reply is read until EOF.
public enum LinkHttp {
    public struct Reply: Hashable, Sendable {
        public var status: Int
        public var body: String
    }

    /// `body` nil: no Content-Type / Content-Length (GET). Empty: sent with Content-Length: 0.
    /// Throws `NetIOError` when the TV can't be reached or doesn't answer in time.
    public static func exchange(host: String, port: Int, method: String, path: String, body: Data?,
                                headers: [(String, String)]?, connectTimeoutMs: Int, readTimeoutMs: Int) async throws -> Reply {
        let conn = try await NetConnection.connect(host: host, port: port, timeoutMs: connectTimeoutMs)
        defer { conn.cancel() }
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host):\(port)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in headers ?? [] { head += "\(k): \(v)\r\n" }
        let bytes = body ?? Data()
        if body != nil { head += "Content-Type: application/json\r\nContent-Length: \(bytes.count)\r\n" }
        head += "\r\n"
        let request = Data(head.utf8) + bytes
        let all = try await withTimeout(readTimeoutMs, "Timed out") {
            try await conn.send(request)
            return try await conn.receiveAll()
        }
        return try parse(String(decoding: all, as: UTF8.self))
    }

    /// Status from line 1 (split on ' ', element 1); body = everything after the first blank line.
    public static func parse(_ text: String) throws -> Reply {
        let firstLine = text.components(separatedBy: "\r\n").first ?? text
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 2, let status = Int(parts[1]) else { throw NetIOError("Not HTTP") }
        guard let split = text.range(of: "\r\n\r\n") else { return Reply(status: status, body: "") }
        return Reply(status: status, body: String(text[split.upperBound...]))
    }
}
