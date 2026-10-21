import XCTest
import VeltoretKit
@testable import VeltoretPlayerKit

/// Port of Windows PlayerLogicTests (Sidecar, EpisodeNav, PlayerPrefs, PlayerFormat/PlayerMath).
final class SidecarTests: XCTestCase {
    private func m(_ video: String, _ names: String...) -> [SidecarMatch<String>] { Sidecars.match(video, names, name: { $0 }) }

    func testLanguageFromTheName() {
        let r = m("Movie.mkv", "Movie.en.srt")
        XCTAssertEqual(1, r.count)
        XCTAssertEqual("en", r[0].language)
    }

    func testPlainNameHasNoLanguage() {
        let r = m("Movie.mkv", "Movie.srt")
        XCTAssertEqual(1, r.count); XCTAssertNil(r[0].language)
    }

    func testForcedTagIsNotALanguage() {
        let r = m("Movie.mkv", "Movie.forced.en.srt")
        XCTAssertEqual(1, r.count); XCTAssertNil(r[0].language)
    }

    func testCaseInsensitiveAndOthersIgnored() {
        let r = m("The.Show.S01E02.mkv", "the.show.s01e02_ENG.ass", "The.Show.S01E03.srt", "The.Show.S01E02.nfo")
        XCTAssertEqual(1, r.count)
        XCTAssertEqual("eng", r[0].language)
    }

    func testThreeLetterAndDigits() {
        let a = m("A.mp4", "A - hin.srt")
        XCTAssertEqual(1, a.count); XCTAssertEqual("hin", a[0].language)
        let b = m("A.mp4", "A.e1.srt")
        XCTAssertEqual(1, b.count); XCTAssertNil(b[0].language)
    }
}

final class EpisodeNavTests: XCTestCase {
    private func ep(_ s: Int, _ e: Int, _ account: String = "a@x", end: Int? = nil) -> MediaFileEntity {
        MediaFileEntity(driveId: "\(account)-\(s)-\(e)", accountEmail: account, libraryFolderId: 1, name: "\(s)x\(e).mkv",
                        kind: .EPISODE, season: s, episode: e, episodeEnd: end, showId: 7)
    }

    func testNextAndPrevious() {
        let files = [ep(1, 1), ep(1, 2), ep(1, 3), ep(2, 1), ep(0, 1)]
        XCTAssertEqual(ep(1, 3).driveId, EpisodeNav.next(files[1], files, online: true)?.driveId)
        XCTAssertEqual(ep(2, 1).driveId, EpisodeNav.next(files[2], files, online: true)?.driveId)
        XCTAssertNil(EpisodeNav.next(files[3], files, online: true))
        XCTAssertEqual(ep(1, 2).driveId, EpisodeNav.previous(files[2], files, online: true)?.driveId)
        XCTAssertNil(EpisodeNav.previous(files[0], files, online: true))
        XCTAssertEqual(ep(1, 3).driveId, EpisodeNav.previous(files[3], files, online: true)?.driveId)
    }

    func testMultiEpisodeFilesSkipTheirRange() {
        let double12 = ep(1, 1, end: 2)
        let files = [double12, ep(1, 2), ep(1, 3)]
        XCTAssertEqual(ep(1, 3).driveId, EpisodeNav.next(double12, files, online: true)?.driveId)
        XCTAssertEqual(ep(1, 2).driveId, EpisodeNav.previous(files[2], files, online: true)?.driveId)
        XCTAssertEqual(double12.driveId, EpisodeNav.previous(files[2], [double12, files[2]], online: true)?.driveId)
    }

    func testSameAccountFirstAndOfflineDeviceOnly() {
        let files = [ep(1, 1), ep(1, 2, "device"), ep(1, 2), ep(1, 3, "b@x")]
        XCTAssertEqual("a@x", EpisodeNav.next(files[0], files, online: true)?.accountEmail)
        XCTAssertEqual("device", EpisodeNav.next(files[0], files, online: false)?.accountEmail)
        XCTAssertNil(EpisodeNav.next(files[1], files, online: false))
    }

    func testEpisodeListPutsSpecialsLast() {
        let list = EpisodeNav.episodeList([ep(0, 1), ep(2, 1), ep(1, 2), ep(1, 1), ep(1, 1, "b@x")])
        XCTAssertEqual([[1, 1], [1, 2], [2, 1], [0, 1]], list.map { [$0.season!, $0.episode!] })
        XCTAssertEqual("a@x", list[0].accountEmail)
    }
}

