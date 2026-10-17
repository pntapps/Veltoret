package com.pntapps.veltoret.player

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** A subtitle file loaded and parsed by Veltoret itself (rather than by the player), so it can be re-timed. */
data class ExternalSubtitle(
    val id: String,
    val label: String,
    val language: String?,
    /** Sorted by start time; every entry has a concrete end time. */
    val cues: List<TimedCues>,
)

data class TimedCues(val startUs: Long, val endUs: Long, val cues: List<Cue>)

/**
 * Loads SRT / WebVTT / ASS / SSA / TTML files using Media3's own parsers, so styling and positioning
 * match what the player would render. Owning the cues lets the user shift them in time (sync).
 */
@OptIn(UnstableApi::class)
object SubtitleEngine {

    /** Larger files are almost certainly not text subtitles. */
    const val MAX_BYTES = 8 * 1024 * 1024

    fun parse(bytes: ByteArray, fileName: String): List<TimedCues> {
        require(bytes.size <= MAX_BYTES) { "That file is too large to be a subtitle" }
        val format = Format.Builder().setSampleMimeType(DriveMedia.subtitleMimeType(fileName)).build()
        val factory = DefaultSubtitleParserFactory()
        require(factory.supportsFormat(format)) { "This subtitle format isn't supported" }
        val parser = factory.create(format)
        val raw = mutableListOf<CuesWithTiming>()
        try {
            parser.parse(normalizeText(bytes), SubtitleParser.OutputOptions.allCues()) { raw += it }
        } finally {
            parser.reset()
        }
        val sorted = raw.filter { it.startTimeUs != C.TIME_UNSET }.sortedBy { it.startTimeUs }
        return sorted.mapIndexed { i, c ->
            // Some formats leave the end open ("until the next cue").
            val end = when {
                c.durationUs != C.TIME_UNSET -> c.startTimeUs + c.durationUs
                i + 1 < sorted.size -> sorted[i + 1].startTimeUs
                else -> c.startTimeUs + 5_000_000
            }
            TimedCues(c.startTimeUs, end, c.cues)
        }.filter { it.cues.isNotEmpty() }
    }

    /** Cues to show at [positionUs], after applying the user's sync offset. */
    fun activeAt(subtitle: ExternalSubtitle, positionUs: Long, offsetUs: Long): List<Cue> {
        val t = positionUs - offsetUs
        val cues = subtitle.cues
        // Binary search for the first cue starting after t, then walk back over overlapping ones.
        var lo = 0
        var hi = cues.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (cues[mid].startUs <= t) lo = mid + 1 else hi = mid
        }
        val out = ArrayList<Cue>(2)
        var i = lo - 1
        var scanned = 0
        while (i >= 0 && scanned < 64) {
            val c = cues[i]
            if (t < c.endUs) out.addAll(0, c.cues)
            i--
            scanned++
        }
        return out
    }

    /**
     * Subtitle files are often not UTF-8 (older Windows encodings for European, Arabic, Hebrew,
     * Cyrillic or Hindi text). Keep UTF-8/UTF-16 (BOM) as-is; otherwise transcode a best guess to UTF-8
     * so the parser shows real letters instead of "Ã©".
     */
    fun normalizeText(bytes: ByteArray): ByteArray {
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) return bytes
        if (bytes.size >= 2 && ((bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) || (bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()))) {
            return bytes
        }
        if (decodes(bytes, Charsets.UTF_8)) return bytes
        val charset = guessLegacyCharset(bytes)
        return String(bytes, charset).toByteArray(Charsets.UTF_8)
    }

    private fun decodes(bytes: ByteArray, charset: Charset): Boolean = try {
        charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
        true
    } catch (_: CharacterCodingException) {
        false
    }

    /**
     * Light heuristic for legacy single-byte encodings. Western text is mostly ASCII letters with the
     * odd accent; Cyrillic and Arabic text is mostly high bytes. Between those two, the most frequent
     * letters differ (Cyrillic а е и н о р с т vs Arabic ا ب ت ر ل م ن و).
     */
    private fun guessLegacyCharset(bytes: ByteArray): Charset {
        var asciiLetters = 0
        var high = 0
        var cyrillic = 0
        var arabic = 0
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            when {
                v < 0x80 -> if (v in 0x41..0x5A || v in 0x61..0x7A) asciiLetters++
                else -> {
                    high++
                    if (v == 0xE0 || v == 0xE5 || v == 0xE8 || v == 0xED || v == 0xEE || v in 0xF0..0xF2) cyrillic++
                    if (v == 0xC7 || v == 0xC8 || v == 0xCA || v == 0xD1 || v == 0xE1 || v == 0xE3 || v == 0xE4 || v == 0xE6) arabic++
                }
            }
        }
        fun cs(name: String) = runCatching { Charset.forName(name) }.getOrNull()
        val nonLatin = high > 0 && high.toFloat() / (high + asciiLetters) > 0.3f
        return when {
            !nonLatin -> cs("windows-1252")
            arabic > cyrillic -> cs("windows-1256")
            else -> cs("windows-1251")
        } ?: Charsets.ISO_8859_1
    }
}
