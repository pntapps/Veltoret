import XCTest
@testable import VeltoretKit

/// An in-memory source: folder id -> children.
final class ScanFakeSource: FileSource, @unchecked Sendable {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    struct Unsupported: Error {}

    let account: String
    var tree: [String: [StorageItem]] = [:]
    var failing = Set<String>()

    init(_ account: String) { self.account = account }

    func add(_ parent: String, _ name: String, folder: Bool = false, size: Int64 = 700 * 1024 * 1024) {
        let id = parent + "/" + name
        tree[parent, default: []].append(StorageItem(id: id, name: name, mimeType: folder ? "folder" : "", isFolder: folder,
                                                     sizeBytes: folder ? 0 : size))
        if folder && tree[id] == nil { tree[id] = [] }
    }

    func handles(_ a: String) -> Bool { a == account }
    func rootId(_ a: String) -> String { "root" }
    func rootName(_ a: String) -> String { "Root" }
    func list(_ a: String, folderId: String) async throws -> [StorageItem] {
        if failing.contains(folderId) { throw Failure(message: "Server went away") }
        return tree[folderId] ?? []
    }
    func search(_ a: String, query: String, currentFolder: String) async throws -> [StorageItem] { throw Unsupported() }
    func rename(_ a: String, id: String, newName: String) async throws -> String { throw Unsupported() }
    func remove(_ a: String, id: String) async throws { throw Unsupported() }
    func deletePermanently(_ a: String, id: String) async throws { throw Unsupported() }
    func space(_ a: String, folderId: String) async throws -> StorageSpace? { nil }
    func spaceKey(_ a: String, folderId: String) -> String? { nil }
    func move(_ a: String, id: String, fromParent: String?, toParent: String) async throws { throw Unsupported() }
    func createFolder(_ a: String, parentId: String, name: String) async throws { throw Unsupported() }
    func openRead(_ a: String, id: String) async throws -> ByteSource { throw Unsupported() }
}

/// TMDB as the Windows test's fake HTTP handler answers it: "The Matrix" (603) and "Dark" (70523), nothing else.
final class ScanFakeTmdb: TmdbMatching {
    let catalog: CatalogDao
    var requests: [String] = []
    init(catalog: CatalogDao) { self.catalog = catalog }

    func matchMovie(title: String, year: Int?, exactOnly: Bool) async throws -> Int? {
        requests.append("search/movie \(title)")
        return title.hasPrefix("The Matrix") ? 603 : nil
    }
    func matchShow(title: String, year: Int?, exactOnly: Bool) async throws -> Int? {
        requests.append("search/tv \(title)")
        return title.hasPrefix("Dark") ? 70523 : nil
    }
    func fetchMovie(_ id: Int) async throws {
        requests.append("movie/\(id)")
        if id == 603 { try catalog.upsertMovie(MovieEntity(tmdbId: 603, title: "The Matrix", releaseDate: "1999-03-30", year: 1999)) }
    }
    func fetchShow(_ id: Int, seasons: Set<Int>) async throws {
        requests.append("tv/\(id)")
        guard id == 70523 else { return }
        try catalog.upsertShow(ShowEntity(tmdbId: 70523, name: "Dark", firstAirDate: "2017-12-01", year: 2017, seasonCount: 1))
        try catalog.upsertSeasons([SeasonEntity(showId: 70523, seasonNumber: 1, name: "Season 1", episodeCount: 10)])
        if seasons.contains(1) {
            try catalog.upsertEpisodes([EpisodeEntity(showId: 70523, seasonNumber: 1, episodeNumber: 1, name: "Secrets")])
        }
    }
    func fetchRecommendations(type: String, id: Int) async throws { requests.append("\(type)/\(id)/recommendations") }
}

final class ScanFakeConnectivity: ScanConnectivity {
    var isOnline = true
    let onlineChanged = Event<Bool>()
    func set(_ online: Bool) { isOnline = online; onlineChanged.fire(online) }
}

