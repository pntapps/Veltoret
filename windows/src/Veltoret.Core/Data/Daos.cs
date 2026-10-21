using System.Collections.Concurrent;
using System.Reflection;
using Dapper;
using Microsoft.Data.Sqlite;

namespace Veltoret.Core.Data;

// Data access, query for query the Android app's Room DAOs. "observe…" Flows become plain queries that screens
// re-run when VeltoretDb.Changed names a table they show.

internal static class Sql
{
    private static readonly ConcurrentDictionary<(Type, string), string> UpsertCache = new();

    /// <summary>INSERT OR REPLACE of every settable property (Room's @Upsert; no table here has foreign keys).</summary>
    public static string Upsert(Type type, string table) => UpsertCache.GetOrAdd((type, table), key =>
    {
        var cols = key.Item1.GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(p => p.SetMethod != null).Select(p => p.Name).ToList();
        return $"INSERT OR REPLACE INTO {key.Item2} ({string.Join(", ", cols.Select(Quote))}) " +
               $"VALUES ({string.Join(", ", cols.Select(c => "@" + c))})";
    });

    private static string Quote(string c) => "\"" + char.ToLowerInvariant(c[0]) + c[1..] + "\"";

    public static async Task UpsertAll<T>(SqliteConnection c, string table, IEnumerable<T> rows, SqliteTransaction? tx = null)
        where T : notnull
    {
        var sql = Upsert(typeof(T), table);
        foreach (var row in rows) await c.ExecuteAsync(sql, VeltoretDb.P(row), tx);
    }
}

public sealed class AccountDao(VeltoretDb db)
{
    public async Task<List<AccountEntity>> Accounts()
    {
        using var c = db.Open();
        return (await c.QueryAsync<AccountEntity>("SELECT * FROM accounts ORDER BY addedAt")).ToList();
    }

    public async Task Upsert(AccountEntity account)
    {
        using (var c = db.Open()) await Sql.UpsertAll(c, "accounts", new[] { account });
        db.NotifyChanged("accounts");
    }

    public async Task Delete(string email)
    {
        using (var c = db.Open()) await c.ExecuteAsync("DELETE FROM accounts WHERE email = @email", new { email });
        db.NotifyChanged("accounts");
    }

    /// <summary>Ordered by type, then name (observeFolders).</summary>
    public async Task<List<LibraryFolderEntity>> FoldersSorted()
    {
        using var c = db.Open();
        return (await c.QueryAsync<LibraryFolderEntity>("SELECT * FROM library_folders ORDER BY type, name")).ToList();
    }

    public async Task<List<LibraryFolderEntity>> Folders()
    {
        using var c = db.Open();
        return (await c.QueryAsync<LibraryFolderEntity>("SELECT * FROM library_folders")).ToList();
    }

    /// <summary>Returns the new row id, or -1 when the folder is already in the library.</summary>
    public async Task<long> InsertFolder(LibraryFolderEntity folder)
    {
        long id;
        using (var c = db.Open())
        {
            var changed = await c.ExecuteAsync(
                "INSERT OR IGNORE INTO library_folders (accountEmail, driveFolderId, name, type, lastScannedAt) " +
                "VALUES (@AccountEmail, @DriveFolderId, @Name, @Type, @LastScannedAt)", VeltoretDb.P(folder));
            id = changed == 0 ? -1 : await c.ExecuteScalarAsync<long>("SELECT last_insert_rowid()");
        }
        db.NotifyChanged("library_folders");
        return id;
    }

    public async Task MarkFolderScanned(long id, long time)
    {
        using (var c = db.Open()) await c.ExecuteAsync("UPDATE library_folders SET lastScannedAt = @time WHERE id = @id", new { id, time });
        db.NotifyChanged("library_folders");
    }

    public async Task DeleteFolder(long id)
    {
        using (var c = db.Open()) await c.ExecuteAsync("DELETE FROM library_folders WHERE id = @id", new { id });
        db.NotifyChanged("library_folders");
    }

    public async Task DeleteFoldersForAccount(string email)
    {
        using (var c = db.Open()) await c.ExecuteAsync("DELETE FROM library_folders WHERE accountEmail = @email", new { email });
        db.NotifyChanged("library_folders");
    }
}

