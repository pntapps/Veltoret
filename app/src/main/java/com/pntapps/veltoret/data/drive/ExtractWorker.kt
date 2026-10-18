package com.pntapps.veltoret.data.drive

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.pntapps.veltoret.R
import com.pntapps.veltoret.VeltoretApp
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.library.SyncWorker
import kotlinx.coroutines.CancellationException
import java.io.BufferedInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.util.zip.ZipException
import java.util.zip.ZipInputStream

/** What happens to the ZIP once every file in it has been extracted. */
enum class ZipAfterExtract { Keep, Trash, Delete }

/**
 * Unpacks a ZIP that lives in Google Drive back into Google Drive.
 *
 * Nothing is written to the phone: the archive is read as a stream, each entry is inflated on the
 * fly and piped straight into a resumable Drive upload in 8 MB pieces. Re-running after a failure
 * skips files that already made it, so an interrupted season picks up where it stopped.
 */
class ExtractWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    private val container get() = (applicationContext as VeltoretApp).container
    private val drive get() = container.driveRepository

    override suspend fun doWork(): Result {
        val email = inputData.getString(KEY_ACCOUNT) ?: return Result.failure()
        val zipId = inputData.getString(KEY_ZIP) ?: return Result.failure()
        val zipName = inputData.getString(KEY_NAME) ?: "Archive.zip"
        val parentId = inputData.getString(KEY_PARENT) ?: return Result.failure()
        val after = inputData.getString(KEY_AFTER)?.let { runCatching { ZipAfterExtract.valueOf(it) }.getOrNull() }
            ?: ZipAfterExtract.Keep

        report(zipName, 0f, "Preparing…", 0)
        var extracted = 0
        var alreadyThere = 0
        return try {
            val folders = FolderCache(email)
            val root = folders.child(parentId, FilenameParser.baseName(zipName))

            drive.download(email, zipId) { raw, length ->
                val counter = CountingInputStream(raw)
                val zip = ZipInputStream(BufferedInputStream(counter, 256 * 1024))
                while (true) {
                    val entry = zip.nextEntry ?: break
                    val path = entry.name.replace('\\', '/').trim('/')
                    if (entry.isDirectory || isJunk(path)) continue

                    val dirId = folders.path(root, path.substringBeforeLast('/', ""))
                    val fileName = path.substringAfterLast('/')
                    val existing = folders.files(dirId)[fileName]
                    if (existing != null && (entry.size < 0 || existing.sizeBytes == entry.size)) {
                        alreadyThere++
                        continue // already extracted on an earlier run; nextEntry() skips its bytes
                    }

                    val fraction = { if (length > 0) counter.count.toFloat() / length else 0f }
                    report(zipName, fraction(), fileName, extracted)
                    var lastPercent = -1
                    drive.upload(
                        email = email,
                        parentId = dirId,
                        name = fileName,
                        mimeType = mimeFor(fileName),
                        size = entry.size,
                        open = { KeepOpen(zip) },
                        onProgress = { _, _ ->
                            val percent = (fraction() * 100).toInt()
                            if (percent != lastPercent) {
                                lastPercent = percent
                                reportAsync(zipName, fraction(), fileName, extracted)
                            }
                        },
                    )
                    extracted++
                }
            }

            // Reaching this point means the whole archive was read and every file is in Drive.
            // Never remove an archive that produced nothing (e.g. it only held junk files).
            var zipNote: String? = null
            if (after != ZipAfterExtract.Keep && extracted + alreadyThere > 0) {
                zipNote = try {
                    if (after == ZipAfterExtract.Delete) {
                        drive.deletePermanently(email, zipId)
                        "ZIP deleted"
                    } else {
                        drive.trash(email, zipId)
                        "ZIP moved to trash"
                    }.also { container.libraryRepository.forgetArchive(zipId) }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    "ZIP kept: ${e.message}"
                }
            }
            SyncWorker.runNow(applicationContext)
            Result.success(
                workDataOf(
                    KEY_NAME to zipName, KEY_COUNT to extracted + alreadyThere, KEY_FOLDER to root, KEY_ZIP_NOTE to zipNote,
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: DriveStorageFullException) {
            // Retrying can't help until space is freed, and every retry would download the ZIP again.
            val done = extracted + alreadyThere
            Result.failure(
                workDataOf(
                    KEY_NAME to zipName,
                    KEY_ERROR to "Google Drive is full" +
                        (if (done > 0) " after ${if (done == 1) "1 file" else "$done files"}" else "") +
                        ". Free up space (and empty Drive's trash), then extract again: it continues where it stopped.",
                )
            )
        } catch (e: ZipException) {
            Result.failure(workDataOf(KEY_NAME to zipName, KEY_ERROR to describeZipError(e)))
        } catch (e: IOException) {
            if (runAttemptCount < 3) Result.retry()
            else Result.failure(workDataOf(KEY_NAME to zipName, KEY_ERROR to (e.message ?: "Network problem")))
        } catch (e: Exception) {
            Result.failure(workDataOf(KEY_NAME to zipName, KEY_ERROR to (e.message ?: "Extraction failed")))
        }
    }

    private fun isJunk(path: String): Boolean {
        val name = path.substringAfterLast('/')
        return path.startsWith("__MACOSX/") || name.startsWith("._") || name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini"
    }

    private fun mimeFor(name: String): String = when (val ext = FilenameParser.extension(name)) {
        "mkv" -> "video/x-matroska"
        "srt" -> "application/x-subrip"
        "ass", "ssa" -> "text/x-ssa"
        "vtt" -> "text/vtt"
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    private fun describeZipError(e: ZipException): String {
        val msg = e.message.orEmpty()
        return when {
            "encrypt" in msg.lowercase() -> "This ZIP is password-protected, which isn't supported."
            "compression method" in msg.lowercase() || "invalid" in msg.lowercase() ->
                "This ZIP uses a compression format Android can't read. Re-create it with standard ZIP compression."
            else -> "The ZIP looks damaged or incomplete ($msg)."
        }
    }

    /** Drive folder lookups with caching: reuses existing folders so re-runs land in the same place. */
    private inner class FolderCache(private val email: String) {
        private val children = HashMap<String, Map<String, DriveFile>>()
        private val resolved = HashMap<String, String>()

        suspend fun files(folderId: String): Map<String, DriveFile> =
            children.getOrPut(folderId) { drive.listChildren(email, folderId).associateBy { it.name } }

        suspend fun child(parentId: String, name: String): String {
            files(parentId)[name]?.takeIf { it.isFolder }?.let { return it.id }
            val created = drive.createFolder(email, parentId, name)
            children[parentId] = files(parentId) + (name to created)
            children[created.id] = emptyMap()
            return created.id
        }

        suspend fun path(root: String, relative: String): String {
            if (relative.isEmpty()) return root
            resolved[relative]?.let { return it }
            var current = root
            // Ignore "." / ".." so a malformed archive can't climb out of its own folder.
            for (segment in relative.split('/').filter { it.isNotBlank() && it != "." && it != ".." }) {
                current = child(current, segment)
            }
            resolved[relative] = current
            return current
        }
    }

    private suspend fun report(zipName: String, progress: Float, current: String, done: Int) {
        setProgress(progressData(zipName, progress, current, done))
        setForeground(foregroundInfo(zipName, progress, current))
    }

    private fun reportAsync(zipName: String, progress: Float, current: String, done: Int) {
        setProgressAsync(progressData(zipName, progress, current, done))
        notificationManager().notify(id.hashCode(), notification(zipName, progress, current))
    }

    private fun progressData(zipName: String, progress: Float, current: String, done: Int) =
        workDataOf(KEY_NAME to zipName, KEY_PROGRESS to progress, KEY_CURRENT to current, KEY_COUNT to done)

    override suspend fun getForegroundInfo(): ForegroundInfo =
        foregroundInfo(inputData.getString(KEY_NAME) ?: "Archive", 0f, "Preparing…")

    private fun notificationManager() =
        applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun notification(zipName: String, progress: Float, current: String) =
        NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_extract)
            .setContentTitle("Extracting $zipName")
            .setContentText(current)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(100, (progress * 100).toInt(), progress <= 0f)
            .build()

    private fun foregroundInfo(zipName: String, progress: Float, current: String): ForegroundInfo {
        val manager = notificationManager()
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Extracting archives", NotificationManager.IMPORTANCE_LOW))
        }
        val notification = notification(zipName, progress, current)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(id.hashCode(), notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(id.hashCode(), notification)
        }
    }

    /** Lets the uploader `use {}` an entry stream without closing the whole archive. */
    private class KeepOpen(input: InputStream) : FilterInputStream(input) {
        override fun close() = Unit
    }

    private class CountingInputStream(input: InputStream) : FilterInputStream(input) {
        @Volatile var count = 0L
            private set

        override fun read(): Int = super.read().also { if (it >= 0) count++ }
        override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { if (it > 0) count += it }
        override fun skip(n: Long): Long = super.skip(n).also { count += it }
    }

    companion object {
        const val TAG = "drive-extract"
        const val KEY_ACCOUNT = "account"
        const val KEY_ZIP = "zip"
        const val KEY_NAME = "name"
        const val KEY_PARENT = "parent"
        const val KEY_AFTER = "after"
        const val KEY_ZIP_NOTE = "zip_note"
        const val KEY_PROGRESS = "progress"
        const val KEY_CURRENT = "current"
        const val KEY_COUNT = "count"
        const val KEY_FOLDER = "folder"
        const val KEY_ERROR = "error"
        private const val CHANNEL = "extract"

        fun tagFor(zipId: String) = "zip:$zipId"

        fun enqueue(
            context: Context,
            email: String,
            zipId: String,
            zipName: String,
            parentId: String,
            wifiOnly: Boolean,
            after: ZipAfterExtract,
        ) {
            val request = OneTimeWorkRequestBuilder<ExtractWorker>()
                .setInputData(
                    workDataOf(
                        KEY_ACCOUNT to email, KEY_ZIP to zipId, KEY_NAME to zipName,
                        KEY_PARENT to parentId, KEY_AFTER to after.name,
                    )
                )
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
                        .build()
                )
                .addTag(TAG)
                .addTag(tagFor(zipId))
                .build()
            // One job per archive: tapping Extract twice doesn't start a duplicate.
            WorkManager.getInstance(context).enqueueUniqueWork("extract-$zipId", ExistingWorkPolicy.KEEP, request)
        }
    }
}
