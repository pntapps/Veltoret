package com.pntapps.veltoret.player

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import java.io.BufferedInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Reads a video a phone streams to this TV ("vlink://host:port/token/id", served by the phone's
 * CastServer at the same path over http). Plain HTTP range requests over a socket, because Android
 * refuses cleartext http:// through OkHttp, and a phone on the home network has no certificate.
 */
@OptIn(UnstableApi::class)
class LinkDataSource : BaseDataSource(/* isNetwork = */ true) {
    private var socket: Socket? = null
    private var input: InputStream? = null
    private var uri: Uri? = null
    private var remaining = C.LENGTH_UNSET.toLong()

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        val target = dataSpec.uri
        uri = target
        val host = target.host ?: throw IOException("No host in $target")
        val port = target.port.takeIf { it > 0 } ?: 80
        val s = Socket()
        socket = s
        try {
            s.connect(InetSocketAddress(host, port), 8_000)
            s.soTimeout = 20_000
            s.tcpNoDelay = true
            val end = if (dataSpec.length != C.LENGTH_UNSET.toLong()) (dataSpec.position + dataSpec.length - 1).toString() else ""
            val request = "GET ${target.encodedPath} HTTP/1.1\r\nHost: $host:$port\r\nRange: bytes=${dataSpec.position}-$end\r\nConnection: close\r\n\r\n"
            s.getOutputStream().apply { write(request.toByteArray(Charsets.ISO_8859_1)); flush() }
            val stream = BufferedInputStream(s.getInputStream(), 64 * 1024)
            val status = readLine(stream).split(' ').getOrNull(1)?.toIntOrNull() ?: throw IOException("Not HTTP")
            var length = C.LENGTH_UNSET.toLong()
            while (true) {
                val line = readLine(stream)
                if (line.isEmpty()) break
                if (line.startsWith("content-length:", ignoreCase = true)) length = line.substringAfter(':').trim().toLongOrNull() ?: length
            }
            if (status == 416) throw androidx.media3.datasource.DataSourceException(androidx.media3.common.PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
            if (status !in 200..299) throw HttpDataSource.InvalidResponseCodeException(status, null, null, emptyMap(), dataSpec, ByteArray(0))
            // A 200 (no range support) would start at 0; the phone always answers ranges with 206.
            if (status == 200 && dataSpec.position > 0) stream.skipFully(dataSpec.position)
            input = stream
            remaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) dataSpec.length else length
            transferStarted(dataSpec)
            return remaining
        } catch (e: IOException) {
            close()
            throw HttpDataSource.HttpDataSourceException.createForIOException(e, dataSpec, HttpDataSource.HttpDataSourceException.TYPE_OPEN)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val max = if (remaining == C.LENGTH_UNSET.toLong()) length else minOf(length.toLong(), remaining).toInt()
        val n = input?.read(buffer, offset, max) ?: return C.RESULT_END_OF_INPUT
        if (n < 0) return C.RESULT_END_OF_INPUT
        if (remaining != C.LENGTH_UNSET.toLong()) remaining -= n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        val wasOpen = input != null
        runCatching { input?.close() }
        runCatching { socket?.close() }
        input = null
        socket = null
        if (wasOpen) transferEnded()
    }

    private fun readLine(stream: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val b = stream.read()
            if (b < 0) throw IOException("Connection closed")
            if (b == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(b.toChar())
            if (sb.length > 8192) throw IOException("Header too long")
        }
    }

    private fun InputStream.skipFully(count: Long) {
        var left = count
        while (left > 0) {
            val n = skip(left)
            if (n <= 0) { if (read() < 0) throw IOException("End of stream") else left-- } else left -= n
        }
    }

    class Factory : DataSource.Factory {
        override fun createDataSource(): DataSource = LinkDataSource()
    }
}
