import Foundation
import AppKit
import CryptoKit
import VeltoretKit

/// Google sign-in for Drive (Android: GoogleAuthManager + AccountConnector), as an OAuth 2.0 installed-app flow:
/// the system browser, a loopback redirect and PKCE. The user brings their own "Desktop app" OAuth client.
///
/// Refresh tokens are stored per account in the Keychain (`SecretStoring`); access tokens live only in memory,
/// cached for at most 45 minutes like on Android. Only one scope is asked for: full Drive. The account's email,
/// name and photo come from Drive's "about".
public final class GoogleAuthService: TokenProvider, @unchecked Sendable {
    public static let driveScope = "https://www.googleapis.com/auth/drive"
    static let clientSecretName = "google-client"
    private static let tokenTtl: TimeInterval = 45 * 60
    private static let signInTimeout: TimeInterval = 5 * 60

    private let http: HttpTransport
    private let secrets: SecretStoring
    private let accounts: AccountDao?
    private let lock = NSLock()
    private var cache: [String: (token: String, expiresAt: Date)] = [:]
    private let refreshLock = AsyncMutex()

    public var authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public var tokenEndpoint = "https://oauth2.googleapis.com/token"
    public var aboutUrl =
        "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress,photoLink),storageQuota(limit,usage)"

    /// Opens the Google sign-in page. Default: the default browser.
    public var openBrowser: (String) throws -> Void = { url in
        guard let u = URL(string: url) else { throw DriveIOError("Bad sign-in address") }
        let opened: Bool = Thread.isMainThread
            ? NSWorkspace.shared.open(u)
            : DispatchQueue.main.sync { NSWorkspace.shared.open(u) }
        if !opened { throw DriveIOError("No web browser answered") }
    }

    public var now: () -> Date = { Date() }

    /// Raised when an account's grant was refused and it has to be connected again (email).
    public let reconnectNeeded = Event<String>()
    /// Raised when the imported client or the stored sign-ins change.
    public let changed = Event<Void>()

    public init(http: HttpTransport, secrets: SecretStoring, accounts: AccountDao?) {
        self.http = http
        self.secrets = secrets
        self.accounts = accounts
    }

    private static func key(_ email: String) -> String { email.lowercased() }

    // MARK: - OAuth client

    public var client: OAuthClient? {
        guard let data = secrets.get(Self.clientSecretName) else { return nil }
        return try? JSONDecoder().decode(OAuthClient.self, from: data)
    }

    public var hasClient: Bool { client != nil }

    /// Imports Google's downloaded client file. Throws `ClientFileError` with a user-facing message.
    public func importClientJson(_ url: URL) throws {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch { throw ClientFileError("Couldn't read that file.") }
        try setClient(OAuthClient.parse(text))
    }

    public func setClient(_ client: OAuthClient) throws {
        try secrets.set(Self.clientSecretName, JSONEncoder().encode(client))
        lock.lock(); cache.removeAll(); lock.unlock()
        changed.fire()
    }

    public func removeClient() {
        secrets.delete(Self.clientSecretName)
        lock.lock(); cache.removeAll(); lock.unlock()
        changed.fire()
    }

    // MARK: - Sign-in

    private struct TimedOut: Error {}

    /// Runs the browser sign-in and adds (or refreshes) the account. `loginHint` reconnects that account.
    /// Throws `ConnectError` for every failure, including cancellation (Swift task cancellation).
    public func signIn(loginHint: String? = nil) async throws -> AccountEntity {
        guard let client else { throw ConnectError.notSetUp() }

        let verifier = Pkce.createVerifier()
        let code: String
        let redirectUri: String
        do {
            let receiver = try LoopbackReceiver()
            defer { receiver.close() }
            redirectUri = receiver.redirectUri
            let state = Pkce.createState()
            let url = authorizationUrl(clientId: client.clientId, redirectUri: redirectUri,
                                       challenge: Pkce.challenge(verifier), state: state, loginHint: loginHint)
            do { try openBrowser(url) } catch {
                throw ConnectError.failed("Couldn't open your web browser: " + Self.text(error))
            }
            let query = try await Self.withTimeout(Self.signInTimeout) {
                try await receiver.waitForRedirect { q in Self.resultPage(q, state) }
            }
            code = try Self.checkRedirect(query, expectedState: state)
        } catch let e as ConnectError {
            throw e
        } catch is TimedOut {
            // The browser was left open for 5 minutes without an answer.
            throw ConnectError.notGranted()
        } catch is CancellationError {
            throw ConnectError.cancelled()
        } catch let e as LoopbackReceiver.SocketError {
            throw ConnectError.failed("Couldn't listen for Google's answer on this Mac: " + e.message)
        }
        if Task.isCancelled { throw ConnectError.cancelled() }

        let tokens = try await exchangeCode(client, code: code, redirectUri: redirectUri, verifier: verifier)
        if let scope = tokens.scope, !scope.split(separator: " ").contains(Substring(Self.driveScope)) {
            throw ConnectError.notGranted()
        }
        guard let access = tokens.access_token, !access.isEmpty else {
            throw ConnectError.failed("Google didn't return an access token.")
        }

        let user: AboutUser
        do {
            user = try await fetchUser(access)
        } catch is CancellationError {
            throw ConnectError.cancelled()
        } catch let e as DriveIOError {
            throw ConnectError.driveFailed(e.message, e)
        } catch {
            throw ConnectError.driveFailed(Self.text(error), error)
        }

        guard let email = user.emailAddress, !email.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConnectError.driveFailed("Google Drive didn't say which account this is.")
        }
        if let loginHint, email.lowercased() != loginHint.lowercased() {
            throw ConnectError(title: "Couldn't connect",
                               message: "You signed in as \(email), not \(loginHint). Pick \(loginHint) on the Google screen to reconnect it.",
                               setupProblem: false)
        }

