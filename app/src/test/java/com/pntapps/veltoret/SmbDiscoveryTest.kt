package com.pntapps.veltoret

import com.pntapps.veltoret.data.smb.NetBios
import com.pntapps.veltoret.data.smb.SmbDiscovery
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SmbDiscoveryTest {

    private fun ip(a: Int, b: Int, c: Int, d: Int) = (a shl 24) or (b shl 16) or (c shl 8) or d

    @Test
    fun sweepsTheSubnetWithoutNetworkAndBroadcast() {
        val hosts = SmbDiscovery.subnetHosts(ip(192, 168, 0, 57), 24)
        assertEquals(254, hosts.size)
        assertEquals("192.168.0.1", SmbDiscovery.fromInt(hosts.first()))
        assertEquals("192.168.0.254", SmbDiscovery.fromInt(hosts.last()))
    }

    @Test
    fun hugeNetworksFallBackToTheNearby254() {
        val hosts = SmbDiscovery.subnetHosts(ip(10, 1, 2, 3), 8)
        assertEquals(254, hosts.size)
        assertEquals("10.1.2.1", SmbDiscovery.fromInt(hosts.first()))
        assertEquals(1022, SmbDiscovery.subnetHosts(ip(10, 1, 2, 3), 22).size)
    }

    @Test
    fun queryAsksForTheWildcardName() {
        val q = NetBios.nodeStatusQuery(0x1234)
        assertEquals(50, q.size)
        assertEquals(0x12, q[0].toInt())
        assertEquals(32, q[12].toInt())
        assertEquals("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", String(q, 13, 32, Charsets.US_ASCII))
        assertEquals(0x21, q[47].toInt())
    }

    /** A node status answer listing [names] as (name, suffix, group). */
    private fun answer(vararg names: Triple<String, Int, Boolean>): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(ByteArray(12))
        out.write(32)
        out.write(ByteArray(32) { 'A'.code.toByte() })
        out.write(0)
        out.write(byteArrayOf(0, 0x21, 0, 1, 0, 0, 0, 0, 0, 0)) // type, class, TTL, length
        out.write(names.size)
        for ((name, suffix, group) in names) {
            out.write(name.padEnd(15).toByteArray(Charsets.US_ASCII))
            out.write(suffix)
            out.write(if (group) 0x80 else 0x04)
            out.write(0)
        }
        return out.toByteArray()
    }

    @Test
    fun readsTheFileServerName() {
        val reply = answer(
            Triple("WORKGROUP", 0x00, true),
            Triple("ROUTER-AX", 0x00, false),
            Triple("ROUTER-AX", 0x20, false),
        )
        assertEquals("ROUTER-AX", NetBios.parseNodeStatus(reply))
    }

    @Test
    fun fallsBackToTheWorkstationNameAndIgnoresGroups() {
        assertEquals("NAS", NetBios.parseNodeStatus(answer(Triple("HOME", 0x20, true), Triple("NAS", 0x00, false))))
        assertNull(NetBios.parseNodeStatus(answer(Triple("WORKGROUP", 0x00, true))))
        assertNull(NetBios.parseNodeStatus(ByteArray(5)))
    }
}
