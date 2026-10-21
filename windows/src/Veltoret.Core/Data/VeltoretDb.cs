using System.Reflection;
using Dapper;
using Microsoft.Data.Sqlite;

namespace Veltoret.Core.Data;

/// <summary>
/// The library database (SQLite, %LOCALAPPDATA%\Veltoret\veltoret.db). Replaces Room: the same tables, plus a
/// <see cref="Changed"/> event that stands in for Room's Flows — screens re-query when a table they show changes.
///
/// Schema changes need a new step in <see cref="Migrations"/> (never drop user data: libraries and watch history
/// would be lost).
/// </summary>
public sealed class VeltoretDb
{
    private readonly string _connectionString;

    /// <summary>Raised after a write, with the table names it touched.</summary>
    public event Action<IReadOnlySet<string>>? Changed;

    public VeltoretDb(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
        }.ToString();
        using var c = Open();
        c.Execute("PRAGMA journal_mode = WAL;");
        Migrate(c);
    }

    static VeltoretDb()
    {
        SqlMapper.AddTypeHandler(new BoolHandler());
    }

    public SqliteConnection Open()
    {
        var c = new SqliteConnection(_connectionString);
        c.Open();
        c.Execute("PRAGMA busy_timeout = 5000;");
        return c;
    }

    public void NotifyChanged(params string[] tables) => Changed?.Invoke(new HashSet<string>(tables));

    /// <summary>
    /// Parameters for an entity: enums go in as their names (Dapper would write numbers), computed
    /// getter-only properties are skipped.
    /// </summary>
    public static DynamicParameters P(object entity)
    {
        var p = new DynamicParameters();
        foreach (var prop in entity.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            if (prop.SetMethod == null) continue;
            var v = prop.GetValue(entity);
            p.Add(prop.Name, v is Enum e ? e.ToString() : v);
        }
        return p;
    }

    private const int Version = 1;

    private static readonly string[] Migrations =
    {
        // 1: the Android app's schema version 4.
        """
        CREATE TABLE IF NOT EXISTS accounts (
            email TEXT NOT NULL PRIMARY KEY, displayName TEXT NOT NULL, photoUrl TEXT, addedAt INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS library_folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT, accountEmail TEXT NOT NULL, driveFolderId TEXT NOT NULL,
            name TEXT NOT NULL, type TEXT NOT NULL, lastScannedAt INTEGER NOT NULL DEFAULT 0);
        CREATE UNIQUE INDEX IF NOT EXISTS index_library_folders_accountEmail_driveFolderId_type
            ON library_folders (accountEmail, driveFolderId, type);
        CREATE TABLE IF NOT EXISTS media_files (
            driveId TEXT NOT NULL PRIMARY KEY, accountEmail TEXT NOT NULL, libraryFolderId INTEGER NOT NULL,
            name TEXT NOT NULL, parentId TEXT NOT NULL, relativePath TEXT NOT NULL, sizeBytes INTEGER NOT NULL,
            modifiedTime TEXT, mimeType TEXT NOT NULL, durationMs INTEGER NOT NULL, width INTEGER NOT NULL,
            height INTEGER NOT NULL, kind TEXT NOT NULL, parsedTitle TEXT NOT NULL, parsedYear INTEGER,
            season INTEGER, episode INTEGER, episodeEnd INTEGER, movieId INTEGER, showId INTEGER,
            matchState TEXT NOT NULL, addedAt INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS index_media_files_movieId ON media_files (movieId);
        CREATE INDEX IF NOT EXISTS index_media_files_showId ON media_files (showId);
        CREATE INDEX IF NOT EXISTS index_media_files_libraryFolderId ON media_files (libraryFolderId);
        CREATE INDEX IF NOT EXISTS index_media_files_matchState ON media_files (matchState);
        CREATE TABLE IF NOT EXISTS subtitle_files (
            driveId TEXT NOT NULL PRIMARY KEY, accountEmail TEXT NOT NULL, libraryFolderId INTEGER NOT NULL,
            parentId TEXT NOT NULL, name TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS index_subtitle_files_parentId ON subtitle_files (parentId);
        CREATE TABLE IF NOT EXISTS movies (
            tmdbId INTEGER NOT NULL PRIMARY KEY, title TEXT NOT NULL, originalTitle TEXT, overview TEXT NOT NULL,
            tagline TEXT, releaseDate TEXT, year INTEGER, runtimeMin INTEGER, rating REAL NOT NULL,
            certification TEXT, posterPath TEXT, backdropPath TEXT, genres TEXT NOT NULL, collectionId INTEGER,
            collectionName TEXT, director TEXT, updatedAt INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS shows (
            tmdbId INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL, overview TEXT NOT NULL, tagline TEXT,
            firstAirDate TEXT, year INTEGER, lastAirDate TEXT, status TEXT, rating REAL NOT NULL, certification TEXT,
            posterPath TEXT, backdropPath TEXT, genres TEXT NOT NULL, network TEXT, seasonCount INTEGER NOT NULL,
            episodeCount INTEGER NOT NULL, episodeRuntimeMin INTEGER, creator TEXT, updatedAt INTEGER NOT NULL,
            nextEpisodeSeason INTEGER, nextEpisodeNumber INTEGER, nextEpisodeName TEXT, nextEpisodeAirDate TEXT);
        CREATE TABLE IF NOT EXISTS seasons (
            showId INTEGER NOT NULL, seasonNumber INTEGER NOT NULL, name TEXT NOT NULL, overview TEXT NOT NULL,
            posterPath TEXT, episodeCount INTEGER NOT NULL, airDate TEXT, fetchedAt INTEGER NOT NULL,
            PRIMARY KEY (showId, seasonNumber));
        CREATE TABLE IF NOT EXISTS episodes (
            showId INTEGER NOT NULL, seasonNumber INTEGER NOT NULL, episodeNumber INTEGER NOT NULL, name TEXT NOT NULL,
            overview TEXT NOT NULL, stillPath TEXT, airDate TEXT, runtimeMin INTEGER, rating REAL NOT NULL,
            PRIMARY KEY (showId, seasonNumber, episodeNumber));
        CREATE TABLE IF NOT EXISTS credits (
            mediaType TEXT NOT NULL, mediaId INTEGER NOT NULL, personId INTEGER NOT NULL, name TEXT NOT NULL,
            character TEXT, profilePath TEXT, ord INTEGER NOT NULL, PRIMARY KEY (mediaType, mediaId, personId));
        CREATE TABLE IF NOT EXISTS recommendations (
            mediaType TEXT NOT NULL, mediaId INTEGER NOT NULL, recommendedIds TEXT NOT NULL, fetchedAt INTEGER NOT NULL,
            PRIMARY KEY (mediaType, mediaId));
        CREATE TABLE IF NOT EXISTS watchlist (
            mediaType TEXT NOT NULL, mediaId INTEGER NOT NULL, addedAt INTEGER NOT NULL, PRIMARY KEY (mediaType, mediaId));
        CREATE TABLE IF NOT EXISTS reminders (
            id INTEGER PRIMARY KEY AUTOINCREMENT, mediaType TEXT NOT NULL, mediaId INTEGER NOT NULL, season INTEGER,
            episode INTEGER, title TEXT NOT NULL, at INTEGER NOT NULL, createdAt INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS index_reminders_mediaType_mediaId ON reminders (mediaType, mediaId);
        CREATE TABLE IF NOT EXISTS watch_state (
            key TEXT NOT NULL PRIMARY KEY, positionMs INTEGER NOT NULL, durationMs INTEGER NOT NULL,
            watched INTEGER NOT NULL, lastWatchedAt INTEGER NOT NULL, lastFileId TEXT, movieId INTEGER, showId INTEGER,
            season INTEGER, episode INTEGER);
        CREATE INDEX IF NOT EXISTS index_watch_state_showId ON watch_state (showId);
        CREATE TABLE IF NOT EXISTS archive_files (
            driveId TEXT NOT NULL PRIMARY KEY, accountEmail TEXT NOT NULL, libraryFolderId INTEGER NOT NULL,
            parentId TEXT NOT NULL, name TEXT NOT NULL, sizeBytes INTEGER NOT NULL, relativePath TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS index_archive_files_libraryFolderId ON archive_files (libraryFolderId);
        """,
    };

    private static void Migrate(SqliteConnection c)
    {
        var current = c.ExecuteScalar<long>("PRAGMA user_version;");
        for (var v = (int)current; v < Version; v++)
        {
            using var tx = c.BeginTransaction();
            c.Execute(Migrations[v], transaction: tx);
            c.Execute($"PRAGMA user_version = {v + 1};", transaction: tx);
            tx.Commit();
        }
    }

    /// <summary>SQLite stores booleans as INTEGER.</summary>
    private sealed class BoolHandler : SqlMapper.TypeHandler<bool>
    {
        public override bool Parse(object value) => Convert.ToInt64(value) != 0;
        public override void SetValue(System.Data.IDbDataParameter parameter, bool value) => parameter.Value = value ? 1 : 0;
    }
}
