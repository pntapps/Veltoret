using System.Net;
using System.Security.Cryptography;
using System.Text;
using Veltoret.Core.Auth;
using Veltoret.Core.Drive;

namespace Veltoret.Core.Tests.Drive;

public class GoogleAuthTests
{
    private sealed class TokenEndpoint(Func<string, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public readonly List<string> Bodies = new();
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content == null ? "" : await request.Content.ReadAsStringAsync(ct);
            Bodies.Add(body);
            return answer(body);
        }
    }

    private static HttpResponseMessage Json(HttpStatusCode code, string json) =>
        new(code) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    private static (GoogleAuthService Auth, MemorySecretStore Secrets, TokenEndpoint Endpoint) Service(Func<string, HttpResponseMessage> answer)
    {
        var endpoint = new TokenEndpoint(answer);
        var secrets = new MemorySecretStore();
        var auth = new GoogleAuthService(new HttpClient(endpoint), secrets, null) { OpenBrowser = _ => { } };
        auth.SetClient(new OAuthClient("123-abc.apps.googleusercontent.com", "secret"));
        secrets.Write(GoogleAuthService.SecretNameFor("a@b.c"),
            """{"email":"a@b.c","refreshToken":"rt-1","scope":"https://www.googleapis.com/auth/drive","savedAt":1}""");
        return (auth, secrets, endpoint);
    }

    [Fact]
    public void PkceChallengeIsBase64UrlSha256WithoutPadding()
    {
        // RFC 7636 appendix B.
        Assert.Equal("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", Pkce.Challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
        var verifier = Pkce.CreateVerifier();
        Assert.Equal(43, verifier.Length);
        Assert.Matches("^[A-Za-z0-9_-]+$", verifier);
        Assert.Equal(Pkce.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))), Pkce.Challenge(verifier));
        Assert.DoesNotContain("=", Pkce.Challenge(verifier));
    }

    [Fact]
    public void StateMismatchIsRejected()
    {
        var e = Assert.Throws<ConnectException>(() =>
            GoogleAuthService.CheckRedirect(new Dictionary<string, string> { ["code"] = "c", ["state"] = "other" }, "expected"));
        Assert.Equal("Couldn't connect", e.Title);
        Assert.Equal("c", GoogleAuthService.CheckRedirect(new Dictionary<string, string> { ["code"] = "c", ["state"] = "s" }, "s"));
    }

    [Fact]
    public void DeniedConsentMeansNotGranted()
    {
        var e = Assert.Throws<ConnectException>(() =>
            GoogleAuthService.CheckRedirect(new Dictionary<string, string> { ["error"] = "access_denied", ["state"] = "s" }, "s"));
        Assert.Equal("Google didn't grant access", e.Title);
        Assert.True(e.SetupProblem);
    }

    [Fact]
    public void AuthorizationUrlAsksForDriveWithPkceAndOfflineAccess()
    {
        var (auth, _, _) = Service(_ => Json(HttpStatusCode.OK, "{}"));
        var url = auth.AuthorizationUrl("id.apps.googleusercontent.com", "http://127.0.0.1:5000/", "chal", "st", "a@b.c");
        var q = LoopbackReceiver.ParseQuery(url);
        Assert.StartsWith("https://accounts.google.com/o/oauth2/v2/auth?", url);
        Assert.Equal("https://www.googleapis.com/auth/drive", q["scope"]);
        Assert.Equal("S256", q["code_challenge_method"]);
        Assert.Equal("chal", q["code_challenge"]);
        Assert.Equal("offline", q["access_type"]);
        Assert.Equal("http://127.0.0.1:5000/", q["redirect_uri"]);
        Assert.Equal("a@b.c", q["login_hint"]);
        Assert.Equal("code", q["response_type"]);
    }

    [Fact]
    public async Task RefreshIsCachedAndUsesTheStoredToken()
    {
        var (auth, _, endpoint) = Service(_ => Json(HttpStatusCode.OK, """{"access_token":"at-1","expires_in":3599,"token_type":"Bearer"}"""));
        Assert.Equal("at-1", await auth.AccessToken("a@b.c"));
        Assert.Equal("at-1", await auth.AccessToken("a@b.c"));
        Assert.Single(endpoint.Bodies);
        Assert.Contains("refresh_token=rt-1", endpoint.Bodies[0]);
        Assert.Contains("grant_type=refresh_token", endpoint.Bodies[0]);
        auth.Invalidate("a@b.c");
        await auth.AccessToken("a@b.c");
        Assert.Equal(2, endpoint.Bodies.Count);
    }

    [Fact]
    public async Task InvalidGrantNeedsReconnectingAndDeletesTheStoredToken()
    {
        var (auth, secrets, _) = Service(_ => Json(HttpStatusCode.BadRequest, """{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"""));
        string? flagged = null;
        auth.ReconnectNeeded += e => flagged = e;
        var e = await Assert.ThrowsAsync<AuthRequiredException>(() => auth.AccessToken("a@b.c"));
        Assert.Equal("Google account a@b.c needs to be reconnected", e.Message);
        Assert.Null(secrets.Read(GoogleAuthService.SecretNameFor("a@b.c")));
        Assert.True(auth.NeedsReconnect("a@b.c"));
        Assert.Equal("a@b.c", flagged);
    }

    [Fact]
    public void ClientFileMustBeADesktopClient()
    {
        var ok = OAuthClient.Parse("""{"installed":{"client_id":"1-x.apps.googleusercontent.com","client_secret":"s","redirect_uris":["http://localhost"]}}""");
        Assert.Equal("1-x.apps.googleusercontent.com", ok.ClientId);
        Assert.Throws<FormatException>(() => OAuthClient.Parse("""{"web":{"client_id":"1-x.apps.googleusercontent.com","client_secret":"s"}}"""));
        Assert.Throws<FormatException>(() => OAuthClient.Parse("not json"));
    }

    /// <summary>A 401 drops the token and re-sends exactly once with a fresh one.</summary>
    [Fact]
    public async Task UnauthorizedIsRetriedOnceWithAFreshToken()
    {
        var seen = new List<string>();
        var handler = new Answer(r =>
        {
            seen.Add(r.Headers.Authorization!.Parameter!);
            return new HttpResponseMessage(seen.Count == 1 ? HttpStatusCode.Unauthorized : HttpStatusCode.OK)
            {
                Content = new StringContent("""{"id":"x","name":"renamed"}"""),
            };
        });
        var tokens = new FixedTokens();
        var drive = new DriveRepository(new HttpClient(new DriveAuthHandler(tokens, handler)));
        var file = await drive.Rename("a@b.c", "x", "renamed");
        Assert.Equal("renamed", file.Name);
        Assert.Equal(new[] { "token-1", "token-2" }, seen);
        Assert.Equal(new[] { "a@b.c" }, tokens.Invalidated);
    }

    [Fact]
    public async Task UnauthorizedTwiceIsNotRetriedAgain()
    {
        var calls = 0;
        var handler = new Answer(_ => { calls++; return new HttpResponseMessage(HttpStatusCode.Unauthorized) { Content = new StringContent("") }; });
        var drive = new DriveRepository(new HttpClient(new DriveAuthHandler(new FixedTokens(), handler)));
        await Assert.ThrowsAsync<IOException>(() => drive.Rename("a@b.c", "x", "y"));
        Assert.Equal(2, calls);
    }

    internal sealed class Answer(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) => Task.FromResult(answer(request));
    }
}
