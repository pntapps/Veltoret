package com.pntapps.veltoret.ui.util

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

object Format {
    fun bytes(bytes: Long): String {
        if (bytes <= 0) return "—"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var unit = 0
        while (value >= 1024 && unit < units.lastIndex) {
            value /= 1024
            unit++
        }
        return if (unit >= 3) String.format(Locale.US, "%.1f %s", value, units[unit])
        else String.format(Locale.US, "%.0f %s", value, units[unit])
    }

    /** "2h 46m" / "48m". */
    fun runtime(minutes: Int?): String? {
        if (minutes == null || minutes <= 0) return null
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0 -> "${m}m"
            m == 0 -> "${h}h"
            else -> "${h}h ${m}m"
        }
    }

    fun runtimeMs(ms: Long): String? = if (ms <= 0) null else runtime((ms / 60_000).toInt().coerceAtLeast(1))

    /** Player clock: "4:05", "1:02:09". */
    fun clock(ms: Long): String {
        val total = (ms.coerceAtLeast(0) / 1000)
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) String.format(Locale.US, "%d:%02d:%02d", h, m, s) else String.format(Locale.US, "%d:%02d", m, s)
    }

    fun remaining(positionMs: Long, durationMs: Long): String {
        val left = ((durationMs - positionMs) / 60_000).coerceAtLeast(1)
        return if (left >= 60) "${left / 60}h ${left % 60}m left" else "${left}m left"
    }

    private val dateFormat = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.US)

    fun driveDate(iso: String?): String? = iso?.let {
        runCatching { dateFormat.format(Instant.parse(it).atZone(ZoneId.systemDefault())) }.getOrNull()
    }

    fun date(isoDate: String?): String? = isoDate?.takeIf { it.isNotBlank() }?.let {
        runCatching { dateFormat.format(LocalDate.parse(it)) }.getOrNull()
    }

    fun relative(time: Long): String {
        if (time <= 0) return "Never"
        val diff = System.currentTimeMillis() - time
        val minutes = diff / 60_000
        return when {
            minutes < 1 -> "Just now"
            minutes < 60 -> "$minutes min ago"
            minutes < 60 * 24 -> "${minutes / 60} h ago"
            else -> "${minutes / (60 * 24)} days ago"
        }
    }

    fun rating(value: Double): String? = if (value <= 0) null else String.format(Locale.US, "%.1f", value)

    fun episodeCode(season: Int?, episode: Int?): String = when {
        season == null || episode == null -> ""
        season == 0 -> "Special $episode"
        else -> "S$season · E$episode"
    }
}