        guard let refresh = tokens.refresh_token ?? readStored(email)?.refreshToken, !refresh.isEmpty else {
            throw ConnectError.failed("Google didn't allow offline access. Try again.")
        }
        store(email, StoredGrant(email: email, refreshToken: refresh, scope: tokens.scope ?? Self.driveScope,
                                 savedAt: Self.millis(now())))
        remember(email, token: access, expiresInSeconds: tokens.expires_in)

        let displayName = (user.displayName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            ? String(email.split(separator: "@").first ?? Substring(email)) : user.displayName!
        var account = AccountEntity(email: email, displayName: displayName, photoUrl: user.photoLink,
                                    addedAt: Self.millis(now()))
        if let accounts {
            do {
                if let existing = try accounts.accounts().first(where: { $0.email.lowercased() == email.lowercased() }) {
                    account.email = existing.email
                    account.addedAt = existing.addedAt
                }
                try accounts.upsert(account)
            } catch {
                throw ConnectError.failed("Couldn't save the account: " + Self.text(error))
            }
        }
        changed.fire()
        return account
    }

    public func authorizationUrl(clientId: String, redirectUri: String, challenge: String, state: String, loginHint: String?) -> String {
        var q: [(String, String)] = [
            ("client_id", clientId),
            ("redirect_uri", redirectUri),
            ("response_type", "code"),
            ("scope", Self.driveScope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("access_type", "offline"),
            ("prompt", "consent select_account"),
            ("include_granted_scopes", "true"),
        ]
        if let loginHint, !loginHint.isEmpty { q.append(("login_hint", loginHint)) }
        return authEndpoint + "?" + q.map { $0.0 + "=" + UrlEncoding.escape($0.1) }.joined(separator: "&")
    }

    /// Returns the authorization code, or throws when the redirect is an error or isn't ours.
    public static func checkRedirect(_ query: [String: String], expectedState: String) throws -> String {
        guard let state = query["state"], constantTimeEquals(Array(state.utf8), Array(expectedState.utf8)) else {
            throw ConnectError.failed("Google's answer didn't match this sign-in. Try again.")
        }
        if let error = query["error"] {
            if error == "access_denied" { throw ConnectError.notGranted() }
            throw ConnectError.failed("Google sign-in failed (\(error)).")
        }
        guard let code = query["code"], !code.isEmpty else { throw ConnectError.notGranted() }
        return code
    }

    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private static func resultPage(_ query: [String: String], _ state: String) -> String {
        let ok = query["code"] != nil && query["state"] == state
        return ok
            ? LoopbackReceiver.page("Veltoret is connected", "You can close this tab and go back to the app.")
            : LoopbackReceiver.page("Veltoret didn't get access", "You can close this tab and go back to the app to try again.")
    }

    private func formRequest(_ pairs: [(String, String)]) -> URLRequest {
        var r = URLRequest(url: URL(string: tokenEndpoint)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = UrlEncoding.form(pairs)
        r.timeoutInterval = 60
        return r
    }

    private func exchangeCode(_ client: OAuthClient, code: String, redirectUri: String, verifier: String) async throws -> TokenResponse {
        let request = formRequest([
            ("code", code),
            ("client_id", client.clientId),
            ("client_secret", client.clientSecret),
            ("redirect_uri", redirectUri),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ])
        let response: HttpResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError {
            throw ConnectError.cancelled()
        } catch {
            throw ConnectError.noConnection(error)
        }
        if response.isSuccess {
            guard let t = try? JSONDecoder().decode(TokenResponse.self, from: response.body) else {
                throw ConnectError.failed("Google sent an empty answer.")
            }
            return t
        }
        let err = Self.parseError(response.body)
        if ["invalid_client", "unauthorized_client", "redirect_uri_mismatch"].contains(err.error ?? "") { throw ConnectError.notSetUp() }
        if err.error == "access_denied" { throw ConnectError.notGranted() }
        throw ConnectError.failed(err.description ?? err.error, status: response.status)
    }

    private func fetchUser(_ accessToken: String) async throws -> AboutUser {
        var request = URLRequest(url: URL(string: aboutUrl)!)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let response = try await http.send(request)
        if !response.isSuccess {
            throw DriveIOError("Google Drive refused to open (HTTP \(response.status)). Check that the Google Drive API is enabled for your Google Cloud project.")
        }
        if response.body.isEmpty { return AboutUser() }
        let about = try JSONDecoder().decode(AboutResponse.self, from: response.body)
        return about.user ?? AboutUser()
    }

    // MARK: - Tokens

    /// A valid access token for the account, refreshed silently when needed.
    public func accessToken(_ email: String) async throws -> String {
        if let t = cached(email) { return t }
        return try await refreshLock.run {
            if let t = cached(email) { return t }
            return try await refresh(email)
        }
    }

    private func cached(_ email: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[Self.key(email)], c.expiresAt > now() { return c.token }
        return nil
    }

    private func refresh(_ email: String) async throws -> String {
        guard let grant = readStored(email) else { throw AuthRequiredError(email: email) }
        guard let client else { throw GoogleSetupError("Google sign-in isn't set up for this build") }

        let request = formRequest([
            ("client_id", client.clientId),
            ("client_secret", client.clientSecret),
            ("refresh_token", grant.refreshToken),
            ("grant_type", "refresh_token"),
        ])
        let response: HttpResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DriveIOError("Could not authorize \(email): \(Self.text(error))")
        }
        if !response.isSuccess {
            let err = Self.parseError(response.body)
            if err.error == "invalid_grant" {
                // Revoked, expired (Testing-mode 7-day tokens), or the password changed: sign in again.
                secrets.delete(Self.secretNameFor(email))
                lock.withLock { cache[Self.key(email)] = nil }
                reconnectNeeded.fire(email)
                changed.fire()
                throw AuthRequiredError(email: email)
            }
            if err.error == "invalid_client" || err.error == "unauthorized_client" {
                throw GoogleSetupError("Google sign-in isn't set up for this build")
            }
            throw DriveIOError("Could not authorize \(email): \(err.description ?? err.error ?? "HTTP \(response.status)")")
        }
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: response.body),
              let access = tokens.access_token, !access.isEmpty else {
            throw DriveIOError("Could not authorize \(email): no token")
        }
        if let rt = tokens.refresh_token, !rt.isEmpty, rt != grant.refreshToken {
            var g = grant
            g.refreshToken = rt
            g.savedAt = Self.millis(now())
            store(email, g)
        }
        remember(email, token: access, expiresInSeconds: tokens.expires_in)
        return access
    }

