import XCTest
@testable import VeltoretKit

final class VeltoretDbTests: XCTestCase {
    private func file(_ id: String, account: String = "a@b.c", movieId: Int? = nil, height: Int = 1080, addedAt: Int64 = 100) -> MediaFileEntity {
        MediaFileEntity(driveId: id, accountEmail: account, libraryFolderId: 7, name: id + ".mkv", parentId: "p",
                        relativePath: "A/B", sizeBytes: 1_234_567_890_123, modifiedTime: nil, mimeType: "video/x-matroska",
                        durationMs: 5_400_000, width: 1920, height: height, kind: .MOVIE, parsedTitle: "Title",
                        episode: 3, movieId: movieId, matchState: .MANUAL, addedAt: addedAt)
    }

    func testMediaFileRoundTripsEnumsAndNullableInts() throws {
        let db = try VeltoretDb()
        let files = MediaFileDao(db)
        var original = file("x1", movieId: 603)
        original.parsedYear = 1999
        original.modifiedTime = "2024-01-01T00:00:00.000Z"
        try files.upsert([original, file("x2")])
        XCTAssertEqual(try files.file("x1"), original)
        let other = try XCTUnwrap(try files.file("x2"))
        XCTAssertNil(other.movieId)
        XCTAssertNil(other.parsedYear)
        XCTAssertEqual(other.episode, 3)
        XCTAssertEqual(other.matchState, .MANUAL)

        try files.setMatchState(["x1"], .IGNORED)
        XCTAssertEqual(try files.file("x1")?.matchState, .IGNORED)
        XCTAssertNil(try files.file("x1")?.movieId)
        XCTAssertEqual(try files.files(["x1", "x2", "nope"]).count, 2)
        XCTAssertEqual(try files.files([String]()).count, 0)
    }

    func testMoviesAggregateCountsCopiesAndDeviceFiles() throws {
        let db = try VeltoretDb()
        let files = MediaFileDao(db), catalog = CatalogDao(db)
        try catalog.upsertMovie(MovieEntity(tmdbId: 603, title: "The Matrix", year: 1999, genres: "Action,Science Fiction", updatedAt: 1))
        try catalog.upsertMovie(MovieEntity(tmdbId: 604, title: "Not in library", updatedAt: 1))
        try files.upsert([file("m1", movieId: 603, height: 1080, addedAt: 300),
                          file("m2", account: "device", movieId: 603, height: 2160, addedAt: 200)])
        let rows = try catalog.movies()
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.movie.title, "The Matrix")
        XCTAssertEqual(row.movie.genreList, ["Action", "Science Fiction"])
        XCTAssertEqual(row.addedAt, 200)
        XCTAssertEqual(row.maxHeight, 2160)
        XCTAssertEqual(row.fileCount, 2)
        XCTAssertEqual(row.deviceFiles, 1)
        XCTAssertEqual(try files.forMovie(603).first?.driveId, "m2")
        try catalog.prune()
        XCTAssertNil(try catalog.movie(604))
        XCTAssertNotNil(try catalog.movie(603))
    }

    func testFoldersRemindersWatchState() throws {
        let db = try VeltoretDb()
        let accounts = AccountDao(db), plans = PlansDao(db), watch = WatchDao(db)
        let id = try accounts.insertFolder(LibraryFolderEntity(accountEmail: "device", driveFolderId: "/x", name: "x", type: .MOVIES))
        XCTAssertGreaterThan(id, 0)
        XCTAssertEqual(try accounts.insertFolder(LibraryFolderEntity(accountEmail: "device", driveFolderId: "/x", name: "x", type: .MOVIES)), -1)
        XCTAssertEqual(try accounts.folders().first?.type, .MOVIES)

        let rid = try plans.insertReminder(ReminderEntity(mediaType: "tv", mediaId: 1, season: 2, title: "T", at: 5, createdAt: 1))
        XCTAssertEqual(try plans.reminder(rid)?.season, 2)
        XCTAssertNil(try plans.reminder(rid)?.episode)
        XCTAssertEqual(try plans.deleteReminder(rid), 1)
        XCTAssertEqual(try plans.deleteReminder(rid), 0)
        try plans.addToWatchlist(WatchlistEntity(mediaType: "movie", mediaId: 9, addedAt: 1))
        XCTAssertTrue(try plans.isInWatchlist("movie", 9))

        try watch.upsert(WatchStateEntity(key: "m:1", positionMs: 50, durationMs: 100, watched: true, movieId: 1))
        XCTAssertEqual(try watch.get("m:1")?.watched, true)
        XCTAssertEqual(try watch.get("m:1")?.progress, 0.5)
    }

    func testChangedFires() throws {
        let db = try VeltoretDb()
        var seen: Set<String> = []
        let sub = db.changed.subscribe { seen.formUnion($0) }
        try AccountDao(db).upsert(AccountEntity(email: "a", displayName: "A", addedAt: 1))
        XCTAssertEqual(seen, ["accounts"])
        sub.cancel()
    }

    func testSettingsDefaultsForMissingKeys() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"skipSeconds": 30}"#.utf8))
        XCTAssertEqual(s.skipSeconds, 30)
        XCTAssertEqual(s.seekSeconds, 10)
        XCTAssertTrue(s.autoPlayNext)
    }
}
