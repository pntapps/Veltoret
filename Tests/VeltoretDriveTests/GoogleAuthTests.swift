import Foundation
import CryptoKit
import XCTest
import VeltoretKit
@testable import VeltoretDrive

final class GoogleAuthTests: XCTestCase {
    private final class TokenEndpoint: HttpTransport, @unchecked Sendable {
        var bodies: [String] = []
        let answer: (String) -> HttpResponse
        init(_ answer: @escaping (String) -> HttpResponse) { self.answer = answer }
        func send(_ request: URLRequest) async throws -> HttpResponse {
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            bodies.append(body)
            return answer(body)
        }
    }

    private func service(_ answer: @escaping (String) -> HttpResponse) throws -> (GoogleAuthService, MemorySecretStore, TokenEndpoint) {
        let endpoint = TokenEndpoint(answer)
        let secrets = MemorySecretStore()
        let auth = GoogleAuthService(http: endpoint, secrets: secrets, accounts: nil)
        auth.openBrowser = { _ in }
        try auth.setClient(OAuthClient(clientId: "123-abc.apps.googleusercontent.com", clientSecret: "secret"))
        try secrets.setString(GoogleAuthService.secretNameFor("a@b.c"),
                              #"{"email":"a@b.c","refreshToken":"rt-1","scope":"https://www.googleapis.com/auth/drive","savedAt":1}"#)
        return (auth, secrets, endpoint)
    }

    func testPkceChallengeIsBase64UrlSha256WithoutPadding() {
        // RFC 7636 appendix B.
        XCTAssertEqual(Pkce.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = Pkce.createVerifier()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNotNil(verifier.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression))
        XCTAssertEqual(Pkce.challenge(verifier), Pkce.base64Url(Data(SHA256.hash(data: Data(verifier.utf8)))))
        XCTAssertFalse(Pkce.challenge(verifier).contains("="))
    }

    func testStateMismatchIsRejected() throws {
        XCTAssertThrowsError(try GoogleAuthService.checkRedirect(["code": "c", "state": "other"], expectedState: "expected")) { e in
            XCTAssertEqual((e as? ConnectError)?.title, "Couldn't connect")
        }
        XCTAssertEqual(try GoogleAuthService.checkRedirect(["code": "c", "state": "s"], expectedState: "s"), "c")
    }

    func testDeniedConsentMeansNotGranted() {
        XCTAssertThrowsError(try GoogleAuthService.checkRedirect(["error": "access_denied", "state": "s"], expectedState: "s")) { e in
            let c = e as? ConnectError
            XCTAssertEqual(c?.title, "Google didn't grant access")
            XCTAssertEqual(c?.setupProblem, true)
        }
    }

    func testAuthorizationUrlAsksForDriveWithPkceAndOfflineAccess() throws {
        let (auth, _, _) = try service { _ in HttpResponse(status: 200, json: "{}") }
        let url = auth.authorizationUrl(clientId: "id.apps.googleusercontent.com", redirectUri: "http://127.0.0.1:5000/",
                                        challenge: "chal", state: "st", loginHint: "a@b.c")
        let q = LoopbackReceiver.parseQuery(url)
        XCTAssertTrue(url.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
        XCTAssertEqual(q["scope"], "https://www.googleapis.com/auth/drive")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], "chal")
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:5000/")
        XCTAssertEqual(q["login_hint"], "a@b.c")
        XCTAssertEqual(q["response_type"], "code")
    }

