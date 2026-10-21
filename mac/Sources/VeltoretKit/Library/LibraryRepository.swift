import Foundation

/// What the screens read (port of Android LibraryRepository, plus folder management from AccountRepository).
/// Android's Flows are plain synchronous queries here: re-run them when `db.changed` names a table they show, or
/// when `connectivity.onlineChanged` fires (offline, the library is what can actually play: titles with a copy on
/// this Mac). Call off the main thread for large results.
public final class LibraryRepository: @unchecked Sendable {
    private let catalog: CatalogDao
    private let files: MediaFileDao
    private let accounts: AccountDao
    private let connectivity: Connectivity

    public init(catalog: CatalogDao, files: MediaFileDao, accounts: AccountDao, connectivity: Connectivity) {
        self.catalog = catalog
        self.files = files
        self.accounts = accounts
        self.connectivity = connectivity
    }

    private var online: Bool { connectivity.isOnline }

    public func movies() throws -> [MovieRow] {
        let rows = try catalog.movies()
        return online ? rows : rows.filter { $0.deviceFiles > 0 }
    }

    public func shows() throws -> [ShowRow] {
        let rows = try catalog.shows()
        if online { return rows }
        return rows.filter { $0.deviceEpisodes > 0 }.map { r in
            var r = r
            r.availableEpisodes = r.deviceEpisodes
            return r
        }
    }

    public func movie(_ id: Int) throws -> MovieEntity? { try catalog.movie(id) }
    public func movieFiles(_ id: Int) throws -> [MediaFileEntity] { try files.forMovie(id) }
    public func show(_ id: Int) throws -> ShowEntity? { try catalog.show(id) }
    public func seasons(_ showId: Int) throws -> [SeasonEntity] { try catalog.seasons(showId) }
    public func episodes(_ showId: Int) throws -> [EpisodeEntity] { try catalog.episodes(showId) }
    public func showFiles(_ showId: Int) throws -> [MediaFileEntity] { try files.forShow(showId) }
    public func credits(type: String, id: Int) throws -> [CreditEntity] { try catalog.credits(type, id) }

    /// TMDB's recommendations for a movie that are in the library (and playable now, via `movies()`).
    public func relatedMovies(_ movieId: Int) throws -> [MovieRow] {
        let rec = try catalog.recommendations("movie", movieId)
        let rows = try movies()
        return RelatedTitles.inLibrary(RelatedTitles.parseIds(rec?.recommendedIds), Self.toMap(rows) { $0.movie.tmdbId },
                                       selfId: movieId)
    }

    /// TMDB's recommendations for a show that are in the library (and playable now, via `shows()`).
    public func relatedShows(_ showId: Int) throws -> [ShowRow] {
        let rec = try catalog.recommendations("tv", showId)
        let rows = try shows()
        return RelatedTitles.inLibrary(RelatedTitles.parseIds(rec?.recommendedIds), Self.toMap(rows) { $0.show.tmdbId },
                                       selfId: showId)
    }

    private static func toMap<T>(_ rows: [T], _ key: (T) -> Int) -> [Int: T] {
        var map: [Int: T] = [:]
        for r in rows { map[key(r)] = r } // associateBy: the last one wins
        return map
    }

    public func unmatched() throws -> [MediaFileEntity] { try files.unmatched() }
    public func ignored() throws -> [MediaFileEntity] { try files.ignored() }

    public func folderCounts() throws -> [Int64: Int] {
        var map: [Int64: Int] = [:]
        for c in try files.folderCounts() { map[c.folderId] = c.videos }
        return map
    }

    /// Which sources hold each movie, for the Movies screen's source filter.
    public func movieSources() throws -> [TitleSource] { try files.movieSources() }
    public func showSources() throws -> [TitleSource] { try files.showSources() }

    public func episodeFiles() throws -> [MediaFileEntity] {
        let list = try files.episodeFiles()
        return online ? list : list.filter { Accounts.isLocal($0.accountEmail) }
    }

    /// The same movie or episode stored on this Mac, if `file` lives elsewhere and a copy exists.
    public func deviceCopy(_ file: MediaFileEntity) throws -> MediaFileEntity? {
        if Accounts.isLocal(file.accountEmail) { return nil }
        if let m = file.movieId { return try files.deviceCopyOfMovie(m) }
        if let s = file.showId, let se = file.season, let e = file.episode {
            return try files.deviceCopyOfEpisode(showId: s, season: se, episode: e)
        }
        return nil
    }

    public func allEpisodes() throws -> [EpisodeEntity] { try catalog.allEpisodes() }
    public func archives() throws -> [ArchiveFileEntity] { try files.archives() }
    public func forgetArchive(_ driveId: String) throws { try files.deleteArchive(driveId) }

