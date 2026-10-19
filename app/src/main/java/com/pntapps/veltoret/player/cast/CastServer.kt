package com.pntapps.veltoret.player.cast

import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * A tiny HTTP server on the phone that a Chromecast streams from while casting. Chromecasts fetch media
 * themselves, but can't sign in to Drive or reach files on this device or a network share, so every
 * video and subtitle goes through here, read with the player's own data sources (Drive, device, SMB).
 *
 * Runs only during a cast session. Paths carry a random token, and only home-network addresses are
 * answered. Supports Range requests (seeking) and CORS (the receiver fetches subtitles with XHR).
 */
@OptIn(UnstableApi::class)
class CastServer(private val dataSources: DataSource.Factory) {

    private sealed interface Entry {
        val mime: String
        /** [length] is the file size when known (library files), else found on first request. */
        /** [patches]: bytes changed in the stream (CastAudio hides the audio tracks not chosen). */
        class Media(val uri: Uri, override val mime: String, var length: Long?, val patches: Map<Long, Byte>) : Entry
        class Text(val bytes: ByteArray, override val mime: String) : Entry
    }

    private val token = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private val entries = ConcurrentHashMap<String, Entry>()
    private val pool = Executors.newCachedThreadPool { r -> Thread(r, "cast-server").apply { isDaemon = true } }
    @Volatile private var socket: ServerSocket? = null
    private var host: String = ""

