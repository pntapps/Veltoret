using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Veltoret.Core.Data;

namespace Veltoret.Core.Auth;

/// <summary>
/// Google sign-in for Drive (Android: GoogleAuthManager + AccountConnector), as an OAuth 2.0 installed-app flow:
/// the system browser, a loopback redirect and PKCE. The user brings their own "Desktop app" OAuth client.
///
/// Refresh tokens are stored per account with DPAPI (<see cref="ISecretStore"/>); access tokens live only in
/// memory, cached for at most 45 minutes like on Android. Only one scope is asked for: full Drive. The account's
/// email, name and photo come from Drive's "about".
/// </summary>
public sealed class GoogleAuthService : ITokenProvider
{
    public const string DriveScope = "https://www.googleapis.com/auth/drive";
    private const string ClientSecretName = "google-client";
    private static readonly TimeSpan TokenTtl = TimeSpan.FromMinutes(45);
    private static readonly TimeSpan SignInTimeout = TimeSpan.FromMinutes(5);

    private readonly HttpClient _http;
    private readonly ISecretStore _secrets;
    private readonly AccountDao? _accounts;
    private readonly ConcurrentDictionary<string, (string Token, DateTimeOffset ExpiresAt)> _cache = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim _refreshLock = new(1, 1);

    public string AuthEndpoint { get; init; } = "https://accounts.google.com/o/oauth2/v2/auth";
    public string TokenEndpoint { get; init; } = "https://oauth2.googleapis.com/token";
    public string AboutUrl { get; init; } =
        "https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress,photoLink),storageQuota(limit,usage)";

