package com.pntapps.veltoret.data.plans

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.pntapps.veltoret.VeltoretApp
import com.pntapps.veltoret.data.db.ReminderEntity
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Shows a reminder when its alarm goes off, and handles "Snooze 1 hour". */
class ReminderReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val container = (context.applicationContext as VeltoretApp).container
        val pending = goAsync()
        container.appScope.launch {
            try {
                withTimeoutOrNull(25_000) {
                    when (intent.action) {
                        ACTION_FIRE -> container.plans.fire(context, container, intent.getLongExtra(EXTRA_ID, -1))
                        ACTION_SNOOZE -> {
                            PlanNotifications.cancel(context, intent.getIntExtra(EXTRA_NOTIFICATION, 0))
                            container.plans.addReminder(
                                type = intent.getStringExtra(EXTRA_TYPE) ?: return@withTimeoutOrNull,
                                id = intent.getIntExtra(EXTRA_MEDIA, -1),
                                season = intent.getIntExtra(EXTRA_SEASON, -1).takeIf { it >= 0 },
                                episode = intent.getIntExtra(EXTRA_EPISODE, -1).takeIf { it >= 0 },
                                title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                                at = System.currentTimeMillis() + SNOOZE_MS,
                                // Snoozing shouldn't undo removing the title from the Watchlist.
                                addToWatchlist = false,
                            )
                        }
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION_FIRE = "com.pntapps.veltoret.REMINDER"
        private const val ACTION_SNOOZE = "com.pntapps.veltoret.REMINDER_SNOOZE"
        const val EXTRA_ID = "id"
        private const val EXTRA_NOTIFICATION = "notification"
        private const val EXTRA_TYPE = "type"
        private const val EXTRA_MEDIA = "media"
        private const val EXTRA_SEASON = "season"
        private const val EXTRA_EPISODE = "episode"
        private const val EXTRA_TITLE = "title"
        private const val SNOOZE_MS = 60L * 60 * 1000

        /** The reminder itself is gone once shown, so snoozing carries what's needed to set it again. */
        fun snoozeIntent(context: Context, r: ReminderEntity, notificationId: Int): PendingIntent {
            val intent = Intent(context, ReminderReceiver::class.java).setAction(ACTION_SNOOZE)
                .putExtra(EXTRA_NOTIFICATION, notificationId)
                .putExtra(EXTRA_TYPE, r.mediaType)
                .putExtra(EXTRA_MEDIA, r.mediaId)
                .putExtra(EXTRA_TITLE, r.title)
            r.season?.let { intent.putExtra(EXTRA_SEASON, it) }
            r.episode?.let { intent.putExtra(EXTRA_EPISODE, it) }
            return PendingIntent.getBroadcast(context, notificationId, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }
}

/** Alarms don't survive a reboot (or an app update on some devices): set every reminder again. */
class RescheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val container = (context.applicationContext as VeltoretApp).container
        val pending = goAsync()
        container.appScope.launch {
            try {
                withTimeoutOrNull(25_000) { container.plans.restore(context, container) }
            } finally {
                pending.finish()
            }
        }
    }
}
