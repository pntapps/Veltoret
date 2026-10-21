using Veltoret.Core.Data;
using Veltoret.Core.Net;
using Veltoret.Core.Storage;

namespace Veltoret.Core.Library;

/// <summary>
/// What the screens read (port of Android LibraryRepository, plus folder management from AccountRepository).
/// Android's Flows are plain queries here: re-run them when <see cref="VeltoretDb.Changed"/> names a table they
/// show, or when <see cref="Connectivity.OnlineChanged"/> fires (offline, the library is what can actually play:
/// titles with a copy on this PC).
/// </summary>
public sealed class LibraryRepository
{
    private readonly CatalogDao _catalog;
    private readonly MediaFileDao _files;
    private readonly AccountDao _accounts;
    private readonly Connectivity _connectivity;

    public LibraryRepository(CatalogDao catalog, MediaFileDao files, AccountDao accounts, Connectivity connectivity)
    {
        _catalog = catalog;
        _files = files;
        _accounts = accounts;
        _connectivity = connectivity;
    }

    private bool Online => _connectivity.IsOnline;

    public async Task<List<MovieRow>> Movies()
    {
        var rows = await _catalog.Movies().ConfigureAwait(false);
        return Online ? rows : rows.Where(r => r.DeviceFiles > 0).ToList();
    }

    public async Task<List<ShowRow>> Shows()
    {
        var rows = await _catalog.Shows().ConfigureAwait(false);
        return Online ? rows : rows.Where(r => r.DeviceEpisodes > 0).Select(r => r with { AvailableEpisodes = r.DeviceEpisodes }).ToList();
    }

    public Task<MovieEntity?> Movie(int id) => _catalog.Movie(id);
    public Task<List<MediaFileEntity>> MovieFiles(int id) => _files.ForMovie(id);
    public Task<ShowEntity?> Show(int id) => _catalog.Show(id);
    public Task<List<SeasonEntity>> Seasons(int showId) => _catalog.Seasons(showId);
    public Task<List<EpisodeEntity>> Episodes(int showId) => _catalog.Episodes(showId);
    public Task<List<MediaFileEntity>> ShowFiles(int showId) => _files.ForShow(showId);
    public Task<List<CreditEntity>> Credits(string type, int id) => _catalog.Credits(type, id);

    /// <summary>TMDB's recommendations for a movie that are in the library (and playable now, via <see cref="Movies"/>).</summary>
    public async Task<List<MovieRow>> RelatedMovies(int movieId)
    {
        var rec = await _catalog.Recommendations("movie", movieId).ConfigureAwait(false);
        var rows = await Movies().ConfigureAwait(false);
        return RelatedTitles.InLibrary(RelatedTitles.ParseIds(rec?.RecommendedIds), ToMap(rows, r => r.Movie.TmdbId), movieId);
    }

    /// <summary>TMDB's recommendations for a show that are in the library (and playable now, via <see cref="Shows"/>).</summary>
    public async Task<List<ShowRow>> RelatedShows(int showId)
    {
        var rec = await _catalog.Recommendations("tv", showId).ConfigureAwait(false);
        var rows = await Shows().ConfigureAwait(false);
        return RelatedTitles.InLibrary(RelatedTitles.ParseIds(rec?.RecommendedIds), ToMap(rows, r => r.Show.TmdbId), showId);
    }

    private static Dictionary<int, T> ToMap<T>(IEnumerable<T> rows, Func<T, int> key)
    {
        var map = new Dictionary<int, T>();
        foreach (var r in rows) map[key(r)] = r; // associateBy: the last one wins
        return map;
    }

    public Task<List<MediaFileEntity>> Unmatched() => _files.Unmatched();
    public Task<List<MediaFileEntity>> Ignored() => _files.Ignored();

    public async Task<Dictionary<long, int>> FolderCounts() =>
        (await _files.FolderCounts().ConfigureAwait(false)).ToDictionary(c => c.FolderId, c => c.Videos);

    /// <summary>Which sources hold each movie, for the Movies screen's source filter.</summary>
    public Task<List<TitleSource>> MovieSources() => _files.MovieSources();
    public Task<List<TitleSource>> ShowSources() => _files.ShowSources();

    public async Task<List<MediaFileEntity>> EpisodeFiles()
    {
        var list = await _files.EpisodeFiles().ConfigureAwait(false);
        return Online ? list : list.Where(f => Accounts.IsLocal(f.AccountEmail)).ToList();
    }

    /// <summary>The same movie or episode stored on this PC, if <paramref name="file"/> lives elsewhere and a copy exists.</summary>
    public async Task<MediaFileEntity?> DeviceCopy(MediaFileEntity file)
    {
        if (Accounts.IsLocal(file.AccountEmail)) return null;
        if (file.MovieId is { } m) return await _files.DeviceCopyOfMovie(m).ConfigureAwait(false);
        if (file is { ShowId: { } s, Season: { } se, Episode: { } e }) return await _files.DeviceCopyOfEpisode(s, se, e).ConfigureAwait(false);
        return null;
    }

    public Task<List<EpisodeEntity>> AllEpisodes() => _catalog.AllEpisodes();
    public Task<List<ArchiveFileEntity>> Archives() => _files.Archives();
    public Task ForgetArchive(string driveId) => _files.DeleteArchive(driveId);

