package com.pntapps.veltoret.player

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * Serves small reads from a memory buffer filled in large chunks.
 *
 * Media3's MKV parser reads the index (Cues) a few bytes at a time. Over HTTP that's cheap because
 * OkHttp buffers, but device files open through the Storage Access Framework and every read becomes
 * a system call into Android's FUSE storage layer. On some devices that turned a 1.7 MB index into
 * ~24 seconds of startup; with this buffer it's one call per [chunkSize].
 */
@UnstableApi
class BufferedDataSource(private val upstream: DataSource, private val chunkSize: Int = 256 * 1024) : DataSource {

    class Factory(private val upstream: DataSource.Factory) : DataSource.Factory {
        override fun createDataSource(): DataSource = BufferedDataSource(upstream.createDataSource())
    }

    private val buffer = ByteArray(chunkSize)
    private var start = 0
    private var end = 0
    private var upstreamEnded = false

    override fun addTransferListener(transferListener: TransferListener) = upstream.addTransferListener(transferListener)

    override fun open(dataSpec: DataSpec): Long {
        start = 0
        end = 0
        upstreamEnded = false
        return upstream.open(dataSpec)
    }

    override fun read(target: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (start < end) {
            val n = minOf(length, end - start)
            System.arraycopy(buffer, start, target, offset, n)
            start += n
            return n
        }
        if (upstreamEnded) return C.RESULT_END_OF_INPUT
        // Large reads (sample data) go straight through; buffering them would only add a copy.
        if (length >= chunkSize) return upstream.read(target, offset, length)
        val read = upstream.read(buffer, 0, chunkSize)
        if (read == C.RESULT_END_OF_INPUT) {
            upstreamEnded = true
            return C.RESULT_END_OF_INPUT
        }
        start = 0
        end = read
        val n = minOf(length, end)
        System.arraycopy(buffer, 0, target, offset, n)
        start = n
        return n
    }

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        start = 0
        end = 0
        upstreamEnded = false
        upstream.close()
    }
}
