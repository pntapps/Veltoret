import XCTest
@testable import VeltoretKit

/// Real-world naming styles, one per line, so a parser change shows exactly which names it breaks.
/// Release sites are made up ("ReleaseSite.at", "ReleaseSite.army"). Same lines as Android FilenameParserCorpusTest.kt and
/// Windows FilenameParserCorpusTests.cs; add a line for every name that parses wrong.
final class FilenameParserCorpusTests: XCTestCase {
    private struct M {
        let file: String, title: String, year: Int?, folders: [String]?
        init(_ file: String, _ title: String, _ year: Int?, _ folders: [String]? = nil) {
            self.file = file; self.title = title; self.year = year; self.folders = folders
        }
    }

    private struct E {
        let file: String, show: String, season: Int, episode: Int, folders: [String]?, year: Int?, episodeEnd: Int?
        init(_ file: String, _ show: String, _ season: Int, _ episode: Int, _ folders: [String]? = nil, year: Int? = nil,
             episodeEnd: Int? = nil) {
            self.file = file; self.show = show; self.season = season; self.episode = episode; self.folders = folders
            self.year = year; self.episodeEnd = episodeEnd
        }
    }

    private static func f(_ f: String...) -> [String] { f }

    private static let movies: [M] = [
        // Scene and P2P styles
        M("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv", "The Matrix", 1999),
        M("Inception.2010.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-GRP.mkv", "Inception", 2010),
        M("Oppenheimer (2023) [2160p] [4K] [WEB] [5.1] [ReleaseSite.at].mp4", "Oppenheimer", 2023),
        M("Dune.Part.Two.2024.1080p.WEB-DL.DDP5.1.Atmos.H.264-GROUP.mkv", "Dune Part Two", 2024),
        M("Interstellar_2014_1080p_BrRip_x264.mp4", "Interstellar", 2014),
        M("Mad Max Fury Road 2015 1080p BluRay x264 DTS-HD MA 7.1.mkv", "Mad Max Fury Road", 2015),
        M("Parasite.2019.KOREAN.1080p.BluRay.x264.mkv", "Parasite", 2019),
        M("The Batman (2022) 1080p WEBRip 10bit x265 HEVC.mkv", "The Batman", 2022),
        M("Movie+Name+2020+720p.mp4", "Movie Name", 2020),
        // Titles that contain numbers or years
        M("1917.2019.2160p.UHD.mkv", "1917", 2019),
        M("2001.A.Space.Odyssey.1968.mkv", "2001 A Space Odyssey", 1968),
        M("Blade.Runner.2049.1080p.WEB-DL.mkv", "Blade Runner 2049", nil),
        M("2012 (2009) 1080p.mkv", "2012", 2009),
        M("Ocean's Eleven (2001).mkv", "Ocean's Eleven", 2001),
        // Indian release styles
        M("R.L.Stines.Pumpkinhead.2025.1080p.Web-Dl.Hindi.English.Esubs.ReleaseSite.army.mkv", "R L Stines Pumpkinhead", 2025),
        M("Good Luck Have Fun Dont Die (2026) 1080p BluRay 10bit HEVC [Hindi DDP 5.1  English AAC 7.1] x265 (Group-Tag).mkv", "Good Luck Have Fun Dont Die", 2026),
        M("Jawan (2023) Hindi 1080p HQ HDRip x264 AAC ESub.mkv", "Jawan", 2023),
        M("Pushpa.2.The.Rule.2024.Hindi.Dubbed.720p.WEB-DL.mkv", "Pushpa 2 The Rule", 2024),
        M("Kalki 2898 AD (2024) Dual Audio [Hindi + Telugu] 1080p.mkv", "Kalki 2898 AD", 2024),
        M("Some Movie (Hindi Dubbed) 720p.mkv", "Some Movie", nil),
        M("Some.Movie.Hindi.English.Esubs.mkv", "Some Movie", nil),
        // Release-site prefixes and suffixes
        M("www.ReleaseSite.com - The Holdovers (2023) 1080p.mkv", "The Holdovers", 2023),
        M("www.ReleaseSite.lol.The.Holdovers.2023.720p.mkv", "The Holdovers", 2023),
        M("ReleaseSite.com - The Holdovers (2023).mkv", "The Holdovers", 2023),
        M("[ReleaseSite.at] The Holdovers 2023.mkv", "The Holdovers", 2023),
        M("The Holdovers - ReleaseSite.army.mkv", "The Holdovers", nil),
        // Dotted titles that look like sites but aren't
        M("The.Fault.in.Our.Stars.2014.mkv", "The Fault in Our Stars", 2014),
        M("The.Office.US.mkv", "The Office US", nil),
        // Accents and other scripts
        M("Am\u{E9}lie.2001.1080p.mkv", "Am\u{E9}lie", 2001),
        M("\u{926}\u{902}\u{917}\u{932}.2016.1080p.mkv", "\u{926}\u{902}\u{917}\u{932}", 2016),
        M("\u{5343}\u{3068}\u{5343}\u{5C0B}\u{306E}\u{795E}\u{96A0}\u{3057} (2001).mkv", "\u{5343}\u{3068}\u{5343}\u{5C0B}\u{306E}\u{795E}\u{96A0}\u{3057}", 2001),
        // Folders
        M("movie.mkv", "Inception", 2010, f("Inception (2010)")),
        M("Heat.mkv", "Heat", 1995, f("Heat (1995)")),
        M("Heat.mkv", "Heat", 1995, f("Heat (1995)", "1080p")),
        M("cd1.avi", "Heat", 1995, f("Hindi Movies", "Heat (1995)")),
    ]

