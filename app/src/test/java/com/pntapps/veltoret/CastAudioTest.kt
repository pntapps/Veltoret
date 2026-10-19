package com.pntapps.veltoret

import com.pntapps.veltoret.player.cast.CastAudio
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class CastAudioTest {

    // Minimal EBML writer: element = id bytes + 8-byte size + data.
    private fun el(id: Long, vararg children: ByteArray): ByteArray {
        val data = ByteArrayOutputStream().apply { children.forEach { write(it) } }.toByteArray()
        val out = ByteArrayOutputStream()
        val idBytes = generateSequence(id) { it shr 8 }.takeWhile { it > 0 }.map { (it and 0xFF).toByte() }.toList().reversed()
        idBytes.forEach { out.write(it.toInt()) }
        out.write(0x01) // 8-byte size marker
        for (i in 6 downTo 0) out.write(((data.size.toLong() shr (8 * i)) and 0xFF).toInt())
        out.write(data)
        return out.toByteArray()
    }
    private fun uint(id: Long, v: Long) = el(id, byteArrayOf(v.toByte()))
    private fun track(number: Long, type: Long) = el(0xAE, uint(0xD7, number), uint(0x83, type))
    private val header = el(0x1A45DFA3, uint(0x4286, 1))
    private fun segment(vararg children: ByteArray) = header + el(0x18538067, *children)
    private fun reader(bytes: ByteArray) = CastAudio.Reader { position, length ->
        bytes.copyOfRange(position.toInt().coerceAtMost(bytes.size), (position + length).toInt().coerceAtMost(bytes.size))
    }
    private val cluster = el(0x1F43B675, uint(0xE7, 0))

    @Test
    fun findsAudioTracksBeforeTheFirstCluster() {
        val file = segment(el(0x1654AE6B, track(1, 1), track(2, 2), track(3, 2), track(4, 0x11)), cluster)
        val tracks = CastAudio.audioTracks(reader(file))
        assertEquals(listOf(2L, 3L), tracks.map { it.number })
        tracks.forEach { assertEquals(2, file[it.typeOffset.toInt()].toInt()) }
    }

    @Test
    fun followsTheSeekHeadToTracksStoredAfterACluster() {
        // SeekHead says Tracks is at (segment-relative) offset = seekHead + cluster sizes.
        fun seekHead(position: Long) = el(0x114D9B74, el(0x4DBB, el(0x53AB, byteArrayOf(0x16, 0x54, 0xAE.toByte(), 0x6B)), uint(0x53AC, position)))
        val tracks = el(0x1654AE6B, track(1, 1), track(2, 2), track(3, 2))
        val headSize = seekHead(0).size
        val file = segment(seekHead((headSize + cluster.size).toLong()), cluster, tracks)
        assertEquals(listOf(2L, 3L), CastAudio.audioTracks(reader(file)).map { it.number })
    }

    @Test
    fun nothingForOtherFormatsOrASingleTrack() {
        assertTrue(CastAudio.audioTracks(reader(ByteArray(4096) { 7 })).isEmpty())
        val one = CastAudio.audioTracks(reader(segment(el(0x1654AE6B, track(1, 1), track(2, 2)))))
        assertTrue(CastAudio.hideAllBut(one, 2).isEmpty())
    }

    @Test
    fun hidesEveryOtherAudioTrackAcrossBufferBoundaries() {
        val file = segment(el(0x1654AE6B, track(1, 1), track(2, 2), track(3, 2), track(4, 2)))
        val tracks = CastAudio.audioTracks(reader(file))
        val patches = CastAudio.hideAllBut(tracks, keep = 3)
        assertEquals(2, patches.size)
        // Stream it in odd-sized chunks, as the server does.
        val streamed = ByteArrayOutputStream()
        var p = 0
        while (p < file.size) {
            val n = minOf(7, file.size - p)
            val chunk = file.copyOfRange(p, p + n)
            CastAudio.apply(patches, p.toLong(), chunk, n)
            streamed.write(chunk)
            p += n
        }
        val result = CastAudio.audioTracks(reader(streamed.toByteArray()))
        assertEquals(listOf(3L), result.map { it.number })
        assertEquals(file.size, streamed.size())
    }
}
