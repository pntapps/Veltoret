using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Veltoret.Core.Tmdb;

/// <summary>No TMDB key is set (Settings → TMDB). A <see cref="HttpRequestException"/> so "network problem" handlers see it too.</summary>
public sealed class TmdbKeyMissingException()
    : HttpRequestException("Add your TMDB API key in Settings to fetch posters and details");

/// <summary>
/// TMDB v3 over HttpClient (Android TmdbApi + TmdbAuthInterceptor). Accepts a v3 API key (sent as
/// <c>api_key</c>) or a v4 "API Read Access Token" (a JWT starting with "eyJ", sent as a bearer token).
/// Every request is pinned to English (US).
/// </summary>
public sealed class TmdbClient
{
    public const string BaseUrl = "https://api.themoviedb.org/3/";

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    private readonly HttpClient _http;
    private readonly Func<string> _key;

    public TmdbClient(HttpClient http, Func<string> keyProvider)
    {
        _http = http;
        _key = keyProvider;
    }

    /// <summary>A client with sensible timeouts (Android: connect 20 s, read 30 s).</summary>
    public static HttpClient CreateHttpClient() => new(new SocketsHttpHandler
    {
        ConnectTimeout = TimeSpan.FromSeconds(20),
        AutomaticDecompression = DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(10),
    })
    {
        Timeout = TimeSpan.FromSeconds(30),
    };

    public Task<TmdbPage<TmdbMovieSummary>> SearchMovie(string query, int? year = null, CancellationToken ct = default) =>
        Get<TmdbPage<TmdbMovieSummary>>("search/movie", ct, ("query", query), ("year", Num(year)), ("include_adult", "false"));

    public Task<TmdbPage<TmdbTvSummary>> SearchTv(string query, int? year = null, CancellationToken ct = default) =>
        Get<TmdbPage<TmdbTvSummary>>("search/tv", ct, ("query", query), ("first_air_date_year", Num(year)), ("include_adult", "false"));

    public Task<TmdbMovieDetail> Movie(int id, CancellationToken ct = default) =>
        Get<TmdbMovieDetail>($"movie/{id}", ct, ("append_to_response", "credits,release_dates"));

    public Task<TmdbTvDetail> Tv(int id, CancellationToken ct = default) =>
        Get<TmdbTvDetail>($"tv/{id}", ct, ("append_to_response", "credits,content_ratings"));

    public Task<TmdbPage<TmdbMovieSummary>> MovieRecommendations(int id, int page = 1, CancellationToken ct = default) =>
        Get<TmdbPage<TmdbMovieSummary>>($"movie/{id}/recommendations", ct, ("page", Num(page)));

    public Task<TmdbPage<TmdbTvSummary>> TvRecommendations(int id, int page = 1, CancellationToken ct = default) =>
        Get<TmdbPage<TmdbTvSummary>>($"tv/{id}/recommendations", ct, ("page", Num(page)));

    public Task<TmdbCollection> Collection(int id, CancellationToken ct = default) => Get<TmdbCollection>($"collection/{id}", ct);

    public Task<TmdbVideos> MovieVideos(int id, CancellationToken ct = default) => Get<TmdbVideos>($"movie/{id}/videos", ct);

    public Task<TmdbVideos> TvVideos(int id, CancellationToken ct = default) => Get<TmdbVideos>($"tv/{id}/videos", ct);

    public Task<TmdbSeasonDetail> Season(int id, int season, CancellationToken ct = default) =>
        Get<TmdbSeasonDetail>($"tv/{id}/season/{season}", ct);

    public Task<JsonElement> Configuration(CancellationToken ct = default) => Get<JsonElement>("configuration", ct);

    private static string? Num(int? n) => n?.ToString(CultureInfo.InvariantCulture);

    private static bool IsBearerToken(string key) => key.StartsWith("eyJ", StringComparison.Ordinal);

    /// <summary>The request URL with language, and the api_key for v3 keys (exposed for tests).</summary>
    public static string BuildUrl(string path, string key, params (string Name, string? Value)[] query)
    {
        var sb = new StringBuilder(BaseUrl).Append(path);
        var first = true;
        void Add(string name, string value)
        {
            sb.Append(first ? '?' : '&').Append(Uri.EscapeDataString(name)).Append('=').Append(Uri.EscapeDataString(value));
            first = false;
        }
        foreach (var (name, value) in query)
            if (value != null) Add(name, value);
        if (!query.Any(q => q.Name == "language")) Add("language", "en-US");
        if (!IsBearerToken(key)) Add("api_key", key);
        return sb.ToString();
    }

    private async Task<T> Get<T>(string path, CancellationToken ct, params (string Name, string? Value)[] query)
    {
        var key = (_key() ?? "").Trim();
        if (key.Length == 0) throw new TmdbKeyMissingException();
        using var request = new HttpRequestMessage(HttpMethod.Get, BuildUrl(path, key, query));
        if (IsBearerToken(key)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var code = (int)response.StatusCode;
            var message = response.StatusCode switch
            {
                HttpStatusCode.Unauthorized => $"TMDB didn't accept the API key (HTTP {code})",
                HttpStatusCode.NotFound => $"TMDB has no such title (HTTP {code})",
                (HttpStatusCode)429 => $"TMDB is busy, try again in a moment (HTTP {code})",
                _ => $"TMDB request failed (HTTP {code})",
            };
            throw new HttpRequestException(message, null, response.StatusCode);
        }
        await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        try
        {
            var result = await JsonSerializer.DeserializeAsync<T>(stream, Json, ct).ConfigureAwait(false);
            if (result is null) throw new HttpRequestException("TMDB sent an empty response");
            return result;
        }
        catch (JsonException e)
        {
            throw new HttpRequestException("TMDB sent a response Veltoret couldn't read", e);
        }
    }
}