    /// <summary>Opens the Google sign-in page. Default: the default browser.</summary>
    public Action<string> OpenBrowser { get; init; } = url => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });

    public Func<DateTimeOffset> Now { get; init; } = () => DateTimeOffset.UtcNow;

    /// <summary>Raised when an account's grant was refused and it has to be connected again (email).</summary>
    public event Action<string>? ReconnectNeeded;

    /// <summary>Raised when the imported client or the stored sign-ins change.</summary>
    public event Action? Changed;

    public GoogleAuthService(HttpClient http, ISecretStore secrets, AccountDao? accounts)
    {
        _http = http;
        _secrets = secrets;
        _accounts = accounts;
    }

    // ---- OAuth client --------------------------------------------------------------------------------------

    public OAuthClient? Client
    {
        get
        {
            var json = _secrets.Read(ClientSecretName);
            if (json == null) return null;
            try { return JsonSerializer.Deserialize<OAuthClient>(json); }
            catch (JsonException) { return null; }
        }
    }

    public bool HasClient => Client != null;

    /// <summary>Imports Google's downloaded client file. Throws <see cref="FormatException"/> with a user-facing message.</summary>
    public void ImportClientJson(string path)
    {
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new FormatException("Couldn't read that file.");
        }
        SetClient(OAuthClient.Parse(text));
    }

    public void SetClient(OAuthClient client)
    {
        _secrets.Write(ClientSecretName, JsonSerializer.Serialize(client));
        _cache.Clear();
        Changed?.Invoke();
    }

    public void RemoveClient()
    {
        _secrets.Delete(ClientSecretName);
        _cache.Clear();
        Changed?.Invoke();
    }

    // ---- Sign-in -------------------------------------------------------------------------------------------

    /// <summary>
    /// Runs the browser sign-in and adds (or refreshes) the account. <paramref name="loginHint"/> reconnects that
    /// account. Throws <see cref="ConnectException"/> for every failure, including cancellation.
    /// </summary>
    public async Task<AccountEntity> SignIn(CancellationToken ct, string? loginHint = null)
    {
        var client = Client ?? throw ConnectException.NotSetUp();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(SignInTimeout);

        string code;
        string redirectUri;
        var verifier = Pkce.CreateVerifier();
        try
        {
            using var receiver = new LoopbackReceiver();
            redirectUri = receiver.RedirectUri;
            var state = Pkce.CreateState();
            var url = AuthorizationUrl(client.ClientId, redirectUri, Pkce.Challenge(verifier), state, loginHint);
            try { OpenBrowser(url); }
            catch (Exception e)
            {
                throw ConnectException.Failed("Couldn't open your web browser: " + e.Message);
            }

            var query = await receiver.WaitForRedirect(q => ResultPage(q, state), timeout.Token).ConfigureAwait(false);
            code = CheckRedirect(query, state);
        }
        catch (OperationCanceledException)
        {
            // The browser was left open for 5 minutes without an answer, or the user clicked Cancel.
            throw ct.IsCancellationRequested ? ConnectException.Cancelled() : ConnectException.NotGranted();
        }
        catch (SocketException e)
        {
            throw ConnectException.Failed("Couldn't listen for Google's answer on this PC: " + e.Message);
        }

        var tokens = await ExchangeCode(client, code, redirectUri, verifier, ct).ConfigureAwait(false);
        if (tokens.Scope != null && !tokens.Scope.Split(' ').Contains(DriveScope)) throw ConnectException.NotGranted();
        if (string.IsNullOrEmpty(tokens.AccessToken)) throw ConnectException.Failed("Google didn't return an access token.");

        AboutUser user;
        try
        {
            user = await FetchUser(tokens.AccessToken, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw ConnectException.Cancelled(); }
        catch (HttpRequestException e) { throw ConnectException.DriveFailed(null, e); }
        catch (Exception e) { throw ConnectException.DriveFailed(e.Message, e); }

        var email = user.EmailAddress;
        if (string.IsNullOrWhiteSpace(email)) throw ConnectException.DriveFailed("Google Drive didn't say which account this is.");
        if (loginHint != null && !string.Equals(email, loginHint, StringComparison.OrdinalIgnoreCase))
            throw new ConnectException("Couldn't connect",
                $"You signed in as {email}, not {loginHint}. Pick {loginHint} on the Google screen to reconnect it.", false);

        var refresh = tokens.RefreshToken ?? ReadStored(email)?.RefreshToken;
        if (string.IsNullOrEmpty(refresh)) throw ConnectException.Failed("Google didn't allow offline access. Try again.");
        Store(email, new StoredGrant(email, refresh, tokens.Scope ?? DriveScope, Now().ToUnixTimeMilliseconds()));
        Remember(email, tokens.AccessToken, tokens.ExpiresIn);

        var account = new AccountEntity
        {
            Email = email,
            DisplayName = string.IsNullOrWhiteSpace(user.DisplayName) ? email.Split('@')[0] : user.DisplayName!,
            PhotoUrl = user.PhotoLink,
            AddedAt = Now().ToUnixTimeMilliseconds(),
        };
        if (_accounts != null)
        {
            var existing = (await _accounts.Accounts().ConfigureAwait(false))
                .FirstOrDefault(a => string.Equals(a.Email, email, StringComparison.OrdinalIgnoreCase));
            if (existing != null) account = account with { Email = existing.Email, AddedAt = existing.AddedAt };
            await _accounts.Upsert(account).ConfigureAwait(false);
        }
        Changed?.Invoke();
        return account;
    }

    public string AuthorizationUrl(string clientId, string redirectUri, string challenge, string state, string? loginHint)
    {
        var q = new List<(string, string)>
        {
            ("client_id", clientId),
            ("redirect_uri", redirectUri),
            ("response_type", "code"),
            ("scope", DriveScope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("access_type", "offline"),
            ("prompt", "consent select_account"),
            ("include_granted_scopes", "true"),
        };
        if (!string.IsNullOrEmpty(loginHint)) q.Add(("login_hint", loginHint));
        return AuthEndpoint + "?" + string.Join("&", q.Select(p => p.Item1 + "=" + Uri.EscapeDataString(p.Item2)));
    }

    /// <summary>Returns the authorization code, or throws when the redirect is an error or isn't ours.</summary>
    public static string CheckRedirect(IReadOnlyDictionary<string, string> query, string expectedState)
    {
        if (!query.TryGetValue("state", out var state) || !CryptographicOperations.FixedTimeEquals(
                Encoding.UTF8.GetBytes(state), Encoding.UTF8.GetBytes(expectedState)))
            throw ConnectException.Failed("Google's answer didn't match this sign-in. Try again.");
        if (query.TryGetValue("error", out var error))
        {
            if (error == "access_denied") throw ConnectException.NotGranted();
            throw ConnectException.Failed($"Google sign-in failed ({error}).");
        }
        if (!query.TryGetValue("code", out var code) || string.IsNullOrEmpty(code)) throw ConnectException.NotGranted();
        return code;
    }

    private static string ResultPage(IReadOnlyDictionary<string, string> query, string state)
    {
        var ok = query.TryGetValue("code", out _) && query.TryGetValue("state", out var s) && s == state;
        return ok
            ? LoopbackReceiver.Page("Veltoret is connected", "You can close this tab and go back to the app.")
            : LoopbackReceiver.Page("Veltoret didn't get access", "You can close this tab and go back to the app to try again.");
    }

    private async Task<TokenResponse> ExchangeCode(OAuthClient client, string code, string redirectUri, string verifier, CancellationToken ct)
    {
        var form = new Dictionary<string, string>
        {
            ["code"] = code,
            ["client_id"] = client.ClientId,
            ["client_secret"] = client.ClientSecret,
            ["redirect_uri"] = redirectUri,
            ["grant_type"] = "authorization_code",
            ["code_verifier"] = verifier,
        };
        HttpResponseMessage response;
        try
        {
            response = await _http.PostAsync(TokenEndpoint, new FormUrlEncodedContent(form), ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw ConnectException.Cancelled(); }
        catch (Exception e) when (e is HttpRequestException or IOException or TaskCanceledException)
        {
            throw ConnectException.NoConnection(e);
        }
        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
                return JsonSerializer.Deserialize<TokenResponse>(body) ?? throw ConnectException.Failed("Google sent an empty answer.");
            var err = ParseError(body);
            if (err.Error is "invalid_client" or "unauthorized_client" or "redirect_uri_mismatch") throw ConnectException.NotSetUp();
            if (err.Error == "access_denied") throw ConnectException.NotGranted();
            throw ConnectException.Failed(err.Description ?? err.Error, (int)response.StatusCode);
        }
    }

    private async Task<AboutUser> FetchUser(string accessToken, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, AboutUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw new IOException($"Google Drive refused to open (HTTP {(int)response.StatusCode}). Check that the Google Drive API is enabled for your Google Cloud project.");
        var about = await response.Content.ReadFromJsonSafe<AboutResponse>(ct).ConfigureAwait(false);
        return about?.User ?? new AboutUser();
    }

    // ---- Tokens --------------------------------------------------------------------------------------------

    /// <summary>A valid access token for the account, refreshed silently when needed.</summary>
    public async Task<string> AccessToken(string email, CancellationToken ct = default)
    {
        if (TryCached(email, out var token)) return token;
        await _refreshLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (TryCached(email, out token)) return token;
            return await Refresh(email, ct).ConfigureAwait(false);
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private bool TryCached(string email, out string token)
    {
        if (_cache.TryGetValue(email, out var c) && c.ExpiresAt > Now())
        {
            token = c.Token;
            return true;
        }
        token = "";
        return false;
    }

    private async Task<string> Refresh(string email, CancellationToken ct)
    {
        var grant = ReadStored(email);
        if (grant == null) throw new AuthRequiredException(email);
        var client = Client ?? throw new GoogleSetupException("Google sign-in isn't set up for this build");

        var form = new Dictionary<string, string>
        {
            ["client_id"] = client.ClientId,
            ["client_secret"] = client.ClientSecret,
            ["refresh_token"] = grant.RefreshToken,
            ["grant_type"] = "refresh_token",
        };
        HttpResponseMessage response;
        try
        {
            response = await _http.PostAsync(TokenEndpoint, new FormUrlEncodedContent(form), ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            throw new IOException($"Could not authorize {email}: {e.Message}", e);
        }
        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                var err = ParseError(body);
                if (err.Error == "invalid_grant")
                {
                    // Revoked, expired (Testing-mode 7-day tokens), or the password changed: sign in again.
                    _secrets.Delete(SecretNameFor(email));
                    _cache.TryRemove(email, out _);
                    ReconnectNeeded?.Invoke(email);
                    Changed?.Invoke();
                    throw new AuthRequiredException(email);
                }
                if (err.Error is "invalid_client" or "unauthorized_client")
                    throw new GoogleSetupException("Google sign-in isn't set up for this build");
                throw new IOException($"Could not authorize {email}: {err.Description ?? err.Error ?? "HTTP " + (int)response.StatusCode}");
            }
            var tokens = JsonSerializer.Deserialize<TokenResponse>(body);
            if (tokens == null || string.IsNullOrEmpty(tokens.AccessToken)) throw new IOException($"Could not authorize {email}: no token");
            if (!string.IsNullOrEmpty(tokens.RefreshToken) && tokens.RefreshToken != grant.RefreshToken)
                Store(email, grant with { RefreshToken = tokens.RefreshToken, SavedAt = Now().ToUnixTimeMilliseconds() });
            Remember(email, tokens.AccessToken, tokens.ExpiresIn);
            return tokens.AccessToken;
        }
    }

    /// <summary>Caches a token until min(expires_in - 5 min, 45 min) from now.</summary>
    public void Remember(string email, string token, int? expiresInSeconds = null)
    {
        var ttl = TokenTtl;
        if (expiresInSeconds is > 0)
        {
            var fromGoogle = TimeSpan.FromSeconds(Math.Max(60, expiresInSeconds.Value - 300));
            if (fromGoogle < ttl) ttl = fromGoogle;
        }
        _cache[email] = (token, Now() + ttl);
    }

    public void Invalidate(string email) => _cache.TryRemove(email, out _);

    /// <summary>True when the account has no usable sign-in on this PC (it was refused, or never stored).</summary>
    public bool NeedsReconnect(string email) => ReadStored(email) == null;

    /// <summary>
    /// Forgets the account's tokens on this PC. Like Android, the grant isn't revoked: revoking would also sign
    /// out every other PC using the same OAuth client.
    /// </summary>
    public Task SignOut(string email)
    {
        _cache.TryRemove(email, out _);
        _secrets.Delete(SecretNameFor(email));
        Changed?.Invoke();
        return Task.CompletedTask;
    }

    // ---- Storage -------------------------------------------------------------------------------------------

    public static string SecretNameFor(string email) =>
        "google-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(email.Trim().ToLowerInvariant()))).ToLowerInvariant();

    private StoredGrant? ReadStored(string email)
    {
        var json = _secrets.Read(SecretNameFor(email));
        if (json == null) return null;
        try
        {
            var g = JsonSerializer.Deserialize<StoredGrant>(json);
            return g == null || string.IsNullOrEmpty(g.RefreshToken) ? null : g;
        }
        catch (JsonException) { return null; }
    }

    private void Store(string email, StoredGrant grant) => _secrets.Write(SecretNameFor(email), JsonSerializer.Serialize(grant));

    private static (string? Error, string? Description) ParseError(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            string? error = null, desc = null;
            if (root.TryGetProperty("error", out var e))
            {
                if (e.ValueKind == JsonValueKind.String) error = e.GetString();
                else if (e.ValueKind == JsonValueKind.Object && e.TryGetProperty("status", out var st)) error = st.GetString();
            }
            if (root.TryGetProperty("error_description", out var d) && d.ValueKind == JsonValueKind.String) desc = d.GetString();
            return (error, desc);
        }
        catch (JsonException) { return (null, null); }
    }

    private sealed record StoredGrant(
        [property: JsonPropertyName("email")] string Email,
        [property: JsonPropertyName("refreshToken")] string RefreshToken,
        [property: JsonPropertyName("scope")] string Scope,
        [property: JsonPropertyName("savedAt")] long SavedAt);

    private sealed class TokenResponse
    {
        [JsonPropertyName("access_token")] public string AccessToken { get; set; } = "";
        [JsonPropertyName("expires_in")] public int? ExpiresIn { get; set; }
        [JsonPropertyName("refresh_token")] public string? RefreshToken { get; set; }
        [JsonPropertyName("scope")] public string? Scope { get; set; }
    }

    private sealed class AboutResponse
    {
        [JsonPropertyName("user")] public AboutUser? User { get; set; }
    }

    private sealed class AboutUser
    {
        [JsonPropertyName("displayName")] public string? DisplayName { get; set; }
        [JsonPropertyName("emailAddress")] public string? EmailAddress { get; set; }
        [JsonPropertyName("photoLink")] public string? PhotoLink { get; set; }
    }
}

internal static class HttpContentJson
{
    public static async Task<T?> ReadFromJsonSafe<T>(this HttpContent content, CancellationToken ct)
    {
        var text = await content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(text)) return default;
        return JsonSerializer.Deserialize<T>(text);
    }
}
