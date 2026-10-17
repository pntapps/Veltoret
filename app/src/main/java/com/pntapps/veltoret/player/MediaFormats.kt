package com.pntapps.veltoret.player

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import java.util.Locale

/** Human-readable names for codecs, channels and HDR, used by track lists and the info panel. */
@OptIn(UnstableApi::class)
object MediaFormats {

    fun videoCodec(mime: String?): String? = when (mime) {
        null -> null
        MimeTypes.VIDEO_H264 -> "H.264"
        MimeTypes.VIDEO_H265 -> "HEVC"
        MimeTypes.VIDEO_DOLBY_VISION -> "Dolby Vision"
        MimeTypes.VIDEO_VP8 -> "VP8"
        MimeTypes.VIDEO_VP9 -> "VP9"
        MimeTypes.VIDEO_AV1 -> "AV1"
        MimeTypes.VIDEO_MP4V -> "MPEG-4 Part 2"
        MimeTypes.VIDEO_MPEG2 -> "MPEG-2"
        MimeTypes.VIDEO_VC1 -> "VC-1"
        MimeTypes.VIDEO_H263 -> "H.263"
        else -> mime.substringAfter('/').uppercase(Locale.US)
    }

    fun audioCodec(mime: String?): String? = when (mime) {
        null -> null
        MimeTypes.AUDIO_AAC -> "AAC"
        MimeTypes.AUDIO_AC3 -> "Dolby Digital"
        MimeTypes.AUDIO_E_AC3 -> "Dolby Digital+"
        MimeTypes.AUDIO_E_AC3_JOC -> "Dolby Digital+ Atmos"
        MimeTypes.AUDIO_AC4 -> "Dolby AC-4"
        MimeTypes.AUDIO_TRUEHD -> "Dolby TrueHD"
        MimeTypes.AUDIO_DTS -> "DTS"
        MimeTypes.AUDIO_DTS_HD -> "DTS-HD"
        MimeTypes.AUDIO_DTS_EXPRESS -> "DTS Express"
        MimeTypes.AUDIO_DTS_X -> "DTS:X"
        MimeTypes.AUDIO_OPUS -> "Opus"
        MimeTypes.AUDIO_FLAC -> "FLAC"
        MimeTypes.AUDIO_VORBIS -> "Vorbis"
        MimeTypes.AUDIO_MPEG -> "MP3"
        MimeTypes.AUDIO_ALAC -> "ALAC"
        MimeTypes.AUDIO_RAW -> "PCM"
        else -> mime.substringAfter('/').uppercase(Locale.US)
    }

    fun channels(count: Int): String? = when (count) {
        Format.NO_VALUE, 0 -> null
        1 -> "Mono"
        2 -> "Stereo"
        6 -> "5.1"
        8 -> "7.1"
        else -> "$count ch"
    }

    fun hdr(format: Format?): String? {
        if (format?.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION) return "Dolby Vision"
        return when (format?.colorInfo?.colorTransfer) {
            C.COLOR_TRANSFER_ST2084 -> "HDR10"
            C.COLOR_TRANSFER_HLG -> "HLG"
            else -> null
        }
    }

    fun resolution(format: Format?): String? {
        if (format == null || format.width <= 0 || format.height <= 0) return null
        val label = when {
            format.height >= 2000 || format.width >= 3800 -> "4K"
            format.height >= 1400 -> "1440p"
            format.height >= 1000 || format.width >= 1900 -> "1080p"
            format.height >= 700 -> "720p"
            else -> "SD"
        }
        return "${format.width}×${format.height} · $label"
    }

    fun bitrate(bps: Int): String? = when {
        bps <= 0 -> null
        bps >= 1_000_000 -> String.format(Locale.US, "%.1f Mbps", bps / 1_000_000f)
        else -> "${bps / 1000} kbps"
    }

    fun frameRate(fps: Float): String? = if (fps <= 0) null else String.format(Locale.US, "%.3g fps", fps)

    // Release sites rotate domains (.at, .town, .army, .zone…), so any "name.tld" with a lowercase ending
    // counts, not a fixed list. Real labels capitalise ("Dub.Intl", "DTS-HD.MA") and codecs are short ("H.264").
    private val junkLabel = Regex("""(?i:www\.|https?://|@)|\b[A-Za-z0-9-]{3,}\.[a-z]{2,10}\b""")

    /** A track's own label, unless it's a release group's web address or similar noise. */
    fun cleanLabel(label: String?): String? = label?.trim()?.takeIf { it.isNotEmpty() && !junkLabel.containsMatchIn(it) }

    /** Subtitle format from the track's codecs string (the sample MIME is Media3's internal cue format). */
    fun subtitleFormat(format: Format): String? = when (format.codecs ?: format.sampleMimeType) {
        MimeTypes.TEXT_SSA -> "ASS"
        MimeTypes.APPLICATION_SUBRIP -> "SRT"
        MimeTypes.TEXT_VTT -> "WebVTT"
        MimeTypes.APPLICATION_TTML -> "TTML"
        MimeTypes.APPLICATION_PGS -> "PGS"
        MimeTypes.APPLICATION_VOBSUB -> "VobSub"
        MimeTypes.APPLICATION_DVBSUBS -> "DVB"
        MimeTypes.APPLICATION_TX3G -> "Timed text"
        else -> null
    }

    /**
     * Display names for a list of tracks: language first ("English"), the track's own label only if
     * it's meaningful, and a number when several tracks would otherwise look identical ("Hindi 2").
     */
    fun trackTitles(formats: List<Format>, fallback: String, language: (String?) -> String?): List<String> {
        val base = formats.mapIndexed { i, f -> language(f.language) ?: cleanLabel(f.label) ?: "$fallback ${i + 1}" }
        val totals = base.groupingBy { it }.eachCount()
        val seen = HashMap<String, Int>()
        return base.map { name ->
            if ((totals[name] ?: 0) > 1) {
                val n = (seen[name] ?: 0) + 1
                seen[name] = n
                "$name $n"
            } else {
                name
            }
        }
    }

    /** "c2.qti.hevc.decoder" → Hardware; "ffmpeg…"/"c2.android…"/"OMX.google…" → Software. */
    fun decoderKind(name: String?): String? = when {
        name == null -> null
        name.contains("ffmpeg", ignoreCase = true) -> "Software · FFmpeg"
        name.startsWith("c2.goldfish.") -> "Emulator"
        name.startsWith("c2.android.") || name.startsWith("OMX.google.") -> "Software · Android"
        else -> "Hardware"
    }
}
