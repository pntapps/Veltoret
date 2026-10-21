import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A fresh P-256 key pair for one pairing attempt. `publicSpki` is the X.509 SubjectPublicKeyInfo DER (named
/// curve, uncompressed point, 91 bytes): what goes on the wire, and the AAD when sealing.
public final class PairingKeys: @unchecked Sendable {
    let privateKey: P256.KeyAgreement.PrivateKey
    public let publicSpki: Data

    init(_ privateKey: P256.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
        publicSpki = privateKey.publicKey.derRepresentation
    }
}

public struct PairingCryptoError: Error, CustomStringConvertible {
    public let description: String
}

/// Port of Android's PairingCrypto (WIRE): shared by "Play on TV" pairing and "Send to TV". CryptoKit + CommonCrypto.
public enum PairingCrypto {
    static let codeIterations: UInt32 = 120_000
    static let info = "veltoret-send-to-tv-v1"

    public struct Sealed: Hashable, Sendable {
        public var iv: String
        public var data: String
        public init(iv: String, data: String) { self.iv = iv; self.data = data }
    }

    public static func newKeyPair() -> PairingKeys { PairingKeys(P256.KeyAgreement.PrivateKey()) }

    /// Uniform over 100000...999999 (TV side; used by tests).
    public static func newCode() -> String { String(Int.random(in: 100_000...999_999)) }

    public static func newSalt() -> Data { randomBytes(16) }

    /// Base64(18 random bytes), URL-safe: 24 chars, no padding.
    public static func newToken() -> String {
        b64(randomBytes(18)).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    public static func encodeKey(_ keys: PairingKeys) -> String { b64(keys.publicSpki) }

    /// Decodes a Base64 SPKI public key (the TV's tvKey or a phone's phoneKey).
    public static func decodeKey(_ text: String) throws -> P256.KeyAgreement.PublicKey {
        guard let der = unb64(text) else { throw PairingCryptoError(description: "Bad key") }
        return try P256.KeyAgreement.PublicKey(derRepresentation: der)
    }

    /// HMAC-SHA256(PBKDF2-SHA256(code, salt, 120000, 32), rawEcdhX || "veltoret-send-to-tv-v1"): the AES-256 key
    /// both sides arrive at.
    public static func sessionKey(_ own: PairingKeys, _ other: P256.KeyAgreement.PublicKey, code: String, salt: Data) throws -> Data {
        let shared = try own.privateKey.sharedSecretFromKeyAgreement(with: other)
        let raw = shared.withUnsafeBytes { Data($0) }
        let stretched = pbkdf2(Data(code.utf8), salt: salt, iterations: codeIterations, length: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: raw + Data(info.utf8), using: SymmetricKey(data: stretched))
        return Data(mac)
    }

    static func pbkdf2(_ password: Data, salt: Data, iterations: UInt32, length: Int) -> Data {
        var out = [UInt8](repeating: 0, count: length)
        let pw = [Int8](password.map { Int8(bitPattern: $0) })
        let s = [UInt8](salt)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, s, s.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &out, length)
        return Data(out)
    }

    /// AES-256-GCM, 12-byte random nonce, 16-byte tag appended to the ciphertext (as Java does).
    public static func seal(_ key: Data, _ plain: Data, aad: Data) throws -> Sealed {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
        return Sealed(iv: b64(Data(nonce)), data: b64(box.ciphertext + box.tag))
    }

    /// Nil when the key is wrong (a wrong code) or the message was changed.
    public static func open(_ key: Data, _ sealed: Sealed, aad: Data) -> Data? {
        guard let iv = unb64(sealed.iv), let data = unb64(sealed.data), data.count >= 16 else { return nil }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data.prefix(data.count - 16),
                                            tag: data.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            return nil
        }
    }

    public static func b64(_ bytes: Data) -> String { bytes.base64EncodedString() }
    public static func unb64(_ text: String) -> Data? { Data(base64Encoded: text) }
}