    /// Caches a token until min(expires_in - 5 min, 45 min) from now.
    public func remember(_ email: String, token: String, expiresInSeconds: Int? = nil) {
        var ttl = Self.tokenTtl
        if let s = expiresInSeconds, s > 0 {
            let fromGoogle = TimeInterval(max(60, s - 300))
            if fromGoogle < ttl { ttl = fromGoogle }
        }
        lock.lock(); cache[Self.key(email)] = (token, now().addingTimeInterval(ttl)); lock.unlock()
    }

    public func invalidate(_ email: String) {
        lock.withLock { cache[Self.key(email)] = nil }
    }

    /// True when the account has no usable sign-in on this Mac (it was refused, or never stored).
    public func needsReconnect(_ email: String) -> Bool { readStored(email) == nil }

    /// Forgets the account's tokens on this Mac. Like Android, the grant isn't revoked: revoking would also sign
    /// out every other computer using the same OAuth client.
    public func signOut(_ email: String) async {
        lock.withLock { cache[Self.key(email)] = nil }
        secrets.delete(Self.secretNameFor(email))
        changed.fire()
    }

    // MARK: - Storage

    public static func secretNameFor(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "google-" + SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readStored(_ email: String) -> StoredGrant? {
        guard let data = secrets.get(Self.secretNameFor(email)),
              let g = try? JSONDecoder().decode(StoredGrant.self, from: data), !g.refreshToken.isEmpty else { return nil }
        return g
    }

    private func store(_ email: String, _ grant: StoredGrant) {
        do { try secrets.set(Self.secretNameFor(email), JSONEncoder().encode(grant)) } catch { Log.error(error, "Keychain") }
    }

    static func parseError(_ body: Data) -> (error: String?, description: String?) {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return (nil, nil) }
        var error: String?
        if let e = root["error"] as? String { error = e } else if let e = root["error"] as? [String: Any] { error = e["status"] as? String }
        return (error, root["error_description"] as? String)
    }

    static func text(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return (error as NSError).localizedDescription
    }

    static func millis(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    struct StoredGrant: Codable {
        var email: String
        var refreshToken: String
        var scope: String
        var savedAt: Int64
    }

    private struct TokenResponse: Decodable {
        var access_token: String?
        var expires_in: Int?
        var refresh_token: String?
        var scope: String?
    }

    private struct AboutResponse: Decodable { var user: AboutUser? }

    private struct AboutUser: Decodable {
        var displayName: String?
        var emailAddress: String?
        var photoLink: String?
    }
}
