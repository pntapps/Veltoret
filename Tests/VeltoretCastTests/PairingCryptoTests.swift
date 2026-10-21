import CryptoKit
import XCTest
@testable import VeltoretCast

/// Port of the Windows PairingCryptoTest.
final class PairingCryptoTests: XCTestCase {
    private let message = Data("{\"host\":\"192.168.0.10\",\"username\":\"me\",\"password\":\"p@ss w'rd\"}".utf8)

    func testPhoneAndTvAgreeOnTheKeyAndTheMessageArrives() throws {
        let tv = PairingCrypto.newKeyPair()
        let phone = PairingCrypto.newKeyPair()
        let salt = PairingCrypto.newSalt()
        let code = PairingCrypto.newCode()
        // Keys travel as text, like over the network.
        let tvSeesPhone = try PairingCrypto.decodeKey(PairingCrypto.encodeKey(phone))
        let phoneSeesTv = try PairingCrypto.decodeKey(PairingCrypto.encodeKey(tv))

        let phoneKey = try PairingCrypto.sessionKey(phone, phoneSeesTv, code: code, salt: salt)
        let tvKey = try PairingCrypto.sessionKey(tv, tvSeesPhone, code: code, salt: salt)
        XCTAssertEqual(phoneKey, tvKey)
        XCTAssertEqual(phoneKey.count, 32)

        let aad = phone.publicSpki
        let sealed = try PairingCrypto.seal(phoneKey, message, aad: aad)
        XCTAssertEqual(PairingCrypto.open(tvKey, sealed, aad: aad), message)
        // 12-byte nonce; ciphertext || 16-byte tag.
        XCTAssertEqual(Data(base64Encoded: sealed.iv)!.count, 12)
        XCTAssertEqual(Data(base64Encoded: sealed.data)!.count, message.count + 16)
    }

    func testAWrongCodeCannotOpenIt() throws {
        let tv = PairingCrypto.newKeyPair()
        let phone = PairingCrypto.newKeyPair()
        let salt = PairingCrypto.newSalt()
        let tvPublic = try PairingCrypto.decodeKey(PairingCrypto.encodeKey(tv))
        let phonePublic = try PairingCrypto.decodeKey(PairingCrypto.encodeKey(phone))
        let sealed = try PairingCrypto.seal(try PairingCrypto.sessionKey(phone, tvPublic, code: "123456", salt: salt), message, aad: phone.publicSpki)
        XCTAssertNil(PairingCrypto.open(try PairingCrypto.sessionKey(tv, phonePublic, code: "123457", salt: salt), sealed, aad: phone.publicSpki))
    }

    func testAnotherKeyPairCannotOpenIt() throws {
        let tv = PairingCrypto.newKeyPair()
        let phone = PairingCrypto.newKeyPair()
        let eavesdropper = PairingCrypto.newKeyPair()
        let salt = PairingCrypto.newSalt()
        let tvPublic = try PairingCrypto.decodeKey(PairingCrypto.encodeKey(tv))
        let phonePublic = try PairingCrypto.decodeKey(PairingCrypto.encodeKey(phone))
        let sealed = try PairingCrypto.seal(try PairingCrypto.sessionKey(phone, tvPublic, code: "123456", salt: salt), message, aad: phone.publicSpki)
        XCTAssertNil(PairingCrypto.open(try PairingCrypto.sessionKey(eavesdropper, phonePublic, code: "123456", salt: salt), sealed, aad: phone.publicSpki))
    }

    func testCodesAndTokensLookRight() {
        for _ in 0..<50 {
            let code = PairingCrypto.newCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isNumber })
        }
        let token = PairingCrypto.newToken()
        XCTAssertEqual(token.count, 24)
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
    }

    func testPublicKeysAreNamedCurveSpki() {
        let keys = PairingCrypto.newKeyPair()
        // 91 bytes: SEQUENCE { AlgorithmIdentifier { id-ecPublicKey, prime256v1 }, BIT STRING 04 || X || Y }.
        let spki = [UInt8](keys.publicSpki)
        XCTAssertEqual(spki.count, 91)
        XCTAssertEqual(spki[0], 0x30)
        XCTAssertEqual(spki[26], 0x04)
        let prefix: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A, 0x86,
                               0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        XCTAssertEqual(Array(spki[..<26]), prefix)
    }

    /// Cross-check against an independent derivation of the same steps (raw ECDH X, PBKDF2-SHA256 120000, HMAC with
    /// the INFO string), so a change to any parameter is caught.
    func testSessionKeyIsTheDocumentedConstruction() throws {
        let a = P256.KeyAgreement.PrivateKey()
        let b = P256.KeyAgreement.PrivateKey()
        let salt = Data((1...16).map { UInt8($0) })
        let raw = try a.sharedSecretFromKeyAgreement(with: b.publicKey).withUnsafeBytes { Data($0) }
        XCTAssertEqual(raw.count, 32)
        let stretched = PairingCrypto.pbkdf2(Data("654321".utf8), salt: salt, iterations: 120_000, length: 32)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: raw + Data("veltoret-send-to-tv-v1".utf8), using: SymmetricKey(data: stretched)))

        let actual = try PairingCrypto.sessionKey(PairingKeys(a), PairingCrypto.decodeKey(b.publicKey.derRepresentation.base64EncodedString()),
                                                  code: "654321", salt: salt)
        XCTAssertEqual(actual, expected)
    }

    /// PBKDF2-HMAC-SHA256 against the RFC 7914 test vector, so CommonCrypto is called right.
    func testPbkdf2KnownVector() {
        let out = PairingCrypto.pbkdf2(Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, length: 64)
        XCTAssertEqual(out.map { String(format: "%02x", $0) }.joined(),
                       "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }
}