public sealed class MediaFileDao(VeltoretDb db)
{
    private const string DeviceFirst = "(accountEmail = 'device') DESC";

    private async Task<List<T>> Q<T>(string sql, object? args = null)
    {
        using var c = db.Open();
        return (await c.QueryAsync<T>(sql, args)).ToList();
    }

    private async Task X(string sql, object? args, params string[] tables)
    {
        using (var c = db.Open()) await c.ExecuteAsync(sql, args);
        db.NotifyChanged(tables);
    }

    public Task<List<MediaFileEntity>> FilesInFolder(long folderId) =>
        Q<MediaFileEntity>("SELECT * FROM media_files WHERE libraryFolderId = @folderId", new { folderId });

    public async Task<MediaFileEntity?> File(string id) =>
        (await Q<MediaFileEntity>("SELECT * FROM media_files WHERE driveId = @id", new { id })).FirstOrDefault();

    public Task<List<MediaFileEntity>> Files(IEnumerable<string> ids) =>
        Q<MediaFileEntity>("SELECT * FROM media_files WHERE driveId IN @ids", new { ids = ids.ToList() });

    public Task<List<MediaFileEntity>> Pending() => Q<MediaFileEntity>("SELECT * FROM media_files WHERE matchState = 'PENDING'");

    public Task<List<FolderVideoCount>> FolderCounts() =>
        Q<FolderVideoCount>("SELECT libraryFolderId AS folderId, COUNT(*) AS videos FROM media_files GROUP BY libraryFolderId");

    public Task<List<MediaFileEntity>> Unmatched() => Q<MediaFileEntity>("SELECT * FROM media_files WHERE matchState = 'UNMATCHED' ORDER BY name");

    public Task<List<MediaFileEntity>> Ignored() => Q<MediaFileEntity>("SELECT * FROM media_files WHERE matchState = 'IGNORED' ORDER BY name");

    public Task SetMatchState(IEnumerable<string> ids, MatchState state) =>
        X("UPDATE media_files SET matchState = @state, movieId = NULL, showId = NULL WHERE driveId IN @ids",
            new { ids = ids.ToList(), state = state.ToString() }, "media_files");

    /// <summary>Device copies first, then highest resolution and largest file.</summary>
    public Task<List<MediaFileEntity>> ForMovie(int movieId) =>
        Q<MediaFileEntity>($"SELECT * FROM media_files WHERE movieId = @movieId ORDER BY {DeviceFirst}, height DESC, sizeBytes DESC", new { movieId });

    public Task<List<MediaFileEntity>> ForShow(int showId) =>
        Q<MediaFileEntity>($"SELECT * FROM media_files WHERE showId = @showId ORDER BY season, episode, {DeviceFirst}", new { showId });

    public Task<List<MediaFileEntity>> EpisodeFiles() =>
        Q<MediaFileEntity>("SELECT * FROM media_files WHERE kind = 'EPISODE' AND showId IS NOT NULL");

    public Task<List<TitleSource>> MovieSources() =>
        Q<TitleSource>("SELECT DISTINCT movieId AS titleId, accountEmail FROM media_files WHERE movieId IS NOT NULL");

    public Task<List<TitleSource>> ShowSources() =>
        Q<TitleSource>("SELECT DISTINCT showId AS titleId, accountEmail FROM media_files WHERE showId IS NOT NULL");

    public async Task<MediaFileEntity?> DeviceCopyOfMovie(int movieId) =>
        (await Q<MediaFileEntity>("SELECT * FROM media_files WHERE movieId = @movieId AND accountEmail = 'device' ORDER BY height DESC, sizeBytes DESC LIMIT 1",
            new { movieId })).FirstOrDefault();

    public async Task<MediaFileEntity?> DeviceCopyOfEpisode(int showId, int season, int episode) =>
        (await Q<MediaFileEntity>("SELECT * FROM media_files WHERE showId = @showId AND season = @season AND episode = @episode " +
            "AND accountEmail = 'device' ORDER BY height DESC LIMIT 1", new { showId, season, episode })).FirstOrDefault();

    // Positional records need Dapper to find a constructor with SQLite's Int64 types, so map by hand.
    public async Task<List<ShowSeason>> ShowSeasons() =>
        (await Q<(long ShowId, long Season)>("SELECT DISTINCT showId, season FROM media_files WHERE showId IS NOT NULL AND season IS NOT NULL"))
        .Select(r => new ShowSeason((int)r.ShowId, (int)r.Season)).ToList();