    private static let episodes: [E] = [
        // Standard numbering
        E("Breaking.Bad.S02E05.Breakage.1080p.mkv", "Breaking Bad", 2, 5),
        E("breaking.bad.s02e05.720p.mkv", "breaking bad", 2, 5),
        E("Show.Name.S01.E02.1080p.mkv", "Show Name", 1, 2),
        E("Show Name S01 E02.mkv", "Show Name", 1, 2),
        E("Show-Name-S01-E02.mkv", "Show-Name", 1, 2),
        E("Show_Name_S01_E02.mkv", "Show Name", 1, 2),
        E("Show.Name.S01EP02.mkv", "Show Name", 1, 2),
        E("Show Name - S01E01-E03 - Pilot.mkv", "Show Name", 1, 1, episodeEnd: 3),
        E("Show.S03E01E02.mkv", "Show", 3, 1, episodeEnd: 2),
        E("Show.Name.S01E01-03.mkv", "Show Name", 1, 1, episodeEnd: 3),
        E("Show.Name.S01E01-1080p.mkv", "Show Name", 1, 1),
        E("Friends 3x07 The One.mkv", "Friends", 3, 7),
        E("Show Name Season 2 Episode 5.mkv", "Show Name", 2, 5),
        E("Show.Name.Season.2.Ep.5.mkv", "Show Name", 2, 5),
        E("Doctor.Who.2005.S01E01.Rose.mkv", "Doctor Who", 1, 1, year: 2005),
        // Daily and date-based
        E("The.Daily.Show.2024.03.15.Guest.Name.720p.mkv", "The Daily Show", 2024, 315),
        // Anime
        E("[SubGroup] Frieren - 05 [1080p].mkv", "Frieren", 1, 5),
        E("[SubGroup] One Piece - 1085 [1080p][ABCD1234].mkv", "One Piece", 1, 1085),
        E("[SubGroup] Show Name 12 (1080p).mkv", "Show Name", 1, 12),
        E("Show Name - 07v2.mkv", "Show Name", 1, 7),
        E("Show Name Ep 07.mkv", "Show Name", 1, 7),
        E("Show Name Episode 7.mkv", "Show Name", 1, 7),
        E("\u{9032}\u{6483}\u{306E}\u{5DE8}\u{4EBA} \u{7B2C}05\u{8A71}.mkv", "\u{9032}\u{6483}\u{306E}\u{5DE8}\u{4EBA}", 1, 5),
        // Compact numbering in scene names only
        E("Show.Name.105.HDTV.mkv", "Show Name", 1, 5),
        // Indian release styles and pack folders
        E("Below.S01E06.The.Unfathering.Deep.480p.x264.English.Hindi.MSubs.ReleaseSite.ai.in.mkv", "Below", 1, 6,
            f("Below.S01.480p.x264.English.Hindi.MSubs.ReleaseSite.ai.in", "480p x264")),
        E("E05.mkv", "Overcompensating", 1, 5, f("Overcompensating.S01.1080p.x264.Hindi.English.Msubs.ReleaseSite.at")),
        E("Episode 4.mkv", "Show Name", 2, 4, f("Show Name S02 720p")),
        // Folder layouts
        E("S01E01.mkv", "The Office US", 1, 1, f("The Office (US) (2005)", "Season 1"), year: 2005),
        E("Episode 3.mkv", "Doctor Who", 0, 3, f("Doctor Who", "Specials")),
        E("05.mkv", "Dark", 2, 5, f("Dark", "Season.2")),
        E("05.mkv", "Dark", 2, 5, f("Dark", "S02")),
        E("05.mkv", "Dark", 2, 5, f("Dark", "Staffel 2")),
        E("05.mkv", "Dark", 3, 5, f("Dark", "Season Three")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, f("English Shows", "Dark")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, f("English Shows")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, f("Dark", "Season 1", "Disc 1")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, f("Dark", "Season 1", "Dark.S01E01.Secrets")),
        E("Office.S01E01.mkv", "The Office", 1, 1, f("The Office (2005)"), year: 2005),
        E("05.mkv", "Show", 2, 5, f("Season 2", "Show")),
        E("01 - Pilot.mkv", "Show", 1, 1, f("Show")),
    ]