    public Task<MediaFileEntity?> File(string id) => _files.File(id);
    public Task<EpisodeEntity?> Episode(int showId, int season, int episode) => _catalog.Episode(showId, season, episode);
    public Task<List<SubtitleFileEntity>> SubtitlesBeside(MediaFileEntity file) => _files.SubtitlesIn(file.ParentId);

    /// <summary>Movie and show matches, each with why it matched when it wasn't the title.</summary>
    public async Task<(List<SearchHit> Movies, List<SearchHit> Shows)> Search(string query) =>
        (await _catalog.SearchMovies(query).ConfigureAwait(false), await _catalog.SearchShows(query).ConfigureAwait(false));

    /// <summary>The episode file that follows <paramref name="file"/>, preferring a copy from the same account (only this PC's copies when offline).</summary>
    public async Task<MediaFileEntity?> NextEpisodeFile(MediaFileEntity file)
    {
        if (file.ShowId is not { } showId || file.Season is not { } season) return null;
        if ((file.EpisodeEnd ?? file.Episode) is not { } last) return null;
        var online = Online;
        return (await _files.ForShow(showId).ConfigureAwait(false))
            .Where(f => f.Season != null && f.Episode != null && f.Season > 0)
            .Where(f => online || Accounts.IsLocal(f.AccountEmail))
            .Where(f => IsAfter((f.Season!.Value, f.Episode!.Value), (season, last)))
            .OrderBy(f => f.Season).ThenBy(f => f.Episode).ThenBy(f => f.AccountEmail == file.AccountEmail ? 0 : 1)
            .FirstOrDefault();
    }

    /// <summary>The episode file before <paramref name="file"/> (same ordering as <see cref="NextEpisodeFile"/>).</summary>
    public async Task<MediaFileEntity?> PreviousEpisodeFile(MediaFileEntity file)
    {
        if (file.ShowId is not { } showId || file.Season is not { } season || file.Episode is not { } episode) return null;
        var online = Online;
        return (await _files.ForShow(showId).ConfigureAwait(false))
            .Where(f => f.Season != null && f.Episode != null && f.Season > 0)
            .Where(f => online || Accounts.IsLocal(f.AccountEmail))
            .Where(f => IsAfter((season, episode), (f.Season!.Value, f.EpisodeEnd ?? f.Episode!.Value)))
            .OrderByDescending(f => f.Season).ThenByDescending(f => f.Episode).ThenBy(f => f.AccountEmail == file.AccountEmail ? 0 : 1)
            .FirstOrDefault();
    }

    private static bool IsAfter((int, int) a, (int, int) b) => a.Item1 > b.Item1 || (a.Item1 == b.Item1 && a.Item2 > b.Item2);

    // ---- Library folders and sources (Android AccountRepository) ----

    public Task<List<AccountEntity>> AccountList() => _accounts.Accounts();
    public Task<List<LibraryFolderEntity>> Folders() => _accounts.FoldersSorted();

    /// <summary>"This PC" appears as an account once the user chooses to use local files.</summary>
    public async Task EnsureDeviceAccount()
    {
        var all = await _accounts.Accounts().ConfigureAwait(false);
        if (all.All(a => a.Email != Accounts.Device))
        {
            await _accounts.Upsert(new AccountEntity
            {
                Email = Accounts.Device,
                DisplayName = Accounts.DeviceDisplayName,
                AddedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            }).ConfigureAwait(false);
        }
    }

    /// <summary>Adds a library folder. Returns the new folder's id, or null when it was already in the library.</summary>
    public async Task<long?> AddFolder(string account, string folderId, string name, LibraryType type)
    {
        if (Accounts.IsLocal(account)) await EnsureDeviceAccount().ConfigureAwait(false);
        var id = await _accounts.InsertFolder(new LibraryFolderEntity
        {
            AccountEmail = account, DriveFolderId = folderId, Name = name, Type = type,
        }).ConfigureAwait(false);
        return id > 0 ? id : null;
    }

    public async Task RemoveFolder(long folderId)
    {
        await _files.DeleteForFolder(folderId).ConfigureAwait(false);
        await _files.DeleteSubtitlesForFolder(folderId).ConfigureAwait(false);
        await _files.DeleteArchivesForFolder(folderId).ConfigureAwait(false);
        await _accounts.DeleteFolder(folderId).ConfigureAwait(false);
        await _catalog.Prune().ConfigureAwait(false);
    }

    /// <summary>
    /// Forgets a source: its folders, files, subtitles, archives and account row. Tokens and passwords belong to the
    /// Drive and network modules, which clear them themselves.
    /// </summary>
    public async Task RemoveAccount(string account)
    {
        await _accounts.DeleteFoldersForAccount(account).ConfigureAwait(false);
        await _files.DeleteForAccount(account).ConfigureAwait(false);
        await _files.DeleteSubtitlesForAccount(account).ConfigureAwait(false);
        await _files.DeleteArchivesForAccount(account).ConfigureAwait(false);
        await _accounts.Delete(account).ConfigureAwait(false);
        await _catalog.Prune().ConfigureAwait(false);
    }
}