    public func file(_ id: String) throws -> MediaFileEntity? { try files.file(id) }
    public func episode(showId: Int, season: Int, episode: Int) throws -> EpisodeEntity? {
        try catalog.episode(showId, season, episode)
    }
    public func subtitlesBeside(_ file: MediaFileEntity) throws -> [SubtitleFileEntity] { try files.subtitlesIn(file.parentId) }

    /// Movie and show matches, each with why it matched when it wasn't the title.
    public func search(_ query: String) throws -> (movies: [SearchHit], shows: [SearchHit]) {
        (try catalog.searchMovies(query), try catalog.searchShows(query))
    }

    /// The episode file that follows `file`, preferring a copy from the same account (only this Mac's copies when offline).
    public func nextEpisodeFile(_ file: MediaFileEntity) throws -> MediaFileEntity? {
        guard let showId = file.showId, let season = file.season, let last = file.episodeEnd ?? file.episode else { return nil }
        let online = self.online
        return try files.forShow(showId)
            .filter { $0.season != nil && $0.episode != nil && $0.season! > 0 }
            .filter { online || Accounts.isLocal($0.accountEmail) }
            .filter { Self.isAfter(($0.season!, $0.episode!), (season, last)) }
            .enumerated()
            .sorted { a, b in
                let x = a.element, y = b.element
                if x.season! != y.season! { return x.season! < y.season! }
                if x.episode! != y.episode! { return x.episode! < y.episode! }
                let sx = x.accountEmail == file.accountEmail ? 0 : 1, sy = y.accountEmail == file.accountEmail ? 0 : 1
                if sx != sy { return sx < sy }
                return a.offset < b.offset
            }
            .first?.element
    }

    /// The episode file before `file` (same ordering as `nextEpisodeFile`).
    public func previousEpisodeFile(_ file: MediaFileEntity) throws -> MediaFileEntity? {
        guard let showId = file.showId, let season = file.season, let episode = file.episode else { return nil }
        let online = self.online
        return try files.forShow(showId)
            .filter { $0.season != nil && $0.episode != nil && $0.season! > 0 }
            .filter { online || Accounts.isLocal($0.accountEmail) }
            .filter { Self.isAfter((season, episode), ($0.season!, $0.episodeEnd ?? $0.episode!)) }
            .enumerated()
            .sorted { a, b in
                let x = a.element, y = b.element
                if x.season! != y.season! { return x.season! > y.season! }
                if x.episode! != y.episode! { return x.episode! > y.episode! }
                let sx = x.accountEmail == file.accountEmail ? 0 : 1, sy = y.accountEmail == file.accountEmail ? 0 : 1
                if sx != sy { return sx < sy }
                return a.offset < b.offset
            }
            .first?.element
    }

    private static func isAfter(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 > b.0 || (a.0 == b.0 && a.1 > b.1) }

    // MARK: Library folders and sources (Android AccountRepository)

    public func accountList() throws -> [AccountEntity] { try accounts.accounts() }
    public func folders() throws -> [LibraryFolderEntity] { try accounts.foldersSorted() }

    /// "This Mac" appears as an account once the user chooses to use local files.
    public func ensureDeviceAccount() throws {
        if try accounts.accounts().allSatisfy({ $0.email != Accounts.device }) {
            try accounts.upsert(AccountEntity(email: Accounts.device, displayName: Accounts.deviceDisplayName,
                                              addedAt: nowMillis()))
        }
    }

    /// Adds a library folder. Returns the new folder's id, or nil when it was already in the library.
    @discardableResult
    public func addFolder(account: String, folderId: String, name: String, type: LibraryType) throws -> Int64? {
        if Accounts.isLocal(account) { try ensureDeviceAccount() }
        let id = try accounts.insertFolder(LibraryFolderEntity(accountEmail: account, driveFolderId: folderId, name: name, type: type))
        return id > 0 ? id : nil
    }

    public func removeFolder(_ folderId: Int64) throws {
        try files.deleteForFolder(folderId)
        try files.deleteSubtitlesForFolder(folderId)
        try files.deleteArchivesForFolder(folderId)
        try accounts.deleteFolder(folderId)
        try catalog.prune()
    }

    /// Forgets a source: its folders, files, subtitles, archives and account row. Tokens and passwords belong to the
    /// Drive and network modules, which clear them themselves.
    public func removeAccount(_ account: String) throws {
        try accounts.deleteFoldersForAccount(account)
        try files.deleteForAccount(account)
        try files.deleteSubtitlesForAccount(account)
        try files.deleteArchivesForAccount(account)
        try accounts.delete(account)
        try catalog.prune()
    }
}
