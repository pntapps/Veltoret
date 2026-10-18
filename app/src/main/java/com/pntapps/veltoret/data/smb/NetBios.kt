package com.pntapps.veltoret.data.smb

/**
 * The tiny bit of NetBIOS used to put a name on a server found by address: a "node status" query
 * (UDP 137) asks a machine for its names, as Windows' `nbtstat -A` does. Routers and NAS boxes running
 * Samba usually answer even when they don't announce themselves.
 */
object NetBios {
    const val PORT = 137

    /** A node status (NBSTAT) request for the wildcard name "*". */
    fun nodeStatusQuery(transactionId: Int): ByteArray {
        val out = ByteArray(50)
        out[0] = (transactionId shr 8).toByte()
        out[1] = transactionId.toByte()
        out[5] = 1 // one question
        out[12] = 32 // encoded name length
        // "*" padded with zeros to 16 bytes, each byte split into two letters ('A' + nibble).
        val raw = ByteArray(16).also { it[0] = '*'.code.toByte() }
        raw.forEachIndexed { i, b ->
            out[13 + i * 2] = ('A'.code + ((b.toInt() shr 4) and 0xF)).toByte()
            out[14 + i * 2] = ('A'.code + (b.toInt() and 0xF)).toByte()
        }
        // out[45] = 0 ends the name; type NBSTAT (0x21), class IN (1).
        out[47] = 0x21
        out[49] = 1
        return out
    }

    /**
     * The machine's own name from a node status answer: the unique "file server" name (suffix 0x20),
     * else its unique workstation name (0x00). Null if the answer can't be read.
     */
    fun parseNodeStatus(data: ByteArray, length: Int = data.size): String? = runCatching {
        var offset = 12
        // Skip the answer's name (length-prefixed labels ending with 0).
        while (data[offset].toInt() != 0) offset += (data[offset].toInt() and 0xFF) + 1
        offset += 1 + 2 + 2 + 4 + 2 // end of name, type, class, TTL, data length
        val count = data[offset].toInt() and 0xFF
        offset += 1
        val names = (0 until count).mapNotNull { i ->
            val start = offset + i * 18
            if (start + 18 > length) return@mapNotNull null
            val name = String(data, start, 15, Charsets.US_ASCII).trim()
            val suffix = data[start + 15].toInt() and 0xFF
            val group = (data[start + 16].toInt() and 0x80) != 0
            Triple(name, suffix, group)
        }
        val unique = names.filter { !it.third && it.first.isNotEmpty() }
        (unique.firstOrNull { it.second == 0x20 } ?: unique.firstOrNull { it.second == 0x00 })?.first
    }.getOrNull()
}
