using CommunityToolkit.Mvvm.ComponentModel;
using Veltoret.App.Controls;
using Veltoret.App.Services;
using Veltoret.Core.Data;
using Veltoret.Core.Library;
using Veltoret.Core.Storage;

namespace Veltoret.App.Pages.Library;

using Accounts = Veltoret.Core.Storage.Accounts;

public enum WatchFilter { All, Unwatched, InProgress, Watched, FourK }
public enum LibrarySort { Recent, Title, Year, Rating }
public enum WatchStatus { Unwatched, InProgress, Watched }

public sealed record LibraryEntry(PosterItem Item, WatchStatus Status, bool Uhd, IReadOnlySet<string> Sources,
    IReadOnlyList<string> Genres, long AddedAt, string SortTitle, int Year, double Rating);

public sealed record SourceOption(string Account, string Label);

/// <summary>Movies / TV Shows grids (Android LibraryScreens + view models, §4 of the spec).</summary>
public sealed partial class LibraryViewModel : ObservableObject
{
    public LibraryViewModel(bool shows)
    {
        Shows = shows;
        var mem = shows ? ShowsMemory : MoviesMemory;
        _filter = mem.Filter;
        _genre = mem.Genre;
        _sort = mem.Sort;
        _source = mem.Source;
    }

    // Filter state per screen, in memory (survives navigating away and back).
    private sealed class Memory
    {
        public WatchFilter Filter;
        public string? Genre;
        public LibrarySort Sort;
        public string? Source;
    }

    private static readonly Memory MoviesMemory = new();
    private static readonly Memory ShowsMemory = new();
    private Memory Mem => Shows ? ShowsMemory : MoviesMemory;

    public bool Shows { get; }

    [ObservableProperty] private bool _loading = true;
    [ObservableProperty] private bool _online = true;
    [ObservableProperty] private int _unmatched;
    [ObservableProperty] private IReadOnlyList<LibraryEntry> _all = Array.Empty<LibraryEntry>();
    [ObservableProperty] private IReadOnlyList<PosterItem> _shown = Array.Empty<PosterItem>();
    [ObservableProperty] private IReadOnlyList<string> _genres = Array.Empty<string>();
    [ObservableProperty] private IReadOnlyList<SourceOption> _sources = Array.Empty<SourceOption>();
    [ObservableProperty] private WatchFilter _filter;
    [ObservableProperty] private string? _genre;
    [ObservableProperty] private LibrarySort _sort;
    [ObservableProperty] private string? _source;

    partial void OnFilterChanged(WatchFilter value) { Mem.Filter = value; Apply(); }
    partial void OnGenreChanged(string? value) { Mem.Genre = value; Apply(); }
    partial void OnSortChanged(LibrarySort value) { Mem.Sort = value; Apply(); }
    partial void OnSourceChanged(string? value) { Mem.Source = value; Apply(); }

    public static readonly string[] WatchedTables = { "movies", "shows", "media_files", "watch_state" };

    public string? SourceLabel => Sources.FirstOrDefault(s => s.Account == Source)?.Label;

