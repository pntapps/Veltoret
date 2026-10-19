using System.Net;
using System.Net.Http.Headers;
using Veltoret.Core.Auth;

namespace Veltoret.Core.Drive;

/// <summary>
/// Adds "Authorization: Bearer" for the account a Drive request is tagged with (<see cref="AccountKey"/>) and, on
/// HTTP 401, drops the token and re-sends exactly once with a fresh one (Android: DriveAuthInterceptor). Requests
/// without an account tag pass through untouched.
/// </summary>
public sealed class DriveAuthHandler : DelegatingHandler
{
    public static readonly HttpRequestOptionsKey<string> AccountKey = new("veltoret.account");

    private readonly ITokenProvider _tokens;

    public DriveAuthHandler(ITokenProvider tokens, HttpMessageHandler inner) : base(inner) => _tokens = tokens;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        if (!request.Options.TryGetValue(AccountKey, out var email) || string.IsNullOrEmpty(email))
            return await base.SendAsync(request, ct).ConfigureAwait(false);

        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _tokens.AccessToken(email, ct).ConfigureAwait(false));
        var response = await base.SendAsync(request, ct).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.Unauthorized) return response;

        response.Dispose();
        _tokens.Invalidate(email);
        var retry = await Clone(request, ct).ConfigureAwait(false);
        retry.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _tokens.AccessToken(email, ct).ConfigureAwait(false));
        return await base.SendAsync(retry, ct).ConfigureAwait(false);
    }

    /// <summary>A request can't be sent twice: copy method, URI, headers, options and (re-readable) content.</summary>
    private static async Task<HttpRequestMessage> Clone(HttpRequestMessage request, CancellationToken ct)
    {
        var copy = new HttpRequestMessage(request.Method, request.RequestUri) { Version = request.Version, VersionPolicy = request.VersionPolicy };
        foreach (var h in request.Headers)
            if (!string.Equals(h.Key, "Authorization", StringComparison.OrdinalIgnoreCase))
                copy.Headers.TryAddWithoutValidation(h.Key, h.Value);
        foreach (var o in request.Options) ((IDictionary<string, object?>)copy.Options)[o.Key] = o.Value;
        if (request.Content != null)
        {
            var bytes = await request.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            var content = new ByteArrayContent(bytes);
            foreach (var h in request.Content.Headers)
                if (!string.Equals(h.Key, "Content-Length", StringComparison.OrdinalIgnoreCase))
                    content.Headers.TryAddWithoutValidation(h.Key, h.Value);
            copy.Content = content;
        }
        return copy;
    }
}
