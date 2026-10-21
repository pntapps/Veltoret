import Foundation

/// Walks the library folders (Drive, this Mac, network shares), mirrors their videos and subtitles into the database,
/// and matches new files against TMDB. Files already matched are never looked up again, so rescans are cheap.
/// Port of the Windows/Android LibraryScanner.
public final class LibraryScanner: @unchecked Sendable {
    /// TMDB lookups per unmatched title at most (each is one or two searches).
    private static let maxCandidates = 6

    private let accounts: AccountDao
    private let files: MediaFileDao
    private let catalog: CatalogDao
    private let storage: Storage
    private let tmdb: TmdbMatching
    private let settings: SettingsStore
    private let connectivity: ScanConnectivity

    private let busyLock = NSLock()
    private var busy = false
    private let stateLock = NSLock()
    private var _state = ScanState()
    private let cancelLock = NSLock()
    private var _cancelRequested = false

    public init(accounts: AccountDao, files: MediaFileDao, catalog: CatalogDao, storage: Storage, tmdb: TmdbMatching,
                settings: SettingsStore, connectivity: ScanConnectivity) {
        self.accounts = accounts
        self.files = files
        self.catalog = catalog
        self.storage = storage
        self.tmdb = tmdb
        self.settings = settings
        self.connectivity = connectivity
    }

    public var state: ScanState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    /// Fired after every state change, on the scanning thread. UI code must hop to the main actor.
    public let stateChanged = Event<ScanState>()

    /// True while a scan holds the scanner.
    public var isBusy: Bool {
        busyLock.lock(); defer { busyLock.unlock() }
        return busy
    }