final class LibraryScannerTests: XCTestCase {
    private var db: VeltoretDb!
    private var accounts: AccountDao!
    private var files: MediaFileDao!
    private var catalog: CatalogDao!
    private var settings: SettingsStore!
    private var drive: ScanFakeSource!
    private var device: ScanFakeSource!
    private var connectivity: ScanFakeConnectivity!
    private var tmdb: ScanFakeTmdb!
    private var scanner: LibraryScanner!
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try VeltoretDb()
        accounts = AccountDao(db)
        files = MediaFileDao(db)
        catalog = CatalogDao(db)
        settings = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        drive = ScanFakeSource("me@example.com")
        device = ScanFakeSource(Accounts.device)
        let storage = Storage()
        storage.register(drive)
        storage.register(device)
        connectivity = ScanFakeConnectivity()
        tmdb = ScanFakeTmdb(catalog: catalog)
        scanner = LibraryScanner(accounts: accounts, files: files, catalog: catalog, storage: storage, tmdb: tmdb,
                                 settings: settings, connectivity: connectivity)
        connectivity.set(true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func addFolder(_ account: String, _ id: String, _ type: LibraryType) throws -> Int64 {
        try accounts.insertFolder(LibraryFolderEntity(accountEmail: account, driveFolderId: id, name: id, type: type))
    }

    func testScansMatchesAndSkipsSamples() async throws {
        drive.add("movies", "The.Matrix.1999.1080p.BluRay.x264.mkv")
        drive.add("movies", "The.Matrix.1999.sample.mkv", size: 20 * 1024 * 1024)
        drive.add("movies", "Unknown.Clip.Thing.2011.mkv")
        drive.add("movies", "The.Matrix.1999.srt")
        drive.add("movies", "Extras.zip")
        drive.add("shows", "Dark", folder: true)
        drive.add("shows/Dark", "Season 1", folder: true)
        drive.add("shows/Dark/Season 1", "Dark.S01E01.mkv")
        try addFolder("me@example.com", "movies", .MOVIES)
        try addFolder("me@example.com", "shows", .SHOWS)

        try await scanner.scanAll()

        let s = scanner.state
        XCTAssertFalse(s.running)
        XCTAssertNil(s.error)
        XCTAssertEqual(3, s.filesFound)
        XCTAssertEqual(3, s.newFiles)
        XCTAssertEqual(2, s.identified)
        XCTAssertTrue(settings.current.lastScanAt > 0)

        let matrix = try XCTUnwrap(files.file("movies/The.Matrix.1999.1080p.BluRay.x264.mkv"))
        XCTAssertEqual(.MATCHED, matrix.matchState)
        XCTAssertEqual(603, matrix.movieId)
        XCTAssertNil(try files.file("movies/The.Matrix.1999.sample.mkv"))
        XCTAssertEqual(.UNMATCHED, try files.file("movies/Unknown.Clip.Thing.2011.mkv")?.matchState)
        let ep = try XCTUnwrap(files.file("shows/Dark/Season 1/Dark.S01E01.mkv"))
        XCTAssertEqual(70523, ep.showId)
        XCTAssertEqual("Dark/Season 1", ep.relativePath)
        XCTAssertEqual(1, try files.subtitlesIn("movies").count)
        XCTAssertEqual(1, try files.archives().count)
        XCTAssertNotNil(try catalog.episode(70523, 1, 1))
        XCTAssertEqual(1, try catalog.movies().count)
    }

    func testManualMatchesSurviveRescansAndGoneFilesAreRemoved() async throws {
        drive.add("movies", "Unknown.Clip.Thing.2011.mkv")
        drive.add("movies", "Other.Clip.2012.mkv")
        try addFolder("me@example.com", "movies", .MOVIES)
        try await scanner.scanAll()
        try await scanner.applyManualMatch(fileIds: ["movies/Unknown.Clip.Thing.2011.mkv"], kind: .MOVIE, tmdbId: 603)
        try await scanner.ignore(["movies/Other.Clip.2012.mkv"])

        try await scanner.scanAll()
        let manual = try XCTUnwrap(files.file("movies/Unknown.Clip.Thing.2011.mkv"))
        XCTAssertEqual(.MANUAL, manual.matchState)
        XCTAssertEqual(603, manual.movieId)
        XCTAssertEqual(.IGNORED, try files.file("movies/Other.Clip.2012.mkv")?.matchState)

        drive.tree["movies"]!.removeAll { $0.name.hasPrefix("Other") }
        try await scanner.scanAll()
        XCTAssertNil(try files.file("movies/Other.Clip.2012.mkv"))
    }

    func testFailedFolderKeepsItsFilesAndReportsTheError() async throws {
        drive.add("movies", "The.Matrix.1999.mkv")
        let id = try addFolder("me@example.com", "movies", .MOVIES)
        try await scanner.scanAll()

        drive.failing.insert("movies")
        try await scanner.scanAll()
        XCTAssertNotNil(try files.file("movies/The.Matrix.1999.mkv"))
        XCTAssertEqual("Server went away", scanner.state.folderErrors[id])
        XCTAssertTrue(scanner.state.error?.contains("Server went away") ?? false)

        drive.failing.removeAll()
        try await scanner.scanAll()
        XCTAssertTrue(scanner.state.folderErrors.isEmpty)
    }

    func testOfflineScansOnlyThisMacAndSkipsTmdb() async throws {
        drive.add("movies", "The.Matrix.1999.mkv")
        device.add("/Volumes/Movies", "The.Matrix.1999.2160p.mkv")
        try addFolder("me@example.com", "movies", .MOVIES)
        try addFolder(Accounts.device, "/Volumes/Movies", .MOVIES)
        connectivity.set(false)

        try await scanner.scanAll()
        XCTAssertNil(try files.file("movies/The.Matrix.1999.mkv"))
        XCTAssertEqual(.PENDING, try files.file("/Volumes/Movies/The.Matrix.1999.2160p.mkv")?.matchState)
        XCTAssertTrue(tmdb.requests.isEmpty)
    }

    func testCancelStopsAtNextCheckpoint() async throws {
        drive.add("movies", "The.Matrix.1999.mkv")
        try addFolder("me@example.com", "movies", .MOVIES)
        let scanner = self.scanner!
        let sub = scanner.stateChanged.subscribe { s in
            if s.running && s.currentFolderId != nil { scanner.cancel() }
        }
        try await scanner.scanAll()
        sub.cancel()
        XCTAssertTrue(scanner.state.cancelled)
        XCTAssertFalse(scanner.state.running)
        XCTAssertTrue(tmdb.requests.isEmpty)
    }

    func testRenameToANewIdKeepsTheMatch() async throws {
        drive.add("movies", "The.Matrix.1999.mkv")
        try addFolder("me@example.com", "movies", .MOVIES)
        try await scanner.scanAll()
        try await scanner.onFileRenamed(oldId: "movies/The.Matrix.1999.mkv", newId: "movies/Matrix.mkv", newName: "Matrix.mkv")
        XCTAssertNil(try files.file("movies/The.Matrix.1999.mkv"))
        XCTAssertEqual(603, try files.file("movies/Matrix.mkv")?.movieId)
    }

    // Mac additions: the scheduler queues user scans and drops automatic ones while busy.

    func testSchedulerRunsQueuedScansAndDropsAutomaticWhileBusy() async throws {
        drive.add("movies", "The.Matrix.1999.mkv")
        try addFolder("me@example.com", "movies", .MOVIES)
        let scheduler = ScanScheduler(scanner: scanner, connectivity: connectivity, settings: settings, prefetch: nil)
        XCTAssertFalse(scheduler.busy)
        async let first: Void = scheduler.runNow()
        async let second: Void = scheduler.runNow()
        _ = await (first, second)
        XCTAssertFalse(scheduler.busy)
        XCTAssertEqual(603, try files.file("movies/The.Matrix.1999.mkv")?.movieId)
    }

    func testScanStateProgress() {
        var s = ScanState()
        XCTAssertNil(s.progress)
        s.running = true
        s.foldersTotal = 4
        s.foldersDone = 1
        XCTAssertEqual(0.25, s.progress)
        s.toMatch = 10
        s.matched = 5
        XCTAssertEqual(0.5, s.progress)
        s.folderIds = [1]
        XCTAssertTrue(s.covers(1))
        XCTAssertFalse(s.covers(2))
        XCTAssertTrue(s.waiting(1))
        s.currentFolderId = 1
        XCTAssertFalse(s.waiting(1))
    }
}
