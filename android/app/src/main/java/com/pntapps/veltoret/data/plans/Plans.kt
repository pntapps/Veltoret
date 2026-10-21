package com.pntapps.veltoret.data.plans

import java.time.DayOfWeek
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters
import java.util.Locale

/** What a notification or deep link opens: a movie, a show, or one episode of it; [play] starts it right away. */
data class OpenTarget(val mediaType: String, val mediaId: Int, val season: Int? = null, val episode: Int? = null, val play: Boolean = false)

/** Pure date and time rules for watchlist, reminders and upcoming episodes (unit-tested in PlansTest). */
object Plans {
    const val MOVIE = "movie"
    const val TV = "tv"

    /** Reminders that fire late (phone off, Doze) still show if they're less than this overdue; older ones are dropped. */
    const val STALE_AFTER_MS = 12L * 60 * 60 * 1000

    /** Shows whose next episode can change: TMDB statuses of shows still being made. */
    private val AIRING = setOf("Returning Series", "In Production", "Planned", "Pilot")
    fun stillAiring(status: String?) = status in AIRING

    /** One-tap reminder times: tonight 8 PM (while it's still ahead), tomorrow 8 PM, Saturday 8 PM. */
    fun quickTimes(now: LocalDateTime): List<Pair<String, LocalDateTime>> {
        val evening = LocalTime.of(20, 0)
        val today = now.toLocalDate()
        val saturday = today.with(TemporalAdjusters.next(DayOfWeek.SATURDAY))
        return buildList {
            if (now.toLocalTime().isBefore(LocalTime.of(19, 30))) add("Tonight, 8 PM" to today.atTime(evening))
            add("Tomorrow, 8 PM" to today.plusDays(1).atTime(evening))
            if (saturday != today.plusDays(1)) add("Saturday, 8 PM" to saturday.atTime(evening))
        }
    }

    /** "Today", "Tomorrow", "Friday" within a week, then "Fri, Oct 23". [date] is TMDB's "yyyy-MM-dd". */
    fun airLabel(date: String?, today: LocalDate): String? {
        val d = parse(date) ?: return null
        val days = ChronoUnit.DAYS.between(today, d)
        return when {
            days < 0 -> null
            days == 0L -> "Today"
            days == 1L -> "Tomorrow"
            days < 7 -> d.format(DateTimeFormatter.ofPattern("EEEE", Locale.US))
            else -> d.format(DateTimeFormatter.ofPattern("EEE, MMM d", Locale.US))
        }
    }

    /** True when the episode airs today or later (yesterday's "next episode" is stale). */
    fun isUpcoming(date: String?, today: LocalDate): Boolean = parse(date)?.let { !it.isBefore(today) } == true

    /** "Fri, Oct 23 at 9:00 PM" (or "Today at …" / "Tomorrow at …"). */
    fun reminderLabel(at: Long, now: LocalDateTime, zone: ZoneId = ZoneId.systemDefault()): String {
        val t = LocalDateTime.ofInstant(java.time.Instant.ofEpochMilli(at), zone)
        val time = t.format(DateTimeFormatter.ofPattern("h:mm a", Locale.US))
        val days = ChronoUnit.DAYS.between(now.toLocalDate(), t.toLocalDate())
        val day = when (days) {
            0L -> "Today"
            1L -> "Tomorrow"
            else -> t.format(DateTimeFormatter.ofPattern("EEE, MMM d", Locale.US))
        }
        return "$day at $time"
    }

    /** At start-up or after a reboot: schedule what's ahead, show what's slightly overdue, drop the rest. */
    enum class Due { Schedule, FireNow, Drop }
    fun due(at: Long, now: Long): Due = when {
        at > now -> Due.Schedule
        now - at <= STALE_AFTER_MS -> Due.FireNow
        else -> Due.Drop
    }

    fun toMillis(t: LocalDateTime, zone: ZoneId = ZoneId.systemDefault()): Long = t.atZone(zone).toInstant().toEpochMilli()

    private fun parse(date: String?): LocalDate? = date?.takeIf { it.isNotBlank() }?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
}