    public async Task Upsert(IEnumerable<MediaFileEntity> files)
    {
        using (var c = db.Open())
        using (var tx = c.BeginTransaction())
        {
            await Sql.UpsertAll(c, "media_files", files, tx);
            tx.Commit();
        }
        db.NotifyChanged("media_files");
    }

    public Task Delete(IEnumerable<string> ids) =>
        X("DELETE FROM media_files WHERE driveId IN @ids", new { ids = ids.ToList() }, "media_files");

    public Task DeleteForFolder(long folderId) =>
        X("DELETE FROM media_files WHERE libraryFolderId = @folderId", new { folderId }, "media_files");

    public Task DeleteForAccount(string email) =>
        X("DELETE FROM media_files WHERE accountEmail = @email", new { email }, "media_files");

    public Task Rename(string id, string name) =>
        X("UPDATE media_files SET name = @name WHERE driveId = @id", new { id, name }, "media_files");

    public Task<List<SubtitleFileEntity>> SubtitlesIn(string parentId) =>
        Q<SubtitleFileEntity>("SELECT * FROM subtitle_files WHERE parentId = @parentId", new { parentId });

    public Task DeleteSubtitlesForFolder(long folderId) =>
        X("DELETE FROM subtitle_files WHERE libraryFolderId = @folderId", new { folderId }, "subtitle_files");

    public Task DeleteSubtitlesForAccount(string email) =>
        X("DELETE FROM subtitle_files WHERE accountEmail = @email", new { email }, "subtitle_files");

    public async Task ReplaceSubtitles(long folderId, IEnumerable<SubtitleFileEntity> subs)
    {
        using (var c = db.Open())
        using (var tx = c.BeginTransaction())
        {
            await c.ExecuteAsync("DELETE FROM subtitle_files WHERE libraryFolderId = @folderId", new { folderId }, tx);
            await Sql.UpsertAll(c, "subtitle_files", subs, tx);
            tx.Commit();
        }
        db.NotifyChanged("subtitle_files");
    }

    public Task<List<ArchiveFileEntity>> Archives() => Q<ArchiveFileEntity>("SELECT * FROM archive_files ORDER BY name");

    public Task DeleteArchivesForFolder(long folderId) =>
        X("DELETE FROM archive_files WHERE libraryFolderId = @folderId", new { folderId }, "archive_files");

    public Task DeleteArchivesForAccount(string email) =>
        X("DELETE FROM archive_files WHERE accountEmail = @email", new { email }, "archive_files");

    public Task DeleteArchive(string id) => X("DELETE FROM archive_files WHERE driveId = @id", new { id }, "archive_files");

    public async Task ReplaceArchives(long folderId, IEnumerable<ArchiveFileEntity> archives)
    {
        using (var c = db.Open())
        using (var tx = c.BeginTransaction())
        {
            await c.ExecuteAsync("DELETE FROM archive_files WHERE libraryFolderId = @folderId", new { folderId }, tx);
            await Sql.UpsertAll(c, "archive_files", archives, tx);
            tx.Commit();
        }
        db.NotifyChanged("archive_files");
    }
}

public sealed class CatalogDao(VeltoretDb db)
{
    private sealed record MovieExtras
    {
        public long AddedAt { get; init; }
        public int MaxHeight { get; init; }
        public int FileCount { get; init; }
        public int DeviceFiles { get; init; }
    }

    private sealed record ShowExtras
    {
        public long AddedAt { get; init; }
        public int AvailableEpisodes { get; init; }
        public int DeviceEpisodes { get; init; }
    }

    private async Task<List<T>> Q<T>(string sql, object? args = null)
    {
        using var c = db.Open();
        return (await c.QueryAsync<T>(sql, args)).ToList();
    }

    private async Task<T?> One<T>(string sql, object? args = null) => (await Q<T>(sql, args)).FirstOrDefault();

