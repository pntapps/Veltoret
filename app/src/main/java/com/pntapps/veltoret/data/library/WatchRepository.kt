package com.pntapps.veltoret.data.library

import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.WatchDao
import com.pntapps.veltoret.data.db.WatchStateEntity
import kotlinx.coroutines.flow.Flow

object WatchKeys {
    fun movie(id: Int) = "movie:$id"
    fun episode(showId: Int, season: Int, episode: Int) = "ep:$showId:$season:$episode"
    fun file(driveId: String) = "file:$driveId"

    fun forFile(file: MediaFileEntity): String = when {
        file.movieId != null -> movie(file.movieId)
        file.showId != null && file.season != null && file.episode != null -> episode(file.showId, file.season, file.episode)
        else -> file(file.driveId)
    }
}

class WatchRepository(private val dao: WatchDao) {

    fun observeAll(): Flow<List<WatchStateEntity>> = dao.observeAll()
    fun observe(key: String): Flow<WatchStateEntity?> = dao.observe(key)
    fun observeForShow(showId: Int): Flow<List<WatchStateEntity>> = dao.observeForShow(showId)
    suspend fun get(key: String): WatchStateEntity? = dao.get(key)

    /** Records playback progress; anything past 92% (or the last 2 minutes) counts as watched. */
    suspend fun savePosition(file: MediaFileEntity?, fallbackFileId: String, positionMs: Long, durationMs: Long) {
        if (durationMs <= 0) return
        val key = file?.let(WatchKeys::forFile) ?: WatchKeys.file(fallbackFileId)
        val finished = positionMs >= durationMs * 0.92 || durationMs - positionMs < 120_000
        val previous = dao.get(key)
        dao.upsert(
            WatchStateEntity(
                key = key,
                positionMs = if (finished) 0 else positionMs,
                durationMs = durationMs,
                watched = finished || (previous?.watched == true && positionMs < 60_000),
                lastWatchedAt = System.currentTimeMillis(),
                lastFileId = file?.driveId ?: fallbackFileId,
                movieId = file?.movieId,
                showId = file?.showId,
                season = file?.season,
                episode = file?.episode,
            )
        )
        // A multi-episode file (S01E01E02) also completes the episodes it spans.
        if (finished && file?.showId != null && file.season != null && file.episode != null && file.episodeEnd != null) {
            for (ep in (file.episode + 1)..file.episodeEnd) {
                setEpisodeWatched(file.showId, file.season, ep, true)
            }
        }
    }

    suspend fun setMovieWatched(movieId: Int, watched: Boolean) {
        val key = WatchKeys.movie(movieId)
        val prev = dao.get(key)
        dao.upsert(
            WatchStateEntity(
                key = key, positionMs = 0, durationMs = prev?.durationMs ?: 0, watched = watched,
                lastWatchedAt = if (watched) System.currentTimeMillis() else (prev?.lastWatchedAt ?: 0),
                lastFileId = prev?.lastFileId, movieId = movieId, showId = null, season = null, episode = null,
            )
        )
    }

    suspend fun setEpisodeWatched(showId: Int, season: Int, episode: Int, watched: Boolean) {
        setEpisodesWatched(showId, listOf(season to episode), watched)
    }

    suspend fun setEpisodesWatched(showId: Int, episodes: List<Pair<Int, Int>>, watched: Boolean) {
        val now = System.currentTimeMillis()
        val states = episodes.mapIndexed { i, (season, episode) ->
            val key = WatchKeys.episode(showId, season, episode)
            val prev = dao.get(key)
            WatchStateEntity(
                key = key, positionMs = 0, durationMs = prev?.durationMs ?: 0, watched = watched,
                // Keep a stable order so "Next Up" continues after the last episode in the batch.
                lastWatchedAt = if (watched) now + i else (prev?.lastWatchedAt ?: 0),
                lastFileId = prev?.lastFileId, movieId = null, showId = showId, season = season, episode = episode,
            )
        }
        dao.upsertAll(states)
    }

    suspend fun setFileWatched(file: MediaFileEntity, watched: Boolean) {
        when {
            file.movieId != null -> setMovieWatched(file.movieId, watched)
            file.showId != null && file.season != null && file.episode != null ->
                setEpisodeWatched(file.showId, file.season, file.episode, watched)
            else -> {
                val key = WatchKeys.file(file.driveId)
                dao.upsert(
                    WatchStateEntity(key, 0, file.durationMs, watched, System.currentTimeMillis(), file.driveId, null, null, null, null)
                )
            }
        }
    }
}
