package com.pntapps.veltoret

import com.pntapps.veltoret.data.library.FilenameParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Real-world naming styles, one per line, so a parser change shows exactly which names it breaks.
 * Release sites are made up ("ReleaseSite.at", "ReleaseSite.army").
 */
class FilenameParserCorpusTest {

    private data class M(val file: String, val title: String, val year: Int?, val folders: List<String> = emptyList())

    private data class E(
        val file: String,
        val show: String,
        val season: Int,
        val episode: Int,
        val folders: List<String> = emptyList(),
        val year: Int? = null,
        val episodeEnd: Int? = null,
    )

    private val movies = listOf(
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
        M("Blade.Runner.2049.1080p.WEB-DL.mkv", "Blade Runner 2049", null),
        M("2012 (2009) 1080p.mkv", "2012", 2009),
        M("Ocean's Eleven (2001).mkv", "Ocean's Eleven", 2001),
        // Indian release styles
        M("R.L.Stines.Pumpkinhead.2025.1080p.Web-Dl.Hindi.English.Esubs.ReleaseSite.army.mkv", "R L Stines Pumpkinhead", 2025),
        M("Good Luck Have Fun Dont Die (2026) 1080p BluRay 10bit HEVC [Hindi DDP 5.1  English AAC 7.1] x265 (Group-Tag).mkv", "Good Luck Have Fun Dont Die", 2026),
        M("Jawan (2023) Hindi 1080p HQ HDRip x264 AAC ESub.mkv", "Jawan", 2023),
        M("Pushpa.2.The.Rule.2024.Hindi.Dubbed.720p.WEB-DL.mkv", "Pushpa 2 The Rule", 2024),
        M("Kalki 2898 AD (2024) Dual Audio [Hindi + Telugu] 1080p.mkv", "Kalki 2898 AD", 2024),
        M("Some Movie (Hindi Dubbed) 720p.mkv", "Some Movie", null),
        M("Some.Movie.Hindi.English.Esubs.mkv", "Some Movie", null),
        // Release-site prefixes and suffixes
        M("www.ReleaseSite.com - The Holdovers (2023) 1080p.mkv", "The Holdovers", 2023),
        M("www.ReleaseSite.lol.The.Holdovers.2023.720p.mkv", "The Holdovers", 2023),
        M("ReleaseSite.com - The Holdovers (2023).mkv", "The Holdovers", 2023),
        M("[ReleaseSite.at] The Holdovers 2023.mkv", "The Holdovers", 2023),
        M("The Holdovers - ReleaseSite.army.mkv", "The Holdovers", null),
        // Dotted titles that look like sites but aren't
        M("The.Fault.in.Our.Stars.2014.mkv", "The Fault in Our Stars", 2014),
        M("The.Office.US.mkv", "The Office US", null),
        // Accents and other scripts
        M("Amélie.2001.1080p.mkv", "Amélie", 2001),
        M("दंगल.2016.1080p.mkv", "दंगल", 2016),
        M("千と千尋の神隠し (2001).mkv", "千と千尋の神隠し", 2001),
        // Folders
        M("movie.mkv", "Inception", 2010, listOf("Inception (2010)")),
        M("Heat.mkv", "Heat", 1995, listOf("Heat (1995)")),
        M("Heat.mkv", "Heat", 1995, listOf("Heat (1995)", "1080p")),
        M("cd1.avi", "Heat", 1995, listOf("Hindi Movies", "Heat (1995)")),
    )

