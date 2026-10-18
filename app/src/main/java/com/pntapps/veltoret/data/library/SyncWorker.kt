package com.pntapps.veltoret.data.library

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.pntapps.veltoret.R
import com.pntapps.veltoret.VeltoretApp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit

/**
 * Rescans the library, or only some folders. Runs periodically, and on demand from the UI. Scans the user
 * starts run as a foreground job with a progress notification, so they keep going when the app is minimized.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val container = (applicationContext as VeltoretApp).container
        val scanner = container.scanner
        val folderIds = inputData.getLongArray(KEY_FOLDERS)?.toSet()
        // Android may refuse a foreground service when the app is in the background (periodic runs); the
        // scan still runs, just without the notification.
        val foreground = inputData.getBoolean(KEY_NOTIFY, false) &&
            runCatching { setForeground(foregroundInfo(scanner.state.value)) }.isSuccess
        return try {
            coroutineScope {
                val updates = if (foreground) launch {
                    while (true) {
                        delay(700)
                        notificationManager().notify(NOTIFICATION_ID, notification(scanner.state.value))
                    }
                } else null
                try {
                    scanner.scan(folderIds)
                } finally {
                    updates?.cancel()
                }
            }
            // Keep artwork on the device for offline use; a failure here never fails the sync.
            if (container.connectivity.isOnline && !scanner.state.value.cancelled) {
                runCatching { ArtworkPrefetch(applicationContext, container.database.catalogDao()).run() }
            }
            Result.success()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (runAttemptCount < 2) Result.retry() else Result.failure()
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo =
        foregroundInfo((applicationContext as VeltoretApp).container.scanner.state.value)

    private fun notificationManager() =
        applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun notification(state: ScanState): android.app.Notification {
        val context = applicationContext
        val title = when {
            state.folderIds == null -> "Scanning your library"
            state.currentFolder.isNotEmpty() -> "Scanning ${state.currentFolder}"
            else -> "Scanning folder"
        }
        val text = when {
            state.toMatch > 0 -> "Matching with TMDB · ${state.matched} of ${state.toMatch}"
            state.foldersTotal > 1 -> "Folder ${minOf(state.foldersDone + 1, state.foldersTotal)} of ${state.foldersTotal} · ${videos(state.filesFound)} found"
            else -> "${videos(state.filesFound)} found"
        }
        val progress = state.progress
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val cancel = PendingIntent.getBroadcast(
            context, 0, Intent(context, CancelScanReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_scan)
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .setProgress(100, ((progress ?: 0f) * 100).toInt(), progress == null)
            .addAction(0, "Cancel", cancel)
            .build()
    }

    private fun foregroundInfo(state: ScanState): ForegroundInfo {
        val manager = notificationManager()
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Library scans", NotificationManager.IMPORTANCE_LOW))
        }
        val notification = notification(state)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val PERIODIC = "library-sync-periodic"
        private const val NOW = "library-sync-now"
        private const val CHANNEL = "library-scan"
        private const val NOTIFICATION_ID = 0x5CA4
        private const val KEY_FOLDERS = "folders"
        private const val KEY_NOTIFY = "notify"

        private val constraints = Constraints.Builder().setRequiredNetworkType(NetworkType.NOT_REQUIRED).build()

        private fun videos(n: Int) = "$n video${if (n == 1) "" else "s"}"

        fun schedulePeriodic(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(12, TimeUnit.HOURS)
                .setConstraints(constraints)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        /**
         * Scans the whole library, or only [folderIds]. [notify] shows the progress notification and keeps the
         * scan alive in the background; use it for scans the user starts, which queue up behind a running scan.
         * Automatic whole-library requests (after renames, moves...) are dropped while another scan is queued
         * or running, since that scan covers them.
         */
        fun runNow(context: Context, folderIds: Set<Long>? = null, notify: Boolean = false) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(constraints)
                .setInputData(
                    workDataOf(KEY_NOTIFY to notify, KEY_FOLDERS to folderIds?.toLongArray()),
                )
                .build()
            val policy = if (folderIds == null && !notify) ExistingWorkPolicy.KEEP else ExistingWorkPolicy.APPEND_OR_REPLACE
            WorkManager.getInstance(context).enqueueUniqueWork(NOW, policy, request)
        }

        /** Stops the running scan (keeping what it already found) and drops queued ones. */
        fun cancel(context: Context) {
            (context.applicationContext as VeltoretApp).container.scanner.cancel()
            WorkManager.getInstance(context).cancelUniqueWork(NOW)
        }
    }
}

/** The notification's Cancel button. */
class CancelScanReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = SyncWorker.cancel(context)
}