    public async Task Load()
    {
        var lib = AppServices.Library;
        var online = AppServices.Connectivity.IsOnline;
        var states = await AppServices.Watch.All();
        var unmatched = await lib.Unmatched();
        var stateByKey = new Dictionary<string, WatchStateEntity>();
        foreach (var s in states) stateByKey[s.Key] = s;
        List<LibraryEntry> entries;
        List<TitleSource> sources;
        if (!Shows)
        {
            var movies = await lib.Movies();
            sources = await lib.MovieSources();
            var srcByTitle = sources.GroupBy(s => s.TitleId).ToDictionary(g => g.Key, g => (IReadOnlySet<string>)g.Select(s => s.AccountEmail).ToHashSet());
            entries = movies.Select(r =>
            {
                var st = stateByKey.GetValueOrDefault(WatchKeys.Movie(r.Movie.TmdbId));
                var status = st?.Watched == true ? WatchStatus.Watched : st is { PositionMs: > 30_000 } ? WatchStatus.InProgress : WatchStatus.Unwatched;
                var item = new PosterItem
                {
                    Id = r.Movie.TmdbId,
                    Title = r.Movie.Title,
                    Subtitle = PosterItems.NullIfEmpty(Formats.JoinTight(r.Movie.Year?.ToString(), Formats.Runtime(r.Movie.RuntimeMin))),
                    PosterUrl = Veltoret.Core.Tmdb.TmdbImages.Poster(r.Movie.PosterPath),
                    Progress = status == WatchStatus.InProgress ? st!.Progress : null,
                    Watched = status == WatchStatus.Watched,
                    Rating = r.Movie.Rating,
                };
                return new LibraryEntry(item, status, r.MaxHeight >= 1600, srcByTitle.GetValueOrDefault(r.Movie.TmdbId) ?? new HashSet<string>(),
                    r.Movie.GenreList, r.AddedAt, SortKey(r.Movie.Title), r.Movie.Year ?? 0, r.Movie.Rating);
            }).ToList();
        }
        else
        {
            var shows = await lib.Shows();
            sources = await lib.ShowSources();
            var files = await lib.EpisodeFiles();
            var uhdShows = files.Where(f => f.Height >= 1600 && f.ShowId != null).Select(f => f.ShowId!.Value).ToHashSet();
            var srcByTitle = sources.GroupBy(s => s.TitleId).ToDictionary(g => g.Key, g => (IReadOnlySet<string>)g.Select(s => s.AccountEmail).ToHashSet());
            var watchedByShow = states.Where(s => s.Watched && s.ShowId != null && s.Season != null && s.Episode != null)
                .GroupBy(s => s.ShowId!.Value)
                .ToDictionary(g => g.Key, g => g.Select(s => (s.Season!.Value, s.Episode!.Value)).Distinct().Count());
            entries = shows.Select(r =>
            {
                var w = watchedByShow.GetValueOrDefault(r.Show.TmdbId);
                var n = r.AvailableEpisodes;
                var status = w == 0 ? WatchStatus.Unwatched : w >= n ? WatchStatus.Watched : WatchStatus.InProgress;
                var item = new PosterItem
                {
                    Id = r.Show.TmdbId,
                    IsShow = true,
                    Title = r.Show.Name,
                    Subtitle = status == WatchStatus.InProgress ? $"{w} of {n} watched" : Formats.Episodes(n),
                    PosterUrl = Veltoret.Core.Tmdb.TmdbImages.Poster(r.Show.PosterPath),
                    Progress = status == WatchStatus.InProgress && n > 0 ? (double)w / n : null,
                    Rating = r.Show.Rating,
                };
                return new LibraryEntry(item, status, uhdShows.Contains(r.Show.TmdbId), srcByTitle.GetValueOrDefault(r.Show.TmdbId) ?? new HashSet<string>(),
                    r.Show.GenreList, r.AddedAt, SortKey(r.Show.Name), r.Show.Year ?? 0, r.Show.Rating);
            }).ToList();
        }

        // Sources: only when online; accounts that hold something; device, Google, then network servers; hidden if ≤ 1.
        var options = new List<SourceOption>();
        if (online)
        {
            var held = entries.SelectMany(e => e.Sources).ToHashSet();
            var ordered = held.OrderBy(a => Accounts.IsLocal(a) ? 0 : Accounts.IsDrive(a) ? 1 : 2).ThenBy(a => a, StringComparer.OrdinalIgnoreCase);
            foreach (var a in ordered) options.Add(new SourceOption(a, LabelFor(a)));
            if (options.Count <= 1) options.Clear();
        }

        Online = online;
        Unmatched = unmatched.Count(f => f.Kind == (Shows ? MediaKind.EPISODE : MediaKind.MOVIE));
        Genres = entries.SelectMany(e => e.Genres).GroupBy(g => g).OrderByDescending(g => g.Count()).Select(g => g.Key).ToList();
        Sources = options;
        All = entries;
        Loading = false;
        if (Source != null && options.All(o => o.Account != Source)) Source = null; // a source that disappeared falls back to all
        if (Genre != null && !Genres.Contains(Genre)) Genre = null;
        Apply();
    }

    public static string LabelFor(string account)
    {
        if (Accounts.IsLocal(account)) return Accounts.DeviceDisplayName;
        if (Accounts.IsSmb(account))
        {
            try { return AppServices.Storage.RootName(account); }
            catch (Exception) { return account.Replace("smb://", ""); }
        }
        return account;
    }

    private static string SortKey(string title)
    {
        var t = title.StartsWith("The ", StringComparison.Ordinal) ? title[4..] : title;
        return t.ToLowerInvariant();
    }

    private void Apply()
    {
        IEnumerable<LibraryEntry> q = All;
        if (Source != null) q = q.Where(e => e.Sources.Contains(Source));
        if (Genre != null) q = q.Where(e => e.Genres.Contains(Genre));
        q = Filter switch
        {
            WatchFilter.FourK => q.Where(e => e.Uhd),
            WatchFilter.Unwatched => q.Where(e => e.Status == WatchStatus.Unwatched),
            WatchFilter.InProgress => q.Where(e => e.Status == WatchStatus.InProgress),
            WatchFilter.Watched => q.Where(e => e.Status == WatchStatus.Watched),
            _ => q,
        };
        q = Sort switch
        {
            LibrarySort.Title => q.OrderBy(e => e.SortTitle, StringComparer.Ordinal),
            LibrarySort.Year => q.OrderByDescending(e => e.Year),
            LibrarySort.Rating => q.OrderByDescending(e => e.Rating),
            _ => q.OrderByDescending(e => e.AddedAt),
        };
        Shown = q.Select(e => e.Item).ToList();
    }
}