final class PlayerPrefsTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-prefs-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func testTrackMemoryRoundTrips() {
        let prefs = PlayerPrefsStore(url: url)
        XCTAssertNil(prefs.trackMemory("f1"))
        prefs.updateTrackMemory("f1") { $0.with { $0.audioIndex = 1; $0.audioLanguage = "hi"; $0.subtitleOffsetMs = -300 } }
        prefs.updateTrackMemory("f1") {
            $0.with { $0.subtitleMode = TrackMemory.subExternal; $0.externalSource = "side:x"; $0.externalName = "Eng\u{1F}lish" }
        }
        let reloaded = PlayerPrefsStore(url: url).trackMemory("f1")!
        XCTAssertEqual(1, reloaded.audioIndex)
        XCTAssertEqual("hi", reloaded.audioLanguage)
        XCTAssertEqual(TrackMemory.subExternal, reloaded.subtitleMode)
        XCTAssertNil(reloaded.subtitleIndex)
        XCTAssertEqual("side:x", reloaded.externalSource)
        XCTAssertEqual("Eng lish", reloaded.externalName)
        XCTAssertEqual(-300, reloaded.subtitleOffsetMs)
    }

    func testAndroidFormatDecodes() {
        let m = TrackMemory.decode("2\u{1F}en\u{1F}embedded\u{1F}0\u{1F}fr\u{1F}\u{1F}\u{1F}0")
        XCTAssertEqual(2, m.audioIndex)
        XCTAssertEqual("embedded", m.subtitleMode)
        XCTAssertEqual(0, m.subtitleIndex)
        XCTAssertEqual("fr", m.subtitleLanguage)
        XCTAssertNil(m.externalSource)
        XCTAssertEqual(0, m.subtitleOffsetMs)
    }

    func testShowLanguages() {
        let prefs = PlayerPrefsStore(url: url)
        prefs.setAudioLanguage(5, "")
        XCTAssertNil(prefs.audioLanguage(5))
        prefs.setAudioLanguage(5, "ja")
        prefs.setSubtitleLanguage(5, nil)
        XCTAssertEqual("ja", prefs.audioLanguage(5))
        XCTAssertEqual("off", prefs.subtitleLanguage(5))
        prefs.setSubtitleLanguage(nil, "en")
        XCTAssertNil(prefs.subtitleLanguage(nil))
        XCTAssertEqual("Fit", prefs.resizeMode)
        prefs.resizeMode = "Fill"
        XCTAssertEqual("Fill", PlayerPrefsStore(url: url).resizeMode)
    }
}

final class PlayerFormatTests: XCTestCase {
    func testClock() {
        XCTAssertEqual("4:05", PlayerFormat.clock(245_000))
        XCTAssertEqual("1:02:09", PlayerFormat.clock(3_729_000))
        XCTAssertEqual("0:00", PlayerFormat.clock(-5))
    }

    func testSwipeGestures() {
        // Full width = 3 minutes, clamped to the video.
        XCTAssertTrue(PlayerMath.swipeSeek(60_000, 600_000, 500, 1000) == (90_000, 150_000))
        XCTAssertTrue(PlayerMath.swipeSeek(60_000, 600_000, -1000, 1000) == (-60_000, 0))
        XCTAssertTrue(PlayerMath.swipeSeek(580_000, 600_000, 1000, 1000) == (20_000, 600_000))
        XCTAssertEqual("+1:30  ·  2:30", PlayerFormat.swipeSeek(90_000, 150_000))
        XCTAssertEqual("−0:20  ·  0:40", PlayerFormat.swipeSeek(-20_000, 40_000))
        // 70 % of the height = 200 points; up (negative dy) is louder.
        XCTAssertEqual(200, PlayerMath.swipeVolume(100, -700, 1000))
        XCTAssertEqual(150, PlayerMath.swipeVolume(100, -175, 1000))
        XCTAssertEqual(0, PlayerMath.swipeVolume(100, 900, 1000))
    }

    func testLabels() {
        XCTAssertEqual("Normal", PlayerFormat.speedOption(1))
        XCTAssertEqual("2×", PlayerFormat.speedOption(2))
        XCTAssertEqual("0.25×", PlayerFormat.speedOption(0.25))
        XCTAssertEqual("1.5×", PlayerFormat.speedChip(1.5))
        XCTAssertEqual("Speed", PlayerFormat.speedChip(1))
        XCTAssertEqual("In sync", PlayerFormat.syncLabel(0))
        XCTAssertEqual("0.5 s later", PlayerFormat.syncLabel(500))
        XCTAssertEqual("1.2 s earlier", PlayerFormat.syncLabel(-1200))
        XCTAssertEqual("S1 · E2", PlayerFormat.episodeCode(1, 2))
        XCTAssertEqual("Special 3", PlayerFormat.episodeCode(0, 3))
        XCTAssertEqual("", PlayerFormat.episodeCode(nil, 3))
        XCTAssertEqual("2h 46m", PlayerFormat.runtime(166))
        XCTAssertEqual("48m", PlayerFormat.runtime(48))
        XCTAssertEqual("2h", PlayerFormat.runtime(120))
        XCTAssertNil(PlayerFormat.runtime(0))
        XCTAssertEqual("1.4 GB", PlayerFormat.bytes(1_503_238_554))
        XCTAssertEqual("700 MB", PlayerFormat.bytes(734_003_200))
        XCTAssertEqual("—", PlayerFormat.bytes(0))
        XCTAssertEqual("Volume 150% · Boost", PlayerFormat.volume(150))
        XCTAssertEqual("Zoom 1.5×", PlayerFormat.zoom(1.5))
    }