    public async Task<List<MovieRow>> Movies()
    {
        using var c = db.Open();
        return (await c.QueryAsync<MovieEntity, MovieExtras, MovieRow>(
            """
            SELECT m.*, MIN(f.addedAt) AS addedAt, MAX(f.height) AS maxHeight, COUNT(f.driveId) AS fileCount,
                   SUM(CASE WHEN f.accountEmail = 'device' THEN 1 ELSE 0 END) AS deviceFiles
            FROM movies m JOIN media_files f ON f.movieId = m.tmdbId
            GROUP BY m.tmdbId
            """,
            (m, e) => new MovieRow(m, e.AddedAt, e.MaxHeight, e.FileCount, e.DeviceFiles), splitOn: "addedAt")).ToList();
    }

    public async Task<List<ShowRow>> Shows()
    {
        using var c = db.Open();
        return (await c.QueryAsync<ShowEntity, ShowExtras, ShowRow>(
            """
            SELECT s.*, MAX(f.addedAt) AS addedAt,
                   COUNT(DISTINCT (f.season * 10000 + f.episode)) AS availableEpisodes,
                   COUNT(DISTINCT CASE WHEN f.accountEmail = 'device' THEN f.season * 10000 + f.episode END) AS deviceEpisodes
            FROM shows s JOIN media_files f ON f.showId = s.tmdbId
            GROUP BY s.tmdbId
            """,
            (s, e) => new ShowRow(s, e.AddedAt, e.AvailableEpisodes, e.DeviceEpisodes), splitOn: "addedAt")).ToList();
    }

    public Task<MovieEntity?> Movie(int id) => One<MovieEntity>("SELECT * FROM movies WHERE tmdbId = @id", new { id });

    public Task<ShowEntity?> Show(int id) => One<ShowEntity>("SELECT * FROM shows WHERE tmdbId = @id", new { id });

    public Task<List<SeasonEntity>> Seasons(int showId) =>
        Q<SeasonEntity>("SELECT * FROM seasons WHERE showId = @showId ORDER BY CASE WHEN seasonNumber = 0 THEN 9999 ELSE seasonNumber END", new { showId });

    public Task<SeasonEntity?> Season(int showId, int season) =>
        One<SeasonEntity>("SELECT * FROM seasons WHERE showId = @showId AND seasonNumber = @season", new { showId, season });

    public Task<List<EpisodeEntity>> Episodes(int showId) =>
        Q<EpisodeEntity>("SELECT * FROM episodes WHERE showId = @showId ORDER BY seasonNumber, episodeNumber", new { showId });

    public Task<EpisodeEntity?> Episode(int showId, int season, int episode) =>
        One<EpisodeEntity>("SELECT * FROM episodes WHERE showId = @showId AND seasonNumber = @season AND episodeNumber = @episode",
            new { showId, season, episode });

    public Task<List<EpisodeEntity>> AllEpisodes() => Q<EpisodeEntity>("SELECT * FROM episodes");

    public Task<List<CreditEntity>> Credits(string type, int id) =>
        Q<CreditEntity>("SELECT * FROM credits WHERE mediaType = @type AND mediaId = @id ORDER BY ord LIMIT 30", new { type, id });

    private async Task UpsertRows<T>(string table, IEnumerable<T> rows) where T : notnull
    {
        using (var c = db.Open())
        using (var tx = c.BeginTransaction())
        {
            await Sql.UpsertAll(c, table, rows, tx);
            tx.Commit();
        }
        db.NotifyChanged(table);
    }

    public Task UpsertMovie(MovieEntity movie) => UpsertRows("movies", new[] { movie });
    public Task UpsertShow(ShowEntity show) => UpsertRows("shows", new[] { show });
    public Task UpsertSeasons(IEnumerable<SeasonEntity> seasons) => UpsertRows("seasons", seasons);
    public Task UpsertEpisodes(IEnumerable<EpisodeEntity> episodes) => UpsertRows("episodes", episodes);

    public async Task ReplaceCredits(string type, int id, IEnumerable<CreditEntity> credits)
    {
        using (var c = db.Open())
        using (var tx = c.BeginTransaction())
        {
            await c.ExecuteAsync("DELETE FROM credits WHERE mediaType = @type AND mediaId = @id", new { type, id }, tx);
            await Sql.UpsertAll(c, "credits", credits, tx);
            tx.Commit();
        }
        db.NotifyChanged("credits");
    }

    public Task<RecommendationEntity?> Recommendations(string type, int id) =>
        One<RecommendationEntity>("SELECT * FROM recommendations WHERE mediaType = @type AND mediaId = @id", new { type, id });

