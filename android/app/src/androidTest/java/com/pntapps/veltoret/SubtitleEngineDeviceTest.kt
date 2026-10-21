package com.pntapps.veltoret

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.pntapps.veltoret.player.ExternalSubtitle
import com.pntapps.veltoret.player.SubtitleEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.charset.Charset

@RunWith(AndroidJUnit4::class)
class SubtitleEngineDeviceTest {

    private val srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Café au lait, señor.

        2
        00:00:04,000 --> 00:00:06,500
        <i>Second line</i>
    """.trimIndent()

    private fun text(sub: ExternalSubtitle, ms: Long, offsetMs: Long = 0) =
        SubtitleEngine.activeAt(sub, ms * 1000, offsetMs * 1000).joinToString(" ") { it.text.toString() }

    @Test
    fun parsesUtf8Srt() {
        val cues = SubtitleEngine.parse(srt.toByteArray(Charsets.UTF_8), "movie.srt")
        assertEquals(2, cues.size)
        val sub = ExternalSubtitle("t", "t", null, cues)
        assertEquals("Café au lait, señor.", text(sub, 2_000))
        assertEquals("", text(sub, 3_500))
        assertEquals("Second line", text(sub, 5_000))
    }

    @Test
    fun legacyWindowsEncodingIsTranscoded() {
        val bytes = srt.toByteArray(Charset.forName("windows-1252"))
        val sub = ExternalSubtitle("t", "t", null, SubtitleEngine.parse(bytes, "movie.srt"))
        assertEquals("Café au lait, señor.", text(sub, 2_000))
    }

    @Test
    fun legacyCyrillicAndArabicAreDetected() {
        val ru = "1\n00:00:01,000 --> 00:00:03,000\nПривет, как дела? Это проверка субтитров.\n"
        val ruSub = ExternalSubtitle("r", "r", null, SubtitleEngine.parse(ru.toByteArray(Charset.forName("windows-1251")), "a.srt"))
        assertEquals("Привет, как дела? Это проверка субтитров.", text(ruSub, 2_000))

        val ar = "1\n00:00:01,000 --> 00:00:03,000\nمرحبا بكم في هذا الفيلم الجميل\n"
        val arSub = ExternalSubtitle("a", "a", null, SubtitleEngine.parse(ar.toByteArray(Charset.forName("windows-1256")), "a.srt"))
        assertEquals("مرحبا بكم في هذا الفيلم الجميل", text(arSub, 2_000))
    }

    @Test
    fun offsetShiftsCues() {
        val sub = ExternalSubtitle("t", "t", null, SubtitleEngine.parse(srt.toByteArray(), "movie.srt"))
        // +2 s: the first line now shows between 3 s and 5 s.
        assertEquals("", text(sub, 2_000, offsetMs = 2_000))
        assertEquals("Café au lait, señor.", text(sub, 4_000, offsetMs = 2_000))
        // −1 s: the second line shows from 3 s.
        assertEquals("Second line", text(sub, 3_200, offsetMs = -1_000))
    }

    @Test
    fun parsesWebVttAndAss() {
        val vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n"
        assertEquals("Hello", text(ExternalSubtitle("v", "v", null, SubtitleEngine.parse(vtt.toByteArray(), "a.vtt")), 1_500))

        val ass = """
            [Script Info]
            ScriptType: v4.00+

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Anime line
        """.trimIndent()
        val sub = ExternalSubtitle("a", "a", null, SubtitleEngine.parse(ass.toByteArray(), "ep.ass"))
        assertTrue(text(sub, 1_500).contains("Anime line"))
    }
}
