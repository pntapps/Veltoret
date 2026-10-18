package com.pntapps.veltoret

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pntapps.veltoret.data.library.FilenameParser
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Android compiles regexes with ICU, which is stricter than the JVM used by unit tests
 * (e.g. an unescaped `}` is fatal on device). This runs the parser's patterns on a real runtime.
 */
@RunWith(AndroidJUnit4::class)
class FilenameParserDeviceTest {

    @Test
    fun patternsCompileAndParseOnDevice() {
        val movie = FilenameParser.parseMovie("[Group] The.Matrix.1999.1080p.BluRay.x264.mkv")
        assertEquals("The Matrix", movie.title)
        assertEquals(1999, movie.year)

        val episode = FilenameParser.parseEpisode("Breaking.Bad.S02E05.mkv")!!
        assertEquals(2 to 5, episode.season to episode.episode)

        val tagged = FilenameParser.parseEpisode("E01.mkv", listOf("Below.S01.480p.English.Hindi.MSubs"))!!
        assertEquals("Below" to 1, tagged.showTitle to tagged.season)
        assertEquals("dont", FilenameParser.normalizeForCompare("Don't"))

        // Patterns that lean on ICU features: Unicode classes, hex escapes, lookbehind, site names.
        assertEquals("The Holdovers", FilenameParser.parseMovie("www.ReleaseSite.com - The Holdovers (2023) 1080p.mkv").title)
        assertEquals("Kalki 2898 AD", FilenameParser.parseMovie("Kalki 2898 AD (2024) Dual Audio [Hindi + Telugu] 1080p.mkv").title)
        assertEquals("दंगल", FilenameParser.parseMovie("दंगल.2016.1080p.mkv").title)
        assertEquals("amelie", FilenameParser.normalizeForCompare("Amélie"))
        assertEquals(5, FilenameParser.parseEpisode("進撃の巨人 第05話.mkv")!!.episode)
        assertEquals("Dark", FilenameParser.parseEpisode("Dark.S01E01.mkv", listOf("English Shows", "Dark", "Season 1"))!!.showTitle)
        assertEquals(2024 to 315, FilenameParser.parseEpisode("The.Daily.Show.2024.03.15.mkv")!!.let { it.season to it.episode })

        assertEquals("amelie", FilenameParser.normalizeForCompare("Amélie"))
        FilenameParser.qualityTags("Movie.2160p.HEVC.Atmos.7.1.mkv", 2160)
    }
}
