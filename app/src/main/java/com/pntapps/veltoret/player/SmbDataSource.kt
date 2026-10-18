package com.pntapps.veltoret.player

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.data.smb.SmbReader
import com.pntapps.veltoret.data.smb.SmbStorage
import kotlinx.coroutines.runBlocking

/**
 * Plays files on network shares: the media URI is the file's id ("smb://host/share/…", see [SmbPath]).
 * Reads go straight to the server at the requested position, so seeking is instant. The player wraps
 * this in [BufferedDataSource], which turns Media3's many tiny index reads into 256 KB requests.
 */
@OptIn(UnstableApi::class)
class SmbDataSource(private val smb: SmbStorage) : BaseDataSource(/* isNetwork = */ true) {

    private var reader: SmbReader? = null
    private var uri: Uri? = null
    private var position = 0L
    private var bytesRemaining = 0L
    private var opened = false

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        transferInitializing(dataSpec)
        val r = try {
            runBlocking { smb.openReader(dataSpec.uri.toString()) }
        } catch (e: Exception) {
            throw DataSourceException(e, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)
        }
        reader = r
        if (dataSpec.position > r.size) {
            throw DataSourceException(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE)
        }
        position = dataSpec.position
        bytesRemaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) dataSpec.length else r.size - position
        opened = true
        transferStarted(dataSpec)
        return bytesRemaining
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
        val r = reader ?: return C.RESULT_END_OF_INPUT
        val n = try {
            r.read(position, buffer, offset, minOf(length.toLong(), bytesRemaining).toInt())
        } catch (e: Exception) {
            throw DataSourceException(e, PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED)
        }
        if (n < 0) return C.RESULT_END_OF_INPUT
        position += n
        bytesRemaining -= n
        bytesTransferred(n)
        return n
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        uri = null
        reader?.close()
        reader = null
        if (opened) {
            opened = false
            transferEnded()
        }
    }

    class Factory(private val smb: SmbStorage) : DataSource.Factory {
        override fun createDataSource(): DataSource = SmbDataSource(smb)
    }
}

/** Sends "smb://" URIs to [smb] and everything else to [other] (Drive over HTTP). */
@OptIn(UnstableApi::class)
class SchemeRoutingDataSource(private val smb: DataSource, private val other: DataSource) : DataSource {
    private var current: DataSource? = null

    override fun addTransferListener(transferListener: TransferListener) {
        smb.addTransferListener(transferListener)
        other.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val source = if (SmbPath.isSmb(dataSpec.uri.toString())) smb else other
        current = source
        return source.open(dataSpec)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int = current!!.read(buffer, offset, length)
    override fun getUri(): Uri? = current?.uri
    override fun getResponseHeaders(): Map<String, List<String>> = current?.responseHeaders ?: emptyMap()

    override fun close() {
        current?.close()
        current = null
    }

    class Factory(private val smb: DataSource.Factory, private val other: DataSource.Factory) : DataSource.Factory {
        override fun createDataSource(): DataSource = SchemeRoutingDataSource(smb.createDataSource(), other.createDataSource())
    }
}