    func testLoadingHints() {
        XCTAssertNil(PlayerFormat.loadingHint(0, "Google Drive"))
        XCTAssertEqual("Loading from MyNAS…", PlayerFormat.loadingHint(1, "MyNAS"))
        XCTAssertEqual("Loading…", PlayerFormat.loadingHint(1, nil))
        XCTAssertEqual("Slow connection, still loading…", PlayerFormat.loadingHint(2, "Google Drive"))
        XCTAssertEqual("Still loading…", PlayerFormat.loadingHint(2, nil))
    }

    func testSeekMath() {
        XCTAssertEqual(0, PlayerMath.seekBy(3_000, 100_000, -10_000))
        XCTAssertEqual(99_500, PlayerMath.seekBy(95_000, 100_000, 10_000))
        XCTAssertEqual(20_000, PlayerMath.seekBy(10_000, 0, 10_000))
        XCTAssertEqual(99_000, PlayerMath.skipForward(50_000, 100_000, 85))
        XCTAssertEqual(0, PlayerMath.resumeAt(false, 9_000, false))
        XCTAssertEqual(60_000, PlayerMath.resumeAt(false, 60_000, false))
        XCTAssertEqual(0, PlayerMath.resumeAt(false, 60_000, true))
        XCTAssertEqual(0, PlayerMath.resumeAt(true, 60_000, false))
        XCTAssertEqual(20, PlayerMath.accumulateSeek(10, true, 800, 10))
        XCTAssertEqual(10, PlayerMath.accumulateSeek(10, true, 1_300, 10))
        XCTAssertEqual(10, PlayerMath.accumulateSeek(10, false, 100, 10))
        XCTAssertEqual(1.25, PlayerMath.stepSpeed(1, 1))
        XCTAssertEqual(0.25, PlayerMath.stepSpeed(0.25, -1))
        XCTAssertEqual(3, PlayerMath.stepSpeed(3, 1))
    }

    func testPromptWindows() {
        XCTAssertTrue(PlayerMath.skipIntroVisible(true, false, false, false, 5_000))
        XCTAssertFalse(PlayerMath.skipIntroVisible(true, false, true, false, 6_000))
        XCTAssertFalse(PlayerMath.skipIntroVisible(true, false, false, false, 180_001))
        XCTAssertTrue(PlayerMath.upNextVisible(true, 100_000, 75_000, false, false, false))
        XCTAssertFalse(PlayerMath.upNextVisible(true, 100_000, 60_000, false, false, false))
        XCTAssertFalse(PlayerMath.upNextVisible(true, 100_000, 100_000, false, false, false))
        XCTAssertFalse(PlayerMath.upNextVisible(true, 100_000, 80_000, false, false, true))
    }

    func testCropGeometry() {
        XCTAssertNil(PlayerMath.cropGeometry(1920, 1080, 1600, 900, fill: true, 1, 0, 0))
        XCTAssertEqual("1440x1080+240+0", PlayerMath.cropGeometry(1920, 1080, 1200, 900, fill: true, 1, 0, 0))
        XCTAssertEqual("960x540+480+270", PlayerMath.cropGeometry(1920, 1080, 0, 0, fill: false, 2, 0, 0))
        XCTAssertEqual("960x540+960+540", PlayerMath.cropGeometry(1920, 1080, 0, 0, fill: false, 2, 1, 1))
    }

    // Mac additions: the pure parts of the Windows player window.
    func testZoomAndEndsAt() {
        XCTAssertEqual(1, PlayerMath.clampZoom(1.04))
        XCTAssertEqual(5, PlayerMath.clampZoom(9))
        XCTAssertEqual(1.1, PlayerMath.wheelZoom(1, notches: 1), accuracy: 0.0001)
        XCTAssertEqual(0, PlayerMath.pan(0.5, delta: 10, size: 100, zoom: 1))
        XCTAssertEqual(-0.2, PlayerMath.pan(0, delta: 10, size: 100, zoom: 2), accuracy: 0.0001)
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(30, PlayerMath.endsAt(now: now, durationMs: 100_000, positionMs: 40_000, speed: 2)!.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertNil(PlayerMath.endsAt(now: now, durationMs: 0, positionMs: 0, speed: 1))
        XCTAssertEqual("Off", PlayerFormat.sleepDetail(nil, false))
        XCTAssertEqual("At the end of this video", PlayerFormat.sleepDetail(nil, true))
        XCTAssertTrue(PlayerFormat.endsAt(now).hasPrefix("Ends at "))
    }
}
