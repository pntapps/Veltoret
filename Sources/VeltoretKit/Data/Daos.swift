import Foundation

// Data access, query for query the Android app's Room DAOs (and the Windows app's Daos.cs). "observe…" Flows
// become plain queries that screens re-run when VeltoretDb.changed names a table they show.
// All methods are synchronous and thread-safe; call them off the main thread for large results.

public final class AccountDao: @unchecked Sendable {
    let db: VeltoretDb
    public init(_ db: VeltoretDb) { self.db = db }

    public func accounts() throws -> [AccountEntity] {
        try db.query("SELECT * FROM accounts ORDER BY addedAt")
    }

    public func upsert(_ account: AccountEntity) throws {
        try db.upsert("accounts", [account])
        db.notifyChanged("accounts")
    }

    public func delete(_ email: String) throws {
        try db.execute("DELETE FROM accounts WHERE email = @email", ["email": email])
        db.notifyChanged("accounts")
    }

    /// Ordered by type, then name (observeFolders).
    public func foldersSorted() throws -> [LibraryFolderEntity] {
        try db.query("SELECT * FROM library_folders ORDER BY type, name")
    }

    public func folders() throws -> [LibraryFolderEntity] {
        try db.query("SELECT * FROM library_folders")
    }

    /// Returns the new row id, or -1 when the folder is already in the library.
    @discardableResult
    public func insertFolder(_ folder: LibraryFolderEntity) throws -> Int64 {
        let id: Int64 = try db.transaction {
            let changed = try db.execute(
                "INSERT OR IGNORE INTO library_folders (accountEmail, driveFolderId, name, type, lastScannedAt) " +
                "VALUES (@accountEmail, @driveFolderId, @name, @type, @lastScannedAt)",
                ["accountEmail": folder.accountEmail, "driveFolderId": folder.driveFolderId, "name": folder.name,
                 "type": folder.type.rawValue, "lastScannedAt": folder.lastScannedAt])
            return changed == 0 ? -1 : db.lastInsertRowId
        }
        db.notifyChanged("library_folders")
        return id
    }

    public func markFolderScanned(_ id: Int64, time: Int64) throws {
        try db.execute("UPDATE library_folders SET lastScannedAt = @time WHERE id = @id", ["id": id, "time": time])
        db.notifyChanged("library_folders")
    }

    public func deleteFolder(_ id: Int64) throws {
        try db.execute("DELETE FROM library_folders WHERE id = @id", ["id": id])
        db.notifyChanged("library_folders")
    }

    public func deleteFoldersForAccount(_ email: String) throws {
        try db.execute("DELETE FROM library_folders WHERE accountEmail = @email", ["email": email])
        db.notifyChanged("library_folders")
    }
}

public final class MediaFileDao: @unchecked Sendable {
    let db: VeltoretDb
    public init(_ db: VeltoretDb) { self.db = db }

    private static let deviceFirst = "(accountEmail = 'device') DESC"

    private func x(_ sql: String, _ args: [String: SQLBindable], _ tables: String...) throws {
        try db.execute(sql, args)
        db.notifyChanged(Set(tables))
    }

    public func filesInFolder(_ folderId: Int64) throws -> [MediaFileEntity] {
        try db.query("SELECT * FROM media_files WHERE libraryFolderId = @folderId", ["folderId": folderId])
    }

    public func file(_ id: String) throws -> MediaFileEntity? {
        try db.one("SELECT * FROM media_files WHERE driveId = @id", ["id": id])
    }

    public func files<S: Sequence>(_ ids: S) throws -> [MediaFileEntity] where S.Element == String {
        try db.query("SELECT * FROM media_files WHERE driveId IN @ids", ["ids": SQLList(Array(ids))])
    }

    public func pending() throws -> [MediaFileEntity] {
        try db.query("SELECT * FROM media_files WHERE matchState = 'PENDING'")
    }

    public func folderCounts() throws -> [FolderVideoCount] {
        try db.query("SELECT libraryFolderId AS folderId, COUNT(*) AS videos FROM media_files GROUP BY libraryFolderId")
    }

