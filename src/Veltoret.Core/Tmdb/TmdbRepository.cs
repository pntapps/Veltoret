using System.Collections.Concurrent;
using System.Globalization;
using Veltoret.Core.Data;
using Veltoret.Core.Library;

namespace Veltoret.Core.Tmdb;

/// <summary>Looks titles up on TMDB and caches the results in the database (port of Android TmdbRepository).</summary>
public sealed class TmdbRepository
{
    private const long Day = 24L * 60 * 60 * 1000;
    private const int RecommendationPages = 2;
    private static readonly string[] TrailerTypes = { "Trailer", "Teaser" };

    private readonly TmdbClient _api;
    private readonly CatalogDao _catalog;

    /// <summary>"movie:603" → YouTube id, or "" when the title has no trailer.</summary>
    private readonly ConcurrentDictionary<string, string> _trailers = new();
    private readonly ConcurrentDictionary<int, TmdbCollection> _collections = new();

    public TmdbRepository(TmdbClient api, CatalogDao catalog)
    {
        _api = api;
        _catalog = catalog;
    }

    private static long Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public async Task<List<TmdbMovieSummary>> SearchMovies(string q, int? year = null) =>
        (await _api.SearchMovie(q, year).ConfigureAwait(false)).Results ?? new();

    public async Task<List<TmdbTvSummary>> SearchShows(string q, int? year = null) =>
        (await _api.SearchTv(q, year).ConfigureAwait(false)).Results ?? new();

    /// <summary>Throws <see cref="TmdbKeyMissingException"/> or <see cref="HttpRequestException"/> when the key doesn't work.</summary>
    public async Task ValidateKey() => await _api.Configuration().ConfigureAwait(false);

    /// <summary>
    /// The best movie match, retrying without the year when the year-filtered search is empty.
    /// <paramref name="exactOnly"/>: accept only an exact title match (fallback names guessed by trimming a file name).
    /// </summary>
    public async Task<TmdbMovieSummary?> FindMovie(string title, int? year, bool exactOnly = false)
    {
        var results = year != null ? await SearchMovies(title, year).ConfigureAwait(false) : new List<TmdbMovieSummary>();
        if (results.Count == 0) results = await SearchMovies(title).ConfigureAwait(false);
        return PickBest(results, title, year, exactOnly, r => r.Title ?? "", r => r.OriginalTitle, r => r.ReleaseDate, r => r.VoteCount);
    }

    public async Task<TmdbTvSummary?> FindShow(string title, int? year, bool exactOnly = false)
    {
        var results = year != null ? await SearchShows(title, year).ConfigureAwait(false) : new List<TmdbTvSummary>();
        if (results.Count == 0) results = await SearchShows(title).ConfigureAwait(false);
        return PickBest(results, title, year, exactOnly, r => r.Name ?? "", r => r.OriginalName, r => r.FirstAirDate, r => r.VoteCount);
    }

    public async Task EnsureMovie(int id, long maxAgeMs = 30L * Day)
    {
        var existing = await _catalog.Movie(id).ConfigureAwait(false);
        if (existing != null && Now - existing.UpdatedAt < maxAgeMs) return;
        var d = await _api.Movie(id).ConfigureAwait(false);
        var certification = d.ReleaseDates?.Results?
            .FirstOrDefault(r => r.Country == "US")?
            .ReleaseDates?.FirstOrDefault(r => !string.IsNullOrWhiteSpace(r.Certification))?.Certification;
        await _catalog.UpsertMovie(new MovieEntity
        {
            TmdbId = d.Id,
            Title = d.Title ?? "",
            OriginalTitle = d.OriginalTitle,
            Overview = d.Overview ?? "",
            Tagline = string.IsNullOrWhiteSpace(d.Tagline) ? null : d.Tagline,
            ReleaseDate = d.ReleaseDate,
            Year = YearOf(d.ReleaseDate),
            RuntimeMin = d.Runtime is > 0 ? d.Runtime : null,
            Rating = d.VoteAverage,
            Certification = certification,
            PosterPath = d.PosterPath,
            BackdropPath = d.BackdropPath,
            Genres = string.Join(",", (d.Genres ?? new()).Select(g => g.Name)),
            CollectionId = d.Collection?.Id,
            CollectionName = d.Collection?.Name,
            Director = d.Credits?.Crew?.FirstOrDefault(c => c.Job == "Director")?.Name,
            UpdatedAt = Now,
        }).ConfigureAwait(false);
        await _catalog.ReplaceCredits("movie", d.Id, ToCredits(d.Credits?.Cast, "movie", d.Id)).ConfigureAwait(false);
    }

