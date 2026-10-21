import CryptoKit
import Foundation

/// Constants and request signing of "Play on TV" (Android TvLink object, WIRE).
public enum TvLinkProtocol {
    public static let serviceType = "_veltoret-play._tcp"
    public static let version = 1
    public static let streamScheme = "vlink"
    public static let headerPhone = "X-Veltoret-Phone"
    public static let headerTime = "X-Veltoret-Time"
    public static let headerSignature = "X-Veltoret-Signature"
    public static let maxSkewMs: Int64 = 5 * 60_000

    public static func newSecret() -> String { PairingCrypto.b64(PairingCrypto.randomBytes(32)) }

    /// Base64(HMAC-SHA256(secret, UTF8("{method} {path} {time}\n") || body)).
    public static func sign(secret: String, method: String, path: String, time: Int64, body: Data) -> String {
        let data = Data("\(method) \(path) \(time)\n".utf8) + body
        let key = SymmetricKey(data: PairingCrypto.unb64(secret) ?? Data())
        return PairingCrypto.b64(Data(HMAC<SHA256>.authenticationCode(for: data, using: key)))
    }

    /// Constant-time check of `signature`, within `maxSkewMs` of `now`.
    public static func verify(secret: String, method: String, path: String, time: Int64, body: Data, signature: String, now: Int64) -> Bool {
        if abs(now - time) > maxSkewMs { return false }
        let expected = Array(sign(secret: secret, method: method, path: path, time: time, body: body).utf8)
        let given = Array(signature.utf8)
        if expected.count != given.count { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= expected[i] ^ given[i] }
        return diff == 0
    }

    /// "vlink://host:port/token/id" for "http://host:port/token/id".
    public static func streamUrl(_ httpUrl: String) -> String {
        streamScheme + (httpUrl.hasPrefix("http") ? String(httpUrl.dropFirst(4)) : httpUrl)
    }

    public static func isStream(_ fileId: String) -> Bool { fileId.hasPrefix(streamScheme + "://") }
}
