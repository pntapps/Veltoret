using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Veltoret.Core.Auth;

/// <summary>Thrown when an account's Drive access can't be refreshed silently and the user must sign in again.</summary>
public sealed class AuthRequiredException(string email) : IOException($"Google account {email} needs to be reconnected")
{
    public string Email { get; } = email;
}

/// <summary>The imported OAuth client was refused by Google (wrong type, deleted, or never set up).</summary>
public sealed class GoogleSetupException(string message) : IOException(message);

/// <summary>
/// Why connecting a Google account failed (Android: ConnectError). Settings shows "{Title}. {Message}".
/// <see cref="SetupProblem"/> means the fix is in Google Cloud / the imported client, not a retry.
/// </summary>
public sealed class ConnectException(string title, string message, bool setupProblem, Exception? inner = null)
    : Exception(message, inner)
{
    public string Title { get; } = title;
    public bool SetupProblem { get; } = setupProblem;

    public static ConnectException NotGranted() => new("Google didn't grant access",
        "If you closed the Google screen, just try again. If Google showed \"Access blocked\" or an error like 400 / 401 / 403, " +
        "this copy of the app isn't registered with Google Cloud yet.", true);

    public static ConnectException NotSetUp() => new("Google sign-in isn't set up for this build",
        "Google doesn't recognise this app yet. Create a Desktop app OAuth client in Google Cloud and import its client file in Settings, then try again.",
        true);

    public static ConnectException NoConnection(Exception? inner = null) =>
        new("No connection", "Check your internet connection and try again.", false, inner);

    public static ConnectException Cancelled() => new("Sign-in cancelled", "Click Connect to try again.", false);

    public static ConnectException Failed(string? message, int? status = null) => new("Couldn't connect",
        (string.IsNullOrWhiteSpace(message) ? "Google sign-in failed." : message) + (status != null ? $" (code {status})" : ""),
        status == null);

    public static ConnectException DriveFailed(string? message, Exception? inner = null) => new("Couldn't open your Drive",
        string.IsNullOrWhiteSpace(message) ? "Google Drive didn't respond. Check your connection and try again." : message, false, inner);
}

/// <summary>A "Desktop app" OAuth client the user created in Google Cloud and imported.</summary>
public sealed record OAuthClient(string ClientId, string ClientSecret)
{
    /// <summary>
    /// Reads Google's downloaded client file (<c>{"installed": {"client_id": …, "client_secret": …}}</c>).
    /// Throws <see cref="FormatException"/> with a message for the user when it isn't a Desktop client file.
    /// </summary>
    public static OAuthClient Parse(string json)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(json); }
        catch (JsonException) { throw new FormatException("That isn't a Google OAuth client file."); }
        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new FormatException("That isn't a Google OAuth client file.");
            if (root.TryGetProperty("web", out _))
                throw new FormatException("This is a Web application client. Create a Desktop app client in Google Cloud and import its file instead.");
            var section = root.TryGetProperty("installed", out var installed) ? installed : root;
            var id = Str(section, "client_id");
            var secret = Str(section, "client_secret");
            if (string.IsNullOrWhiteSpace(id) || !id.EndsWith(".apps.googleusercontent.com", StringComparison.OrdinalIgnoreCase))
                throw new FormatException("That isn't a Google OAuth client file.");
            if (string.IsNullOrWhiteSpace(secret))
                throw new FormatException("The client file has no client secret. Download it again from Google Cloud.");
            return new OAuthClient(id.Trim(), secret.Trim());
        }
    }

    private static string? Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    /// <summary>"1234…abcd.apps.googleusercontent.com" — enough to recognise it, not to copy it from a screenshot.</summary>
    public string MaskedId
    {
        get
        {
            const string suffix = ".apps.googleusercontent.com";
            var core = ClientId.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) ? ClientId[..^suffix.Length] : ClientId;
            var masked = core.Length <= 10 ? core : core[..6] + "…" + core[^4..];
            return masked + (core.Length != ClientId.Length ? suffix : "");
        }
    }
}

/// <summary>PKCE (RFC 7636) and state values for the loopback flow.</summary>
public static class Pkce
{
    public static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>32 random bytes, base64url: 43 characters from [A-Za-z0-9-_].</summary>
    public static string CreateVerifier() => Base64Url(RandomNumberGenerator.GetBytes(32));

    public static string CreateState() => Base64Url(RandomNumberGenerator.GetBytes(32));

    /// <summary>S256: base64url(SHA256(ASCII(verifier))), no padding.</summary>
    public static string Challenge(string verifier) => Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
}

/// <summary>Gives Drive calls a bearer token for an account (GoogleAuthService; fakes in tests).</summary>
public interface ITokenProvider
{
    Task<string> AccessToken(string email, CancellationToken ct = default);
    /// <summary>Drops a token Google rejected (HTTP 401) so the next call fetches a fresh one.</summary>
    void Invalidate(string email);
}
