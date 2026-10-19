package com.pntapps.veltoret

import com.pntapps.veltoret.player.cast.CastServer
import com.pntapps.veltoret.player.cast.CastSubtitles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class CastTest {

    @Test
    fun rangesAgainstAKnownSize() {
        assertEquals(0L..999L, CastServer.parseRange("bytes=0-", 1000))
        assertEquals(500L..999L, CastServer.parseRange("bytes=500-", 1000))
        assertEquals(100L..199L, CastServer.parseRange("bytes=100-199", 1000))
        // An end past the file is clipped; the last N bytes work too.
        assertEquals(900L..999L, CastServer.parseRange("bytes=900-5000", 1000))
        assertEquals(800L..999L, CastServer.parseRange("bytes=-200", 1000))
    }

    @Test
    fun unsatisfiableRanges() {
        assertNull(CastServer.parseRange("bytes=1000-", 1000))
        assertNull(CastServer.parseRange("bytes=300-200", 1000))
        assertNull(CastServer.parseRange("items=0-1", 1000))
        assertNull(CastServer.parseRange("bytes=abc-", 1000))
    }

    @Test
    fun openRangeOnUnknownSize() {
        assertEquals(500L..CastServer.OPEN_END, CastServer.parseRange("bytes=500-", null))
        assertEquals(10L..20L, CastServer.parseRange("bytes=10-20", null))
    }

    @Test
    fun onlyHomeNetworkClients() {
        assertTrue(CastServer.isHomeNetwork(InetAddress.getByName("192.168.0.125")))
        assertTrue(CastServer.isHomeNetwork(InetAddress.getByName("10.0.0.7")))
        assertTrue(CastServer.isHomeNetwork(InetAddress.getByName("127.0.0.1")))
        assertTrue(CastServer.isHomeNetwork(InetAddress.getByName("fd12:3456::1")))
        assertFalse(CastServer.isHomeNetwork(InetAddress.getByName("8.8.8.8")))
        assertFalse(CastServer.isHomeNetwork(InetAddress.getByName("2001:4860:4860::8888")))
    }

    @Test
    fun webVttFromCues() {
        val vtt = CastSubtitles.toVtt(
            listOf(
                CastSubtitles.Line(1_000_000, 2_500_000, "Hello"),
                CastSubtitles.Line(3_723_045_000, 3_725_000_000, "Two\n\nlines --> here"),
            )
        )
        assertEquals(
            "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n01:02:03.045 --> 01:02:05.000\nTwo\nlines -> here\n\n",
            vtt,
        )
    }

    @Test
    fun webVttAppliesTheSyncOffset() {
        val lines = listOf(CastSubtitles.Line(1_000_000, 2_000_000, "Early"), CastSubtitles.Line(5_000_000, 6_000_000, "Later"))
        // Shifted 1.5 s earlier: the first cue would end before 0 only if it ended under 1.5 s; it's clipped to start at 0.
        val vtt = CastSubtitles.toVtt(lines, offsetUs = -1_500_000)
        assertEquals("WEBVTT\n\n00:00:00.000 --> 00:00:00.500\nEarly\n\n00:00:03.500 --> 00:00:04.500\nLater\n\n", vtt)
        // Cues that end before the start of the video are dropped.
        assertEquals("WEBVTT\n\n", CastSubtitles.toVtt(listOf(CastSubtitles.Line(0, 1_000_000, "Gone")), offsetUs = -2_000_000))
    }
}
