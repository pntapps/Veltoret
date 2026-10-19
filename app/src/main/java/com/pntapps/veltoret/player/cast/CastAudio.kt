package com.pntapps.veltoret.player.cast

/**
 * Picks the audio language on a Chromecast. The Default Media Receiver can't switch audio tracks (it
 * reports none and plays the file's default one), so the copy streamed to the TV marks every other audio
 * track as a track type the receiver ignores. Only the TrackType bytes change, so the stream keeps its
 * size and byte offsets (seeking still works) and the file itself is never touched. MKV only.
 */
object CastAudio {

    /** An MKV audio track: its TrackNumber and where its TrackType value sits in the file. */
    data class Track(val number: Long, val typeOffset: Long, val typeLength: Int)

    /** Reads up to [length] bytes at [position] (fewer at the end of the file). */
    fun interface Reader {
        fun read(position: Long, length: Int): ByteArray
    }

    /** "Control" track type: valid Matroska, but not a kind players or the receiver play. */
    private const val HIDDEN_TYPE: Byte = 0x20

    private const val ID_EBML = 0x1A45DFA3L
    private const val ID_SEGMENT = 0x18538067L
    private const val ID_SEEK_HEAD = 0x114D9B74L
    private const val ID_SEEK = 0x4DBBL
    private const val ID_SEEK_ID = 0x53ABL
    private const val ID_SEEK_POSITION = 0x53ACL
    private const val ID_CLUSTER = 0x1F43B675L
    private const val ID_TRACKS = 0x1654AE6BL
    private const val ID_TRACK_ENTRY = 0xAEL
    private const val ID_TRACK_NUMBER = 0xD7L
    private const val ID_TRACK_TYPE = 0x83L
    private const val TYPE_AUDIO = 2L

    /** The file's audio tracks, or empty when it isn't MKV or its Tracks can't be found. */
    fun audioTracks(reader: Reader): List<Track> = runCatching { parse(Cursor(reader)) }.getOrDefault(emptyList())

    /** Byte changes that leave only track [keep] audible; none when [keep] isn't one of [tracks]. */
    fun hideAllBut(tracks: List<Track>, keep: Long): Map<Long, Byte> {
        if (tracks.size < 2 || tracks.none { it.number == keep }) return emptyMap()
        return buildMap {
            for (t in tracks) {
                if (t.number == keep) continue
                // A big-endian unsigned int: zeros, then the new type in the last byte.
                for (i in 0 until t.typeLength) put(t.typeOffset + i, if (i == t.typeLength - 1) HIDDEN_TYPE else 0)
            }
        }
    }

    /** Applies [patches] to [buffer], which holds [count] bytes of the file starting at [position]. */
    fun apply(patches: Map<Long, Byte>, position: Long, buffer: ByteArray, count: Int) {
        if (patches.isEmpty()) return
        for ((offset, value) in patches) {
            if (offset >= position && offset < position + count) buffer[(offset - position).toInt()] = value
        }
    }

    private fun parse(c: Cursor): List<Track> {
        val ebml = c.element(0) ?: return emptyList()
        if (ebml.id != ID_EBML || ebml.size == null) return emptyList()
        val segment = c.element(ebml.end) ?: return emptyList()
        if (segment.id != ID_SEGMENT) return emptyList()
        val segmentEnd = segment.size?.let { segment.data + it } ?: Long.MAX_VALUE
        var tracksAt: Long? = null
        var p = segment.data
        // Tracks normally come before the first Cluster; some files store them after it (SeekHead says where).
        repeat(64) {
            if (p >= segmentEnd) return emptyList()
            val e = c.element(p) ?: return emptyList()
            when (e.id) {
                ID_TRACKS -> return tracks(c, e)
                ID_SEEK_HEAD -> if (tracksAt == null) tracksAt = seekTarget(c, e, ID_TRACKS)?.let { segment.data + it }
                ID_CLUSTER -> {
                    val target = tracksAt ?: return emptyList()
                    if (target <= p) return emptyList()
                    p = target
                    return@repeat
                }
            }
            p = e.end.takeIf { e.size != null } ?: return emptyList()
        }
        return emptyList()
    }

