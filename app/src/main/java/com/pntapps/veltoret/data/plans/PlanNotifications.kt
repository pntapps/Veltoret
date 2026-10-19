package com.pntapps.veltoret.data.plans

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.MainActivity
import com.pntapps.veltoret.R
import com.pntapps.veltoret.data.db.ReminderEntity
import com.pntapps.veltoret.data.db.ShowEntity
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.ui.util.Format
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Reminder and new-episode notifications: the title's backdrop as a big picture, its poster as the icon,
 * the amber accent, and actions to play or snooze. Artwork comes through Coil, so it's usually cached.
 */
object PlanNotifications {
    const val CHANNEL_REMINDERS = "reminders"
    const val CHANNEL_EPISODES = "new-episodes"
    private const val AMBER = 0xFFE8A33D.toInt()

    fun canPost(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_REMINDERS) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_REMINDERS, "Reminders", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "The movies and episodes you asked to be reminded about"
                }
            )
        }
        if (manager.getNotificationChannel(CHANNEL_EPISODES) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_EPISODES, "New episodes", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "When a show on your Watchlist airs a new episode"
                }
            )
        }
    }

    /** "Time for Dune: Part Two" with the backdrop, plus Play (when a copy can play now) and Snooze. */
    suspend fun showReminder(context: Context, container: AppContainer, r: ReminderEntity) {
        if (!canPost(context)) return
        ensureChannels(context)
        val catalog = container.database.catalogDao()
        val movie = if (r.mediaType == Plans.MOVIE) catalog.movie(r.mediaId) else null
        val show = if (r.mediaType == Plans.TV) catalog.show(r.mediaId) else null
        val episodeCode = if (r.season != null && r.episode != null) Format.episodeCode(r.season, r.episode) else null

        var season = r.season
        var episode = r.episode
        val playable: Boolean
        val title: String
        val text: String
        var picture: String? = null
        var poster: String? = null
        when {
            movie != null -> {
                title = "Time for ${movie.title}"
                text = listOfNotNull(movie.year?.toString(), movie.genres.split(',').firstOrNull()?.takeIf { it.isNotBlank() }, Format.runtime(movie.runtimeMin))
                    .joinToString(" · ")
                picture = TmdbImages.backdrop(movie.backdropPath, "w780")
                poster = TmdbImages.poster(movie.posterPath)
                playable = container.playback.movieFile(movie.tmdbId) != null
            }
            show != null && season != null && episode != null -> {
                val ep = catalog.episode(show.tmdbId, season, episode)
                title = "Time for ${show.name}"
                text = listOfNotNull(episodeCode, ep?.name?.takeIf { it.isNotBlank() }).joinToString("  ·  ")
                picture = TmdbImages.still(ep?.stillPath, "w780") ?: TmdbImages.backdrop(show.backdropPath, "w780")
                poster = TmdbImages.poster(show.posterPath)
                playable = container.playback.episodeFile(show.tmdbId, season, episode) != null
            }
            show != null -> {
                // A show reminder plays what "Play" on its page would: the next episode.
                val target = container.playback.showPlayTarget(show.tmdbId)
                season = target?.file?.season
                episode = target?.file?.episode
                val ep = if (season != null && episode != null) catalog.episode(show.tmdbId, season, episode) else null
                title = "Time for ${show.name}"
                text = if (target == null) "Your reminder" else listOfNotNull(
                    if (target.resuming) "Continue" else "Up next",
                    Format.episodeCode(season, episode).ifEmpty { null },
                    ep?.name?.takeIf { it.isNotBlank() },
                ).joinToString("  ·  ")
                picture = TmdbImages.still(ep?.stillPath, "w780") ?: TmdbImages.backdrop(show.backdropPath, "w780")
                poster = TmdbImages.poster(show.posterPath)
                playable = target != null
            }
            else -> {
                // The title left the library since the reminder was set.
                title = "Time for ${r.title}"
                text = "Your reminder"
                playable = false
            }
        }

        val notificationId = REMINDER_BASE + r.id.toInt()
        val open = OpenTarget(r.mediaType, r.mediaId, r.season, r.episode)
        val builder = base(context, CHANNEL_REMINDERS, R.drawable.ic_stat_reminder, title, text, picture, poster)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setSubText("Reminder")
            .setContentIntent(DeepLinks.pending(context, notificationId, open))
        if (playable && (movie != null || show != null)) {
            builder.addAction(R.drawable.ic_stat_play, "Play", DeepLinks.pending(context, notificationId, open.copy(season = season, episode = episode, play = true)))
        }
        builder.addAction(R.drawable.ic_stat_reminder, "Snooze 1 hour", ReminderReceiver.snoozeIntent(context, r, notificationId))
        notify(context, notificationId, builder)
    }

    /** "New episode of The Bear" on the day it airs. */
    suspend fun showNewEpisode(context: Context, show: ShowEntity) {
        if (!canPost(context)) return
        ensureChannels(context)
        val code = Format.episodeCode(show.nextEpisodeSeason, show.nextEpisodeNumber)
        val text = listOfNotNull(code.ifEmpty { null }, show.nextEpisodeName?.let { "“$it”" }, "out today").joinToString("  ·  ")
        val notificationId = EPISODE_BASE + show.tmdbId
        val builder = base(
            context, CHANNEL_EPISODES, R.drawable.ic_stat_new_episode, "New episode of ${show.name}", text,
            TmdbImages.backdrop(show.backdropPath, "w780"), TmdbImages.poster(show.posterPath),
        )
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .setSubText(show.network ?: "New episode")
            .setContentIntent(DeepLinks.pending(context, notificationId, OpenTarget(Plans.TV, show.tmdbId)))
        notify(context, notificationId, builder)
    }

    private suspend fun base(
        context: Context, channel: String, icon: Int, title: String, text: String, pictureUrl: String?, posterUrl: String?,
    ): NotificationCompat.Builder {
        val picture = pictureUrl?.let { bitmap(context, it) }
        val poster = posterUrl?.let { bitmap(context, it) }?.let(::squareTop)
        return NotificationCompat.Builder(context, channel)
            .setSmallIcon(icon)
            .setColor(AMBER)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setLargeIcon(poster)
            .setStyle(
                if (picture != null) NotificationCompat.BigPictureStyle()
                    .bigPicture(picture)
                    // Expanded, the backdrop takes over and the poster steps aside.
                    .bigLargeIcon(null as Bitmap?)
                    .setSummaryText(text)
                else NotificationCompat.BigTextStyle().bigText(text)
            )
    }

    @android.annotation.SuppressLint("MissingPermission") // checked in canPost
    private fun notify(context: Context, id: Int, builder: NotificationCompat.Builder) {
        NotificationManagerCompat.from(context).notify(id, builder.build())
    }

    fun cancel(context: Context, id: Int) = NotificationManagerCompat.from(context).cancel(id)

    /** Artwork for a notification, from Coil's cache when possible; null after a few seconds or on failure. */
    private suspend fun bitmap(context: Context, url: String): Bitmap? = withTimeoutOrNull(8_000) {
        val request = ImageRequest.Builder(context).data(url).allowHardware(false).build()
        (SingletonImageLoader.get(context).execute(request) as? SuccessResult)?.image?.toBitmap()
    }

    /** Posters are 2:3; the large icon is square, so keep the top square (where titles and faces usually are). */
    private fun squareTop(b: Bitmap): Bitmap {
        val side = minOf(b.width, b.height)
        return Bitmap.createBitmap(b, (b.width - side) / 2, 0, side, side)
    }

    private const val REMINDER_BASE = 0x4E000000
    private const val EPISODE_BASE = 0x4F000000
}

