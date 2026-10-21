package com.pntapps.veltoret.data.plans

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import com.pntapps.veltoret.data.db.PlansDao
import com.pntapps.veltoret.data.db.ReminderEntity
import com.pntapps.veltoret.data.db.WatchlistEntity
import kotlinx.coroutines.flow.Flow

/**
 * The watchlist ("Watch later") and reminders ("Remind me"). Reminders are inexact alarms that fire within
 * about ten minutes of the chosen time, which needs no special permission (exact alarms do on Android 14+).
 */
class PlansRepository(private val context: Context, private val dao: PlansDao) {

    fun observeWatchlist(): Flow<List<WatchlistEntity>> = dao.observeWatchlist()
    suspend fun watchlist(): List<WatchlistEntity> = dao.watchlist()
    fun inWatchlist(type: String, id: Int): Flow<Boolean> = dao.observeInWatchlist(type, id)

    suspend fun setInWatchlist(type: String, id: Int, saved: Boolean) {
        if (saved) dao.addToWatchlist(WatchlistEntity(type, id, System.currentTimeMillis()))
        else dao.removeFromWatchlist(type, id)
    }

    fun observeReminders(): Flow<List<ReminderEntity>> = dao.observeReminders()
    fun remindersFor(type: String, id: Int): Flow<List<ReminderEntity>> = dao.observeRemindersFor(type, id)

    /** Saves and schedules a reminder; a new one also puts the title on the watchlist (a snooze doesn't). */
    suspend fun addReminder(
        type: String, id: Int, season: Int?, episode: Int?, title: String, at: Long, addToWatchlist: Boolean = true,
    ): ReminderEntity {
        val reminder = ReminderEntity(mediaType = type, mediaId = id, season = season, episode = episode, title = title, at = at, createdAt = System.currentTimeMillis())
        val saved = reminder.copy(id = dao.insertReminder(reminder))
        schedule(saved)
        if (addToWatchlist && !dao.isInWatchlist(type, id)) setInWatchlist(type, id, true)
        return saved
    }

    suspend fun cancelReminder(id: Long) {
        dao.deleteReminder(id)
        alarms().cancel(fireIntent(id))
    }

    /**
     * Shows a due reminder exactly once: the alarm, app start and boot can all find the same row at the same
     * time, and only the caller whose delete removes it posts the notification. When notifications are off
     * the row is kept (Settings shows it with a warning) until it goes stale.
     */
    suspend fun fire(context: Context, container: com.pntapps.veltoret.AppContainer, id: Long) {
        val r = dao.reminder(id) ?: return
        if (!PlanNotifications.canPost(context)) return
        if (dao.deleteReminder(id) == 0) return
        PlanNotifications.showReminder(context, container, r)
    }

    /** App start and reboots (alarms don't survive a restart): schedule what's ahead, fire what's slightly late. */
    suspend fun rescheduleAll(): List<ReminderEntity> {
        val now = System.currentTimeMillis()
        val overdue = mutableListOf<ReminderEntity>()
        for (r in dao.reminders()) {
            when (Plans.due(r.at, now)) {
                Plans.Due.Schedule -> schedule(r)
                Plans.Due.FireNow -> overdue += r
                Plans.Due.Drop -> dao.deleteReminder(r.id)
            }
        }
        return overdue
    }

    /** [rescheduleAll], then shows the reminders that came due while the device was off. */
    suspend fun restore(context: Context, container: com.pntapps.veltoret.AppContainer) {
        for (r in rescheduleAll()) fire(context, container, r.id)
    }

    private fun schedule(r: ReminderEntity) {
        alarms().setWindow(AlarmManager.RTC_WAKEUP, r.at, WINDOW_MS, fireIntent(r.id))
    }

    private fun alarms() = context.getSystemService(AlarmManager::class.java)

    private fun fireIntent(id: Long): PendingIntent = PendingIntent.getBroadcast(
        context, id.toInt(),
        Intent(context, ReminderReceiver::class.java).setAction(ReminderReceiver.ACTION_FIRE).putExtra(ReminderReceiver.EXTRA_ID, id),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    companion object {
        /** Android may deliver the alarm anywhere in this window, batching it with others to save battery. */
        const val WINDOW_MS = 10L * 60 * 1000
    }
}
