using CommunityToolkit.Mvvm.ComponentModel;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Tmdb;

namespace Veltoret.App.Pages.Home;

public sealed record FeaturedItem
{
    public int Id { get; init; }
    public bool IsShow { get; init; }
    public string Title { get; init; } = "";
    public string? BackdropUrl { get; init; }
    /// <summary>Meta parts joined with "  �  " (MetaLine).</summary>
    public string Meta { get; init; } = "";
    public string Overview { get; init; } = "";
    public double Rating { get; init; }
}

public sealed record HomeRow(string Title, bool Wide, IReadOnlyList<object> Items, string? Action = null, Navigation.Route? ActionRoute = null);

/// <summary>Everything Home shows, computed in one pass (Android HomeViewModel, row logic §3.3 of the spec).</summary>
public sealed record HomeState
{
    public bool Loading { get; init; } = true;
    public bool HasFolders { get; init; }
    public bool IsEmpty { get; init; }
    public bool Online { get; init; } = true;
    public int UnmatchedCount { get; init; }
    public int ArchiveCount { get; init; }
    public IReadOnlyList<FeaturedItem> Featured { get; init; } = Array.Empty<FeaturedItem>();
    public IReadOnlyList<HomeRow> Rows { get; init; } = Array.Empty<HomeRow>();
}

public sealed partial class HomeViewModel : ObservableObject
{
    [ObservableProperty] private HomeState _state = new();
    [ObservableProperty] private ScanState _scan = new();

    public static readonly string[] WatchedTables =
    {
        "movies", "shows", "media_files", "watch_state", "watchlist", "episodes", "library_folders", "archive_files",
    };

    public async Task Load()
    {
        var lib = AppServices.Library;
        var online = AppServices.Connectivity.IsOnline;
        var moviesT = lib.Movies();
        var showsT = lib.Shows();
        var statesT = AppServices.Watch.All();
        var filesT = lib.EpisodeFiles();
        var episodesT = lib.AllEpisodes();
        var unmatchedT = lib.Unmatched();
        var archivesT = lib.Archives();
        var foldersT = lib.Folders();
        Task<List<WatchlistEntity>> watchlistT;
        try { watchlistT = AppServices.Plans.Watchlist(); }
        catch (Exception) { watchlistT = AppServices.PlansDao.Watchlist(); }
        await Task.WhenAll(moviesT, showsT, statesT, filesT, episodesT, unmatchedT, archivesT, foldersT, watchlistT);
        var result = await Task.Run(() => Compute(moviesT.Result, showsT.Result, statesT.Result, filesT.Result, episodesT.Result,
            watchlistT.Result, unmatchedT.Result.Count, archivesT.Result.Count, foldersT.Result.Count > 0, online));
        State = result;
    }

    private static DateTime Today => DateTime.Today;

