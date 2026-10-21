package com.pntapps.veltoret.data.plans

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.pntapps.veltoret.VeltoretApp
import com.pntapps.veltoret.ui.util.isTv
import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime
import java.util.concurrent.TimeUnit

/**
 * Once a day, around 10 AM: refreshes the next episode of shows the user follows (on the Watchlist or
 * started) that are still airing, and posts "New episode of …" for Watchlist shows airing today.
 * Library scans refresh shows only weekly, which is too slow for air dates.
 */
class UpcomingWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val container = (applicationContext as VeltoretApp).container
        val settings = container.settings.current()
        if (!settings.onboardingComplete) return Result.success()
        val catalog = container.database.catalogDao()
        val watchlistShows = container.plans.watchlist().filter { it.mediaType == Plans.TV }.map { it.mediaId }.toSet()
        val followed = watchlistShows + container.database.watchDao().watchedShowIds()

        for (id in followed) {
            val show = catalog.show(id) ?: continue
            if (Plans.stillAiring(show.status) || show.nextEpisodeAirDate != null) {
                runCatching { container.tmdbRepository.ensureShow(id, emptySet(), maxAgeMs = REFRESH_MS) }
            }
        }

        if (settings.newEpisodeAlerts && !applicationContext.isTv()) {
            val today = LocalDate.now().toString()
            val prefs = applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            // "2026-10-23|showId:season:episode": the date prefix sorts, so pruning keeps the newest
            // (a StringSet has no order of its own).
            val alerted = prefs.getStringSet(KEY_ALERTED, emptySet()).orEmpty().toMutableSet()
            for (id in watchlistShows) {
                val show = catalog.show(id) ?: continue
                if (show.nextEpisodeAirDate != today) continue
                val key = "$today|$id:${show.nextEpisodeSeason}:${show.nextEpisodeNumber}"
                if (key in alerted) continue
                PlanNotifications.showNewEpisode(applicationContext, show)
                alerted += key
            }
            prefs.edit().putStringSet(KEY_ALERTED, alerted.sorted().takeLast(200).toSet()).apply()
        }
        return Result.success()
    }

    companion object {
        private const val NAME = "upcoming-daily"
        private const val PREFS = "plans"
        private const val KEY_ALERTED = "alerted_episodes"
        /** A bit under a day, so the daily run always refreshes. */
        private const val REFRESH_MS = 20L * 60 * 60 * 1000

        fun schedule(context: Context) {
            val now = LocalDateTime.now()
            var next = now.toLocalDate().atTime(10, 0)
            if (!next.isAfter(now)) next = next.plusDays(1)
            val request = PeriodicWorkRequestBuilder<UpcomingWorker>(1, TimeUnit.DAYS)
                .setInitialDelay(Duration.between(now, next).toMillis(), TimeUnit.MILLISECONDS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            val work = WorkManager.getInstance(context)
            work.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
            // And once now, so air dates show up without waiting for tomorrow (shows refreshed in the last
            // 20 hours are skipped, and alerts are never repeated).
            work.enqueueUniqueWork(
                "$NAME-now", ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<UpcomingWorker>()
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .build(),
            )
        }
    }
}