    public func unmatched() throws -> [MediaFileEntity] {
        try db.query("SELECT * FROM media_files WHERE matchState = 'UNMATCHED' ORDER BY name")
    }

    public func ignored() throws -> [MediaFileEntity] {
        try db.query("SELECT * FROM media_files WHERE matchState = 'IGNORED' ORDER BY name")
    }

    public func setMatchState<S: Sequence>(_ ids: S, _ state: MatchState) throws where S.Element == String {
        try x("UPDATE media_files SET matchState = @state, movieId = NULL, showId = NULL WHERE driveId IN @ids",
              ["ids": SQLList(Array(ids)), "state": state.rawValue], "media_files")
    }

    /// Device copies first, then highest resolution and largest file.
    public func forMovie(_ movieId: Int) throws -> [MediaFileEntity] {
        try db.query("SELECT * FROM media_files WHERE movieId = @movieId ORDER BY \(Self.deviceFirst), height DESC, sizeBytes DESC",
                     ["movieId": movieId])
    }

    public func forShow(_ showId: Int) throws -> [MediaFileEntity] {
        try db.query("SELECT * FROM media_files WHERE showId = @showId ORDER BY season, episode, \(Self.deviceFirst)",
                     ["showId": showId])
    }

    public func episodeFiles() throws -> [MediaFileEntity] {
        try db.query("SELECT * FROM media_files WHERE kind = 'EPISODE' AND showId IS NOT NULL")
    }

    public func movieSources() throws -> [TitleSource] {
        try db.query("SELECT DISTINCT movieId AS titleId, accountEmail FROM media_files WHERE movieId IS NOT NULL")
    }

    public func showSources() throws -> [TitleSource] {
        try db.query("SELECT DISTINCT showId AS titleId, accountEmail FROM media_files WHERE showId IS NOT NULL")
    }

    public func deviceCopyOfMovie(_ movieId: Int) throws -> MediaFileEntity? {
        try db.one("SELECT * FROM media_files WHERE movieId = @movieId AND accountEmail = 'device' ORDER BY height DESC, sizeBytes DESC LIMIT 1",
                   ["movieId": movieId])
    }

    public func deviceCopyOfEpisode(showId: Int, season: Int, episode: Int) throws -> MediaFileEntity? {
        try db.one("SELECT * FROM media_files WHERE showId = @showId AND season = @season AND episode = @episode " +
                   "AND accountEmail = 'device' ORDER BY height DESC LIMIT 1",
                   ["showId": showId, "season": season, "episode": episode])
    }

    public func showSeasons() throws -> [ShowSeason] {
        try db.rows("SELECT DISTINCT showId, season FROM media_files WHERE showId IS NOT NULL AND season IS NOT NULL")
            .compactMap { r in
                guard let s = r.int("showId"), let n = r.int("season") else { return nil }
                return ShowSeason(showId: Int(s), season: Int(n))
            }
    }

    public func upsert(_ files: [MediaFileEntity]) throws {
        try db.upsert("media_files", files)
        db.notifyChanged("media_files")
    }

    public func delete<S: Sequence>(_ ids: S) throws where S.Element == String {
        try x("DELETE FROM media_files WHERE driveId IN @ids", ["ids": SQLList(Array(ids))], "media_files")
    }

    public func deleteForFolder(_ folderId: Int64) throws {
        try x("DELETE FROM media_files WHERE libraryFolderId = @folderId", ["folderId": folderId], "media_files")
    }

    public func deleteForAccount(_ email: String) throws {
        try x("DELETE FROM media_files WHERE accountEmail = @email", ["email": email], "media_files")
    }

    public func rename(_ id: String, name: String) throws {
        try x("UPDATE media_files SET name = @name WHERE driveId = @id", ["id": id, "name": name], "media_files")
    }

    public func subtitlesIn(_ parentId: String) throws -> [SubtitleFileEntity] {
        try db.query("SELECT * FROM subtitle_files WHERE parentId = @parentId", ["parentId": parentId])
    }

    public func deleteSubtitlesForFolder(_ folderId: Int64) throws {
        try x("DELETE FROM subtitle_files WHERE libraryFolderId = @folderId", ["folderId": folderId], "subtitle_files")
    }

