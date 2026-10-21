import Foundation

/// GET /pair on a TV showing "Use your phone" (WIRE).
public struct PairOffer: Decodable, Hashable, Sendable {
    public var tvKey = ""
    public var salt = ""
    public var name = ""
    enum CodingKeys: String, CodingKey { case tvKey, salt, name }
    public init(tvKey: String = "", salt: String = "", name: String = "") { self.tvKey = tvKey; self.salt = salt; self.name = name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tvKey = c.value(.tvKey, ""); salt = c.value(.salt, ""); name = c.value(.name, "")
    }
}

/// POST /pair (and TvLink /pair): the sealed message (WIRE).
public struct PairMessage: Decodable, Hashable, Sendable, LinkEncodable {
    public var phoneKey = ""
    public var iv = ""
    public var data = ""
    enum CodingKeys: String, CodingKey { case phoneKey, iv, data }
    public init(phoneKey: String = "", iv: String = "", data: String = "") { self.phoneKey = phoneKey; self.iv = iv; self.data = data }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phoneKey = c.value(.phoneKey, ""); iv = c.value(.iv, ""); data = c.value(.data, "")
    }
    public var linkFields: [(String, Any?)] { [("phoneKey", phoneKey), ("iv", iv), ("data", data)] }
}

/// A saved network server handed to the TV (WIRE). Never log or persist it.
public struct PhoneSubmission: Hashable, Sendable, LinkEncodable {
    public var address = ""
    public var guest = false
    public var username = ""
    public var password = ""
    public var name: String?
    public init(address: String = "", guest: Bool = false, username: String = "", password: String = "", name: String? = nil) {
        self.address = address; self.guest = guest; self.username = username; self.password = password; self.name = name
    }
    public var linkFields: [(String, Any?)] {
        [("address", address), ("guest", guest), ("username", username), ("password", password), ("name", name)]
    }
}

public struct SetupReply: Decodable, Hashable, Sendable {
    public var ok = false
    public var message = ""
    enum CodingKeys: String, CodingKey { case ok, message }
    public init(ok: Bool = false, message: String = "") { self.ok = ok; self.message = message }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.value(.ok, false); message = c.value(.message, "")
    }
}

/// A TV showing Veltoret's "Use your phone" panel.
public struct FoundTv: Hashable, Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public init(name: String, host: String, port: Int) { self.name = name; self.host = host; self.port = port }
}

/// "Send to TV" (Android SendToTv): finds TVs showing "Use your phone" and sends one saved network server,
/// sealed with the code the TV shows. This Mac plays the phone's part.
public enum SendToTv {
    public static let serviceType = "_veltoret._tcp"

    /// TVs as they answer (one entry per host; a newer answer replaces an older one). Search ~8 s before showing
    /// "No TV found".
    public static func find(window: TimeInterval) -> AsyncStream<FoundTv> {
        AsyncStream { continuation in
            let task = Task {
                for await service in Bonjour.browse(serviceType, window: window) {
                    guard let host = service.host, service.port != 0 else { continue }
                    if let offer = try? await offer(host: host, port: service.port, timeoutMs: 3_000) {
                        continuation.yield(FoundTv(name: offer.name, host: host, port: service.port))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func offer(host: String, port: Int, timeoutMs: Int) async throws -> PairOffer {
        let reply = try await LinkHttp.exchange(host: host, port: port, method: "GET", path: "/pair", body: nil, headers: nil,
                                                connectTimeoutMs: timeoutMs, readTimeoutMs: timeoutMs)
        if reply.status != 200 { throw NetIOError("HTTP \(reply.status)") }
        return try LinkJson.decode(PairOffer.self, reply.body)
    }

    /// Sends `submission`; the TV's answer, or a sentence about what went wrong.
    public static func send(_ tv: FoundTv, code: String, submission: PhoneSubmission) async -> SetupReply {
        let offer: PairOffer
        do {
            offer = try await self.offer(host: tv.host, port: tv.port, timeoutMs: 5_000)
        } catch {
            return SetupReply(ok: false, message: "Couldn't reach the TV. Check it's on the same Wi-Fi and still showing \"Use your phone\".")
        }
        do {
            let keys = PairingCrypto.newKeyPair()
            guard let salt = PairingCrypto.unb64(offer.salt) else { throw PairingCryptoError(description: "Bad salt") }
            let key = try PairingCrypto.sessionKey(keys, try PairingCrypto.decodeKey(offer.tvKey),
                                                   code: code.trimmingCharacters(in: .whitespacesAndNewlines), salt: salt)
            let sealed = try PairingCrypto.seal(key, LinkJson.encode(submission), aad: keys.publicSpki)
            let message = PairMessage(phoneKey: PairingCrypto.encodeKey(keys), iv: sealed.iv, data: sealed.data)
            // The TV answers only after trying the server, which can take up to a minute.
            let reply = try await LinkHttp.exchange(host: tv.host, port: tv.port, method: "POST", path: "/pair",
                                                    body: LinkJson.encode(message), headers: nil,
                                                    connectTimeoutMs: 5_000, readTimeoutMs: 75_000)
            return try LinkJson.decode(SetupReply.self, reply.body)
        } catch {
            return SetupReply(ok: false, message: "The TV stopped answering. Check it's still showing \"Use your phone\" and try again.")
        }
    }

    /// The username the TV expects: "domain\user" when there is a domain.
    public static func username(domain: String, user: String) -> String { domain.isEmpty ? user : domain + "\\" + user }
}
