import Foundation
import Network
import Security
import VeltoretKit

/// A tiny HTTP server a Chromecast (or Veltoret on a TV, as vlink://) streams from while casting (Android
/// CastServer, WIRE §4). NWListener on the LAN address facing the receiver. Runs only while casting; paths carry a
/// random token, and only home-network addresses are answered. Supports Range (seeking) and CORS (the receiver
/// fetches subtitles with XHR).
public final class CastServer: @unchecked Sendable {
    /// Marks "to the end" in a range whose file size isn't known.
    public static let openEnd: Int64 = Int64.max - 1

    /// Opens a random-access reader for a file of any source (Storage.openRead).
    public typealias Opener = (_ account: String, _ fileId: String) async throws -> ByteSource

    private enum Entry {
        case media(MediaEntry)
        case text(bytes: Data, mime: String)
    }

    private final class MediaEntry: @unchecked Sendable {
        let account: String
        let fileId: String
        let mime: String
        var length: Int64?
        let patches: [Int64: UInt8]
        init(account: String, fileId: String, mime: String, length: Int64?, patches: [Int64: UInt8]) {
            self.account = account; self.fileId = fileId; self.mime = mime; self.length = length; self.patches = patches
        }
    }

    private let open: Opener
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var listener: NWListener?
    private var host = ""
    private var port: UInt16 = 0
    private let queue = DispatchQueue(label: "veltoret.castserver", attributes: .concurrent)

    /// Raised (on a background thread) for every request from a home-network client: the receiver can reach us.
    public let requestReceived = Event<Void>()

    public init(open: @escaping Opener) { self.open = open }

    /// 16 random bytes as lowercase hex, made once per server instance.
    public let token: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    public var running: Bool { lock.lock(); defer { lock.unlock() }; return listener != nil }

    /// Listens on `address` (this Mac's address facing the receiver), a random port; idempotent.
    public func start(_ address: String) throws {
        lock.lock(); defer { lock.unlock() }
        if listener != nil && host == address { return }
        stopSocket()
        let params = NWParameters(tls: nil, tcp: { let t = NWProtocolTCP.Options(); t.noDelay = true; return t }())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut || failure != nil || l.port == nil {
            l.cancel()
            throw failure ?? NetIOError("The cast server couldn't start")
        }
        listener = l
        host = address
        port = l.port!.rawValue
    }