    /** Listens on [address] (the phone's address facing the Chromecast); idempotent. */
    @Synchronized
    fun start(address: InetAddress) {
        if (socket != null && host == address.hostAddress) return
        stopSocket()
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress(address, 0))
        socket = server
        host = address.hostAddress.orEmpty()
        pool.execute { acceptLoop(server) }
    }

    @Synchronized
    fun stop() {
        stopSocket()
        entries.clear()
    }

    private fun stopSocket() {
        runCatching { socket?.close() }
        socket = null
    }

    /** The URL the Chromecast loads [uri] from. */
    fun media(id: String, uri: Uri, mime: String, length: Long?, patches: Map<Long, Byte> = emptyMap()): String {
        entries[id] = Entry.Media(uri, mime, length?.takeIf { it > 0 }, patches)
        return url(id)
    }

    /** Serves [text] (a WebVTT subtitle) at a URL. */
    fun text(id: String, text: String, mime: String = "text/vtt"): String {
        entries[id] = Entry.Text(text.toByteArray(Charsets.UTF_8), mime)
        return url(id)
    }

    private fun url(id: String): String {
        val server = socket ?: error("Cast server isn't running")
        return "http://$host:${server.localPort}/$token/$id"
    }

    private fun acceptLoop(server: ServerSocket) {
        while (!server.isClosed) {
            val client = runCatching { server.accept() }.getOrNull() ?: break
            pool.execute { client.use { handle(it) } }
        }
    }

    private fun handle(client: Socket) {
        try {
            client.soTimeout = 30_000
            val remote = client.inetAddress
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), Charsets.ISO_8859_1))
            val requestLine = reader.readLine() ?: return
            val headers = HashMap<String, String>()
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
            val parts = requestLine.split(' ')
            val method = parts.getOrNull(0).orEmpty()
            val path = parts.getOrNull(1).orEmpty().substringBefore('?')
            val out = client.getOutputStream()
            if (!isHomeNetwork(remote)) return respond(out, 403, "Forbidden")
            if (method == "OPTIONS") return respond(out, 204, null, emptyMap())
            val segments = path.trim('/').split('/')
            if (segments.size != 2 || segments[0] != token) return respond(out, 404, "Not found")
            val entry = entries[segments[1]] ?: return respond(out, 404, "Not found")
            val head = method == "HEAD"
            when (entry) {
                is Entry.Text -> {
                    respond(out, 200, null, mapOf("Content-Type" to "${entry.mime}; charset=utf-8", "Content-Length" to entry.bytes.size.toString()))
                    if (!head) out.write(entry.bytes)
                }
                is Entry.Media -> serveMedia(out, entry, headers["range"], head)
            }
            out.flush()
        } catch (e: Exception) {
            // The Chromecast closes connections whenever it seeks or has buffered enough; that's normal.
            if (com.pntapps.veltoret.BuildConfig.DEBUG) Log.d("VeltoretCast", "request ended: ${e.message}")
        }
    }

    private fun serveMedia(out: OutputStream, entry: Entry.Media, rangeHeader: String?, head: Boolean) {
        val total = entry.length ?: probeLength(entry.uri).also { entry.length = it }
        val range = rangeHeader?.let { parseRange(it, total) }
        if (rangeHeader != null && range == null) {
            return respond(out, 416, null, mapOf("Content-Range" to "bytes */${total ?: "*"}"))
        }
        val start = range?.first ?: 0L
        // An open range on a file of unknown size ("bytes=500-") streams to the end.
        val end = range?.last?.takeIf { it != OPEN_END } ?: total?.minus(1)
        val length = if (end != null) end - start + 1 else null
        val headers = buildMap {
            put("Content-Type", entry.mime)
            put("Accept-Ranges", "bytes")
            if (length != null) put("Content-Length", length.toString())
            if (range != null) put("Content-Range", "bytes $start-$end/${total ?: "*"}")
        }
        respond(out, if (range != null) 206 else 200, null, headers)
        if (head) return
        val source = dataSources.createDataSource()
        try {
            source.open(DataSpec.Builder().setUri(entry.uri).setPosition(start).setLength(length ?: C.LENGTH_UNSET.toLong()).build())
            val buffer = ByteArray(256 * 1024)
            var remaining = length ?: Long.MAX_VALUE
            var position = start
            while (remaining > 0) {
                val n = source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (n == C.RESULT_END_OF_INPUT) break
                CastAudio.apply(entry.patches, position, buffer, n)
                out.write(buffer, 0, n)
                remaining -= n
                position += n
            }
        } finally {
            runCatching { source.close() }
        }
    }

    private fun probeLength(uri: Uri): Long? {
        val source = dataSources.createDataSource()
        return try {
            source.open(DataSpec.Builder().setUri(uri).build()).takeIf { it != C.LENGTH_UNSET.toLong() && it > 0 }
        } catch (e: Exception) {
            null
        } finally {
            runCatching { source.close() }
        }
    }

    private fun respond(out: OutputStream, code: Int, body: String?, headers: Map<String, String> = emptyMap()) {
        val text = StringBuilder("HTTP/1.1 $code ${reason(code)}\r\n")
        // The Default Media Receiver loads subtitles with XHR, which needs CORS.
        text.append("Access-Control-Allow-Origin: *\r\n")
        text.append("Access-Control-Allow-Headers: Range, Content-Type\r\n")
        text.append("Access-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges\r\n")
        text.append("Connection: close\r\n")
        headers.forEach { (k, v) -> text.append("$k: $v\r\n") }
        val bytes = body?.toByteArray()
        if (bytes != null) text.append("Content-Type: text/plain\r\nContent-Length: ${bytes.size}\r\n")
        text.append("\r\n")
        out.write(text.toString().toByteArray(Charsets.ISO_8859_1))
        if (bytes != null) out.write(bytes)
        out.flush()
    }

    private fun reason(code: Int) = when (code) {
        200 -> "OK"; 204 -> "No Content"; 206 -> "Partial Content"; 403 -> "Forbidden"; 404 -> "Not Found"
        416 -> "Range Not Satisfiable"; else -> "Error"
    }

    companion object {
        /** Marks "to the end" in a range whose file size isn't known. */
        const val OPEN_END = Long.MAX_VALUE - 1

        /**
         * "bytes=500-" / "bytes=500-999" / "bytes=-200" against a file of [total] bytes (null = unknown).
         * Returns the inclusive byte range, or null when it can't be satisfied.
         */
        fun parseRange(header: String, total: Long?): LongRange? {
            val spec = header.trim().removePrefix("bytes=").substringBefore(',').trim()
            val dash = spec.indexOf('-')
            if (!header.trim().startsWith("bytes=") || dash < 0) return null
            val startText = spec.substring(0, dash).trim()
            val endText = spec.substring(dash + 1).trim()
            return when {
                startText.isEmpty() -> {
                    // Suffix range: the last N bytes.
                    val n = endText.toLongOrNull() ?: return null
                    if (total == null || n <= 0) return null
                    maxOf(0, total - n)..(total - 1)
                }
                else -> {
                    val start = startText.toLongOrNull() ?: return null
                    if (total != null && start >= total) return null
                    val last = total?.minus(1)
                    val end = endText.toLongOrNull()?.let { if (last != null) minOf(it, last) else it } ?: last ?: return start..OPEN_END
                    if (end < start) null else start..end
                }
            }
        }

        /** Only devices on the home network (and this phone) may stream. */
        fun isHomeNetwork(address: InetAddress): Boolean =
            address.isSiteLocalAddress || address.isLinkLocalAddress || address.isLoopbackAddress ||
                // IPv6 unique local addresses (fc00::/7) aren't covered by isSiteLocalAddress.
                (address.address.size == 16 && (address.address[0].toInt() and 0xFE) == 0xFC)
    }
}
