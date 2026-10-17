package com.pntapps.veltoret.data.library

import com.pntapps.veltoret.data.db.MediaFileDao
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.WatchDao
import com.pntapps.veltoret.data.db.WatchStateEntity

data class EpisodeTarget(
    val file: MediaFileEntity,
    val state: WatchStateEntity?,
    /** True when this continues a partly watched episode rather than starting a new one. */
    val resuming: Boolean,
    /** True when nothing of the show has been watched yet. */
    val fresh: Boolean,
)

object PlayTargets {

    /**
     * Picks what "Play" should start for a show: the most recent in-progress episode if it is newer
     * than anything finished, otherwise the first unwatched episode after the last finished one.
     */
    fun nextEpisode(files: List<MediaFileEntity>, states: List<WatchStateEntity>): EpisodeTarget? {
        val playable = files
            .filter { it.season != null && it.episode != null }
            .sortedWith(compareBy({ if (it.season == 0) Int.MAX_VALUE else it.season }, { it.episode }))
            .distinctBy { it.season to it.episode }
        if (playable.isEmpty()) return null
        val byKey = states.associateBy { it.key }
        fun stateOf(f: MediaFileEntity) = byKey[WatchKeys.forFile(f)]

        val lastWatched = states.filter { it.watched && it.season != null }.maxByOrNull { it.lastWatchedAt }
        val inProgress = states.filter { !it.watched && it.positionMs > 30_000 && it.season != null }.maxByOrNull { it.lastWatchedAt }

        if (inProgress != null && (lastWatched == null || inProgress.lastWatchedAt > lastWatched.lastWatchedAt)) {
            playable.firstOrNull { it.season == inProgress.season && it.episode == inProgress.episode }?.let {
                return EpisodeTarget(it, inProgress, resuming = true, fresh = false)
            }
        }
        if (lastWatched != null) {
            val lastSeason = lastWatched.season!!
            val lastEpisode = lastWatched.episode ?: 0
            val next = playable.firstOrNull { f ->
                val s = f.season!!
                val after = if (lastSeason == 0) s == 0 && f.episode!! > lastEpisode
                else s > lastSeason && s != 0 || (s == lastSeason && f.episode!! > lastEpisode)
                after && stateOf(f)?.watched != true
            }
            return next?.let { EpisodeTarget(it, stateOf(it), resuming = false, fresh = false) }
        }
        val first = playable.firstOrNull { it.season != 0 } ?: playable.first()
        return EpisodeTarget(first, stateOf(first), resuming = false, fresh = true)
    }
}

/** Resolves what a "Play" button should start. */
class PlaybackResolver(
    private val files: MediaFileDao,
    private val watch: WatchDao,
    private val connectivity: com.pntapps.veltoret.data.net.Connectivity,
) {
    /** Best version of a movie: a device copy first, then highest resolution and largest file. */
    suspend fun movieFile(movieId: Int): MediaFileEntity? = playable(files.forMovie(movieId)).firstOrNull()

    suspend fun showTarget(showId: Int): EpisodeTarget? =
        PlayTargets.nextEpisode(playable(files.forShow(showId)), watch.forShow(showId))

    /** What "Play" on a show starts: the next episode, or episode 1 again once everything is watched. */
    suspend fun showPlayTarget(showId: Int): EpisodeTarget? =
        showTarget(showId) ?: PlayTargets.nextEpisode(playable(files.forShow(showId)), emptyList())

    /** Offline, only device copies can play. */
    private fun playable(list: List<MediaFileEntity>) =
        if (connectivity.isOnline) list else list.filter { com.pntapps.veltoret.data.storage.LocalStorage.isLocal(it.accountEmail) }
}
