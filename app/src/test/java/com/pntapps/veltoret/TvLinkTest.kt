package com.pntapps.veltoret

import com.pntapps.veltoret.data.tvlink.TvLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TvLinkTest {
    private val secret = TvLink.newSecret()
    private val body = """{"type":"pause"}""".toByteArray()

    @Test
    fun signedRequestsVerify() {
        val time = 1_000_000L
        val signature = TvLink.sign(secret, "POST", "/command", time, body)
        assertTrue(TvLink.verify(secret, "POST", "/command", time, body, signature, now = time + 1_000))
    }

    @Test
    fun anyChangeBreaksTheSignature() {
        val time = 1_000_000L
        val signature = TvLink.sign(secret, "POST", "/command", time, body)
        assertFalse(TvLink.verify(secret, "POST", "/play", time, body, signature, now = time))
        assertFalse(TvLink.verify(secret, "POST", "/command", time + 1, body, signature, now = time))
        assertFalse(TvLink.verify(secret, "POST", "/command", time, """{"type":"stop"}""".toByteArray(), signature, now = time))
        assertFalse(TvLink.verify(TvLink.newSecret(), "POST", "/command", time, body, signature, now = time))
    }

    @Test
    fun oldRequestsAreRefused() {
        val time = 1_000_000L
        val signature = TvLink.sign(secret, "POST", "/status", time, ByteArray(0))
        assertFalse(TvLink.verify(secret, "POST", "/status", time, ByteArray(0), signature, now = time + TvLink.MAX_SKEW_MS + 1))
    }

    @Test
    fun streamUrls() {
        assertEquals("vlink://192.168.1.20:4000/abc/v1", TvLink.streamUrl("http://192.168.1.20:4000/abc/v1"))
        assertTrue(TvLink.isStream("vlink://192.168.1.20:4000/abc/v1"))
        assertFalse(TvLink.isStream("content://media/external/video/1"))
    }
}
