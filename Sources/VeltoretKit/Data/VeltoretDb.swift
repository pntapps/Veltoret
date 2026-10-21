import Foundation

/// The library database (SQLite, ~/Library/Application Support/Veltoret/veltoret.db). Same tables as the Android
/// app's Room schema (version 4) and the Windows app, plus a `changed` event that stands in for Room's Flows:
/// screens re-query when a table they show changes.
///
/// Schema changes need a new step in `migrations` (never drop user data: libraries and watch history would be lost).
///
/// Thread-safe: every call is serialized on one connection (SQLite is fast enough for this app's queries; WAL keeps
/// readers and the writer from blocking each other on disk).
public final class VeltoretDb: @unchecked Sendable {
    private let conn: SQLiteConnection
    private let lock = NSRecursiveLock()

    /// Raised after a write, with the table names it touched (on the writing thread).
    public let changed = Event<Set<String>>()

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        conn = try SQLiteConnection(path: path.path)
        try conn.exec("PRAGMA journal_mode = WAL;")
        try migrate()
    }

    /// An in-memory database (tests).
    public init(inMemory: Void = ()) throws {
        conn = try SQLiteConnection(path: ":memory:")
        try migrate()
    }

    public func notifyChanged(_ tables: String...) { changed.fire(Set(tables)) }
    public func notifyChanged(_ tables: Set<String>) { changed.fire(tables) }

    // MARK: Queries

    /// Rows decoded as `T` (column names = property names).
    public func query<T: Decodable>(_ sql: String, _ args: [String: SQLBindable] = [:], as type: T.Type = T.self) throws -> [T] {
        try rows(sql, args).map { try $0.decode(T.self) }
    }

    public func one<T: Decodable>(_ sql: String, _ args: [String: SQLBindable] = [:], as type: T.Type = T.self) throws -> T? {
        try rows(sql, args).first.map { try $0.decode(T.self) }
    }

    public func rows(_ sql: String, _ args: [String: SQLBindable] = [:]) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        return try conn.run(sql, args)
    }

    /// The first column of the first row as an integer (COUNT, EXISTS, last_insert_rowid…).
    public func scalar(_ sql: String, _ args: [String: SQLBindable] = [:]) throws -> Int64? {
        guard let row = try rows(sql, args).first, let v = row.values.values.first else { return nil }
        switch v {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    /// Runs a write; returns the number of changed rows. Doesn't fire `changed` (callers name the tables).
    @discardableResult
    public func execute(_ sql: String, _ args: [String: SQLBindable] = [:]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try conn.run(sql, args)
        return conn.changes
    }

    /// Runs several statements without parameters.
    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        try conn.exec(sql)
    }

    public var lastInsertRowId: Int64 {
        lock.lock(); defer { lock.unlock() }
        return conn.lastInsertRowId
    }

    /// Runs `body` in a transaction (rolled back if it throws). Nested calls join the outer transaction.
    public func transaction<R>(_ body: () throws -> R) throws -> R {
        lock.lock(); defer { lock.unlock() }
        if inTransaction { return try body() }
        try conn.exec("BEGIN IMMEDIATE;")
        inTransaction = true
        defer { inTransaction = false }
        do {
            let r = try body()
            try conn.exec("COMMIT;")
            return r
        } catch {
            try? conn.exec("ROLLBACK;")
            throw error
        }
    }
    private var inTransaction = false

    /// INSERT OR REPLACE of every encoded property (Room's @Upsert; no table here has foreign keys).
    public func upsert<T: Encodable>(_ table: String, _ rows: [T]) throws {
        guard !rows.isEmpty else { return }
        try transaction {
            for row in rows {
                let cols = try RowEncoder.columns(row)
                let names = cols.map { "\"\($0.0)\"" }.joined(separator: ", ")
                let params = cols.map { "@\($0.0)" }.joined(separator: ", ")
                var args: [String: SQLBindable] = [:]
                for (k, v) in cols { args[k] = v }
                try conn.run("INSERT OR REPLACE INTO \(table) (\(names)) VALUES (\(params))", args)
            }
        }
    }

    // MARK: Schema

    static let version = 1

    static let migrations: [String] = [
        // 1: the Android app's schema version 4 (same as Windows).
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
    ]

    private func migrate() throws {
        let current = Int(try scalar("PRAGMA user_version;") ?? 0)
        guard current < Self.version else { return }
        for v in current..<Self.version {
            try transaction {
                try conn.exec(Self.migrations[v])
                try conn.exec("PRAGMA user_version = \(v + 1);")
            }
        }
    }
}