    public async Task<long?> RecommendationsFetchedAt(string type, int id) =>
        (await Recommendations(type, id))?.FetchedAt;

    public Task UpsertRecommendations(RecommendationEntity r) => UpsertRows("recommendations", new[] { r });

    /// <summary>Removes catalog rows for titles that left the library.</summary>
    public async Task Prune()
    {
        using (var c = db.Open())
        using (var tx = c.BeginTransaction())
        {
            await c.ExecuteAsync(
                """
                DELETE FROM movies WHERE tmdbId NOT IN (SELECT movieId FROM media_files WHERE movieId IS NOT NULL);
                DELETE FROM shows WHERE tmdbId NOT IN (SELECT showId FROM media_files WHERE showId IS NOT NULL);
                DELETE FROM seasons WHERE showId NOT IN (SELECT tmdbId FROM shows);
                DELETE FROM episodes WHERE showId NOT IN (SELECT tmdbId FROM shows);
                DELETE FROM credits WHERE (mediaType = 'movie' AND mediaId NOT IN (SELECT tmdbId FROM movies))
                   OR (mediaType = 'tv' AND mediaId NOT IN (SELECT tmdbId FROM shows));
                DELETE FROM recommendations WHERE (mediaType = 'movie' AND mediaId NOT IN (SELECT tmdbId FROM movies))
                   OR (mediaType = 'tv' AND mediaId NOT IN (SELECT tmdbId FROM shows));
                """, transaction: tx);
            tx.Commit();
        }
        db.NotifyChanged("movies", "shows", "seasons", "episodes", "credits", "recommendations");
    }

    /// <summary>Title, original title, director, collection or cast; title matches first.</summary>
    public Task<List<SearchHit>> SearchMovies(string q) => Q<SearchHit>(
        """
        SELECT id, reason FROM (
          SELECT m.tmdbId AS id, m.year AS year,
            CASE
              WHEN m.title LIKE '%' || @q || '%' OR m.originalTitle LIKE '%' || @q || '%' THEN NULL
              WHEN m.director LIKE '%' || @q || '%' THEN 'Directed by ' || m.director
              WHEN m.collectionName LIKE '%' || @q || '%' THEN m.collectionName
              ELSE (SELECT c.name FROM credits c WHERE c.mediaType = 'movie' AND c.mediaId = m.tmdbId
                    AND c.name LIKE '%' || @q || '%' ORDER BY c.ord LIMIT 1)
            END AS reason
          FROM movies m
          WHERE m.title LIKE '%' || @q || '%' OR m.originalTitle LIKE '%' || @q || '%'
            OR m.director LIKE '%' || @q || '%' OR m.collectionName LIKE '%' || @q || '%'
            OR EXISTS (SELECT 1 FROM credits c WHERE c.mediaType = 'movie' AND c.mediaId = m.tmdbId AND c.name LIKE '%' || @q || '%')
        ) ORDER BY reason IS NOT NULL, year DESC LIMIT 60
        """, new { q });

    /// <summary>Name, creator or cast; name matches first.</summary>
    public Task<List<SearchHit>> SearchShows(string q) => Q<SearchHit>(
        """
        SELECT id, reason FROM (
          SELECT s.tmdbId AS id, s.year AS year,
            CASE
              WHEN s.name LIKE '%' || @q || '%' THEN NULL
              WHEN s.creator LIKE '%' || @q || '%' THEN 'Created by ' || s.creator
              ELSE (SELECT c.name FROM credits c WHERE c.mediaType = 'tv' AND c.mediaId = s.tmdbId
                    AND c.name LIKE '%' || @q || '%' ORDER BY c.ord LIMIT 1)
            END AS reason
          FROM shows s
          WHERE s.name LIKE '%' || @q || '%' OR s.creator LIKE '%' || @q || '%'
            OR EXISTS (SELECT 1 FROM credits c WHERE c.mediaType = 'tv' AND c.mediaId = s.tmdbId AND c.name LIKE '%' || @q || '%')
        ) ORDER BY reason IS NOT NULL, year DESC LIMIT 60
        """, new { q });
}

public sealed class PlansDao(VeltoretDb db)
{
    private async Task<List<T>> Q<T>(string sql, object? args = null)
    {
        using var c = db.Open();
        return (await c.QueryAsync<T>(sql, args)).ToList();
    }

