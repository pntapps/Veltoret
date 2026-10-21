import Foundation
import VeltoretKit

/// This Mac's half of "Play on TV" (Android TvLinkClient): finds Veltoret TVs on the network, pairs with the code
/// the TV shows, and sends signed requests over plain HTTP/1.1 sockets (WIRE §0.2).
public final class TvLinkClient: @unchecked Sendable {
    public let store: TvLinkStore
    private let phoneNameProvider: (() -> String)?

    public init(store: TvLinkStore, phoneName: (() -> String)? = nil) {
        self.store = store
        phoneNameProvider = phoneName
    }

    /// The name the TV shows while pairing.
    public var phoneName: String {
        if let n = phoneNameProvider?(), !n.isEmpty { return n }
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// Veltoret TVs as they're found (each answers /hello first) during `window`.
    public func find(window: TimeInterval) -> AsyncStream<LinkTv> {
        AsyncStream { continuation in
            let task = Task {
                var seen = Set<String>()
                for await service in Bonjour.browse(TvLinkProtocol.serviceType, window: window) {
                    guard let host = service.host, service.port != 0 else { continue }
                    guard let hello = try? await self.hello(host: host, port: service.port), !hello.id.isEmpty else { continue }
                    let key = "\(hello.id)|\(host)|\(service.port)"
                    if !seen.insert(key).inserted { continue }
                    continuation.yield(LinkTv(id: hello.id, name: hello.name, host: host, port: service.port,
                                              paired: self.store.secret(hello.id) != nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func hello(host: String, port: Int) async throws -> LinkHello {
        let reply = try await LinkHttp.exchange(host: host, port: port, method: "GET", path: "/hello", body: nil, headers: nil,
                                                connectTimeoutMs: 4_000, readTimeoutMs: 3_000)
        if reply.status != 200 { throw NetIOError("HTTP \(reply.status)") }
        return try LinkJson.decode(LinkHello.self, reply.body)
    }

    // ---- Pairing ------------------------------------------------------------------------------------

    /// Asks `tv` to show a pairing code. Throws `LinkError` when it can't.
    public func startPairing(_ tv: LinkTv) async throws {
        let reply = try await call(tv, "/pair/start", LinkPairStart(phoneId: store.deviceId, phoneName: phoneName), signed: false, timeoutMs: 8_000)
        if !reply.ok { throw LinkError(reply.message, code: reply.code) }
    }

    /// Sends a new secret sealed with `code`; on success the TV is remembered as paired.
    public func pair(_ tv: LinkTv, code: String) async throws {
        let hello: LinkHello
        do { hello = try await self.hello(host: tv.host, port: tv.port) }
        catch { throw LinkError("Couldn't reach \(tv.name). Check it's on and on the same Wi-Fi.") }
        let keys = PairingCrypto.newKeyPair()
        guard let salt = PairingCrypto.unb64(hello.salt), let tvKey = try? PairingCrypto.decodeKey(hello.tvKey) else {
            throw LinkError("\(tv.name) couldn't do that")
        }
        let key = try PairingCrypto.sessionKey(keys, tvKey, code: code.trimmingCharacters(in: .whitespacesAndNewlines), salt: salt)
        let secret = TvLinkProtocol.newSecret()
        let plain = LinkJson.encode(LinkPairSecret(phoneId: store.deviceId, phoneName: phoneName, secret: secret))
        let sealed = try PairingCrypto.seal(key, plain, aad: keys.publicSpki)
        let message = PairMessage(phoneKey: PairingCrypto.encodeKey(keys), iv: sealed.iv, data: sealed.data)
        let reply = try await call(tv, "/pair", message, signed: false, timeoutMs: 15_000)
        if !reply.ok { throw LinkError(reply.message, code: reply.code) }
        store.save(LinkPeer(id: hello.id, name: hello.name), secret: secret)
    }

    public func forget(_ tvId: String) { store.remove(tvId) }

    // ---- Playback -----------------------------------------------------------------------------------

    /// Plays `request`; returns where it plays from (`LinkStatus.sourceTv` or `sourcePhone`).
    public func play(_ tv: LinkTv, _ request: LinkPlay) async throws -> String {
        let reply = try await call(tv, "/play", request, signed: true, timeoutMs: 15_000)
        if !reply.ok { throw LinkError(reply.message, code: reply.code) }
        return reply.message
    }

    public func command(_ tv: LinkTv, _ command: LinkCommand) async throws {
        let reply = try await call(tv, "/command", command, signed: true, timeoutMs: 8_000)
        if !reply.ok { throw LinkError(reply.message, code: reply.code) }
    }

    public func status(_ tv: LinkTv) async throws -> LinkStatus {
        let body = try await request(tv, "/status", Data(), signed: true, timeoutMs: 5_000)
        do { return try LinkJson.decode(LinkStatus.self, body) }
        catch { throw LinkError("\(tv.name) couldn't do that") }
    }

    private func call(_ tv: LinkTv, _ path: String, _ value: LinkEncodable, signed: Bool, timeoutMs: Int) async throws -> LinkReply {
        let body = try await request(tv, path, LinkJson.encode(value), signed: signed, timeoutMs: timeoutMs)
        do { return try LinkJson.decode(LinkReply.self, body) }
        catch { throw LinkError("\(tv.name) couldn't do that") }
    }

    /// POSTs `body`; returns the response body, or throws `LinkError` with the TV's message.
    private func request(_ tv: LinkTv, _ path: String, _ body: Data, signed: Bool, timeoutMs: Int) async throws -> String {
        var headers: [(String, String)]?
        if signed {
            guard let secret = store.secret(tv.id) else { throw LinkError("Pair this Mac with \(tv.name) first", code: "unpaired") }
            let time = Self.nextTime()
            headers = [
                (TvLinkProtocol.headerPhone, store.deviceId),
                (TvLinkProtocol.headerTime, String(time)),
                (TvLinkProtocol.headerSignature, TvLinkProtocol.sign(secret: secret, method: "POST", path: path, time: time, body: body)),
            ]
        }
        let reply: LinkHttp.Reply
        do {
            reply = try await LinkHttp.exchange(host: tv.host, port: tv.port, method: "POST", path: path, body: body, headers: headers,
                                                connectTimeoutMs: 4_000, readTimeoutMs: timeoutMs)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LinkError("Couldn't reach \(tv.name). Check it's on and on the same Wi-Fi.")
        }
        if reply.status == 200 { return reply.body }
        let refused = LinkJson.tryDecode(LinkReply.self, reply.body)
        if refused?.code == "unpaired" { store.remove(tv.id) }
        let message = (refused?.message ?? "").isEmpty ? "\(tv.name) couldn't do that (HTTP \(reply.status))" : refused!.message
        throw LinkError(message, code: refused?.code)
    }

    private static let timeLock = NSLock()
    nonisolated(unsafe) private static var lastTime: Int64 = 0

    /// A fresh millisecond per request: the TV refuses a signature it has seen (replay protection).
    private static func nextTime() -> Int64 {
        timeLock.lock(); defer { timeLock.unlock() }
        let next = max(nowMillis(), lastTime + 1)
        lastTime = next
        return next
    }
}
