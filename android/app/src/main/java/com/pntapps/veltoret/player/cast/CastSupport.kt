package com.pntapps.veltoret.player.cast

import android.content.Context
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions
import com.google.android.gms.cast.framework.media.NotificationOptions
import com.pntapps.veltoret.MainActivity

/**
 * Named in the manifest (and kept in rules.keep for R8). Google's Default Media Receiver plays plain
 * video URLs, so Veltoret needs no receiver app of its own. Cast's media notification gives lock-screen
 * and notification controls while casting.
 */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions {
        val notification = NotificationOptions.Builder()
            .setTargetActivityClassName(MainActivity::class.java.name)
            .build()
        val media = CastMediaOptions.Builder()
            .setNotificationOptions(notification)
            .build()
        return CastOptions.Builder()
            .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
            .setCastMediaOptions(media)
            .setStopReceiverApplicationWhenEndingSession(true)
            .build()
    }

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

/** Subtitles for the TV: Chromecasts read WebVTT, so every format the player parses is converted. */
object CastSubtitles {

    /** One cue: start and end in microseconds, and its text (lines separated by '\n'). */
    data class Line(val startUs: Long, val endUs: Long, val text: String)

    /** WebVTT for [lines], shifted by [offsetUs] (the player's subtitle sync); cues before 0 are dropped. */
    fun toVtt(lines: List<Line>, offsetUs: Long = 0): String = buildString {
        append("WEBVTT\n\n")
        for (line in lines) {
            val start = line.startUs + offsetUs
            val end = line.endUs + offsetUs
            val text = line.text.trim().replace("-->", "->")
            if (end <= 0 || text.isEmpty()) continue
            append(time(maxOf(0, start))).append(" --> ").append(time(end)).append('\n')
            // A blank line would end the cue early.
            append(text.lines().filter { it.isNotBlank() }.joinToString("\n")).append("\n\n")
        }
    }

    /** "01:02:03.045" */
    fun time(us: Long): String {
        val ms = us / 1000
        return "%02d:%02d:%02d.%03d".format(ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