    /// Stops listening and forgets every entry.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopSocket()
        entries.removeAll()
    }

    private func stopSocket() {
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        host = ""
        port = 0
    }

    /// The URL the receiver loads the file from. `id` must be URL-safe ([A-Za-z0-9._-]).
    public func media(_ id: String, account: String, fileId: String, mime: String, length: Int64?, patches: [Int64: UInt8]? = nil) throws -> String {
        lock.lock()
        entries[id] = .media(MediaEntry(account: account, fileId: fileId, mime: mime, length: (length ?? 0) > 0 ? length : nil,
                                         patches: patches ?? [:]))
        lock.unlock()
        return try url(id)
    }

    /// Serves `text` (a WebVTT subtitle) at a URL.
    public func text(_ id: String, _ text: String, mime: String = "text/vtt") throws -> String {
        lock.lock(); entries[id] = .text(bytes: Data(text.utf8), mime: mime); lock.unlock()
        return try url(id)
    }

    private func url(_ id: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard listener != nil else { throw NetIOError("Cast server isn't running") }
        let h = host.contains(":") ? "[\(host)]" : host
        return "http://\(h):\(port)/\(token)/\(id)"
    }

    private func entry(_ id: String) -> Entry? { lock.lock(); defer { lock.unlock() }; return entries[id] }

    // ---- Connections ---------------------------------------------------------------------------------

    private func accept(_ conn: NWConnection) {
        let nc = NetConnection(conn, queue: DispatchQueue(label: "veltoret.castserver.conn"))
        conn.start(queue: DispatchQueue(label: "veltoret.castserver.c"))
        Task.detached { [weak self] in
            // The Chromecast closes connections whenever it seeks or has buffered enough; that's normal.
            do {
                try await withTimeout(6 * 3600 * 1000, "") { [weak self] in try await self?.handle(nc, remote: conn.endpoint) }
            } catch {}
            nc.finish()
            try? await Task.sleep(nanoseconds: 50_000_000)
            nc.cancel()
        }
    }

    private func remoteBytes(_ endpoint: NWEndpoint) -> [UInt8]? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return [UInt8](a.rawValue)
        case .ipv6(let a): return [UInt8](a.rawValue)
        case .name(let n, _): return IPAddressUtil.bytes(n)
        @unknown default: return nil
        }
    }

    /// The request head (request line + header lines), ISO-8859-1, at most 16 KiB; the rest is put back.
    private func readHead(_ c: NetConnection) async throws -> [String]? {
        var head = Data()
        let marker = Data("\r\n\r\n".utf8)
        while true {
            let chunk = try await withTimeout(30_000, "Read timed out") { try await c.receive(max: 4096) }
            if chunk.isEmpty { break }
            head.append(chunk)
            if let r = head.range(of: marker) {
                let rest = head[r.upperBound...]
                if !rest.isEmpty { c.unread(Data(rest)) }
                head = head[..<r.lowerBound]
                break
            }
            if head.count > 16 * 1024 { return nil }
        }
        if head.isEmpty { return nil }
        let text = String(data: head, encoding: .isoLatin1) ?? ""
        return text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private func handle(_ c: NetConnection, remote: NWEndpoint) async throws {
        guard let lines = try await readHead(c), let requestLine = lines.first else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":"), colon > line.startIndex {
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let method = parts.count > 0 ? parts[0] : ""
        let target = parts.count > 1 ? parts[1] : ""
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""

        guard let remoteAddr = remoteBytes(remote), IPAddressUtil.isHomeNetwork(remoteAddr) else {
            try await respond(c, 403, "Forbidden"); return
        }
        requestReceived.fire()
        if method == "OPTIONS" { try await respond(c, 204, nil); return }
        let segments = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 2, segments[0] == token, let entry = entry(segments[1]) else {
            try await respond(c, 404, "Not found"); return
        }
        let head = method == "HEAD"
        switch entry {
        case let .text(bytes, mime):
            try await respond(c, 200, nil, [("Content-Type", mime + "; charset=utf-8"), ("Content-Length", String(bytes.count))])
            if !head { try await c.send(bytes) }
        case let .media(media):
            try await serveMedia(c, media, headers["range"], head: head)
        }
    }

    private func serveMedia(_ output: NetConnection, _ entry: MediaEntry, _ rangeHeader: String?, head: Bool) async throws {
        var source: ByteSource?
        defer { source?.close() }
        var total = entry.length
        if total == nil {
            let s = try await open(entry.account, entry.fileId)
            source = s
            total = s.length > 0 ? s.length : nil
            entry.length = total
        }
        let range = rangeHeader.flatMap { Self.parseRange($0, total: total) }
        if rangeHeader != nil && range == nil {
            try await respond(output, 416, nil, [("Content-Range", "bytes */\(total.map { String($0) } ?? "*")")])
            return
        }
        let start = range?.first ?? 0
        // An open range on a file of unknown size ("bytes=500-") streams to the end.
        let end: Int64? = (range != nil && range!.last != Self.openEnd) ? range!.last : total.map { $0 - 1 }
        let length: Int64? = end.map { $0 - start + 1 }
        var headers: [(String, String)] = [("Content-Type", entry.mime), ("Accept-Ranges", "bytes")]
        if let length { headers.append(("Content-Length", String(length))) }
        if range != nil {
            headers.append(("Content-Range", "bytes \(start)-\(end.map { String($0) } ?? "")/\(total.map { String($0) } ?? "*")"))
        }
        try await respond(output, range != nil ? 206 : 200, nil, headers)
        if head { return }

        let src: ByteSource
        if let s = source { src = s } else { let s = try await open(entry.account, entry.fileId); source = s; src = s }
        var remaining = length ?? Int64.max
        var position = start
        while remaining > 0 {
            var chunk = try await src.read(at: position, count: Int(min(256 * 1024, remaining)))
            if chunk.isEmpty { break }
            CastAudio.apply(entry.patches, position: position, buffer: &chunk)
            try await output.send(chunk)
            remaining -= Int64(chunk.count)
            position += Int64(chunk.count)
        }
    }

    /// Writes the response head in the exact order Android does (CORS first), then a text body if any.
    private func respond(_ c: NetConnection, _ code: Int, _ body: String?, _ headers: [(String, String)]? = nil) async throws {
        let (head, bodyBytes) = Self.responseHead(code, body, headers)
        try await c.send(bodyBytes.map { head + $0 } ?? head)
    }

    public static func responseHead(_ code: Int, _ body: String?, _ headers: [(String, String)]?) -> (Data, Data?) {
        var text = "HTTP/1.1 \(code) \(reason(code))\r\n"
        text += "Access-Control-Allow-Origin: *\r\n"
        text += "Access-Control-Allow-Headers: Range, Content-Type\r\n"
        text += "Access-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges\r\n"
        text += "Connection: close\r\n"
        for (k, v) in headers ?? [] { text += "\(k): \(v)\r\n" }
        let bodyBytes = body.map { Data($0.utf8) }
        if let bodyBytes { text += "Content-Type: text/plain\r\nContent-Length: \(bodyBytes.count)\r\n" }
        text += "\r\n"
        return (text.data(using: .isoLatin1) ?? Data(text.utf8), bodyBytes)
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        default: return "Error"
        }
    }

    /// "bytes=500-" / "bytes=500-999" / "bytes=-200" against a file of `total` bytes (nil = unknown).
    /// Returns the inclusive byte range, or nil when it can't be satisfied.
    public static func parseRange(_ header: String, total: Int64?) -> (first: Int64, last: Int64)? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes=") else { return nil }
        var spec = String(trimmed.dropFirst("bytes=".count))
        if let comma = spec.firstIndex(of: ",") { spec = String(spec[..<comma]) }
        spec = spec.trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        let startText = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endText = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            // Suffix range: the last N bytes.
            guard let n = Int64(endText), let total, n > 0 else { return nil }
            return (max(0, total - n), total - 1)
        }
        guard let start = Int64(startText) else { return nil }
        if let total, start >= total { return nil }
        let last = total.map { $0 - 1 }
        let end: Int64
        if let e = Int64(endText) { end = last.map { min(e, $0) } ?? e }
        else if let last { end = last }
        else { return (start, openEnd) }
        return end < start ? nil : (start, end)
    }

    /// Only devices on the home network (and this Mac) may stream.
    public static func isHomeNetwork(_ address: String) -> Bool { IPAddressUtil.isHomeNetwork(address) }

    /// This Mac's address on the network the receiver is on.
    public static func addressFacing(_ receiver: String) -> String {
        IPAddressUtil.addressFacing(receiver) ?? (IPAddressUtil.bytes(receiver)?.count == 16 ? "::1" : "127.0.0.1")
    }
}
