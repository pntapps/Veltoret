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

        assertEquals("amelie", FilenameParser.normalizeForCompare("Amélie"))
        FilenameParser.qualityTags("Movie.2160p.HEVC.Atmos.7.1.mkv", 2160)
    }
}
