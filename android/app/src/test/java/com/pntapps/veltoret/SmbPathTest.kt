package com.pntapps.veltoret

import com.pntapps.veltoret.data.smb.SmbPath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SmbPathTest {

    @Test
    fun readsWindowsPaths() {
        val p = SmbPath.fromUserInput("\\\\192.168.0.10\\h\\My Movies")!!
        assertEquals("192.168.0.10", p.host)
        assertEquals("h", p.share)
        assertEquals(listOf("My Movies"), p.segments)
    }

    @Test
    fun readsOtherWaysPeopleTypeAddresses() {
        assertEquals(SmbPath("nas", "Media", listOf("Films")), SmbPath.fromUserInput("smb://NAS/Media/Films/"))
        assertEquals(SmbPath("192.168.0.10", "share", emptyList()), SmbPath.fromUserInput(" 192.168.0.10/share "))
        assertEquals(SmbPath("router", null, emptyList()), SmbPath.fromUserInput("router"))
        assertNull(SmbPath.fromUserInput("   "))
        assertNull(SmbPath.fromUserInput("\\\\"))
    }

    @Test
    fun idsRoundTrip() {
        val p = SmbPath("192.168.0.10", "h", listOf("Movies", "Heat (1995).mkv"))
        assertEquals("smb://192.168.0.10/h/Movies/Heat (1995).mkv", p.id)
        assertEquals(p, SmbPath.parse(p.id))
        assertEquals("Movies\\Heat (1995).mkv", p.sharePath)
        assertEquals("Heat (1995).mkv", p.name)
    }

    @Test
    fun walksUpAndDown() {
        val server = SmbPath.parse("smb://nas")
        assertNull(server.share)
        assertEquals("", server.child("Media").sharePath)
        assertEquals("smb://nas/Media/TV", server.child("Media").child("TV").id)
        assertEquals("smb://nas/Media", SmbPath.parse("smb://nas/Media/TV").parent!!.id)
        assertEquals("smb://nas", SmbPath.parse("smb://nas/Media").parent!!.id)
        assertNull(server.parent)
    }

    @Test
    fun accountIsTheServer() {
        assertEquals("smb://nas", SmbPath.account(" NAS "))
        assertTrue(SmbPath.isSmb("smb://nas/Media"))
        assertFalse(SmbPath.isSmb("device"))
        assertFalse(SmbPath.isSmb(null))
    }
}
