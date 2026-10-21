package com.pntapps.veltoret

import androidx.media3.common.Format
import com.pntapps.veltoret.player.MediaFormats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4

/** Device test: Media3's Format normalises language codes with Android APIs. */
@RunWith(AndroidJUnit4::class)
class MediaFormatsDeviceTest {

    @Test fun releaseGroupLabelsAreHidden() {
        assertNull(MediaFormats.cleanLabel("ReleaseSite.ai.in"))
        assertNull(MediaFormats.cleanLabel("www.example.com"))
        assertNull(MediaFormats.cleanLabel("Encoded by x@y"))
        assertEquals("SDH", MediaFormats.cleanLabel("SDH"))
        assertEquals("Director's Commentary", MediaFormats.cleanLabel("Director's Commentary"))
        assertEquals("Dub.Intl", MediaFormats.cleanLabel("Dub.Intl")) // ".in" inside a word is not a domain
        assertNull(MediaFormats.cleanLabel("ReleaseSite.at"))
        assertNull(MediaFormats.cleanLabel("ExampleRips.town"))
        assertEquals("DTS-HD.MA 5.1", MediaFormats.cleanLabel("DTS-HD.MA 5.1"))
        assertEquals("H.264", MediaFormats.cleanLabel("H.264"))
    }

    @Test fun duplicateLanguagesAreNumbered() {
        fun f(lang: String?, label: String? = null) = Format.Builder().setLanguage(lang).setLabel(label).build()
        val names = mapOf("hi" to "Hindi", "en" to "English")
        val titles = MediaFormats.trackTitles(
            listOf(f("hi", "ReleaseSite.ai.in"), f("hi"), f("en"), f(null, "Commentary"), f(null)),
            "Subtitle",
        ) { names[it] }
        assertEquals(listOf("Hindi 1", "Hindi 2", "English", "Commentary", "Subtitle 5"), titles)
    }
}
