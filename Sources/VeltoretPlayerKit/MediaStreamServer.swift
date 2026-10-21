import Foundation
import Network
import VeltoretKit

/// Why a stream request failed (the player turns it into its error text: Drive 403/404, SMB errors…).
public struct StreamFailure: @unchecked Sendable {
    public let account: String
    public let fileId: String
    public let error: Error
}

/// A tiny HTTP/1.1 server on 127.0.0.1 (random port, random URL token) that serves any file from
/// `AppServices.storage.openRead(account:id:)`, so VLCKit can play Drive and SMB files with fast seeking
/// (Range / 206, HEAD, keep-alive, several connections at once). New for the Mac port (Windows used a MediaInput).
///
/// URLs look like `http://127.0.0.1:<port>/<token>/<entry>/<file name>`; they stay valid until `stop()`.
public final class MediaStreamServer: @unchecked Sendable {
    public static let shared = MediaStreamServer()

    /// Bytes read from the source and sent per step (the next one is read while this one is sent).
    public static let chunkSize = 1 << 20
    /// A keep-alive connection with no request for this long is closed.
    static let idleTimeout: TimeInterval = 120

    /// Fired (on a background thread) when a source can't be opened or read for a request.
    public let streamFailed = Event<StreamFailure>()

    private struct Entry {
        let account: String
        let fileId: String
        let name: String
        let mime: String
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "veltoret.media-stream-server", attributes: .concurrent)
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var token = ""
    private var starting: Task<UInt16, Error>?
    private var entries: [String: Entry] = [:]
    private var entryByFile: [String: String] = [:]
    private var connections: [ObjectIdentifier: StreamConnection] = [:]
    private var errors: [String: Error] = [:]

    public init() {}

    /// A loopback URL VLC can play (and seek in) for the file. Starts the server on first use.
    public func url(account: String, fileId: String, name: String, mime: String? = nil) async throws -> URL {
        let port = try await ensureStarted()
        lock.lock()
        let key = account + "\u{1F}" + fileId
        let id: String
        if let existing = entryByFile[key] {
            id = existing
        } else {
            id = Self.randomHex(8)
            entryByFile[key] = id
        }
        entries[id] = Entry(account: account, fileId: fileId, name: name, mime: mime ?? Self.mimeFor(name))
        errors[key] = nil
        let token = self.token
        lock.unlock()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        let safeName = (name.isEmpty ? "video" : name).addingPercentEncoding(withAllowedCharacters: allowed) ?? "video"
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(id)/\(safeName)") else { throw URLError(.badURL) }
        return url
    }

    /// The last error a request for this file hit (nil when none since `url(…)`).
    public func lastError(account: String, fileId: String) -> Error? {
        lock.lock(); defer { lock.unlock() }
        return errors[account + "\u{1F}" + fileId]
    }