/** Intents that open Veltoret on a title (and maybe start playing it), from notifications. */
object DeepLinks {
    private const val EXTRA_TYPE = "veltoret.open.type"
    private const val EXTRA_ID = "veltoret.open.id"
    private const val EXTRA_SEASON = "veltoret.open.season"
    private const val EXTRA_EPISODE = "veltoret.open.episode"
    private const val EXTRA_PLAY = "veltoret.open.play"
    private const val EXTRA_NOTIFICATION = "veltoret.open.notification"

    /**
     * Opens [target] and dismisses notification [notificationId]. Each target gets its own data URI:
     * PendingIntents that differ only in extras are one PendingIntent, so one reminder's Play could open another's title.
     */
    fun pending(context: Context, notificationId: Int, target: OpenTarget): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .setData(android.net.Uri.parse("veltoret://open/$notificationId/${target.mediaType}/${target.mediaId}/${target.season}/${target.episode}/${target.play}"))
            .putExtra(EXTRA_TYPE, target.mediaType)
            .putExtra(EXTRA_ID, target.mediaId)
            .putExtra(EXTRA_PLAY, target.play)
            .putExtra(EXTRA_NOTIFICATION, notificationId)
        target.season?.let { intent.putExtra(EXTRA_SEASON, it) }
        target.episode?.let { intent.putExtra(EXTRA_EPISODE, it) }
        return PendingIntent.getActivity(context, notificationId, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /**
     * The title a notification asked for, or null. Each intent is handled once: relaunching from Recents
     * redelivers the original intent, which replayed the title, so history launches are ignored and the
     * extras are removed. Also dismisses the notification (action buttons don't auto-cancel).
     */
    fun consume(context: Context, intent: Intent?): OpenTarget? {
        if (intent == null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        val target = parse(intent) ?: return null
        intent.getIntExtra(EXTRA_NOTIFICATION, 0).takeIf { it != 0 }?.let { PlanNotifications.cancel(context, it) }
        listOf(EXTRA_TYPE, EXTRA_ID, EXTRA_SEASON, EXTRA_EPISODE, EXTRA_PLAY, EXTRA_NOTIFICATION).forEach(intent::removeExtra)
        return target
    }

    private fun parse(intent: Intent?): OpenTarget? {
        val type = intent?.getStringExtra(EXTRA_TYPE) ?: return null
        val id = intent.getIntExtra(EXTRA_ID, -1).takeIf { it >= 0 } ?: return null
        return OpenTarget(
            type, id,
            season = intent.getIntExtra(EXTRA_SEASON, -1).takeIf { it >= 0 },
            episode = intent.getIntExtra(EXTRA_EPISODE, -1).takeIf { it >= 0 },
            play = intent.getBooleanExtra(EXTRA_PLAY, false),
        )
    }
}
