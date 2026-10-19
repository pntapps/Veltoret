package com.pntapps.veltoret

import com.pntapps.veltoret.data.plans.Plans
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneOffset

class PlansTest {

    // A Monday.
    private val monday = LocalDate.of(2026, 10, 19)

    @Test
    fun quickTimesOfferTonightOnlyWhileItsAhead() {
        val afternoon = Plans.quickTimes(monday.atTime(15, 0)).map { it.first }
        assertEquals(listOf("Tonight, 8 PM", "Tomorrow, 8 PM", "Saturday, 8 PM"), afternoon)
        val late = Plans.quickTimes(monday.atTime(21, 0)).map { it.first }
        assertEquals(listOf("Tomorrow, 8 PM", "Saturday, 8 PM"), late)
    }

    @Test
    fun quickTimesSkipSaturdayWhenItIsTomorrow() {
        val friday = LocalDate.of(2026, 10, 23).atTime(10, 0)
        val times = Plans.quickTimes(friday)
        assertEquals(listOf("Tonight, 8 PM", "Tomorrow, 8 PM"), times.map { it.first })
        assertEquals(LocalDateTime.of(2026, 10, 24, 20, 0), times[1].second)
    }

    @Test
    fun airLabels() {
        assertEquals("Today", Plans.airLabel("2026-10-19", monday))
        assertEquals("Tomorrow", Plans.airLabel("2026-10-20", monday))
        assertEquals("Friday", Plans.airLabel("2026-10-23", monday))
        assertEquals("Mon, Oct 26", Plans.airLabel("2026-10-26", monday))
        assertNull(Plans.airLabel("2026-10-18", monday))
        assertNull(Plans.airLabel("", monday))
        assertNull(Plans.airLabel("not a date", monday))
    }

    @Test
    fun upcomingIncludesToday() {
        assertTrue(Plans.isUpcoming("2026-10-19", monday))
        assertTrue(Plans.isUpcoming("2027-01-01", monday))
        assertFalse(Plans.isUpcoming("2026-10-18", monday))
        assertFalse(Plans.isUpcoming(null, monday))
    }

    @Test
    fun reminderLabels() {
        val now = monday.atTime(12, 0)
        fun at(t: LocalDateTime) = t.toInstant(ZoneOffset.UTC).toEpochMilli()
        assertEquals("Today at 8:00 PM", Plans.reminderLabel(at(monday.atTime(20, 0)), now, ZoneOffset.UTC))
        assertEquals("Tomorrow at 9:30 AM", Plans.reminderLabel(at(monday.plusDays(1).atTime(9, 30)), now, ZoneOffset.UTC))
        assertEquals("Fri, Oct 23 at 8:00 PM", Plans.reminderLabel(at(monday.plusDays(4).atTime(20, 0)), now, ZoneOffset.UTC))
    }

    @Test
    fun overdueRemindersFireWithinTwelveHoursThenDrop() {
        val now = 1_000_000_000_000L
        assertEquals(Plans.Due.Schedule, Plans.due(now + 60_000, now))
        assertEquals(Plans.Due.FireNow, Plans.due(now - 60_000, now))
        assertEquals(Plans.Due.FireNow, Plans.due(now - Plans.STALE_AFTER_MS, now))
        assertEquals(Plans.Due.Drop, Plans.due(now - Plans.STALE_AFTER_MS - 1, now))
    }

    @Test
    fun stillAiringStatuses() {
        assertTrue(Plans.stillAiring("Returning Series"))
        assertTrue(Plans.stillAiring("In Production"))
        assertFalse(Plans.stillAiring("Ended"))
        assertFalse(Plans.stillAiring("Canceled"))
        assertFalse(Plans.stillAiring(null))
    }
}