    public static HomeState Compute(
        List<MovieRow> movies, List<ShowRow> shows, List<WatchStateEntity> states, List<MediaFileEntity> episodeFiles,
        List<EpisodeEntity> episodes, List<WatchlistEntity> watchlist, int unmatched, int archives, bool hasFolders, bool online)
    {
        var stateByKey = new Dictionary<string, WatchStateEntity>();
        foreach (var s in states) stateByKey[s.Key] = s;
        var movieById = new Dictionary<int, MovieRow>();
        foreach (var m in movies) movieById[m.Movie.TmdbId] = m;
        var showById = new Dictionary<int, ShowRow>();
        foreach (var s in shows) showById[s.Show.TmdbId] = s;
        var episodeByKey = new Dictionary<(int, int, int), EpisodeEntity>();
        foreach (var e in episodes) episodeByKey[(e.ShowId, e.SeasonNumber, e.EpisodeNumber)] = e;
        WatchStateEntity? MovieState(int id) => stateByKey.GetValueOrDefault(WatchKeys.Movie(id));
        PosterItem MoviePoster(MovieRow r) => PosterItems.Movie(r.Movie, MovieState(r.Movie.TmdbId));
        PosterItem ShowPoster(ShowRow r) => PosterItems.Show(r.Show, r.AvailableEpisodes);

        // ---- Featured ----
        var merged = movies.Select(m => (m.AddedAt, Movie: (MovieRow?)m, Show: (ShowRow?)null))
            .Concat(shows.Select(s => (s.AddedAt, Movie: (MovieRow?)null, Show: (ShowRow?)s)))
            .OrderByDescending(x => x.AddedAt)
            .ToList();
        var featuredAll = new List<FeaturedItem>();
        foreach (var x in merged)
        {
            if (x.Show is { } s)
            {
                if (s.Show.BackdropPath == null) continue;
                featuredAll.Add(new FeaturedItem
                {
                    Id = s.Show.TmdbId, IsShow = true, Title = s.Show.Name, BackdropUrl = TmdbImages.Backdrop(s.Show.BackdropPath),
                    Meta = Formats.Join( s.Show.Year?.ToString(), s.Show.Certification, FirstGenre(s.Show.Genres), s.Show.SeasonCount > 0 ? Formats.Seasons(s.Show.SeasonCount) : null),
                    Overview = s.Show.Overview, Rating = s.Show.Rating,
                });
            }
            else if (x.Movie is { } m)
            {
                if (m.Movie.BackdropPath == null || MovieState(m.Movie.TmdbId)?.Watched == true) continue;
                featuredAll.Add(new FeaturedItem
                {
                    Id = m.Movie.TmdbId, Title = m.Movie.Title, BackdropUrl = TmdbImages.Backdrop(m.Movie.BackdropPath),
                    Meta = Formats.Join( m.Movie.Year?.ToString(), m.Movie.Certification, FirstGenre(m.Movie.Genres), Formats.Runtime(m.Movie.RuntimeMin)),
                    Overview = m.Movie.Overview, Rating = m.Movie.Rating,
                });
            }
        }
        var good = featuredAll.Where(f => f.Rating >= 5.5).ToList();
        var featured = (good.Count > 0 ? good : featuredAll).Take(6).ToList();

        // ---- Continue Watching ----
        var fileKeys = new HashSet<(int, int, int)>();
        var filesByShow = new Dictionary<int, List<MediaFileEntity>>();
        foreach (var f in episodeFiles)
        {
            if (f.ShowId is not { } sid) continue;
            if (f.Season is { } se && f.Episode is { } ep) fileKeys.Add((sid, se, ep));
            if (!filesByShow.TryGetValue(sid, out var list)) filesByShow[sid] = list = new List<MediaFileEntity>();
            list.Add(f);
        }
        string? StillOrBackdrop(ShowEntity show, int season, int episode) =>
            episodeByKey.TryGetValue((show.TmdbId, season, episode), out var e) && e.StillPath != null
                ? TmdbImages.Still(e.StillPath, "w780")
                : TmdbImages.Backdrop(show.BackdropPath, "w780");
        string EpisodeSubtitle(int showId, int season, int episode)
        {
            var name = episodeByKey.TryGetValue((showId, season, episode), out var e) ? e.Name : null;
            return Formats.Join(Formats.EpisodeCode(season, episode), name);
        }

        var continueItems = new List<PlayItem>();
        foreach (var s in states.Where(s => !s.Watched && s.PositionMs > 30_000 && s.LastFileId != null).OrderByDescending(s => s.LastWatchedAt))
        {
            if (s.MovieId is { } mid)
            {
                if (!movieById.TryGetValue(mid, out var row)) continue;
                continueItems.Add(new PlayItem
                {
                    FileId = s.LastFileId!, Title = row.Movie.Title, Subtitle = Formats.Remaining(s.PositionMs, s.DurationMs),
                    ImageUrl = TmdbImages.Backdrop(row.Movie.BackdropPath, "w780"), Progress = s.Progress, MovieId = mid,
                });
            }
            else if (s is { ShowId: { } sid, Season: { } se, Episode: { } ep })
            {
                if (!fileKeys.Contains((sid, se, ep)) || !showById.TryGetValue(sid, out var show)) continue;
                continueItems.Add(new PlayItem
                {
                    FileId = s.LastFileId!, Title = show.Show.Name, Subtitle = EpisodeSubtitle(sid, se, ep),
                    ImageUrl = StillOrBackdrop(show.Show, se, ep), Progress = s.Progress,
                    Caption = Formats.Remaining(s.PositionMs, s.DurationMs), ShowId = sid, Season = se, Episode = ep,
                });
            }
            if (continueItems.Count >= 20) break;
        }

        // ---- Next Up ----
        var inContinue = continueItems.Where(c => c.ShowId != null).Select(c => c.ShowId!.Value).ToHashSet();
        var statesByShow = states.Where(s => s.ShowId != null).GroupBy(s => s.ShowId!.Value).ToDictionary(g => g.Key, g => g.ToList());
        var nextUp = new List<(long Last, PlayItem Item)>();
        foreach (var (sid, files) in filesByShow)
        {
            if (inContinue.Contains(sid)) continue;
            var showStates = statesByShow.GetValueOrDefault(sid) ?? new List<WatchStateEntity>();
            if (!showStates.Any(s => s.Watched)) continue;
            var target = PlayTargets.NextEpisode(files, showStates);
            if (target == null || !showById.TryGetValue(sid, out var show)) continue;
            var se = target.File.Season!.Value;
            var ep = target.File.Episode!.Value;
            nextUp.Add((showStates.Max(s => s.LastWatchedAt), new PlayItem
            {
                FileId = target.File.DriveId, Title = show.Show.Name, Subtitle = EpisodeSubtitle(sid, se, ep),
                ImageUrl = StillOrBackdrop(show.Show, se, ep), Caption = "Next", ShowId = sid, Season = se, Episode = ep,
            }));
        }
        var nextUpItems = nextUp.OrderByDescending(x => x.Last).Take(20).Select(x => x.Item).ToList();

        // ---- Watchlist ----
        var watchlistItems = new List<PosterItem>();
        foreach (var w in watchlist)
        {
            if (w.MediaType == "movie")
            {
                if (movieById.TryGetValue(w.MediaId, out var m) && MovieState(w.MediaId)?.Watched != true) watchlistItems.Add(MoviePoster(m));
            }
            else if (showById.TryGetValue(w.MediaId, out var s)) watchlistItems.Add(ShowPoster(s));
        }

        // ---- Coming Up ----
        var followed = watchlist.Where(w => w.MediaType == "tv").Select(w => w.MediaId).ToHashSet();
        foreach (var s in states) if (s.ShowId is { } id) followed.Add(id);
        var comingUp = shows
            .Where(s => followed.Contains(s.Show.TmdbId))
            .Select(s => (Row: s, Date: Formats.ParseDate(s.Show.NextEpisodeAirDate)))
            .Where(x => x.Date != null && x.Date.Value.Date >= Today)
            .OrderBy(x => x.Date)
            .Select(x => PosterItems.Show(x.Row.Show, x.Row.AvailableEpisodes,
                subtitle: PosterItems.NullIfEmpty(Formats.EpisodeCode(x.Row.Show.NextEpisodeSeason, x.Row.Show.NextEpisodeNumber)),
                badge: Formats.AirLabel(x.Date!.Value)) with { Subtitle = PosterItems.NullIfEmpty(Formats.EpisodeCode(x.Row.Show.NextEpisodeSeason, x.Row.Show.NextEpisodeNumber)) })
            .ToList();

        // ---- Recently added / updated ----
        var recentMovies = movies.OrderByDescending(m => m.AddedAt).Take(20).Select(MoviePoster).ToList();
        var recentShows = shows.OrderByDescending(s => s.AddedAt).Take(20).Select(ShowPoster).ToList();

        // ---- Highly Rated ----
        var rated = movies.Where(m => m.Movie.Rating >= 7.0).Select(m => (m.Movie.Rating, Item: MoviePoster(m)))
            .Concat(shows.Where(s => s.Show.Rating >= 7.0).Select(s => (s.Show.Rating, Item: ShowPoster(s))))
            .OrderByDescending(x => x.Rating).Take(20).Select(x => x.Item).ToList();
        if (rated.Count < 4) rated.Clear();

        // ---- Collections ----
        var collections = movies.Where(m => m.Movie.CollectionId != null)
            .GroupBy(m => m.Movie.CollectionId!.Value)
            .Where(g => g.Count() >= 2)
            .Select(g =>
            {
                var latest = g.OrderByDescending(m => m.Movie.ReleaseDate ?? "", StringComparer.Ordinal).First();
                var first = g.First();
                return (Added: g.Max(m => m.AddedAt), Item: new PosterItem
                {
                    Id = g.Key, IsCollection = true,
                    Title = first.Movie.CollectionName ?? first.Movie.Title,
                    Subtitle = Formats.Plural(g.Count(), "movie", "movies"),
                    PosterUrl = TmdbImages.Poster(latest.Movie.PosterPath),
                });
            })
            .OrderByDescending(x => x.Added).Select(x => x.Item).ToList();

        // ---- Genre rows ----
        var byGenre = new Dictionary<string, List<(double Rating, PosterItem Item)>>();
        void AddGenres(string genres, double rating, PosterItem item)
        {
            foreach (var g in genres.Split(','))
            {
                var name = g.Trim();
                if (name.Length == 0) continue;
                if (!byGenre.TryGetValue(name, out var list)) byGenre[name] = list = new();
                list.Add((rating, item));
            }
        }
        foreach (var m in movies) AddGenres(m.Movie.Genres, m.Movie.Rating, MoviePoster(m));
        foreach (var s in shows) AddGenres(s.Show.Genres, s.Show.Rating, ShowPoster(s));
        var genreRows = byGenre.Where(kv => kv.Value.Count >= 4)
            .OrderByDescending(kv => kv.Value.Count)
            .Take(5)
            .Select(kv => new HomeRow(kv.Key, false, kv.Value.OrderByDescending(x => x.Rating).Take(20).Select(x => (object)x.Item).ToList()))
            .ToList();

        var rows = new List<HomeRow>();
        void Add(string title, bool wide, IReadOnlyList<object> items, string? action = null, Navigation.Route? route = null)
        {
            if (items.Count > 0) rows.Add(new HomeRow(title, wide, items, action, route));
        }
        Add("Continue Watching", true, continueItems);
        Add("Next Up", true, nextUpItems);
        Add("Watchlist", false, watchlistItems);
        Add("Coming Up", false, comingUp);
        Add("Recently Added Movies", false, recentMovies, "See all", new Navigation.MoviesRoute());
        Add("Recently Updated Shows", false, recentShows, "See all", new Navigation.ShowsRoute());
        Add("Highly Rated", false, rated);
        Add("Collections", false, collections);
        rows.AddRange(genreRows);

        return new HomeState
        {
            Loading = false,
            HasFolders = hasFolders,
            IsEmpty = recentMovies.Count == 0 && recentShows.Count == 0,
            Online = online,
            UnmatchedCount = unmatched,
            ArchiveCount = archives,
            Featured = featured,
            Rows = rows,
        };
    }

    private static string? FirstGenre(string genres)
    {
        var first = genres.Split(',').FirstOrDefault()?.Trim();
        return string.IsNullOrEmpty(first) ? null : first;
    }
}