    public func deleteSubtitlesForAccount(_ email: String) throws {
        try x("DELETE FROM subtitle_files WHERE accountEmail = @email", ["email": email], "subtitle_files")
    }

    public func replaceSubtitles(folderId: Int64, _ subs: [SubtitleFileEntity]) throws {
        try db.transaction {
            try db.execute("DELETE FROM subtitle_files WHERE libraryFolderId = @folderId", ["folderId": folderId])
            try db.upsert("subtitle_files", subs)
        }
        db.notifyChanged("subtitle_files")
    }

    public func archives() throws -> [ArchiveFileEntity] {
        try db.query("SELECT * FROM archive_files ORDER BY name")
    }

    public func deleteArchivesForFolder(_ folderId: Int64) throws {
        try x("DELETE FROM archive_files WHERE libraryFolderId = @folderId", ["folderId": folderId], "archive_files")
    }

    public func deleteArchivesForAccount(_ email: String) throws {
        try x("DELETE FROM archive_files WHERE accountEmail = @email", ["email": email], "archive_files")
    }

    public func deleteArchive(_ id: String) throws {
        try x("DELETE FROM archive_files WHERE driveId = @id", ["id": id], "archive_files")
    }

    public func replaceArchives(folderId: Int64, _ archives: [ArchiveFileEntity]) throws {
        try db.transaction {
            try db.execute("DELETE FROM archive_files WHERE libraryFolderId = @folderId", ["folderId": folderId])
            try db.upsert("archive_files", archives)
        }
        db.notifyChanged("archive_files")
    }
}

public final class CatalogDao: @unchecked Sendable {
    let db: VeltoretDb
    public init(_ db: VeltoretDb) { self.db = db }

    public func movies() throws -> [MovieRow] {
        try db.rows("""
            SELECT m.*, MIN(f.addedAt) AS addedAtX, MAX(f.height) AS maxHeight, COUNT(f.driveId) AS fileCount,
                   SUM(CASE WHEN f.accountEmail = 'device' THEN 1 ELSE 0 END) AS deviceFiles
            FROM movies m JOIN media_files f ON f.movieId = m.tmdbId
            GROUP BY m.tmdbId
            """).map { r in
            MovieRow(movie: try r.decode(MovieEntity.self), addedAt: r.int("addedAtX") ?? 0,
                     maxHeight: Int(r.int("maxHeight") ?? 0), fileCount: Int(r.int("fileCount") ?? 0),
                     deviceFiles: Int(r.int("deviceFiles") ?? 0))
        }
    }

    public func shows() throws -> [ShowRow] {
        try db.rows("""
            SELECT s.*, MAX(f.addedAt) AS addedAtX,
                   COUNT(DISTINCT (f.season * 10000 + f.episode)) AS availableEpisodes,
                   COUNT(DISTINCT CASE WHEN f.accountEmail = 'device' THEN f.season * 10000 + f.episode END) AS deviceEpisodes
            FROM shows s JOIN media_files f ON f.showId = s.tmdbId
            GROUP BY s.tmdbId
            """).map { r in
            ShowRow(show: try r.decode(ShowEntity.self), addedAt: r.int("addedAtX") ?? 0,
                    availableEpisodes: Int(r.int("availableEpisodes") ?? 0), deviceEpisodes: Int(r.int("deviceEpisodes") ?? 0))
        }
    }

    public func movie(_ id: Int) throws -> MovieEntity? {
        try db.one("SELECT * FROM movies WHERE tmdbId = @id", ["id": id])
    }

    public func show(_ id: Int) throws -> ShowEntity? {
        try db.one("SELECT * FROM shows WHERE tmdbId = @id", ["id": id])
    }

    public func seasons(_ showId: Int) throws -> [SeasonEntity] {
        try db.query("SELECT * FROM seasons WHERE showId = @showId ORDER BY CASE WHEN seasonNumber = 0 THEN 9999 ELSE seasonNumber END",
                     ["showId": showId])
    }

