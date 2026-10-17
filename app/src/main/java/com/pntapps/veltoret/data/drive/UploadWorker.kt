package com.pntapps.veltoret.data.drive

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.pntapps.veltoret.R
import com.pntapps.veltoret.VeltoretApp

/** Uploads one local document to a Drive folder with a progress notification. */
class UploadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val container = (applicationContext as VeltoretApp).container
        val email = inputData.getString(KEY_ACCOUNT) ?: return Result.failure()
        val parentId = inputData.getString(KEY_PARENT) ?: return Result.failure()
        val uri = inputData.getString(KEY_URI)?.let(Uri::parse) ?: return Result.failure()
        val resolver = applicationContext.contentResolver

        var name = "Upload"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0) ?: name
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        val mime = resolver.getType(uri) ?: "application/octet-stream"
        setProgress(workDataOf(KEY_NAME to name, KEY_PROGRESS to 0f))
        setForeground(foregroundInfo(name, 0f))

        return try {
            var lastReported = -1
            container.driveRepository.upload(
                email = email,
                parentId = parentId,
                name = name,
                mimeType = mime,
                size = size,
                // Unknown sizes (-1) are fine: the uploader tells Drive the total on the last chunk.
                open = { resolver.openInputStream(uri) ?: error("Cannot open $uri") },
                onProgress = { sent, total ->
                    val fraction = if (total > 0) sent.toFloat() / total else 0f
                    val percent = (fraction * 100).toInt()
                    if (percent != lastReported) {
                        lastReported = percent
                        setProgressAsync(workDataOf(KEY_NAME to name, KEY_PROGRESS to fraction))
                        notificationManager().notify(id.hashCode(), notification(name, fraction))
                    }
                },
            )
            Result.success(workDataOf(KEY_NAME to name, KEY_PARENT to parentId))
        } catch (e: Exception) {
            if (runAttemptCount < 2) Result.retry() else Result.failure(workDataOf(KEY_NAME to name, KEY_ERROR to e.message))
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo("Uploading", 0f)

    private fun notificationManager() =
        applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun notification(name: String, progress: Float) =
        NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_upload)
            .setContentTitle("Uploading to Drive")
            .setContentText(name)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(100, (progress * 100).toInt(), progress <= 0f)
            .build()

    private fun foregroundInfo(name: String, progress: Float): ForegroundInfo {
        val manager = notificationManager()
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Uploads", NotificationManager.IMPORTANCE_LOW))
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(id.hashCode(), notification(name, progress), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(id.hashCode(), notification(name, progress))
        }
    }

    companion object {
        const val TAG = "drive-upload"
        const val KEY_ACCOUNT = "account"
        const val KEY_PARENT = "parent"
        const val KEY_URI = "uri"
        const val KEY_NAME = "name"
        const val KEY_PROGRESS = "progress"
        const val KEY_ERROR = "error"
        private const val CHANNEL = "uploads"

        fun enqueue(context: Context, email: String, parentId: String, uri: Uri) {
            val data: Data = workDataOf(KEY_ACCOUNT to email, KEY_PARENT to parentId, KEY_URI to uri.toString())
            val request = OneTimeWorkRequestBuilder<UploadWorker>().setInputData(data).addTag(TAG).build()
            WorkManager.getInstance(context).enqueue(request)
        }
    }
}
