package com.pntapps.veltoret.player

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.ResolvingDataSource
import com.pntapps.veltoret.data.auth.GoogleAuthManager
import kotlinx.coroutines.runBlocking

/**
 * Drive media is addressed as `veltoret-drive://media/<fileId>?account=<email>`. The resolver
 * rewrites that to the Drive download URL and attaches a fresh bearer token on every open, so
 * seeking keeps working long after the original token would have expired.
 */
object DriveMedia {
    private const val SCHEME = "veltoret-drive"

    fun uri(fileId: String, accountEmail: String): Uri = Uri.Builder()
        .scheme(SCHEME)
        .authority("media")
        .appendPath(fileId)
        .appendQueryParameter("account", accountEmail)
        .build()

    @OptIn(UnstableApi::class)
    class Resolver(private val auth: GoogleAuthManager) : ResolvingDataSource.Resolver {
        override fun resolveDataSpec(dataSpec: DataSpec): DataSpec {
            val uri = dataSpec.uri
            if (uri.scheme != SCHEME) return dataSpec
            val fileId = uri.lastPathSegment ?: return dataSpec
            val account = uri.getQueryParameter("account") ?: return dataSpec
            val token = runBlocking { auth.accessToken(account) }
            return dataSpec
                .withUri(Uri.parse("https://www.googleapis.com/drive/v3/files/$fileId?alt=media&supportsAllDrives=true"))
                .withAdditionalHeaders(mapOf("Authorization" to "Bearer $token"))
        }
    }

    fun subtitleMimeType(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "srt" -> MimeTypes.APPLICATION_SUBRIP
        "vtt" -> MimeTypes.TEXT_VTT
        "ass", "ssa" -> MimeTypes.TEXT_SSA
        "ttml", "dfxp" -> MimeTypes.APPLICATION_TTML
        else -> MimeTypes.APPLICATION_SUBRIP
    }
}