    /// <summary>Stores show details plus full episode lists for <paramref name="seasonsNeeded"/>.</summary>
    public async Task EnsureShow(int id, IReadOnlySet<int> seasonsNeeded, long maxAgeMs = 7L * Day)
    {
        var existing = await _catalog.Show(id).ConfigureAwait(false);
        var now = Now;
        if (existing == null || now - existing.UpdatedAt >= maxAgeMs)
        {
            var d = await _api.Tv(id).ConfigureAwait(false);
            var creator = string.Join(", ", (d.CreatedBy ?? new()).Select(c => c.Name));
            await _catalog.UpsertShow(new ShowEntity
            {
                TmdbId = d.Id,
                Name = d.Name ?? "",
                Overview = d.Overview ?? "",
                Tagline = string.IsNullOrWhiteSpace(d.Tagline) ? null : d.Tagline,
                FirstAirDate = d.FirstAirDate,
                Year = YearOf(d.FirstAirDate),
                LastAirDate = d.LastAirDate,
                Status = d.Status,
                Rating = d.VoteAverage,
                Certification = d.ContentRatings?.Results?.FirstOrDefault(r => r.Country == "US")?.Rating is { } r && !string.IsNullOrWhiteSpace(r) ? r : null,
                PosterPath = d.PosterPath,
                BackdropPath = d.BackdropPath,
                Genres = string.Join(",", (d.Genres ?? new()).Select(g => g.Name)),
                Network = d.Networks?.FirstOrDefault()?.Name,
                SeasonCount = d.NumberOfSeasons,
                EpisodeCount = d.NumberOfEpisodes,
                EpisodeRuntimeMin = d.EpisodeRunTime is { Count: > 0 } rt ? rt[0] : null,
                Creator = string.IsNullOrWhiteSpace(creator) ? null : creator,
                UpdatedAt = now,
                NextEpisodeSeason = d.NextEpisode?.SeasonNumber,
                NextEpisodeNumber = d.NextEpisode?.EpisodeNumber,
                NextEpisodeName = string.IsNullOrWhiteSpace(d.NextEpisode?.Name) ? null : d.NextEpisode!.Name,
                NextEpisodeAirDate = string.IsNullOrWhiteSpace(d.NextEpisode?.AirDate) ? null : d.NextEpisode!.AirDate,
            }).ConfigureAwait(false);
            await _catalog.UpsertSeasons((d.Seasons ?? new()).Select(s => new SeasonEntity
            {
                ShowId = d.Id,
                SeasonNumber = s.SeasonNumber,
                Name = s.Name ?? "",
                Overview = s.Overview ?? "",
                PosterPath = s.PosterPath,
                EpisodeCount = s.EpisodeCount,
                AirDate = s.AirDate,
                FetchedAt = 0,
            }).ToList()).ConfigureAwait(false);
            await _catalog.ReplaceCredits("tv", d.Id, ToCredits(d.Credits?.Cast, "tv", d.Id)).ConfigureAwait(false);
        }
        foreach (var seasonNumber in seasonsNeeded)
        {
            var season = await _catalog.Season(id, seasonNumber).ConfigureAwait(false);
            if (season != null && now - season.FetchedAt < maxAgeMs) continue;
            TmdbSeasonDetail s;
            try
            {
                s = await _api.Season(id, seasonNumber).ConfigureAwait(false);
            }
            catch (TmdbKeyMissingException)
            {
                throw;
            }
            catch (Exception)
            {
                continue; // runCatching in Android: a missing season doesn't fail the show
            }
            var episodes = s.Episodes ?? new();
            await _catalog.UpsertSeasons(new[]
            {
                new SeasonEntity
                {
                    ShowId = id,
                    SeasonNumber = s.SeasonNumber,
                    Name = s.Name ?? "",
                    Overview = s.Overview ?? "",
                    PosterPath = s.PosterPath ?? season?.PosterPath,
                    EpisodeCount = episodes.Count,
                    AirDate = s.AirDate,
                    FetchedAt = now,
                },
            }).ConfigureAwait(false);
            await _catalog.UpsertEpisodes(episodes.Select(e => new EpisodeEntity
            {
                ShowId = id,
                SeasonNumber = e.SeasonNumber,
                EpisodeNumber = e.EpisodeNumber,
                Name = e.Name ?? "",
                Overview = e.Overview ?? "",
                StillPath = e.StillPath,
                AirDate = e.AirDate,
                RuntimeMin = e.Runtime,
                Rating = e.VoteAverage,
            }).ToList()).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Stores TMDB's recommendations for a movie (<paramref name="type"/> "movie") or show ("tv"). Fetches the first
    /// two pages (20 titles each) so a personal library has a fair chance of owning some.
    /// </summary>
    public async Task EnsureRecommendations(string type, int id, long maxAgeMs = 30L * Day)
    {
        var fetchedAt = await _catalog.RecommendationsFetchedAt(type, id).ConfigureAwait(false);
        if (fetchedAt != null && Now - fetchedAt.Value < maxAgeMs) return;
        var ids = new List<int>();
        for (var page = 1; page <= RecommendationPages; page++)
        {
            int pages;
            if (type == "movie")
            {
                var p = await _api.MovieRecommendations(id, page).ConfigureAwait(false);
                ids.AddRange((p.Results ?? new()).Select(r => r.Id));
                pages = p.TotalPages;
            }
            else
            {
                var p = await _api.TvRecommendations(id, page).ConfigureAwait(false);
                ids.AddRange((p.Results ?? new()).Select(r => r.Id));
                pages = p.TotalPages;
            }
            if (page >= pages) break;
        }
        await _catalog.UpsertRecommendations(new RecommendationEntity
        {
            MediaType = type,
            MediaId = id,
            RecommendedIds = string.Join(",", ids.Distinct().Where(x => x != id)),
            FetchedAt = Now,
        }).ConfigureAwait(false);
    }

    /// <summary>
    /// The YouTube id of the title's trailer (<paramref name="type"/> "movie" or "tv"), or null when TMDB lists none.
    /// Kept for the session; nothing is stored in the database.
    /// </summary>
    public async Task<string?> Trailer(string type, int id)
    {
        var key = $"{type}:{id}";
        if (_trailers.TryGetValue(key, out var known)) return known.Length == 0 ? null : known;
        var videos = type == "movie" ? await _api.MovieVideos(id).ConfigureAwait(false) : await _api.TvVideos(id).ConfigureAwait(false);
        var picked = PickTrailer(videos.Results ?? new(), newest: type == "tv");
        _trailers[key] = picked ?? "";
        return picked;
    }

    /// <summary>A movie collection with all its parts, oldest first (undated last). Kept for the session.</summary>
    public async Task<TmdbCollection> Collection(int id)
    {
        if (_collections.TryGetValue(id, out var cached)) return cached;
        var c = await _api.Collection(id).ConfigureAwait(false);
        var sorted = c with
        {
            Parts = (c.Parts ?? new())
                .OrderBy(p => string.IsNullOrEmpty(p.ReleaseDate) ? "9999" : p.ReleaseDate, StringComparer.Ordinal)
                .ToList(),
        };
        _collections[id] = sorted;
        return sorted;
    }

    private static List<CreditEntity> ToCredits(List<TmdbCast>? cast, string type, int id)
    {
        var seen = new HashSet<int>();
        return (cast ?? new()).Take(30).Where(c => seen.Add(c.Id)).Select(c => new CreditEntity
        {
            MediaType = type,
            MediaId = id,
            PersonId = c.Id,
            Name = c.Name ?? "",
            Character = c.Character,
            ProfilePath = c.ProfilePath,
            Ord = c.Order,
        }).ToList();
    }

    /// <summary>
    /// Strict on purpose (see CLAUDE.md): exact or close partial titles only, a year bonus, and no guesses for short
    /// yearless names that only match something nobody has rated.
    /// </summary>
    public static T? PickBest<T>(
        IReadOnlyList<T> results,
        string wantTitle,
        int? wantYear,
        bool exactOnly,
        Func<T, string> title,
        Func<T, string?> originalTitle,
        Func<T, string?> date,
        Func<T, int> votes) where T : class
    {
        if (results.Count == 0) return null;
        var want = FilenameParser.NormalizeForCompare(wantTitle);
        if (string.IsNullOrWhiteSpace(want)) return null;
        T? best = null;
        var bestScore = 0.0;
        var index = 0;
        foreach (var item in results.Take(8))
        {
            var i = index++;
            var names = new[] { title(item), originalTitle(item) }.Where(n => n != null).Select(n => FilenameParser.NormalizeForCompare(n!)).ToList();
            var y = YearOf(date(item));
            int? yearDiff = wantYear != null && y != null ? Math.Abs(y.Value - wantYear.Value) : null;
            var exact = names.Any(n => n == want);
            // A partial title match ("vids" vs "ambient vids") only counts when the names are close in
            // length or the year agrees; otherwise any short filename would grab an obscure title.
            var partial = !exact && names.Any(n =>
                (n.Contains(want, StringComparison.Ordinal) || want.Contains(n, StringComparison.Ordinal)) &&
                ((double)Math.Min(n.Length, want.Length) / Math.Max(n.Length, want.Length) >= 0.6 || yearDiff == 0));
            if (!exact && !partial) continue;
            // Fallback names (see FilenameParser.TitleCandidate) need the exact title and, when known, a close year.
            if (exactOnly && (!exact || (yearDiff != null && yearDiff > 1))) continue;
            var score = exact ? 3.0 : 1.0;
            score -= i * 0.15;
            score += yearDiff switch
            {
                null => 0.0,
                0 => 2.0,
                1 => 1.0,
                _ => -0.5,
            };
            // Prefer titles people have actually rated; breaks ties between remakes and obscure uploads.
            score += Math.Min(Math.Log10(votes(item) + 1.0), 4.0) * 0.25;
            // A bare title with no year that only matches something nobody has heard of is a guess.
            if (wantYear == null && votes(item) < 20 && want.Length < 12) continue;
            if (best == null || score > bestScore)
            {
                best = item;
                bestScore = score;
            }
        }
        return best;
    }

    public static int? YearOf(string? date)
    {
        if (date == null) return null;
        var head = date.Length > 4 ? date[..4] : date;
        return int.TryParse(head, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var y) ? y : null;
    }

    /// <summary>
    /// YouTube trailers first, then teasers (no clips or featurettes); official uploads first. Movies take
    /// the earliest (the original trailer, not a re-release); shows take the newest (the latest season's).
    /// </summary>
    public static string? PickTrailer(IReadOnlyList<TmdbVideo> videos, bool newest)
    {
        int Compare(TmdbVideo a, TmdbVideo b)
        {
            var c = Array.IndexOf(TrailerTypes, a.Type).CompareTo(Array.IndexOf(TrailerTypes, b.Type));
            if (c != 0) return c;
            c = (!a.Official).CompareTo(!b.Official);
            if (c != 0) return c;
            // ISO dates sort as text; undated videos go last either way.
            var x = a.PublishedAt ?? "";
            var y = b.PublishedAt ?? "";
            if (x.Length == 0 || y.Length == 0) return Math.Clamp(y.Length.CompareTo(x.Length), -1, 1);
            return newest ? string.CompareOrdinal(y, x) : string.CompareOrdinal(x, y);
        }
        return videos
            .Where(v => string.Equals(v.Site, "YouTube", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(v.Key) && TrailerTypes.Contains(v.Type))
            .OrderBy(v => v, Comparer<TmdbVideo>.Create(Compare))
            .FirstOrDefault()?.Key;
    }
}
