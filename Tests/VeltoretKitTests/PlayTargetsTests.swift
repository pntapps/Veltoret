import XCTest
@testable import VeltoretKit

/// Port of Android PlayTargetsTest.kt (Windows PlayTargetsTests.cs), plus the resolver and watch rules.
final class PlayTargetsTests: XCTestCase {
    private let show = 42

    private func file(_ season: Int, _ episode: Int, account: String = "a@b.c", height: Int = 0) -> MediaFileEntity {
        MediaFileEntity(driveId: "f\(season)-\(episode)-\(account)-\(height)", accountEmail: account, libraryFolderId: 1,
                        name: "S\(season)E\(episode).mkv", parentId: "p", sizeBytes: 1, mimeType: "video/x-matroska",
                        height: height, kind: .EPISODE, parsedTitle: "Show", season: season, episode: episode,
                        showId: show, matchState: .MATCHED)
    }

    private func state(_ season: Int, _ episode: Int, _ watched: Bool, _ at: Int64, position: Int64 = 0) -> WatchStateEntity {
        WatchStateEntity(key: WatchKeys.episode(show, season, episode), positionMs: position, durationMs: 3_000_000,
                         watched: watched, lastWatchedAt: at, showId: show, season: season, episode: episode)
    }

    private var files: [MediaFileEntity] { [file(1, 1), file(1, 2), file(1, 3), file(2, 1), file(0, 1)] }

    func testFreshShowStartsAtS1E1() throws {
        let t = try XCTUnwrap(PlayTargets.nextEpisode(files, []))
        XCTAssertEqual(1, t.file.season); XCTAssertEqual(1, t.file.episode)
        XCTAssertTrue(t.fresh)
    }

    func testContinuesAfterLastWatched() throws {
        let t = try XCTUnwrap(PlayTargets.nextEpisode(files, [state(1, 1, true, 10), state(1, 2, true, 20)]))
        XCTAssertEqual(1, t.file.season); XCTAssertEqual(3, t.file.episode)
    }

    func testCrossesSeasonBoundaryAndSkipsSpecials() throws {
        let t = try XCTUnwrap(PlayTargets.nextEpisode(files, [state(1, 3, true, 30)]))
        XCTAssertEqual(2, t.file.season); XCTAssertEqual(1, t.file.episode)
    }

    func testResumesNewerInProgressEpisode() throws {
        let t = try XCTUnwrap(PlayTargets.nextEpisode(files, [state(1, 1, true, 10), state(1, 2, false, 20, position: 600_000)]))
        XCTAssertEqual(1, t.file.season); XCTAssertEqual(2, t.file.episode)
        XCTAssertTrue(t.resuming)
    }

    func testAllCaughtUp() {
        XCTAssertNil(PlayTargets.nextEpisode(files, [state(2, 1, true, 99)]))
    }

    // Mac additions.

    func testResolverPrefersDeviceCopyAndPlaysOnlyDeviceCopiesOffline() throws {
        let db = try VeltoretDb()
        let dao = MediaFileDao(db)
        try dao.upsert([file(1, 1, height: 2160), file(1, 1, account: Accounts.device, height: 720), file(1, 2, height: 1080)])
        var online = true
        let resolver = PlaybackResolver(files: dao, watch: WatchDao(db), isOnline: { online })
        XCTAssertEqual(Accounts.device, try resolver.episodeFile(showId: show, season: 1, episode: 1)?.accountEmail)
        XCTAssertEqual(2, try resolver.showPlayTarget(show).map { _ in 2 })
        online = false
        XCTAssertNil(try resolver.episodeFile(showId: show, season: 1, episode: 2))
        XCTAssertEqual(Accounts.device, try resolver.showPlayTarget(show)?.file.accountEmail)
    }

    func testWatchedRuleAndMultiEpisodeFiles() throws {
        let db = try VeltoretDb()
        let watch = WatchRepository(WatchDao(db))
        XCTAssertTrue(WatchRepository.isFinished(positionMs: 920_000, durationMs: 1_000_000_000 / 1000))
        XCTAssertTrue(WatchRepository.isFinished(positionMs: 2_900_000, durationMs: 3_000_000)) // < 2 min left
        XCTAssertFalse(WatchRepository.isFinished(positionMs: 1_000_000, durationMs: 3_000_000))

        var f = file(1, 1)
        f.episodeEnd = 3
        try watch.savePosition(f, fallbackFileId: f.driveId, positionMs: 2_950_000, durationMs: 3_000_000)
        let states = try watch.forShow(show)
        XCTAssertEqual(3, states.filter(\.watched).count)
        XCTAssertEqual(0, try watch.get(WatchKeys.episode(show, 1, 1))?.positionMs)

        try watch.savePosition(nil, fallbackFileId: "/x.mkv", positionMs: 60_000, durationMs: 3_000_000)
        let s = try XCTUnwrap(try watch.get(WatchKeys.file("/x.mkv")))
        XCTAssertFalse(s.watched)
        XCTAssertEqual(60_000, s.positionMs)
    }
}