    /// The port while running (0 when stopped).
    public var currentPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return listener == nil ? 0 : port
    }

    /// Stops listening and closes every connection (their sources too). URLs handed out stop working.
    public func stop() {
        lock.lock()
        let l = listener, conns = Array(connections.values), s = starting
        listener = nil; starting = nil; port = 0; token = ""
        entries.removeAll(); entryByFile.removeAll(); connections.removeAll(); errors.removeAll()
        lock.unlock()
        s?.cancel()
        l?.cancel()
        for c in conns { c.cancel() }
    }

    // ---- Listener ------------------------------------------------------------------------------

    private func ensureStarted() async throws -> UInt16 {
        lock.lock()
        if listener != nil && port != 0 { let p = port; lock.unlock(); return p }
        if let s = starting { lock.unlock(); return try await s.value }
        let task = Task { try await self.startListener() }
        starting = task
        lock.unlock()
        do {
            let p = try await task.value
            return p
        } catch {
            lock.lock(); if starting == task { starting = nil }; lock.unlock()
            throw error
        }
    }

    private func startListener() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        let l = try NWListener(using: params)
        let newToken = Self.randomHex(16)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.take() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.take() { cont.resume(throwing: e) }
                    else { self?.listenerFailed(l, e) }
                case .cancelled:
                    if once.take() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        guard port != 0 else { l.cancel(); throw URLError(.cannotConnectToHost) }
        lock.lock()
        listener = l
        self.port = port
        token = newToken
        starting = nil
        lock.unlock()
        Log.info("media stream server on 127.0.0.1:\(port)")
        return port
    }

    private func listenerFailed(_ l: NWListener, _ error: Error) {
        Log.error("media stream server stopped: \(error)")
        lock.lock()
        if listener === l { listener = nil; port = 0 }
        lock.unlock()
        l.cancel()
    }

    private func accept(_ c: NWConnection) {
        // Loopback only (the listener is bound to 127.0.0.1 already; this is belt and braces).
        if case let .hostPort(host, _) = c.endpoint {
            let ok: Bool
            switch host {
            case .ipv4(let a): ok = a.isLoopback
            case .ipv6(let a): ok = a.isLoopback
            case .name(let n, _): ok = n == "localhost" || n == "127.0.0.1"
            @unknown default: ok = false
            }
            if !ok { c.cancel(); return }
        }
        let conn = StreamConnection(c, server: self, queue: queue)
        lock.lock(); connections[ObjectIdentifier(conn)] = conn; lock.unlock()
        conn.start()
    }

    fileprivate func finished(_ conn: StreamConnection) {
        lock.lock(); connections[ObjectIdentifier(conn)] = nil; lock.unlock()
    }

    fileprivate func resolve(path: String) -> (account: String, fileId: String, mime: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !token.isEmpty, Self.constantTimeEquals(String(parts[0]), token), let e = entries[String(parts[1])] else { return nil }
        return (e.account, e.fileId, e.mime)
    }

    fileprivate func report(account: String, fileId: String, error: Error) {
        lock.lock(); errors[account + "\u{1F}" + fileId] = error; lock.unlock()
        Log.error("stream \(Accounts.isLocal(account) ? "local" : account) failed: \(error)")
        streamFailed.fire(StreamFailure(account: account, fileId: fileId, error: error))
    }

    // ---- Helpers --------------------------------------------------------------------------------

    static func randomHex(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// A MIME type from the file name (VLC sniffs the content anyway).
    public static func mimeFor(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "mpg", "mpeg": return "video/mpeg"
        case "3gp": return "video/3gpp"
        case "ogv": return "video/ogg"
        case "srt": return "application/x-subrip"
        case "vtt": return "text/vtt"
        case "ass", "ssa": return "text/x-ssa"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    /// A parsed `Range` header against a known length: nil = whole file, .invalid = 416.
    enum RangeSpec: Equatable {
        case whole
        case range(Int64, Int64) // inclusive
        case unsatisfiable
    }

    static func parseRange(_ header: String?, length: Int64) -> RangeSpec {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return .whole }
        guard header.lowercased().hasPrefix("bytes="), length >= 0 else { return .whole }
        let spec = header.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let dash = spec.firstIndex(of: "-") else { return .whole }
        let a = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let b = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if a.isEmpty {
            guard let suffix = Int64(b), suffix > 0 else { return .unsatisfiable }
            if length == 0 { return .unsatisfiable }
            return .range(max(0, length - suffix), length - 1)
        }
        guard let start = Int64(a), start >= 0 else { return .whole }
        if start >= length { return .unsatisfiable }
        var end = length - 1
        if !b.isEmpty {
            guard let e = Int64(b), e >= start else { return .whole }
            end = min(e, length - 1)
        }
        return .range(start, end)
    }
}

/// Resumes a continuation once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private struct ConnectionClosed: Error {}
private struct ShortRead: Error {}

