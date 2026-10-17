package com.pntapps.veltoret.data.demo

import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.db.MatchState
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.library.WatchKeys
import com.pntapps.veltoret.data.db.WatchStateEntity
import kotlinx.coroutines.flow.first

/**
 * Debug-only sample library: real TMDB titles backed by placeholder "files", so contributors can
 * explore and design every screen without connecting Google Drive. Remove it from Settings by
 * removing the "Demo Library" account. Playback is not available for demo items.
 */
object DemoLibrary {
    const val EMAIL = "demo@veltoret.local"

    private val movies = listOf(
        693134 to 2160, 157336 to 2160, 27205 to 1080, 603 to 1080, 155 to 2160, 872585 to 2160,
        335984 to 2160, 680 to 1080, 438631 to 2160, 496243 to 1080, 129 to 1080, 324857 to 1080,
    )
    private val shows = listOf(1396 to listOf(1, 2), 66732 to listOf(1), 100088 to listOf(1), 94997 to listOf(1), 1399 to listOf(1))

    suspend fun seed(container: AppContainer, onProgress: (Float) -> Unit = {}) {
        val db = container.database
        val accounts = db.accountDao()
        val files = db.mediaFileDao()
        val catalog = db.catalogDao()
        val tmdb = container.tmdbRepository
        val watch = db.watchDao()
        val now = System.currentTimeMillis()
        val total = (movies.size + shows.size).toFloat()
        var done = 0

        accounts.upsert(AccountEntity(EMAIL, "Demo Library", null, now))
        accounts.insertFolder(LibraryFolderEntity(accountEmail = EMAIL, driveFolderId = "demo-movies", name = "Demo Movies", type = LibraryType.MOVIES))
        accounts.insertFolder(LibraryFolderEntity(accountEmail = EMAIL, driveFolderId = "demo-shows", name = "Demo TV Shows", type = LibraryType.SHOWS))
        val folders = accounts.folders().filter { it.accountEmail == EMAIL }
        val movieFolder = folders.first { it.type == LibraryType.MOVIES }.id
        val showFolder = folders.first { it.type == LibraryType.SHOWS }.id

        movies.forEachIndexed { i, (id, height) ->
            runCatching { tmdb.ensureMovie(id) }
            val title = catalog.movie(id)?.title ?: "Movie $id"
            files.upsert(
                listOf(
                    file("demo-m-$id", movieFolder, "${title.replace(' ', '.')}.${if (height > 2000) "2160p.HDR.HEVC.Atmos" else "1080p.x264.DTS"}.mkv",
                        MediaKind.MOVIE, height, movieId = id, added = now - i * 3_600_000L)
                )
            )
            onProgress(++done / total)
        }

        shows.forEachIndexed { i, (id, seasons) ->
            runCatching { tmdb.ensureShow(id, seasons.toSet()) }
            val episodes = catalog.observeEpisodes(id).first().filter { it.seasonNumber in seasons }
            files.upsert(
                episodes.groupBy { it.seasonNumber }.flatMap { (_, eps) -> eps.take(8) }.map { ep ->
                    file(
                        "demo-e-$id-${ep.seasonNumber}-${ep.episodeNumber}", showFolder,
                        "S%02dE%02d.1080p.mkv".format(ep.seasonNumber, ep.episodeNumber),
                        MediaKind.EPISODE, 1080, showId = id, season = ep.seasonNumber, episode = ep.episodeNumber,
                        added = now - i * 7_200_000L,
                    )
                }
            )
            onProgress(++done / total)
        }

        // Some viewing history so Continue Watching, Next Up and progress bars have something to show.
        fun ep(show: Int, s: Int, e: Int, watched: Boolean, pos: Long, ago: Long) = WatchStateEntity(
            WatchKeys.episode(show, s, e), pos, 2_820_000, watched, now - ago, "demo-e-$show-$s-$e", null, show, s, e,
        )
        watch.upsertAll(
            listOf(
                WatchStateEntity(WatchKeys.movie(157336), 4_200_000, 10_140_000, false, now - 60_000, "demo-m-157336", 157336, null, null, null),
                WatchStateEntity(WatchKeys.movie(155), 0, 9_120_000, true, now - 86_400_000, "demo-m-155", 155, null, null, null),
                WatchStateEntity(WatchKeys.movie(27205), 2_100_000, 8_880_000, false, now - 3_600_000, "demo-m-27205", 27205, null, null, null),
                ep(1396, 1, 1, true, 0, 9_000_000), ep(1396, 1, 2, true, 0, 8_000_000), ep(1396, 1, 3, true, 0, 7_000_000),
                ep(1396, 1, 4, false, 1_300_000, 120_000),
                ep(66732, 1, 1, true, 0, 50_000_000), ep(66732, 1, 2, true, 0, 49_000_000),
                ep(100088, 1, 1, true, 0, 20_000_000),
            )
        )
        container.settings.setOnboardingComplete(true)
    }

    private fun file(
        id: String,
        folder: Long,
        name: String,
        kind: MediaKind,
        height: Int,
        movieId: Int? = null,
        showId: Int? = null,
        season: Int? = null,
        episode: Int? = null,
        added: Long,
    ) = MediaFileEntity(
        driveId = id, accountEmail = EMAIL, libraryFolderId = folder, name = name, parentId = "demo", relativePath = "",
        sizeBytes = if (height > 2000) 24_000_000_000 else 4_300_000_000, modifiedTime = null, mimeType = "video/x-matroska",
        durationMs = if (kind == MediaKind.MOVIE) 8_400_000 else 2_820_000, width = height * 16 / 9, height = height,
        kind = kind, parsedTitle = "", parsedYear = null, season = season, episode = episode, episodeEnd = null,
        movieId = movieId, showId = showId, matchState = MatchState.MATCHED, addedAt = added,
    )
}