    func testRefreshIsCachedAndUsesTheStoredToken() async throws {
        let (auth, _, endpoint) = try service { _ in
            HttpResponse(status: 200, json: #"{"access_token":"at-1","expires_in":3599,"token_type":"Bearer"}"#)
        }
        let first = try await auth.accessToken("a@b.c")
        let second = try await auth.accessToken("a@b.c")
        XCTAssertEqual(first, "at-1")
        XCTAssertEqual(second, "at-1")
        XCTAssertEqual(endpoint.bodies.count, 1)
        XCTAssertTrue(endpoint.bodies[0].contains("refresh_token=rt-1"))
        XCTAssertTrue(endpoint.bodies[0].contains("grant_type=refresh_token"))
        auth.invalidate("a@b.c")
        _ = try await auth.accessToken("a@b.c")
        XCTAssertEqual(endpoint.bodies.count, 2)
    }

    func testInvalidGrantNeedsReconnectingAndDeletesTheStoredToken() async throws {
        let (auth, secrets, _) = try service { _ in
            HttpResponse(status: 400, json: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)
        }
        var flagged: String?
        let sub = auth.reconnectNeeded.subscribe { flagged = $0 }
        defer { sub.cancel() }
        let e = await asyncError { _ = try await auth.accessToken("a@b.c") }
        XCTAssertEqual((e as? AuthRequiredError)?.message, "Google account a@b.c needs to be reconnected")
        XCTAssertNil(secrets.get(GoogleAuthService.secretNameFor("a@b.c")))
        XCTAssertTrue(auth.needsReconnect("a@b.c"))
        XCTAssertEqual(flagged, "a@b.c")
    }

    func testInvalidClientIsASetupProblem() async throws {
        let (auth, _, _) = try service { _ in HttpResponse(status: 401, json: #"{"error":"invalid_client"}"#) }
        let e = await asyncError { _ = try await auth.accessToken("a@b.c") }
        XCTAssertTrue(e is GoogleSetupError)
        XCTAssertFalse(auth.needsReconnect("a@b.c"))
    }

    func testClientFileMustBeADesktopClient() throws {
        let ok = try OAuthClient.parse(#"{"installed":{"client_id":"1-x.apps.googleusercontent.com","client_secret":"s","redirect_uris":["http://localhost"]}}"#)
        XCTAssertEqual(ok.clientId, "1-x.apps.googleusercontent.com")
        XCTAssertThrowsError(try OAuthClient.parse(#"{"web":{"client_id":"1-x.apps.googleusercontent.com","client_secret":"s"}}"#))
        XCTAssertThrowsError(try OAuthClient.parse("not json"))
    }

    func testImportedClientIsKeptInSecretsAndMasked() throws {
        let secrets = MemorySecretStore()
        let auth = GoogleAuthService(http: Answer { _ in HttpResponse(status: 500) }, secrets: secrets, accounts: nil)
        XCTAssertFalse(auth.hasClient)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("client-\(UUID().uuidString).json")
        try Data(#"{"installed":{"client_id":"1234567890-abcdefgh.apps.googleusercontent.com","client_secret":"s"}}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try auth.importClientJson(file)
        XCTAssertTrue(auth.hasClient)
        XCTAssertNotNil(secrets.get("google-client"))
        XCTAssertEqual(auth.client?.maskedId, "123456…efgh.apps.googleusercontent.com")
        auth.removeClient()
        XCTAssertFalse(auth.hasClient)
    }

    func testSecretNameIsSha256OfTheNormalizedEmail() {
        XCTAssertEqual(GoogleAuthService.secretNameFor(" A@B.c "), GoogleAuthService.secretNameFor("a@b.c"))
        XCTAssertTrue(GoogleAuthService.secretNameFor("a@b.c").hasPrefix("google-"))
        XCTAssertEqual(GoogleAuthService.secretNameFor("a@b.c").count, "google-".count + 64)
    }

    /// A 401 drops the token and re-sends exactly once with a fresh one.
    func testUnauthorizedIsRetriedOnceWithAFreshToken() async throws {
        var seen: [String] = []
        let handler = Answer { r in
            seen.append(r.value(forHTTPHeaderField: "Authorization")!.replacingOccurrences(of: "Bearer ", with: ""))
            return HttpResponse(status: seen.count == 1 ? 401 : 200, json: #"{"id":"x","name":"renamed"}"#)
        }
        let tokens = FixedTokens()
        let drive = DriveRepository(http: DriveAuthTransport(tokens: tokens, inner: handler))
        let file = try await drive.rename("a@b.c", id: "x", newName: "renamed")
        XCTAssertEqual(file.name, "renamed")
        XCTAssertEqual(seen, ["token-1", "token-2"])
        XCTAssertEqual(tokens.invalidated, ["a@b.c"])
    }

    func testUnauthorizedTwiceIsNotRetriedAgain() async {
        var calls = 0
        let handler = Answer { _ in calls += 1; return HttpResponse(status: 401) }
        let drive = DriveRepository(http: DriveAuthTransport(tokens: FixedTokens(), inner: handler))
        let e = await asyncError { try await drive.rename("a@b.c", id: "x", newName: "y") }
        XCTAssertTrue(e is DriveIOError)
        XCTAssertEqual(calls, 2)
    }

    func testAccountTagNeverLeavesTheMac() async throws {
        var headers: [String: String] = [:]
        let handler = Answer { r in headers = r.allHTTPHeaderFields ?? [:]; return HttpResponse(status: 200, json: #"{"id":"x"}"#) }
        let drive = DriveRepository(http: DriveAuthTransport(tokens: FixedTokens(), inner: handler))
        _ = try await drive.get("a@b.c", id: "x")
        XCTAssertNil(headers[DriveAuthTransport.accountHeader])
        XCTAssertEqual(headers["Authorization"], "Bearer token-1")
    }

    func testSignInWithoutClientIsNotSetUp() async {
        let auth = GoogleAuthService(http: Answer { _ in HttpResponse(status: 500) }, secrets: MemorySecretStore(), accounts: nil)
        let e = await asyncError { _ = try await auth.signIn() }
        XCTAssertEqual((e as? ConnectError)?.title, "Google sign-in isn't set up for this build")
    }

    /// The whole loopback flow against fake Google endpoints: the "browser" follows the redirect itself.
    func testSignInRunsTheLoopbackFlowAndStoresTheAccount() async throws {
        try AppServices.initForTests()
        let secrets = MemorySecretStore()
        var tokenBody = ""
        let http = Answer { r in
            if r.url!.absoluteString.contains("/token") {
                tokenBody = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
                return HttpResponse(status: 200, json: #"{"access_token":"at","refresh_token":"rt","expires_in":3599,"scope":"https://www.googleapis.com/auth/drive"}"#)
            }
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer at")
            return HttpResponse(status: 200, json: #"{"user":{"displayName":"Ann","emailAddress":"ann@example.com"}}"#)
        }
        let auth = GoogleAuthService(http: http, secrets: secrets, accounts: AppServices.accountDao)
        try auth.setClient(OAuthClient(clientId: "1-x.apps.googleusercontent.com", clientSecret: "s"))
        try AppServices.accountDao.upsert(AccountEntity(email: "ann@example.com", displayName: "Old", addedAt: 42))
        auth.openBrowser = { url in
            let q = LoopbackReceiver.parseQuery(url)
            let redirect = q["redirect_uri"]! + "?code=the-code&state=" + UrlEncoding.escape(q["state"]!)
            Task.detached { _ = try? await URLSession.shared.data(from: URL(string: redirect)!) }
        }
        let account = try await auth.signIn()
        XCTAssertEqual(account.email, "ann@example.com")
        XCTAssertEqual(account.displayName, "Ann")
        XCTAssertEqual(account.addedAt, 42)
        XCTAssertTrue(tokenBody.contains("code=the-code"))
        XCTAssertTrue(tokenBody.contains("code_verifier="))
        XCTAssertFalse(auth.needsReconnect("ann@example.com"))
        let stored = try AppServices.accountDao.accounts().first { $0.email == "ann@example.com" }
        XCTAssertEqual(stored?.addedAt, 42)
        XCTAssertEqual(stored?.displayName, "Ann")
        let token = try await auth.accessToken("ann@example.com")
        XCTAssertEqual(token, "at")
    }
}