    private fun tracks(c: Cursor, tracks: Element): List<Track> {
        val size = tracks.size ?: return emptyList()
        val out = ArrayList<Track>()
        children(c, tracks.data, tracks.data + size) { entry ->
            if (entry.id != ID_TRACK_ENTRY || entry.size == null) return@children
            var number: Long? = null
            var type: Long? = null
            var typeAt = 0L
            var typeLength = 0
            children(c, entry.data, entry.end) { field ->
                val length = field.size?.toInt() ?: return@children
                when (field.id) {
                    ID_TRACK_NUMBER -> number = c.uint(field.data, length)
                    ID_TRACK_TYPE -> { type = c.uint(field.data, length); typeAt = field.data; typeLength = length }
                }
            }
            val n = number
            if (type == TYPE_AUDIO && n != null && typeLength in 1..8) out += Track(n, typeAt, typeLength)
        }
        return out
    }

    /** The segment-relative position the SeekHead gives for element [wanted]. */
    private fun seekTarget(c: Cursor, head: Element, wanted: Long): Long? {
        val size = head.size ?: return null
        var found: Long? = null
        children(c, head.data, head.data + size) { seek ->
            if (seek.id != ID_SEEK || seek.size == null || found != null) return@children
            var id: Long? = null
            var position: Long? = null
            children(c, seek.data, seek.end) { f ->
                val length = f.size?.toInt() ?: return@children
                when (f.id) {
                    ID_SEEK_ID -> id = c.uint(f.data, length)
                    ID_SEEK_POSITION -> position = c.uint(f.data, length)
                }
            }
            if (id == wanted) found = position
        }
        return found
    }

    private inline fun children(c: Cursor, start: Long, end: Long, block: (Element) -> Unit) {
        var p = start
        while (p < end) {
            val e = c.element(p) ?: return
            block(e)
            if (e.size == null) return
            p = e.end
        }
    }

    /** An EBML element: [data] is where its content starts; [size] is null when unknown. */
    private class Element(val id: Long, val data: Long, val size: Long?) {
        val end: Long get() = data + (size ?: 0)
    }

    /** Reads the file in 64 KB windows, so walking the header costs only a few reads (HTTP requests for Drive). */
    private class Cursor(private val reader: Reader) {
        private var windowStart = -1L
        private var window = ByteArray(0)
        private var reads = 0

        fun byte(position: Long): Int {
            if (position < windowStart || position >= windowStart + window.size || windowStart < 0) {
                check(++reads <= 16) { "Too many reads" }
                window = reader.read(position, WINDOW)
                windowStart = position
                check(window.isNotEmpty()) { "End of file" }
            }
            return window[(position - windowStart).toInt()].toInt() and 0xFF
        }

        fun uint(position: Long, length: Int): Long {
            var v = 0L
            for (i in 0 until length) v = (v shl 8) or byte(position + i).toLong()
            return v
        }

        fun element(position: Long): Element? {
            val first = byte(position)
            val idLength = Integer.numberOfLeadingZeros(first) - 23
            if (idLength !in 1..4) return null
            val id = uint(position, idLength)
            val sizeAt = position + idLength
            val sizeFirst = byte(sizeAt)
            val sizeLength = Integer.numberOfLeadingZeros(sizeFirst) - 23
            if (sizeLength !in 1..8) return null
            var size = (sizeFirst and (0xFF shr sizeLength)).toLong()
            var allOnes = size == (0xFF shr sizeLength).toLong()
            for (i in 1 until sizeLength) {
                val b = byte(sizeAt + i)
                size = (size shl 8) or b.toLong()
                if (b != 0xFF) allOnes = false
            }
            return Element(id, sizeAt + sizeLength, size.takeUnless { allOnes })
        }

        companion object { const val WINDOW = 64 * 1024 }
    }
}