    private val episodes = listOf(
        // Standard numbering
        E("Breaking.Bad.S02E05.Breakage.1080p.mkv", "Breaking Bad", 2, 5),
        E("breaking.bad.s02e05.720p.mkv", "breaking bad", 2, 5),
        E("Show.Name.S01.E02.1080p.mkv", "Show Name", 1, 2),
        E("Show Name S01 E02.mkv", "Show Name", 1, 2),
        E("Show-Name-S01-E02.mkv", "Show-Name", 1, 2),
        E("Show_Name_S01_E02.mkv", "Show Name", 1, 2),
        E("Show.Name.S01EP02.mkv", "Show Name", 1, 2),
        E("Show Name - S01E01-E03 - Pilot.mkv", "Show Name", 1, 1, episodeEnd = 3),
        E("Show.S03E01E02.mkv", "Show", 3, 1, episodeEnd = 2),
        E("Show.Name.S01E01-03.mkv", "Show Name", 1, 1, episodeEnd = 3),
        E("Show.Name.S01E01-1080p.mkv", "Show Name", 1, 1),
        E("Friends 3x07 The One.mkv", "Friends", 3, 7),
        E("Show Name Season 2 Episode 5.mkv", "Show Name", 2, 5),
        E("Show.Name.Season.2.Ep.5.mkv", "Show Name", 2, 5),
        E("Doctor.Who.2005.S01E01.Rose.mkv", "Doctor Who", 1, 1, year = 2005),
        // Daily and date-based
        E("The.Daily.Show.2024.03.15.Guest.Name.720p.mkv", "The Daily Show", 2024, 315),
        // Anime
        E("[SubGroup] Frieren - 05 [1080p].mkv", "Frieren", 1, 5),
        E("[SubGroup] One Piece - 1085 [1080p][ABCD1234].mkv", "One Piece", 1, 1085),
        E("[SubGroup] Show Name 12 (1080p).mkv", "Show Name", 1, 12),
        E("Show Name - 07v2.mkv", "Show Name", 1, 7),
        E("Show Name Ep 07.mkv", "Show Name", 1, 7),
        E("Show Name Episode 7.mkv", "Show Name", 1, 7),
        E("進撃の巨人 第05話.mkv", "進撃の巨人", 1, 5),
        // Compact numbering in scene names only
        E("Show.Name.105.HDTV.mkv", "Show Name", 1, 5),
        // Indian release styles and pack folders
        E("Below.S01E06.The.Unfathering.Deep.480p.x264.English.Hindi.MSubs.ReleaseSite.ai.in.mkv", "Below", 1, 6,
            listOf("Below.S01.480p.x264.English.Hindi.MSubs.ReleaseSite.ai.in", "480p x264")),
        E("E05.mkv", "Overcompensating", 1, 5, listOf("Overcompensating.S01.1080p.x264.Hindi.English.Msubs.ReleaseSite.at")),
        E("Episode 4.mkv", "Show Name", 2, 4, listOf("Show Name S02 720p")),
        // Folder layouts
        E("S01E01.mkv", "The Office US", 1, 1, listOf("The Office (US) (2005)", "Season 1"), year = 2005),
        E("Episode 3.mkv", "Doctor Who", 0, 3, listOf("Doctor Who", "Specials")),
        E("05.mkv", "Dark", 2, 5, listOf("Dark", "Season.2")),
        E("05.mkv", "Dark", 2, 5, listOf("Dark", "S02")),
        E("05.mkv", "Dark", 2, 5, listOf("Dark", "Staffel 2")),
        E("05.mkv", "Dark", 3, 5, listOf("Dark", "Season Three")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, listOf("English Shows", "Dark")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, listOf("English Shows")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, listOf("Dark", "Season 1", "Disc 1")),
        E("Dark.S01E01.mkv", "Dark", 1, 1, listOf("Dark", "Season 1", "Dark.S01E01.Secrets")),
        E("Office.S01E01.mkv", "The Office", 1, 1, listOf("The Office (2005)"), year = 2005),
        E("05.mkv", "Show", 2, 5, listOf("Season 2", "Show")),
        E("01 - Pilot.mkv", "Show", 1, 1, listOf("Show")),
    )

    @Test fun movies() {
        val failures = movies.mapNotNull { m ->
            val g = FilenameParser.parseMovie(m.file, m.folders)
            if (g.title == m.title && g.year == m.year) null else "${m.file} -> \"${g.title}\" ${g.year} (want \"${m.title}\" ${m.year})"
        }
        assertTrue(failures.joinToString("\n", prefix = "\n"), failures.isEmpty())
    }

    @Test fun episodes() {
        val failures = episodes.mapNotNull { e ->
            val g = FilenameParser.parseEpisode(e.file, e.folders)
            val got = g?.let { listOf(it.showTitle, it.season, it.episode, it.showYear, it.episodeEnd) }
            val want = listOf(e.show, e.season, e.episode, e.year, e.episodeEnd)
            if (got == want) null else "${e.file} ${e.folders} -> $got (want $want)"
        }
        assertTrue(failures.joinToString("\n", prefix = "\n"), failures.isEmpty())
    }

    @Test fun notEpisodes() {
        listOf("Behind the scenes.mkv", "Show Name 1080p.mkv", "Show Name 2019.mkv").forEach {
            assertEquals(it, null, FilenameParser.parseEpisode(it))
        }
    }

    @Test fun movieFallbacksTrimLeftovers() {
        val c = FilenameParser.movieCandidates("Some.Movie.Hindi.720p.mkv")
        assertEquals("Some Movie Hindi", c.first().title)
        assertTrue(c.toString(), c.any { it.title == "Some Movie" && it.exactOnly })
    }

    @Test fun movieFallbacksSplitSubtitle() {
        val c = FilenameParser.movieCandidates("Mission Impossible - Dead Reckoning 2023.mkv")
        assertTrue(c.toString(), c.any { it.title == "Mission Impossible" && it.year == 2023 && it.exactOnly })
    }

    @Test fun trimmedFallbacksNeverShrinkToOneYearlessWord() {
        val c = FilenameParser.movieCandidates("drone footage beach.mkv")
        assertTrue(c.toString(), c.none { it.title == "drone" })
    }

    @Test fun showFallbacksIncludeFileTitle() {
        val c = FilenameParser.showCandidates("Dark.S01E01.mkv", listOf("English Shows", "My Stuff"))
        assertEquals("My Stuff", c.first().title)
        assertTrue(c.toString(), c.any { it.title == "Dark" && !it.exactOnly })
    }

    @Test fun otherScriptsSurviveNormalizing() {
        assertEquals("दंगल", FilenameParser.normalizeForCompare("दंगल!"))
        assertEquals("amelie", FilenameParser.normalizeForCompare("Amélie"))
    }
}
