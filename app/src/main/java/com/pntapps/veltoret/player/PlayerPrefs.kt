package com.pntapps.veltoret.player

import android.content.Context
import androidx.core.content.edit

/**
 * What the user picked for one video, restored the next time it opens.
 * Tracks are identified by their position among tracks of the same type plus their language, which
 * stays stable for a given file.
 */
data class TrackMemory(
    val audioIndex: Int? = null,
    val audioLanguage: String? = null,
    /** [SUB_OFF], [SUB_EMBEDDED] or [SUB_EXTERNAL]; null = never chosen. */
    val subtitleMode: String? = null,
    val subtitleIndex: Int? = null,
    val subtitleLanguage: String? = null,
    /** For external subtitles: "drive:<fileId>" or "device:<uri>", plus the display name. */
    val externalSource: String? = null,
    val externalName: String? = null,
    val subtitleOffsetMs: Long = 0,
) {
    companion object {
        const val SUB_OFF = "off"
        const val SUB_EMBEDDED = "embedded"
        const val SUB_EXTERNAL = "external"
    }
}

/**
 * Small, synchronous player memory: per-video track choices, the audio/subtitle language picked for
 * each show (so a new episode starts the way the last one was left) and the last aspect mode.
 */
class PlayerPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("player", Context.MODE_PRIVATE)

    // ---- Per video ------------------------------------------------------------------------------

    fun trackMemory(videoKey: String): TrackMemory? {
        val raw = prefs.getString("video:$videoKey", null) ?: return null
        val f = raw.split(SEP)
        fun at(i: Int) = f.getOrNull(i)?.takeIf { it.isNotEmpty() }
        return TrackMemory(
            audioIndex = at(0)?.toIntOrNull(),
            audioLanguage = at(1),
            subtitleMode = at(2),
            subtitleIndex = at(3)?.toIntOrNull(),
            subtitleLanguage = at(4),
            externalSource = at(5),
            externalName = at(6),
            subtitleOffsetMs = at(7)?.toLongOrNull() ?: 0,
        )
    }

    fun updateTrackMemory(videoKey: String, change: (TrackMemory) -> TrackMemory) {
        val m = change(trackMemory(videoKey) ?: TrackMemory())
        val raw = listOf(
            m.audioIndex?.toString(), m.audioLanguage, m.subtitleMode, m.subtitleIndex?.toString(),
            m.subtitleLanguage, m.externalSource, m.externalName?.replace(SEP, " "), m.subtitleOffsetMs.toString(),
        ).joinToString(SEP) { it.orEmpty() }
        prefs.edit { putString("video:$videoKey", raw) }
    }

    // ---- Per show -------------------------------------------------------------------------------

    fun audioLanguage(showId: Int?): String? = showId?.let { prefs.getString("audio:$it", null) }
    fun setAudioLanguage(showId: Int?, language: String?) {
        if (showId == null || language.isNullOrBlank()) return
        prefs.edit { putString("audio:$showId", language) }
    }

    /** null = no preference, [OFF] = subtitles off, otherwise a language code. */
    fun subtitleLanguage(showId: Int?): String? = showId?.let { prefs.getString("sub:$it", null) }
    fun setSubtitleLanguage(showId: Int?, language: String?) {
        if (showId == null) return
        prefs.edit { putString("sub:$showId", language ?: OFF) }
    }

    var resizeMode: ResizeMode
        get() = runCatching { ResizeMode.valueOf(prefs.getString("resize", null) ?: "") }.getOrDefault(ResizeMode.Fit)
        set(value) = prefs.edit { putString("resize", value.name) }

    companion object {
        const val OFF = "off"
        private const val SEP = "\u001F" // unit separator; never appears in names or URIs
    }
}
