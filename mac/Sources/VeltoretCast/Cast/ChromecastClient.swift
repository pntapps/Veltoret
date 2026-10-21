import Foundation
import Network

public typealias CastJSON = [String: Any]

/// The receiver refused the video (LOAD_FAILED, LOAD_CANCELLED, INVALID_REQUEST).
public struct CastLoadError: Error, CustomStringConvertible, LocalizedError {
    public let code: String
    public init(code: String) { self.code = code }
    public var description: String { "The TV couldn't play this video (\(code))" }
    public var errorDescription: String? { description }
}

/// A hand-rolled Cast v2 sender: TLS to port 8009 (self-signed device certificate accepted, Network.framework),
/// length-prefixed protobuf `CastMessage`s, the connection / heartbeat / receiver / media namespaces, and the Default
/// Media Receiver (CC1AD845).
public final class ChromecastClient: @unchecked Sendable {
    public static let defaultMediaReceiver = "CC1AD845"
    private static let sender = "sender-0"
    private static let receiver = "receiver-0"

    private let conn: NetConnection
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<CastJSON, Error>] = [:]
    private var requestId = 0
    private var lastHeard = Date()
    private var closed = false
    private var loops: [Task<Void, Never>] = []
    private var _transportId: String?
    private var _sessionId: String?
    private var _onMediaStatus: ((CastJSON) -> Void)?
    private var _onReceiverStatus: ((CastJSON) -> Void)?
    private var _onClosed: (() -> Void)?

    /// The app session (after `launch()`).
    public var transportId: String? { lock.lock(); defer { lock.unlock() }; return _transportId }
    public var sessionId: String? { lock.lock(); defer { lock.unlock() }; return _sessionId }

    /// A MEDIA_STATUS message (the whole payload).
    public var onMediaStatus: ((CastJSON) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onMediaStatus }
        set { lock.withLock { _onMediaStatus = newValue } }
    }
    /// A RECEIVER_STATUS message (the whole payload).
    public var onReceiverStatus: ((CastJSON) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onReceiverStatus }
        set { lock.withLock { _onReceiverStatus = newValue } }
    }
    /// The connection dropped, the receiver app closed, or heartbeats stopped.
    public var onClosed: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onClosed }
        set { lock.withLock { _onClosed = newValue } }
    }

    private init(_ conn: NetConnection) { self.conn = conn }

    public static func connect(host: String, port: Int) async throws -> ChromecastClient {
        // Cast devices use self-signed certificates; sender-side device authentication is optional.
        let conn = try await NetConnection.connect(host: host, port: port, tls: true, timeoutMs: 8_000)
        let client = ChromecastClient(conn)
        client.begin()
        do {
            try await client.send(CastMessage.nsConnection, receiver, ["type": "CONNECT"])
        } catch {
            client.close()
            throw error
        }
        return client
    }

    private func begin() {
        let r = Task.detached { [weak self] in guard let self else { return }; await self.readLoop() }
        let h = Task.detached { [weak self] in guard let self else { return }; await self.heartbeatLoop() }
        lock.withLock { loops = [r, h] }
    }

    // ---- Receiver ------------------------------------------------------------------------------------

    /// Joins the Default Media Receiver if it is already running, else launches it; then connects to it.
    public func launch() async throws {
        var status = try await request(CastMessage.nsReceiver, Self.receiver, ["type": "GET_STATUS"])
        var app = Self.findApp(status)
        if app == nil {
            status = try await request(CastMessage.nsReceiver, Self.receiver,
                                       ["type": "LAUNCH", "appId": Self.defaultMediaReceiver], timeoutMs: 20_000)
            app = Self.findApp(status)
            // LAUNCH replies once the app is starting; its RECEIVER_STATUS may follow separately.
            var i = 0
            while app == nil && i < 20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                status = try await request(CastMessage.nsReceiver, Self.receiver, ["type": "GET_STATUS"])
                app = Self.findApp(status)
                i += 1
            }
        }
        guard let (transport, session) = app else { throw NetIOError("The TV didn't start the player") }
        lock.withLock { _transportId = transport; _sessionId = session }
        try await send(CastMessage.nsConnection, transport, ["type": "CONNECT"])
    }

    static func findApp(_ status: CastJSON) -> (String, String)? {
        guard let s = status["status"] as? CastJSON, let apps = s["applications"] as? [CastJSON] else { return nil }
        for app in apps where app["appId"] as? String == defaultMediaReceiver {
            if let t = app["transportId"] as? String, let sid = app["sessionId"] as? String {
                return t.isEmpty ? nil : (t, sid)
            }
        }
        return nil
    }

    /// Asks for RECEIVER_STATUS (volume); the answer comes through `onReceiverStatus`.
    public func receiverGetStatus() async throws {
        try await send(CastMessage.nsReceiver, Self.receiver, ["type": "GET_STATUS", "requestId": nextId()])
    }

    public func setVolume(_ level: Double) async throws {
        try await send(CastMessage.nsReceiver, Self.receiver,
                       ["type": "SET_VOLUME", "requestId": nextId(), "volume": ["level": min(max(level, 0), 1)]])
    }

    public func setMuted(_ muted: Bool) async throws {
        try await send(CastMessage.nsReceiver, Self.receiver, ["type": "SET_VOLUME", "requestId": nextId(), "volume": ["muted": muted]])
    }

    /// Stops the receiver app on the TV (stopReceiverApplicationWhenEndingSession).
    public func stopApp() async {
        if let session = sessionId, !session.isEmpty {
            try? await send(CastMessage.nsReceiver, Self.receiver, ["type": "STOP", "sessionId": session, "requestId": nextId()])
        }
    }

    // ---- Media ---------------------------------------------------------------------------------------

    /// Sends LOAD and waits for its MEDIA_STATUS, or throws `CastLoadError` (LOAD_FAILED …).
    public func load(_ build: (Int, String) -> CastJSON) async throws -> CastJSON {
        guard let transport = transportId else { throw NetIOError("Not launched") }
        let id = nextId()
        let payload = build(id, sessionId ?? "")
        let reply = try await requestWithId(CastMessage.nsMedia, transport, payload, id: id, timeoutMs: 60_000)
        let type = reply["type"] as? String
        if type == "LOAD_FAILED" || type == "LOAD_CANCELLED" || type == "INVALID_REQUEST" {
            let code = (reply["detailedErrorCode"] as? NSNumber).map { "\($0.intValue)" } ?? type!
            throw CastLoadError(code: code)
        }
        return reply
    }

    public func mediaCommand(_ type: String, mediaSessionId: Int64, extra: CastJSON? = nil) async throws {
        guard let transport = transportId else { throw NetIOError("Not launched") }
        var payload: CastJSON = ["type": type, "mediaSessionId": mediaSessionId, "requestId": nextId()]
        for (k, v) in extra ?? [:] { payload[k] = v }
        try await send(CastMessage.nsMedia, transport, payload)
    }

    public func mediaGetStatus() async throws {
        guard let transport = transportId else { throw NetIOError("Not launched") }
        try await send(CastMessage.nsMedia, transport, ["type": "GET_STATUS", "requestId": nextId()])
    }

    // ---- Plumbing ------------------------------------------------------------------------------------

    private func nextId() -> Int { lock.lock(); defer { lock.unlock() }; requestId += 1; return requestId }

    public func request(_ ns: String, _ destination: String, _ payload: CastJSON, timeoutMs: Int = 10_000) async throws -> CastJSON {
        let id = nextId()
        var p = payload
        p["requestId"] = id
        return try await requestWithId(ns, destination, p, id: id, timeoutMs: timeoutMs)
    }

    private func requestWithId(_ ns: String, _ destination: String, _ payload: CastJSON, id: Int, timeoutMs: Int) async throws -> CastJSON {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CastJSON, Error>) in
            lock.lock()
            if closed { lock.unlock(); cont.resume(throwing: NetIOError("The connection to the TV was lost")); return }
            pending[id] = cont
            lock.unlock()
            Task.detached { [weak self] in
                do { try await self?.send(ns, destination, payload) } catch { self?.fail(id, error) }
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                self?.fail(id, NetIOError("The TV didn't answer"))
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        let c = lock.withLock { pending.removeValue(forKey: id) }
        c?.resume(throwing: error)
    }

    public func send(_ ns: String, _ destination: String, _ payload: CastJSON) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        let frame = CastMessage(sourceId: Self.sender, destinationId: destination, namespace: ns,
                                payloadUtf8: String(decoding: data, as: UTF8.self)).frame()
        if isClosed { throw NetIOError("The connection to the TV was lost") }
        try await conn.send(frame)
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func readLoop() async {
        do {
            while !isClosed {
                let header = [UInt8](try await conn.receiveExactly(4))
                let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                if length < 0 || length > 1 << 20 { throw CastProtocolError("Bad frame") }
                let body = try await conn.receiveExactly(length)
                lock.withLock { lastHeard = Date() }
                let message = try CastMessage.decode(body)
                if let json = message.payloadUtf8 { await dispatch(message, json) }
            }
        } catch {
            // Dropped (or closed by us).
        }
        close()
    }

    private func dispatch(_ message: CastMessage, _ json: String) async {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)), let payload = obj as? CastJSON else { return }
        let type = payload["type"] as? String
        switch message.namespace {
        case CastMessage.nsHeartbeat:
            if type == "PING" { try? await send(CastMessage.nsHeartbeat, message.sourceId, ["type": "PONG"]) }
            return
        case CastMessage.nsConnection:
            // The receiver app (or the device) closed our virtual connection.
            if type == "CLOSE" && (message.sourceId == transportId || message.sourceId == Self.receiver) { close() }
            return
        default: break
        }
        if let rid = payload["requestId"] as? NSNumber, rid.intValue != 0 {
            let c = lock.withLock { pending.removeValue(forKey: rid.intValue) }
            c?.resume(returning: payload)
        }
        switch type {
        case "MEDIA_STATUS":
            onMediaStatus?(payload)
        case "RECEIVER_STATUS":
            onReceiverStatus?(payload)
            // Our app was stopped from elsewhere (another phone, the TV's remote).
            if transportId != nil && Self.findApp(payload) == nil { close() }
        default: break
        }
    }

    private func heartbeatLoop() async {
        do {
            while !isClosed {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                // Drop the connection after about 3 missed beats.
                let heard = lock.withLock { lastHeard }
                if Date().timeIntervalSince(heard) > 16 { break }
                try await send(CastMessage.nsHeartbeat, Self.receiver, ["type": "PING"])
            }
        } catch {}
        close()
    }

    private func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let waiting = Array(pending.values)
        pending.removeAll()
        let closedHandler = _onClosed
        let ls = loops
        lock.unlock()
        for c in waiting { c.resume(throwing: NetIOError("The connection to the TV was lost")) }
        conn.cancel()
        ls.forEach { $0.cancel() }
        closedHandler?()
    }

    /// Closes deliberately (CLOSE to the app and the device); `onClosed` isn't called.
    public func dispose() async {
        if !isClosed {
            if let t = transportId { try? await send(CastMessage.nsConnection, t, ["type": "CLOSE"]) }
            try? await send(CastMessage.nsConnection, Self.receiver, ["type": "CLOSE"])
        }
        onClosed = nil // a deliberate close isn't a drop
        close()
    }
}
