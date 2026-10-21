package com.pntapps.veltoret

import com.pntapps.veltoret.data.library.FilenameParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FilenameParserTest {

    private fun movie(name: String, vararg folders: String) = FilenameParser.parseMovie(name, folders.toList())
    private fun ep(name: String, vararg folders: String) = FilenameParser.parseEpisode(name, folders.toList())

    @Test fun sceneMovie() {
        val m = movie("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv")
        assertEquals("The Matrix", m.title)
        assertEquals(1999, m.year)
    }

    @Test fun movieWithParenthesesYear() {
        val m = movie("Dune Part Two (2024) [2160p] [HDR].mkv")
        assertEquals("Dune Part Two", m.title)
        assertEquals(2024, m.year)
    }

    @Test fun titleThatIsAYear() {
        assertEquals(MovieGuessExpect("1917", 2019), movie("1917.2019.2160p.UHD.mkv").let { MovieGuessExpect(it.title, it.year) })
        assertEquals(MovieGuessExpect("2001 A Space Odyssey", 1968), movie("2001.A.Space.Odyssey.1968.mkv").let { MovieGuessExpect(it.title, it.year) })
    }

    @Test fun futureNumberIsNotAYear() {
        val m = movie("Blade.Runner.2049.1080p.WEB-DL.mkv")
        assertEquals("Blade Runner 2049", m.title)
        assertNull(m.year)
    }

    @Test fun genericFileUsesFolder() {
        val m = movie("movie.mkv", "Inception (2010)")
        assertEquals("Inception", m.title)
        assertEquals(2010, m.year)
    }

    @Test fun folderSuppliesMissingYear() {
        val m = movie("Heat.mkv", "Heat (1995)")
        assertEquals(1995, m.year)
    }

    @Test fun keepsAbbreviationDots() {
        assertEquals("Mr Robot", ep("Mr.Robot.S01E02.720p.mkv")!!.showTitle)
    }

    @Test fun standardEpisode() {
        val e = ep("Breaking.Bad.S02E05.Breakage.1080p.mkv")!!
        assertEquals("Breaking Bad", e.showTitle)
        assertEquals(2, e.season)
        assertEquals(5, e.episode)
    }

    @Test fun showFolderWins() {
        val e = ep("S01E01.mkv", "The Office (US) (2005)", "Season 1")!!
        assertEquals("The Office US", e.showTitle)
        assertEquals(2005, e.showYear)
        assertEquals(1, e.season)
    }

    @Test fun multiEpisode() {
        val e = ep("Show.S03E01E02.mkv")!!
        assertEquals(1, e.episode)
        assertEquals(2, e.episodeEnd)
    }

    @Test fun xNotation() {
        val e = ep("Friends 3x07 The One.mkv")!!
        assertEquals(3, e.season)
        assertEquals(7, e.episode)
    }

    @Test fun animeStyleUsesSeasonFolder() {
        val e = ep("[SubGroup] Frieren - 05 [1080p].mkv", "Frieren", "Season 2")!!
        assertEquals("Frieren", e.showTitle)
        assertEquals(2, e.season)
        assertEquals(5, e.episode)
    }

    @Test fun specialsFolder() {
        val e = ep("Episode 3.mkv", "Doctor Who", "Specials")!!
        assertEquals(0, e.season)
        assertEquals(3, e.episode)
    }

    @Test fun noEpisodeNumber() {
        assertNull(ep("Behind the scenes.mkv"))
    }

    @Test fun seasonTagInShowFolderIsDropped() {
        val e = ep("Below.S01E03.480p.x264.mkv", "Below.S01.480p.x264.English.Hindi.MSubs.ReleaseSite.at", "480p x264")!!
        assertEquals("Below", e.showTitle)
        assertEquals(1, e.season)
        assertEquals(3, e.episode)
        assertEquals("Overcompensating", ep("E05.mkv", "Overcompensating.S01.1080p.x264.Hindi.English.Msubs.ReleaseSite.at")!!.showTitle)
    }

    @Test fun seasonFromShowFolderTag() {
        val e = ep("Episode 4.mkv", "Show Name S02 720p")!!
        assertEquals("Show Name", e.showTitle)
        assertEquals(2, e.season)
    }

    @Test fun seasonRangesAndCompleteInShowFolder() {
        assertEquals("The Wire", ep("The.Wire.S03E01.mkv", "The Wire S01-S05 Complete 1080p")!!.showTitle)
        assertEquals("Dark", ep("Dark.S01E01.mkv", "Dark Season 1-3 (2017)")!!.showTitle)
        assertEquals("Fargo", ep("Fargo.S02E01.mkv", "Fargo Complete Series")!!.showTitle)
    }

    @Test fun seasonTagInFileNameOnly() {
        assertEquals("Below", ep("Below.S01.E02.480p.mkv")!!.showTitle)
    }

    @Test fun languagesAreNotPartOfTitle() {
        assertEquals("Some Movie", movie("Some.Movie.Hindi.English.Esubs.mkv").title)
        val m = movie("R.L.Stines.Pumpkinhead.2025.1080p.Web-Dl.Hindi.English.Esubs.ReleaseSite.at.mkv")
        assertEquals("R L Stines Pumpkinhead", m.title)
        assertEquals(2025, m.year)
    }

    @Test fun apostrophesIgnoredWhenComparing() {
        assertEquals(
            FilenameParser.normalizeForCompare("Good Luck, Have Fun, Don't Die"),
            FilenameParser.normalizeForCompare("Good Luck Have Fun Dont Die"),
        )
        assertEquals(
            FilenameParser.normalizeForCompare("R.L. Stine\u2019s Pumpkinhead"),
            FilenameParser.normalizeForCompare("R L Stines Pumpkinhead"),
        )
    }

    @Test fun qualityTags() {
        val tags = FilenameParser.qualityTags("Movie.2160p.UHD.BluRay.HEVC.TrueHD.Atmos.7.1.mkv", 0)
        assertEquals(listOf("4K", "HEVC", "Atmos", "7.1"), tags)
    }

    private data class MovieGuessExpect(val title: String, val year: Int?)
}