    private var cancelRequested: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelRequested }
        set { cancelLock.lock(); _cancelRequested = newValue; cancelLock.unlock() }
    }

    private func update(_ edit: (inout ScanState) -> Void) {
        stateLock.lock()
        var next = _state
        edit(&next)
        _state = next
        stateLock.unlock()
        stateChanged.fire(next)
    }

    private func setState(_ s: ScanState) { update { $0 = s } }

    /// Thrown at the next checkpoint after `cancel()`; folders already read keep their results.
    private struct ScanCancelled: Error {}

    public func scanAll() async throws { try await scan(nil) }

    /// Stops the running scan at the next folder or TMDB lookup.
    public func cancel() {
        if state.running { cancelRequested = true }
    }

    private func checkCancelled() throws {
        if cancelRequested || Task.isCancelled { throw ScanCancelled() }
    }

    /// Scans `folderIds`, or every library folder when nil. Returns at once if a scan is running.
    public func scan(_ folderIds: Set<Int64>?) async throws {
        let acquired = busyLock.withLock { () -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        if !acquired { return } // a scan is already running; its result will cover this request
        cancelRequested = false
        defer {
            cancelRequested = false
            busyLock.withLock { busy = false }
        }
        do {
            await Task.yield()
            var errors: [String] = []
            let all = try accounts.folders()
            let allIds = Set(all.map(\.id))
            var folderErrors = state.folderErrors.filter { allIds.contains($0.key) }
            // Offline: folders on this Mac still refresh; Drive and network folders and TMDB wait for the connection
            // to return (ScanScheduler rescans when it does). Skipping them also keeps their titles in the library.
            let online = connectivity.isOnline
            let targets = all.filter { (folderIds == nil || folderIds!.contains($0.id)) && (online || storage.isLocal($0.accountEmail)) }
            let previous = state
            var start = ScanState()
            start.running = true
            start.phase = "Reading your folders"
            start.folderIds = folderIds
            start.foldersTotal = targets.count
            start.folderErrors = folderErrors
            start.lastFinishedAt = previous.lastFinishedAt
            setState(start)
            for folder in targets {
                try checkCancelled()
                update { $0.currentFolderId = folder.id; $0.currentFolder = folder.name; $0.currentPath = "" }
                do {
                    try await scanFolder(folder)
                    folderErrors[folder.id] = nil
                } catch let e as ScanCancelled {
                    throw e
                } catch {
                    let reason = Self.folderError(error)
                    folderErrors[folder.id] = reason
                    errors.append("\(folder.name): \(reason)")
                }
                let snapshot = folderErrors
                update {
                    $0.foldersDone += 1
                    $0.doneFolderIds.insert(folder.id)
                    $0.folderErrors = snapshot
                }
            }
            update { $0.currentFolderId = nil; $0.currentFolder = ""; $0.currentPath = "" }
            if online {
                do {
                    try await matchPending()
                    // Refreshing every show is a whole-library job; a single-folder scan skips it.
                    if folderIds == nil {
                        try await refreshShows()
                        try await refreshRecommendations()
                    }
                } catch let e as ScanCancelled {
                    throw e
                } catch {
                    let message = Self.message(error)
                    errors.append(message.isEmpty ? "Could not reach TMDB" : message)
                }
            }
            try catalog.prune()
            let now = nowMillis()
            if folderIds == nil { settings.update { $0.lastScanAt = now } }
            let firstError = errors.first
            update { $0.running = false; $0.phase = ""; $0.error = firstError; $0.lastFinishedAt = now }
        } catch is ScanCancelled {
            try? catalog.prune()
            update {
                $0.running = false; $0.phase = ""; $0.cancelled = true; $0.currentFolderId = nil; $0.currentFolder = ""
                $0.currentPath = ""; $0.lastFinishedAt = nowMillis()
            }
        } catch {
            // Database trouble and the like: end the scan visibly, then let the caller (ScanScheduler) retry.
            let message = Self.message(error)
            update {
                $0.running = false; $0.phase = ""; $0.error = message; $0.currentFolderId = nil; $0.currentFolder = ""
                $0.currentPath = ""; $0.lastFinishedAt = nowMillis()
            }
            throw error
        }
    }

    static func message(_ error: Error) -> String {
        if let l = error as? LocalizedError, let d = l.errorDescription { return d }
        if !(type(of: error) is NSError.Type) { return String(describing: error) }
        return (error as NSError).localizedDescription
    }

    private static func folderError(_ e: Error) -> String {
        // A folder whose permission is gone (another user's folder, a locked-down drive...).
        let ns = e as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError) {
            return "Veltoret lost access to this folder. Remove it and add it again."
        }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) {
            return "Veltoret lost access to this folder. Remove it and add it again."
        }
        let m = message(e)
        return m.isEmpty ? String(describing: type(of: e)) : m
    }

    private func scanFolder(_ folder: LibraryFolderEntity) async throws {
        var existing: [String: MediaFileEntity] = [:]
        for f in try files.filesInFolder(folder.id) { existing[f.driveId] = f }
        var seen: [MediaFileEntity] = []
        var seenIds = Set<String>()
        var subtitles: [SubtitleFileEntity] = []
        var archives: [ArchiveFileEntity] = []
        var queue: [(folderId: String, path: [String])] = [(folder.driveFolderId, [])]
        var head = 0
        var visited = Set<String>()
        let isLocal = storage.isLocal(folder.accountEmail)
        let isSmb = storage.isSmb(folder.accountEmail)

        while head < queue.count {
            let (folderId, path) = queue[head]
            head += 1
            if !visited.insert(folderId).inserted { continue }
            try checkCancelled()
            let joined = path.joined(separator: "/")
            update { $0.currentPath = joined }
            for child in try await storage.list(folder.accountEmail, folderId: folderId) {
                if child.isFolder {
                    queue.append((child.id, path + [child.name]))
                } else if FilenameParser.isSubtitle(child.name) {
                    subtitles.append(SubtitleFileEntity(driveId: child.id, accountEmail: folder.accountEmail,
                                                        libraryFolderId: folder.id, parentId: folderId, name: child.name))
                } else if FilenameParser.isArchive(child.name) && !isLocal && !isSmb {
                    // ZIP extraction uploads to Drive, so archives are only listed for Drive folders.
                    archives.append(ArchiveFileEntity(driveId: child.id, accountEmail: folder.accountEmail,
                                                      libraryFolderId: folder.id, parentId: folderId, name: child.name,
                                                      sizeBytes: child.sizeBytes, relativePath: joined))
                } else if FilenameParser.isVideo(child.name, mimeType: child.mimeType) && !Self.isSample(child) {
                    let previous = existing[child.id]
                    if !seenIds.insert(child.id).inserted { continue }
                    seen.append(Self.toEntity(child, folder, folderId, path, previous))
                    let isNew = previous == nil
                    update { $0.filesFound += 1; $0.newFiles += isNew ? 1 : 0 }
                }
            }
        }

        try files.upsert(seen)
        let gone = existing.keys.filter { !seenIds.contains($0) }
        if !gone.isEmpty { try files.delete(gone) }
        try files.replaceSubtitles(folderId: folder.id, subtitles)
        try files.replaceArchives(folderId: folder.id, archives)
        try accounts.markFolderScanned(folder.id, time: nowMillis())
    }

    private static func isSample(_ file: StorageItem) -> Bool {
        file.name.range(of: "sample", options: .caseInsensitive) != nil && file.sizeBytes >= 1 && file.sizeBytes < 150 * 1024 * 1024
    }

    static func toEntity(_ file: StorageItem, _ folder: LibraryFolderEntity, _ parentId: String, _ path: [String],
                         _ previous: MediaFileEntity?) -> MediaFileEntity {
        let relativePath = path.joined(separator: "/")
        let duration = file.durationMs ?? previous?.durationMs ?? 0
        // Unmatched files fall through and are parsed again (back to PENDING) when the parser now reads
        // their name differently, e.g. after a parser fix; otherwise they'd stay unmatched forever.
        if let previous, previous.name == file.name, previous.relativePath == relativePath,
           !(previous.matchState == .UNMATCHED && parsesDifferently(file.name, path, folder.type, previous)) {
            var p = previous
            p.parentId = parentId
            p.sizeBytes = file.sizeBytes
            p.modifiedTime = file.modifiedTime
            p.durationMs = duration
            p.width = file.width ?? previous.width
            p.height = file.height ?? previous.height
            return p
        }

        let manual = previous?.matchState == .MANUAL
        let ignored = previous?.matchState == .IGNORED
        var e = MediaFileEntity(
            driveId: file.id, accountEmail: folder.accountEmail, libraryFolderId: folder.id, name: file.name,
            parentId: parentId, relativePath: relativePath, sizeBytes: file.sizeBytes, modifiedTime: file.modifiedTime,
            mimeType: file.mimeType, durationMs: duration, width: file.width ?? 0, height: file.height ?? 0,
            kind: folder.type == .MOVIES ? .MOVIE : .EPISODE, parsedTitle: "", parsedYear: nil, season: nil, episode: nil,
            episodeEnd: nil, movieId: manual ? previous!.movieId : nil, showId: manual ? previous!.showId : nil,
            matchState: manual ? .MANUAL : ignored ? .IGNORED : .PENDING, addedAt: previous?.addedAt ?? nowMillis())
        if folder.type == .MOVIES {
            let guess = FilenameParser.parseMovie(file.name, folders: path)
            e.parsedTitle = guess.title
            e.parsedYear = guess.year
            return e
        }
        guard let ep = FilenameParser.parseEpisode(file.name, folders: path) else {
            e.parsedTitle = FilenameParser.clean(file.name)
            e.matchState = manual ? .MANUAL : ignored ? .IGNORED : .UNMATCHED
            return e
        }
        e.parsedTitle = ep.showTitle
        e.parsedYear = ep.showYear
        e.season = ep.season
        e.episode = ep.episode
        e.episodeEnd = ep.episodeEnd
        return e
    }

    private static func parsesDifferently(_ name: String, _ path: [String], _ type: LibraryType, _ previous: MediaFileEntity) -> Bool {
        if type == .MOVIES {
            let guess = FilenameParser.parseMovie(name, folders: path)
            return guess.title != previous.parsedTitle || guess.year != previous.parsedYear
        }
        guard let ep = FilenameParser.parseEpisode(name, folders: path) else { return false }
        return ep.showTitle != previous.parsedTitle || ep.showYear != previous.parsedYear ||
            ep.season != previous.season || ep.episode != previous.episode
    }

    private static func pathOf(_ f: MediaFileEntity) -> [String] {
        f.relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    }

    private struct GroupKey: Hashable { let kind: MediaKind; let title: String; let year: Int? }
    private struct CandidateKey: Hashable { let title: String; let year: Int? }

    private func matchPending() async throws {
        let pending = try files.pending()
        if pending.isEmpty { return }
        update { $0.phase = "Matching with TMDB"; $0.toMatch = pending.count; $0.matched = 0 }

        // Groups in first-seen order (like LINQ GroupBy).
        var order: [GroupKey] = []
        var groups: [GroupKey: [MediaFileEntity]] = [:]
        for f in pending {
            let key = GroupKey(kind: f.kind, title: FilenameParser.normalizeForCompare(f.parsedTitle), year: f.parsedYear)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f)
        }
        for key in order {
            try checkCancelled()
            let list = groups[key]!
            let sample = list[0]
            var updated: [MediaFileEntity]?
            do {
                let path = Self.pathOf(sample)
                // The parser's guess first, then its fallbacks (the file's own title, trimmed leftovers...).
                var candidates = [FilenameParser.TitleCandidate(title: sample.parsedTitle, year: sample.parsedYear)]
                candidates += key.kind == .MOVIE
                    ? FilenameParser.movieCandidates(sample.name, folders: path)
                    : FilenameParser.showCandidates(sample.name, folders: path)
                var keys = Set<CandidateKey>()
                let lookups = Array(candidates.filter {
                    keys.insert(CandidateKey(title: FilenameParser.normalizeForCompare($0.title), year: $0.year)).inserted
                }.prefix(Self.maxCandidates))
                updated = nil
                if key.kind == .MOVIE {
                    var match: Int?
                    for c in lookups {
                        match = try await tmdb.matchMovie(title: c.title, year: c.year, exactOnly: c.exactOnly)
                        if match != nil { break }
                    }
                    if let id = match {
                        try await tmdb.fetchMovie(id)
                        updated = list.map { var f = $0; f.movieId = id; f.showId = nil; f.matchState = .MATCHED; return f }
                    }
                } else {
                    var match: Int?
                    for c in lookups {
                        match = try await tmdb.matchShow(title: c.title, year: c.year, exactOnly: c.exactOnly)
                        if match != nil { break }
                    }
                    if let id = match {
                        try await tmdb.fetchShow(id, seasons: Set(list.compactMap(\.season)))
                        updated = list.map { var f = $0; f.showId = id; f.movieId = nil; f.matchState = .MATCHED; return f }
                    }
                }
            } catch {
                if tmdb.isFatal(error) { throw error }
                // Network hiccup: leave as PENDING so the next scan retries.
                update { $0.matched += list.count }
                continue
            }
            try files.upsert(updated ?? list.map { var f = $0; f.matchState = .UNMATCHED; return f })
            let identified = updated?.count ?? 0
            update { $0.matched += list.count; $0.identified += identified }
        }
    }

    /// Keeps ongoing shows fresh and fetches episode lists for newly added seasons.
    private func refreshShows() async throws {
        let seasons = try files.showSeasons()
        var order: [Int] = []
        var byShow: [Int: Set<Int>] = [:]
        for s in seasons {
            if byShow[s.showId] == nil { order.append(s.showId) }
            byShow[s.showId, default: []].insert(s.season)
        }
        for id in order {
            do {
                try await tmdb.fetchShow(id, seasons: byShow[id]!)
            } catch {
                if tmdb.isFatal(error) { throw error }
                // One show's failure doesn't stop the others.
            }
        }
    }

    /// Fetches "More like this" for titles that have none yet or a month-old list. Detail pages also fetch on open.
    private func refreshRecommendations() async throws {
        let ids = try catalog.movies().map { ("movie", $0.movie.tmdbId) } + catalog.shows().map { ("tv", $0.show.tmdbId) }
        for (type, id) in ids {
            try checkCancelled()
            do {
                try await tmdb.fetchRecommendations(type: type, id: id)
            } catch {
                if tmdb.isFatal(error) { throw error }
            }
        }
    }

    /// "Fix match": pins files to a TMDB title chosen by the user.
    public func applyManualMatch(fileIds: [String], kind: MediaKind, tmdbId: Int) async throws {
        let targets = try files.files(fileIds)
        if kind == .MOVIE {
            try await tmdb.fetchMovie(tmdbId)
            try files.upsert(targets.map {
                var f = $0
                f.kind = .MOVIE; f.movieId = tmdbId; f.showId = nil; f.season = nil; f.episode = nil
                f.episodeEnd = nil; f.matchState = .MANUAL
                return f
            })
        } else {
            let updated = targets.map { file -> MediaFileEntity in
                let guess = FilenameParser.parseEpisode(file.name, folders: Self.pathOf(file))
                var f = file
                f.kind = .EPISODE
                f.showId = tmdbId
                f.movieId = nil
                f.season = file.season ?? guess?.season ?? 1
                f.episode = file.episode ?? guess?.episode ?? 1
                f.matchState = .MANUAL
                return f
            }
            try await tmdb.fetchShow(tmdbId, seasons: Set(updated.compactMap(\.season)))
            try files.upsert(updated)
        }
        try catalog.prune()
    }

    /// Keeps files out of the library until restored; survives rescans.
    public func ignore(_ ids: [String]) async throws {
        try files.setMatchState(ids, .IGNORED)
        try catalog.prune()
    }

    /// Puts ignored files back up for automatic matching on the next scan.
    public func restore(_ ids: [String]) async throws {
        try files.setMatchState(ids, .PENDING)
    }

    /// A file was renamed in Files. Same id (Drive): the name is updated and the next scan re-parses it. New id
    /// (this Mac, network shares: the path changed): the row moves to the new id, keeping its match.
    public func onFileRenamed(oldId: String, newId: String, newName: String) async throws {
        if oldId == newId {
            try files.rename(oldId, name: newName)
            return
        }
        let file = try files.file(oldId)
        try files.delete([oldId])
        if var f = file {
            f.driveId = newId
            f.name = newName
            try files.upsert([f])
        }
        try catalog.prune()
    }

    public func onFilesRemoved(_ ids: [String]) async throws {
        try files.delete(ids)
        try catalog.prune()
    }
}
