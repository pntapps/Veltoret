package com.pntapps.veltoret.data.drive

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.io.InputStream

/** The Google account's storage (shared by Drive, Gmail and Photos) is full. */
class DriveStorageFullException : IOException("Google Drive is full")

class DriveRepository(
    private val api: DriveApi,
    /** Client that carries [DriveAuthInterceptor]; used for resumable uploads. */
    private val http: OkHttpClient,
    private val json: Json,
) {

    suspend fun listChildren(email: String, folderId: String, orderBy: String = "folder,name_natural"): List<DriveFile> =
        paged { token -> api.list(DriveAccount(email), "'${escape(folderId)}' in parents and trashed = false", token, orderBy) }

    suspend fun listSharedWithMe(email: String): List<DriveFile> =
        paged { token -> api.list(DriveAccount(email), "sharedWithMe = true and trashed = false", token, "folder,name") }

    suspend fun search(email: String, text: String): List<DriveFile> =
        api.list(
            DriveAccount(email),
            "name contains '${escape(text)}' and trashed = false",
            orderBy = "folder,name",
            pageSize = 200,
        ).files

    suspend fun get(email: String, id: String): DriveFile = api.get(DriveAccount(email), id)

    suspend fun about(email: String): DriveAbout = api.about(DriveAccount(email))

    /** Free space in the account's storage (shared with Gmail and Photos), or null when unlimited or unknown. */
    suspend fun freeBytes(email: String): Long? {
        val quota = about(email).storageQuota ?: return null
        val limit = quota.limit?.toLongOrNull() ?: return null
        val usage = quota.usage?.toLongOrNull() ?: return null
        return (limit - usage).coerceAtLeast(0)
    }

    suspend fun rename(email: String, id: String, newName: String): DriveFile =
        api.update(DriveAccount(email), id, DriveFileUpdate(name = newName))

    suspend fun move(email: String, id: String, fromParent: String?, toParent: String): DriveFile =
        api.update(DriveAccount(email), id, DriveFileUpdate(), addParents = toParent, removeParents = fromParent)

    /** Moves to Drive's trash (recoverable for 30 days) rather than deleting permanently. */
    suspend fun trash(email: String, id: String): DriveFile =
        api.update(DriveAccount(email), id, DriveFileUpdate(trashed = true))

    /** Deletes permanently, skipping Drive's trash. Only the file's owner is allowed to do this. */
    suspend fun deletePermanently(email: String, id: String) {
        val response = api.delete(DriveAccount(email), id)
        if (!response.isSuccessful) {
            throw IOException(
                if (response.code() == 403) "Only the owner of this file can delete it permanently"
                else "Delete failed (HTTP ${response.code()})"
            )
        }
    }

    suspend fun createFolder(email: String, parentId: String, name: String): DriveFile =
        api.create(DriveAccount(email), DriveFileCreate(name, DriveFile.FOLDER_MIME, listOf(parentId)))

    /**
     * Resumable upload in 8 MB chunks, so large videos survive flaky connections chunk by chunk.
     * [size] may be -1 when the length isn't known up front (a video streamed straight out of a ZIP):
     * Drive is told the total on the final chunk, so nothing has to be written to the phone first.
     */
    suspend fun upload(
        email: String,
        parentId: String,
        name: String,
        mimeType: String,
        size: Long,
        open: () -> InputStream,
        onProgress: (sent: Long, total: Long) -> Unit,
    ): DriveFile = withContext(Dispatchers.IO) {
        val account = DriveAccount(email)
        val metadata = json.encodeToString(DriveFileCreate.serializer(), DriveFileCreate(name, mimeType, listOf(parentId)))
        val init = Request.Builder()
            .url("$UPLOAD_URL?uploadType=resumable&supportsAllDrives=true&fields=$DRIVE_FILE_FIELDS")
            .tag(DriveAccount::class.java, account)
            .header("X-Upload-Content-Type", mimeType)
            .apply { if (size >= 0) header("X-Upload-Content-Length", size.toString()) }
            .post(metadata.toRequestBody("application/json; charset=UTF-8".toMediaType()))
            .build()
        val session = http.newCall(init).execute().use { response ->
            if (!response.isSuccessful) throw uploadError(response, "Upload could not start")
            response.header("Location") ?: throw IOException("Drive did not return an upload session")
        }

        open().use { input ->
            val buffer = ByteArray(CHUNK_SIZE)
            var offset = 0L
            while (true) {
                val read = input.readChunk(buffer)
                // readChunk only returns a short (or empty) chunk at the end of the stream.
                val last = read < CHUNK_SIZE
                val count = maxOf(read, 0)
                val total = when {
                    size >= 0 -> size.toString()
                    last -> (offset + count).toString()
                    else -> "*"
                }
                val range = if (count == 0) "bytes */$total" else "bytes $offset-${offset + count - 1}/$total"
                val request = Request.Builder()
                    .url(session)
                    .tag(DriveAccount::class.java, account)
                    .header("Content-Range", range)
                    .put(buffer.toRequestBody(null, 0, count))
                    .build()
                http.newCall(request).execute().use { response ->
                    when {
                        response.code == 308 -> {
                            if (last) throw IOException("File ended before upload completed")
                            offset += count
                            onProgress(offset, size)
                        }
                        response.isSuccessful -> {
                            onProgress(offset + count, size)
                            return@withContext json.decodeFromString(DriveFile.serializer(), response.body.string())
                        }
                        else -> throw uploadError(response, "Upload failed")
                    }
                }
            }
            @Suppress("UNREACHABLE_CODE")
            error("unreachable")
        }
    }

    /** Drive answers 403 "storageQuotaExceeded" when the account is full; anything else stays a plain IOException. */
    private fun uploadError(response: Response, what: String): IOException {
        val body = runCatching { response.body.string() }.getOrDefault("")
        return if (response.code == 403 && "storageQuotaExceeded" in body) DriveStorageFullException()
        else IOException("$what (HTTP ${response.code})")
    }

    /**
     * Streams a file's content. [block] gets the raw stream and its length (-1 if unknown) and runs on
     * the IO dispatcher; the connection closes when it returns.
     */
    suspend fun <T> download(email: String, id: String, block: suspend (InputStream, Long) -> T): T =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url("https://www.googleapis.com/drive/v3/files/$id?alt=media&supportsAllDrives=true")
                .tag(DriveAccount::class.java, DriveAccount(email))
                .get()
                .build()
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    val reason = when (response.code) {
                        403 -> "Google Drive refused the download (it may have hit its daily download limit, or be flagged by Google)."
                        404 -> "The file is no longer in Google Drive."
                        else -> "Download failed (HTTP ${response.code})."
                    }
                    throw IOException(reason)
                }
                block(response.body.byteStream(), response.body.contentLength())
            }
        }

    private suspend fun paged(fetch: suspend (String?) -> DriveFileList): List<DriveFile> {
        val all = mutableListOf<DriveFile>()
        var token: String? = null
        do {
            val page = fetch(token)
            all += page.files
            token = page.nextPageToken
        } while (token != null)
        return all
    }

    private fun InputStream.readChunk(buffer: ByteArray): Int {
        var total = 0
        while (total < buffer.size) {
            val n = read(buffer, total, buffer.size - total)
            if (n < 0) break
            total += n
        }
        return if (total == 0) -1 else total
    }

    companion object {
        const val ROOT = "root"
        private const val UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files"
        private const val CHUNK_SIZE = 8 * 1024 * 1024

        fun escape(value: String) = value.replace("\\", "\\\\").replace("'", "\\'")
    }
}