    private static func s(_ v: Int?) -> String { v.map(String.init) ?? "" }

    func testMoviesParse() {
        let failures = Self.movies.compactMap { m -> String? in
            let g = FilenameParser.parseMovie(m.file, folders: m.folders ?? [])
            if g.title == m.title && g.year == m.year { return nil }
            return "\(m.file) -> \"\(g.title)\" \(Self.s(g.year)) (want \"\(m.title)\" \(Self.s(m.year)))"
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }

    func testEpisodesParse() {
        var failures: [String] = []
        for e in Self.episodes {
            let g = FilenameParser.parseEpisode(e.file, folders: e.folders ?? [])
            let got = g.map { "[\($0.showTitle), \($0.season), \($0.episode), \(Self.s($0.showYear)), \(Self.s($0.episodeEnd))]" } ?? "nil"
            let want = "[\(e.show), \(e.season), \(e.episode), \(Self.s(e.year)), \(Self.s(e.episodeEnd))]"
            if got != want { failures.append("\(e.file) [\((e.folders ?? []).joined(separator: ", "))] -> \(got) (want \(want))") }
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }

    func testNotEpisodes() {
        for name in ["Behind the scenes.mkv", "Show Name 1080p.mkv", "Show Name 2019.mkv"] {
            XCTAssertNil(FilenameParser.parseEpisode(name), name)
        }
    }

    func testMovieFallbacksTrimLeftovers() {
        let c = FilenameParser.movieCandidates("Some.Movie.Hindi.720p.mkv")
        XCTAssertEqual("Some Movie Hindi", c[0].title)
        XCTAssertTrue(c.contains { $0.title == "Some Movie" && $0.exactOnly })
    }

    func testMovieFallbacksSplitSubtitle() {
        let c = FilenameParser.movieCandidates("Mission Impossible - Dead Reckoning 2023.mkv")
        XCTAssertTrue(c.contains { $0.title == "Mission Impossible" && $0.year == 2023 && $0.exactOnly })
    }

    func testTrimmedFallbacksNeverShrinkToOneYearlessWord() {
        let c = FilenameParser.movieCandidates("drone footage beach.mkv")
        XCTAssertFalse(c.contains { $0.title == "drone" })
    }

    func testShowFallbacksIncludeFileTitle() {
        let c = FilenameParser.showCandidates("Dark.S01E01.mkv", folders: ["English Shows", "My Stuff"])
        XCTAssertEqual("My Stuff", c[0].title)
        XCTAssertTrue(c.contains { $0.title == "Dark" && !$0.exactOnly })
    }

    func testOtherScriptsSurviveNormalizing() {
        XCTAssertEqual("\u{926}\u{902}\u{917}\u{932}", FilenameParser.normalizeForCompare("\u{926}\u{902}\u{917}\u{932}!"))
        XCTAssertEqual("amelie", FilenameParser.normalizeForCompare("Am\u{E9}lie"))
    }
}