/// One client connection: reads requests one after the other (keep-alive), streams the bodies with
/// backpressure (the next chunk is read while the current one is sent; nothing more is buffered), and closes its
/// ByteSource when the connection ends.
private final class StreamConnection: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: MediaStreamServer?
    private let queue: DispatchQueue
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var lastActivity = Date()
    private var cancelled = false

    // The open source (reused while the client keeps asking for the same file).
    private var source: ByteSource?
    private var sourceKey: String?

    init(_ connection: NWConnection, server: MediaStreamServer, queue: DispatchQueue) {
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        task = Task { [weak self] in await self?.run() }
        Task { [weak self] in await self?.watchdog() }
    }

    func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        guard first else { return }
        connection.cancel()
        task?.cancel()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func touch() { lock.lock(); lastActivity = Date(); lock.unlock() }

    private func watchdog() async {
        while !isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            lock.lock(); let idle = Date().timeIntervalSince(lastActivity); lock.unlock()
            if idle > MediaStreamServer.idleTimeout { cancel() }
        }
    }

    private func run() async {
        var pending = Data()
        defer {
            source?.close()
            source = nil
            cancel()
            server?.finished(self)
        }
        do {
            while !isCancelled {
                // Headers end with an empty line.
                var headerEnd: Range<Data.Index>?
                while true {
                    headerEnd = pending.range(of: Data("\r\n\r\n".utf8))
                    if headerEnd != nil { break }
                    if pending.count > 32 * 1024 {
                        try await sendHead(status: "431 Request Header Fields Too Large", headers: ["Content-Length": "0", "Connection": "close"])
                        return
                    }
                    guard let d = try await receive() else { return }
                    pending.append(d)
                }
                let head = String(decoding: pending[pending.startIndex..<headerEnd!.lowerBound], as: UTF8.self)
                pending = Data(pending[headerEnd!.upperBound...])
                touch()
                var lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.removeFirst().split(separator: " ")
                var headers: [String: String] = [:]
                for l in lines {
                    guard let colon = l.firstIndex(of: ":") else { continue }
                    headers[l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                        l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                // Ignore (discard) any request body.
                if let cl = headers["content-length"].flatMap({ Int($0) }), cl > 0 {
                    while pending.count < cl { guard let d = try await receive() else { return }; pending.append(d) }
                    pending = Data(pending.dropFirst(cl))
                }
                guard requestLine.count >= 2 else {
                    try await sendHead(status: "400 Bad Request", headers: ["Content-Length": "0", "Connection": "close"])
                    return
                }
                let version = requestLine.count >= 3 ? String(requestLine[2]) : "HTTP/1.0"
                let connectionHeader = headers["connection"]?.lowercased() ?? ""
                var keepAlive = version == "HTTP/1.1" ? !connectionHeader.contains("close") : connectionHeader.contains("keep-alive")
                let keep = try await handle(method: String(requestLine[0]), target: String(requestLine[1]),
                                            headers: headers, keepAlive: keepAlive)
                keepAlive = keepAlive && keep
                touch()
                if !keepAlive { return }
            }
        } catch {
            // Client went away (VLC closes a connection when it seeks) or a read failed: just end.
        }
    }

    /// Answers one request; false = close the connection afterwards.
    private func handle(method: String, target: String, headers: [String: String], keepAlive: Bool) async throws -> Bool {
        let conn = keepAlive ? "keep-alive" : "close"
        guard method == "GET" || method == "HEAD" else {
            try await sendHead(status: "405 Method Not Allowed", headers: ["Allow": "GET, HEAD", "Content-Length": "0", "Connection": conn])
            return keepAlive
        }
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        guard let server, let entry = server.resolve(path: path) else {
            try await sendHead(status: "404 Not Found", headers: ["Content-Length": "0", "Connection": conn])
            return keepAlive
        }
        let src: ByteSource
        do {
            src = try await openSource(account: entry.account, fileId: entry.fileId)
        } catch {
            server.report(account: entry.account, fileId: entry.fileId, error: error)
            try await sendHead(status: "502 Bad Gateway", headers: ["Content-Length": "0", "Connection": "close"])
            return false
        }
        let length = src.length
        var h: [String: String] = ["Content-Type": entry.mime, "Cache-Control": "no-store"]
        if length < 0 {
            // Unknown length: no ranges; stream to the end and close.
            h["Connection"] = "close"
            try await sendHead(status: "200 OK", headers: h)
            if method == "GET" { try await streamBody(src, from: 0, count: nil, entry: entry) }
            return false
        }
        h["Accept-Ranges"] = "bytes"
        h["Connection"] = conn
        let status: String
        let start: Int64, count: Int64
        switch MediaStreamServer.parseRange(headers["range"], length: length) {
        case .whole:
            status = "200 OK"; start = 0; count = length
        case let .range(s, e):
            status = "206 Partial Content"; start = s; count = e - s + 1
            h["Content-Range"] = "bytes \(s)-\(e)/\(length)"
        case .unsatisfiable:
            h["Content-Range"] = "bytes */\(length)"
            h["Content-Length"] = "0"
            try await sendHead(status: "416 Range Not Satisfiable", headers: h)
            return keepAlive
        }
        h["Content-Length"] = String(count)
        try await sendHead(status: status, headers: h)
        if method == "GET" && count > 0 { try await streamBody(src, from: start, count: count, entry: entry) }
        return keepAlive
    }

    private func openSource(account: String, fileId: String) async throws -> ByteSource {
        let key = account + "\u{1F}" + fileId
        if let s = source, sourceKey == key { return s }
        source?.close()
        source = nil; sourceKey = nil
        let s = try await AppServices.storage.openRead(account, id: fileId)
        source = s; sourceKey = key
        return s
    }

    /// Sends `count` bytes from `start` (nil = to the end), reading the next chunk while the current one is sent.
    private func streamBody(_ src: ByteSource, from start: Int64, count: Int64?, entry: (account: String, fileId: String, mime: String)) async throws {
        var pos = start
        var remaining = count ?? Int64.max
        func readTask(_ at: Int64, _ n: Int) -> Task<Data, Error> { Task { try await src.read(at: at, count: n) } }
        var next: Task<Data, Error>? = readTask(pos, Int(min(Int64(MediaStreamServer.chunkSize), remaining)))
        do {
            while remaining > 0, let reading = next {
                let data: Data
                do { data = try await reading.value } catch {
                    next = nil
                    if !(error is CancellationError) && !isCancelled {
                        server?.report(account: entry.account, fileId: entry.fileId, error: error)
                    }
                    throw error
                }
                next = nil
                if data.isEmpty {
                    if count == nil { return }
                    throw ShortRead() // shorter than its length said: close, the client retries
                }
                pos += Int64(data.count)
                remaining -= Int64(data.count)
                if remaining > 0 { next = readTask(pos, Int(min(Int64(MediaStreamServer.chunkSize), remaining))) }
                try await send(data)
                touch()
            }
        } catch {
            // Never close the source under a read in flight.
            if let n = next { _ = try? await n.value }
            throw error
        }
    }

    // ---- NWConnection, async -------------------------------------------------------------------

    private func receive() async throws -> Data? {
        if isCancelled { throw ConnectionClosed() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if let error { cont.resume(throwing: error) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func send(_ data: Data) async throws {
        if isCancelled { throw ConnectionClosed() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func sendHead(status: String, headers: [String: String]) async throws {
        var s = "HTTP/1.1 \(status)\r\n"
        s += "Server: Veltoret\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        try await send(Data(s.utf8))
    }
}
