package com.pntapps.veltoret.data.smb

/**
 * Ids for things on a network share: "smb://host" is the server (lists its shares), "smb://host/share"
 * a share, and "smb://host/share/folder/file" anything inside one. The host is part of every id because
 * ids must be unique across sources (they're primary keys of library rows).
 */
data class SmbPath(val host: String, val share: String?, val segments: List<String>) {

    val id: String get() = buildString {
        append(SCHEME).append(host)
        if (share != null) {
            append('/').append(share)
            segments.forEach { append('/').append(it) }
        }
    }

    /** The path inside the share as smbj wants it ("folder\\file"; "" for the share itself). */
    val sharePath: String get() = segments.joinToString("\\")

    val name: String get() = segments.lastOrNull() ?: share ?: host

    val parent: SmbPath? get() = when {
        segments.isNotEmpty() -> copy(segments = segments.dropLast(1))
        share != null -> copy(share = null)
        else -> null
    }

    fun child(name: String): SmbPath = if (share == null) copy(share = name) else copy(segments = segments + name)

    companion object {
        const val SCHEME = "smb://"

        fun isSmb(id: String?) = id != null && id.startsWith(SCHEME)

        fun account(host: String) = SCHEME + host.trim().lowercase()

        fun parse(id: String): SmbPath {
            require(isSmb(id)) { "Not a network share path: $id" }
            val parts = id.removePrefix(SCHEME).split('/').filter { it.isNotEmpty() }
            require(parts.isNotEmpty()) { "No server in $id" }
            return SmbPath(parts[0].lowercase(), parts.getOrNull(1), parts.drop(2))
        }

        /**
         * Reads what people type or paste: "\\192.168.0.10\share\folder" (Windows), "smb://nas/share",
         * "192.168.0.10/share" or just a host name. Returns null when there's no host.
         */
        fun fromUserInput(text: String): SmbPath? {
            val cleaned = text.trim().removePrefix("smb:").replace('\\', '/').trim('/')
            val parts = cleaned.split('/').map { it.trim() }.filter { it.isNotEmpty() }
            val host = parts.firstOrNull()?.lowercase()?.takeIf { h -> h.none { it.isWhitespace() } } ?: return null
            return SmbPath(host, parts.getOrNull(1), parts.drop(2))
        }
    }
}
