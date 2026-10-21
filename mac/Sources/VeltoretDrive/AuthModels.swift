import Foundation
import CryptoKit
import Security

/// Thrown when an account's Drive access can't be refreshed silently and the user must sign in again.
public struct AuthRequiredError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let email: String
    public init(email: String) { self.email = email }
    public var message: String { "Google account \(email) needs to be reconnected" }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The imported OAuth client was refused by Google (wrong type, deleted, or never set up).
public struct GoogleSetupError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A Google client file the user picked can't be used. `message` is for the user (C# FormatException).
public struct ClientFileError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Why connecting a Google account failed (Android: ConnectError). Settings shows "{title}. {message}".
/// `setupProblem` means the fix is in Google Cloud / the imported client, not a retry.
public struct ConnectError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public let title: String
    public let message: String
    public let setupProblem: Bool
    public let underlying: Error?

    public init(title: String, message: String, setupProblem: Bool, underlying: Error? = nil) {
        self.title = title; self.message = message; self.setupProblem = setupProblem; self.underlying = underlying
    }

    public var errorDescription: String? { message }
    public var description: String { "\(title). \(message)" }

    public static func notGranted() -> ConnectError {
        ConnectError(title: "Google didn't grant access",
                     message: "If you closed the Google screen, just try again. If Google showed \"Access blocked\" or an error like 400 / 401 / 403, " +
                         "this copy of the app isn't registered with Google Cloud yet.", setupProblem: true)
    }

    public static func notSetUp() -> ConnectError {
        ConnectError(title: "Google sign-in isn't set up for this build",
                     message: "Google doesn't recognise this app yet. Create a Desktop app OAuth client in Google Cloud and import its client file in Settings, then try again.",
                     setupProblem: true)
    }

    public static func noConnection(_ underlying: Error? = nil) -> ConnectError {
        ConnectError(title: "No connection", message: "Check your internet connection and try again.", setupProblem: false,
                     underlying: underlying)
    }

    public static func cancelled() -> ConnectError {
        ConnectError(title: "Sign-in cancelled", message: "Click Connect to try again.", setupProblem: false)
    }

    public static func failed(_ message: String?, status: Int? = nil) -> ConnectError {
        let text = (message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? "Google sign-in failed." : message!
        return ConnectError(title: "Couldn't connect", message: text + (status.map { " (code \($0))" } ?? ""),
                            setupProblem: status == nil)
    }

    public static func driveFailed(_ message: String?, _ underlying: Error? = nil) -> ConnectError {
        let text = (message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? "Google Drive didn't respond. Check your connection and try again." : message!
        return ConnectError(title: "Couldn't open your Drive", message: text, setupProblem: false, underlying: underlying)
    }
}

/// A "Desktop app" OAuth client the user created in Google Cloud and imported.
public struct OAuthClient: Codable, Hashable, Sendable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId; self.clientSecret = clientSecret
    }

    /// Reads Google's downloaded client file (`{"installed": {"client_id": …, "client_secret": …}}`).
    /// Throws `ClientFileError` with a message for the user when it isn't a Desktop client file.
    public static func parse(_ json: String) throws -> OAuthClient {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ClientFileError("That isn't a Google OAuth client file.")
        }
        guard let root = any as? [String: Any] else { throw ClientFileError("That isn't a Google OAuth client file.") }
        if root["web"] != nil {
            throw ClientFileError("This is a Web application client. Create a Desktop app client in Google Cloud and import its file instead.")
        }
        let section = (root["installed"] as? [String: Any]) ?? root
        let id = (section["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = (section["client_secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id.isEmpty || !id.lowercased().hasSuffix(".apps.googleusercontent.com") {
            throw ClientFileError("That isn't a Google OAuth client file.")
        }
        if secret.isEmpty { throw ClientFileError("The client file has no client secret. Download it again from Google Cloud.") }
        return OAuthClient(clientId: id, clientSecret: secret)
    }

    /// "1234…abcd.apps.googleusercontent.com" — enough to recognise it, not to copy it from a screenshot.
    public var maskedId: String {
        let suffix = ".apps.googleusercontent.com"
        let hasSuffix = clientId.lowercased().hasSuffix(suffix)
        let core = hasSuffix ? String(clientId.dropLast(suffix.count)) : clientId
        let masked = core.count <= 10 ? core : String(core.prefix(6)) + "…" + String(core.suffix(4))
        return masked + (hasSuffix ? suffix : "")
    }
}

/// PKCE (RFC 7636) and state values for the loopback flow.
public enum Pkce {
    public static func base64Url(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator()
            for i in 0..<n { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        }
        return Data(bytes)
    }

    /// 32 random bytes, base64url: 43 characters from [A-Za-z0-9-_].
    public static func createVerifier() -> String { base64Url(randomBytes(32)) }

    public static func createState() -> String { base64Url(randomBytes(32)) }

    /// S256: base64url(SHA256(ASCII(verifier))), no padding.
    public static func challenge(_ verifier: String) -> String {
        base64Url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}