    public func season(_ showId: Int, _ season: Int) throws -> SeasonEntity? {
        try db.one("SELECT * FROM seasons WHERE showId = @showId AND seasonNumber = @season", ["showId": showId, "season": season])
    }

    public func episodes(_ showId: Int) throws -> [EpisodeEntity] {
        try db.query("SELECT * FROM episodes WHERE showId = @showId ORDER BY seasonNumber, episodeNumber", ["showId": showId])
    }

    public func episode(_ showId: Int, _ season: Int, _ episode: Int) throws -> EpisodeEntity? {
        try db.one("SELECT * FROM episodes WHERE showId = @showId AND seasonNumber = @season AND episodeNumber = @episode",
                   ["showId": showId, "season": season, "episode": episode])
    }

    public func allEpisodes() throws -> [EpisodeEntity] {
        try db.query("SELECT * FROM episodes")
    }

    public func credits(_ type: String, _ id: Int) throws -> [CreditEntity] {
        try db.query("SELECT * FROM credits WHERE mediaType = @type AND mediaId = @id ORDER BY ord LIMIT 30", ["type": type, "id": id])
    }

    private func upsertRows<T: Encodable>(_ table: String, _ rows: [T]) throws {
        try db.upsert(table, rows)
        db.notifyChanged(table)
    }

    public func upsertMovie(_ movie: MovieEntity) throws { try upsertRows("movies", [movie]) }
    public func upsertShow(_ show: ShowEntity) throws { try upsertRows("shows", [show]) }
    public func upsertSeasons(_ seasons: [SeasonEntity]) throws { try upsertRows("seasons", seasons) }
    public func upsertEpisodes(_ episodes: [EpisodeEntity]) throws { try upsertRows("episodes", episodes) }

    public func replaceCredits(_ type: String, _ id: Int, _ credits: [CreditEntity]) throws {
        try db.transaction {
            try db.execute("DELETE FROM credits WHERE mediaType = @type AND mediaId = @id", ["type": type, "id": id])
            try db.upsert("credits", credits)
        }
        db.notifyChanged("credits")
    }

    public func recommendations(_ type: String, _ id: Int) throws -> RecommendationEntity? {
        try db.one("SELECT * FROM recommendations WHERE mediaType = @type AND mediaId = @id", ["type": type, "id": id])
    }

    public func recommendationsFetchedAt(_ type: String, _ id: Int) throws -> Int64? {
        try recommendations(type, id)?.fetchedAt
    }

    public func upsertRecommendations(_ r: RecommendationEntity) throws { try upsertRows("recommendations", [r]) }

    /// Removes catalog rows for titles that left the library.
    public func prune() throws {
        try db.transaction {
            try db.executeScript("""
                DELETE FROM movies WHERE tmdbId NOT IN (SELECT movieId FROM media_files WHERE movieId IS NOT NULL);
                DELETE FROM shows WHERE tmdbId NOT IN (SELECT showId FROM media_files WHERE showId IS NOT NULL);
                DELETE FROM seasons WHERE showId NOT IN (SELECT tmdbId FROM shows);
                DELETE FROM episodes WHERE showId NOT IN (SELECT tmdbId FROM shows);
                DELETE FROM credits WHERE (mediaType = 'movie' AND mediaId NOT IN (SELECT tmdbId FROM movies))
                   OR (mediaType = 'tv' AND mediaId NOT IN (SELECT tmdbId FROM shows));
                DELETE FROM recommendations WHERE (mediaType = 'movie' AND mediaId NOT IN (SELECT tmdbId FROM movies))
                   OR (mediaType = 'tv' AND mediaId NOT IN (SELECT tmdbId FROM shows));
                """)
        }
        db.notifyChanged("movies", "shows", "seasons", "episodes", "credits", "recommendations")
    }

    /// Title, original title, director, collection or cast; title matches first.
    public func searchMovies(_ q: String) throws -> [SearchHit] {
        try db.query("""
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
            """, ["q": q])
    }

    /// Name, creator or cast; name matches first.
    public func searchShows(_ q: String) throws -> [SearchHit] {
        try db.query("""
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
            """, ["q": q])
    }
}

