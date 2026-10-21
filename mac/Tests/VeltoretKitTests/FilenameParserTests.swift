import XCTest
@testable import VeltoretKit

/// Port of Windows FilenameParserTests.cs (itself a port of Android FilenameParserTest.kt).
final class FilenameParserTests: XCTestCase {
    private func movie(_ name: String, _ folders: String...) -> FilenameParser.MovieGuess {
        FilenameParser.parseMovie(name, folders: folders)
    }
    private func ep(_ name: String, _ folders: String...) -> FilenameParser.EpisodeGuess? {
        FilenameParser.parseEpisode(name, folders: folders)
    }

    func testSceneMovie() {
        let m = movie("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv")
        XCTAssertEqual("The Matrix", m.title)
        XCTAssertEqual(1999, m.year)
    }

    func testMovieWithParenthesesYear() {
        let m = movie("Dune Part Two (2024) [2160p] [HDR].mkv")
        XCTAssertEqual("Dune Part Two", m.title)
        XCTAssertEqual(2024, m.year)
    }

    func testTitleThatIsAYear() {
        XCTAssertEqual(FilenameParser.MovieGuess(title: "1917", year: 2019), movie("1917.2019.2160p.UHD.mkv"))
        XCTAssertEqual(FilenameParser.MovieGuess(title: "2001 A Space Odyssey", year: 1968), movie("2001.A.Space.Odyssey.1968.mkv"))
    }

    func testFutureNumberIsNotAYear() {
        let m = movie("Blade.Runner.2049.1080p.WEB-DL.mkv")
        XCTAssertEqual("Blade Runner 2049", m.title)
        XCTAssertNil(m.year)
    }

    func testGenericFileUsesFolder() {
        let m = movie("movie.mkv", "Inception (2010)")
        XCTAssertEqual("Inception", m.title)
        XCTAssertEqual(2010, m.year)
    }

    func testFolderSuppliesMissingYear() { XCTAssertEqual(1995, movie("Heat.mkv", "Heat (1995)").year) }

    func testKeepsAbbreviationDots() { XCTAssertEqual("Mr Robot", ep("Mr.Robot.S01E02.720p.mkv")!.showTitle) }

    func testStandardEpisode() {
        let e = ep("Breaking.Bad.S02E05.Breakage.1080p.mkv")!
        XCTAssertEqual("Breaking Bad", e.showTitle)
        XCTAssertEqual(2, e.season)
        XCTAssertEqual(5, e.episode)
    }

    func testShowFolderWins() {
        let e = ep("S01E01.mkv", "The Office (US) (2005)", "Season 1")!
        XCTAssertEqual("The Office US", e.showTitle)
        XCTAssertEqual(2005, e.showYear)
        XCTAssertEqual(1, e.season)
    }

    func testMultiEpisode() {
        let e = ep("Show.S03E01E02.mkv")!
        XCTAssertEqual(1, e.episode)
        XCTAssertEqual(2, e.episodeEnd)
    }

    func testXNotation() {
        let e = ep("Friends 3x07 The One.mkv")!
        XCTAssertEqual(3, e.season)
        XCTAssertEqual(7, e.episode)
    }

    func testAnimeStyleUsesSeasonFolder() {
        let e = ep("[SubGroup] Frieren - 05 [1080p].mkv", "Frieren", "Season 2")!
        XCTAssertEqual("Frieren", e.showTitle)
        XCTAssertEqual(2, e.season)
        XCTAssertEqual(5, e.episode)
    }

    func testSpecialsFolder() {
        let e = ep("Episode 3.mkv", "Doctor Who", "Specials")!
        XCTAssertEqual(0, e.season)
        XCTAssertEqual(3, e.episode)
    }

    func testNoEpisodeNumber() { XCTAssertNil(ep("Behind the scenes.mkv")) }

    func testSeasonTagInShowFolderIsDropped() {
        let e = ep("Below.S01E03.480p.x264.mkv", "Below.S01.480p.x264.English.Hindi.MSubs.ReleaseSite.at", "480p x264")!
        XCTAssertEqual("Below", e.showTitle)
        XCTAssertEqual(1, e.season)
        XCTAssertEqual(3, e.episode)
        XCTAssertEqual("Overcompensating", ep("E05.mkv", "Overcompensating.S01.1080p.x264.Hindi.English.Msubs.ReleaseSite.at")!.showTitle)
    }

    func testSeasonFromShowFolderTag() {
        let e = ep("Episode 4.mkv", "Show Name S02 720p")!
        XCTAssertEqual("Show Name", e.showTitle)
        XCTAssertEqual(2, e.season)
    }

    func testSeasonRangesAndCompleteInShowFolder() {
        XCTAssertEqual("The Wire", ep("The.Wire.S03E01.mkv", "The Wire S01-S05 Complete 1080p")!.showTitle)
        XCTAssertEqual("Dark", ep("Dark.S01E01.mkv", "Dark Season 1-3 (2017)")!.showTitle)
        XCTAssertEqual("Fargo", ep("Fargo.S02E01.mkv", "Fargo Complete Series")!.showTitle)
    }

    func testSeasonTagInFileNameOnly() { XCTAssertEqual("Below", ep("Below.S01.E02.480p.mkv")!.showTitle) }

    func testLanguagesAreNotPartOfTitle() {
        XCTAssertEqual("Some Movie", movie("Some.Movie.Hindi.English.Esubs.mkv").title)
        let m = movie("R.L.Stines.Pumpkinhead.2025.1080p.Web-Dl.Hindi.English.Esubs.ReleaseSite.at.mkv")
        XCTAssertEqual("R L Stines Pumpkinhead", m.title)
        XCTAssertEqual(2025, m.year)
    }

    func testApostrophesIgnoredWhenComparing() {
        XCTAssertEqual(
            FilenameParser.normalizeForCompare("Good Luck, Have Fun, Don't Die"),
            FilenameParser.normalizeForCompare("Good Luck Have Fun Dont Die"))
        XCTAssertEqual(
            FilenameParser.normalizeForCompare("R.L. Stine\u{2019}s Pumpkinhead"),
            FilenameParser.normalizeForCompare("R L Stines Pumpkinhead"))
    }

    func testQualityTags() {
        let tags = FilenameParser.qualityTags("Movie.2160p.UHD.BluRay.HEVC.TrueHD.Atmos.7.1.mkv", height: 0)
        XCTAssertEqual(["4K", "HEVC", "Atmos", "7.1"], tags)
    }
}