    public Task<List<WatchlistEntity>> Watchlist() => Q<WatchlistEntity>("SELECT * FROM watchlist ORDER BY addedAt DESC");

    public async Task<bool> IsInWatchlist(string type, int id)
    {
        using var c = db.Open();
        return await c.ExecuteScalarAsync<long>("SELECT EXISTS(SELECT 1 FROM watchlist WHERE mediaType = @type AND mediaId = @id)", new { type, id }) != 0;
    }

    public async Task AddToWatchlist(WatchlistEntity item)
    {
        using (var c = db.Open()) await Sql.UpsertAll(c, "watchlist", new[] { item });
        db.NotifyChanged("watchlist");
    }

    public async Task RemoveFromWatchlist(string type, int id)
    {
        using (var c = db.Open()) await c.ExecuteAsync("DELETE FROM watchlist WHERE mediaType = @type AND mediaId = @id", new { type, id });
        db.NotifyChanged("watchlist");
    }

    public Task<List<ReminderEntity>> Reminders() => Q<ReminderEntity>("SELECT * FROM reminders ORDER BY at");

    public Task<List<ReminderEntity>> RemindersFor(string type, int id) =>
        Q<ReminderEntity>("SELECT * FROM reminders WHERE mediaType = @type AND mediaId = @id ORDER BY at", new { type, id });

    public async Task<ReminderEntity?> Reminder(long id) =>
        (await Q<ReminderEntity>("SELECT * FROM reminders WHERE id = @id", new { id })).FirstOrDefault();

    public async Task<long> InsertReminder(ReminderEntity r)
    {
        long id;
        using (var c = db.Open())
        {
            await c.ExecuteAsync(
                "INSERT INTO reminders (mediaType, mediaId, season, episode, title, at, createdAt) " +
                "VALUES (@MediaType, @MediaId, @Season, @Episode, @Title, @At, @CreatedAt)", VeltoretDb.P(r));
            id = await c.ExecuteScalarAsync<long>("SELECT last_insert_rowid()");
        }
        db.NotifyChanged("reminders");
        return id;
    }

    public async Task UpdateReminder(ReminderEntity r)
    {
        using (var c = db.Open())
            await c.ExecuteAsync(
                "UPDATE reminders SET mediaType = @MediaType, mediaId = @MediaId, season = @Season, episode = @Episode, " +
                "title = @Title, at = @At, createdAt = @CreatedAt WHERE id = @Id", VeltoretDb.P(r));
        db.NotifyChanged("reminders");
    }

    /// <summary>Returns how many rows went (0 when another caller deleted it first).</summary>
    public async Task<int> DeleteReminder(long id)
    {
        int n;
        using (var c = db.Open()) n = await c.ExecuteAsync("DELETE FROM reminders WHERE id = @id", new { id });
        db.NotifyChanged("reminders");
        return n;
    }
}

public sealed class WatchDao(VeltoretDb db)
{
    private async Task<List<WatchStateEntity>> Q(string sql, object? args = null)
    {
        using var c = db.Open();
        return (await c.QueryAsync<WatchStateEntity>(sql, args)).ToList();
    }

    public Task<List<WatchStateEntity>> All() => Q("SELECT * FROM watch_state");

    public async Task<WatchStateEntity?> Get(string key) => (await Q("SELECT * FROM watch_state WHERE \"key\" = @key", new { key })).FirstOrDefault();

    public Task<List<WatchStateEntity>> ForShow(int showId) => Q("SELECT * FROM watch_state WHERE showId = @showId", new { showId });

    public async Task<List<int>> WatchedShowIds()
    {
        using var c = db.Open();
        return (await c.QueryAsync<int>("SELECT DISTINCT showId FROM watch_state WHERE showId IS NOT NULL")).ToList();
    }

    public Task Upsert(WatchStateEntity state) => UpsertAll(new[] { state });

    public async Task UpsertAll(IEnumerable<WatchStateEntity> states)
    {
        using (var c = db.Open())
        using (var tx = c.BeginTransaction())
        {
            await Sql.UpsertAll(c, "watch_state", states, tx);
            tx.Commit();
        }
        db.NotifyChanged("watch_state");
    }
}