public final class PlansDao: @unchecked Sendable {
    let db: VeltoretDb
    public init(_ db: VeltoretDb) { self.db = db }

    public func watchlist() throws -> [WatchlistEntity] {
        try db.query("SELECT * FROM watchlist ORDER BY addedAt DESC")
    }

    public func isInWatchlist(_ type: String, _ id: Int) throws -> Bool {
        (try db.scalar("SELECT EXISTS(SELECT 1 FROM watchlist WHERE mediaType = @type AND mediaId = @id)", ["type": type, "id": id]) ?? 0) != 0
    }

    public func addToWatchlist(_ item: WatchlistEntity) throws {
        try db.upsert("watchlist", [item])
        db.notifyChanged("watchlist")
    }

    public func removeFromWatchlist(_ type: String, _ id: Int) throws {
        try db.execute("DELETE FROM watchlist WHERE mediaType = @type AND mediaId = @id", ["type": type, "id": id])
        db.notifyChanged("watchlist")
    }

    public func reminders() throws -> [ReminderEntity] {
        try db.query("SELECT * FROM reminders ORDER BY at")
    }

    public func remindersFor(_ type: String, _ id: Int) throws -> [ReminderEntity] {
        try db.query("SELECT * FROM reminders WHERE mediaType = @type AND mediaId = @id ORDER BY at", ["type": type, "id": id])
    }

    public func reminder(_ id: Int64) throws -> ReminderEntity? {
        try db.one("SELECT * FROM reminders WHERE id = @id", ["id": id])
    }

    @discardableResult
    public func insertReminder(_ r: ReminderEntity) throws -> Int64 {
        let id: Int64 = try db.transaction {
            try db.execute(
                "INSERT INTO reminders (mediaType, mediaId, season, episode, title, at, createdAt) " +
                "VALUES (@mediaType, @mediaId, @season, @episode, @title, @at, @createdAt)",
                ["mediaType": r.mediaType, "mediaId": r.mediaId, "season": r.season, "episode": r.episode,
                 "title": r.title, "at": r.at, "createdAt": r.createdAt])
            return db.lastInsertRowId
        }
        db.notifyChanged("reminders")
        return id
    }

    public func updateReminder(_ r: ReminderEntity) throws {
        try db.execute(
            "UPDATE reminders SET mediaType = @mediaType, mediaId = @mediaId, season = @season, episode = @episode, " +
            "title = @title, at = @at, createdAt = @createdAt WHERE id = @id",
            ["id": r.id, "mediaType": r.mediaType, "mediaId": r.mediaId, "season": r.season, "episode": r.episode,
             "title": r.title, "at": r.at, "createdAt": r.createdAt])
        db.notifyChanged("reminders")
    }

    /// Returns how many rows went (0 when another caller deleted it first).
    @discardableResult
    public func deleteReminder(_ id: Int64) throws -> Int {
        let n = try db.execute("DELETE FROM reminders WHERE id = @id", ["id": id])
        db.notifyChanged("reminders")
        return n
    }
}

public final class WatchDao: @unchecked Sendable {
    let db: VeltoretDb
    public init(_ db: VeltoretDb) { self.db = db }

    public func all() throws -> [WatchStateEntity] {
        try db.query("SELECT * FROM watch_state")
    }

    public func get(_ key: String) throws -> WatchStateEntity? {
        try db.one("SELECT * FROM watch_state WHERE \"key\" = @key", ["key": key])
    }

    public func forShow(_ showId: Int) throws -> [WatchStateEntity] {
        try db.query("SELECT * FROM watch_state WHERE showId = @showId", ["showId": showId])
    }

    public func watchedShowIds() throws -> [Int] {
        try db.rows("SELECT DISTINCT showId FROM watch_state WHERE showId IS NOT NULL").compactMap { $0.int("showId").map(Int.init) }
    }

    public func upsert(_ state: WatchStateEntity) throws { try upsertAll([state]) }

    public func upsertAll(_ states: [WatchStateEntity]) throws {
        try db.upsert("watch_state", states)
        db.notifyChanged("watch_state")
    }
}
