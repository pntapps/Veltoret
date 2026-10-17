package com.pntapps.veltoret.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.EpisodeEntity
import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MovieRow
import com.pntapps.veltoret.data.db.ShowRow
import com.pntapps.veltoret.data.db.WatchStateEntity
import com.pntapps.veltoret.data.db.progress
import com.pntapps.veltoret.data.library.PlayTargets
import com.pntapps.veltoret.data.library.ScanState
import com.pntapps.veltoret.data.library.SyncWorker
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.ui.util.Format
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

data class PosterItem(
    val id: Int,
    val isShow: Boolean,
    val title: String,
    val subtitle: String?,
    val posterUrl: String?,
    val progress: Float? = null,
    val watched: Boolean = false,
)

data class FeaturedItem(
    val id: Int,
    val isShow: Boolean,
    val title: String,
    val backdropUrl: String?,
    val meta: List<String?>,
    val overview: String,
    val rating: Double,
)

data class PlayItem(
    val fileId: String,
    val title: String,
    val subtitle: String,
    val imageUrl: String?,
    val progress: Float?,
    val caption: String?,
    val movieId: Int?,
    val showId: Int?,
)

/** Everything the TV home's header shows for the focused title. Keys: "movie:<id>" / "show:<id>". */
data class HeroInfo(
    val title: String,
    val backdropUrl: String?,
    val meta: List<String?>,
    val overview: String,
    val rating: Double,
    val genres: List<String>,
)

fun heroKey(isShow: Boolean, id: Int) = if (isShow) "show:$id" else "movie:$id"

data class HomeUiState(
    val loading: Boolean = true,
    val hasFolders: Boolean = true,
    val featured: List<FeaturedItem> = emptyList(),
    val continueWatching: List<PlayItem> = emptyList(),
    val nextUp: List<PlayItem> = emptyList(),
    val recentMovies: List<PosterItem> = emptyList(),
    val recentShows: List<PosterItem> = emptyList(),
    val topRated: List<PosterItem> = emptyList(),
    val genreRows: List<Pair<String, List<PosterItem>>> = emptyList(),
    val unmatchedCount: Int = 0,
    val archiveCount: Int = 0,
    val scan: ScanState = ScanState(),
    val heroes: Map<String, HeroInfo> = emptyMap(),
) {
    val isEmpty get() = recentMovies.isEmpty() && recentShows.isEmpty()
}

private data class LibrarySnapshot(
    val movies: List<MovieRow>,
    val shows: List<ShowRow>,
    val states: List<WatchStateEntity>,
    val episodeFiles: List<MediaFileEntity>,
    val episodes: List<EpisodeEntity>,
)

class HomeViewModel(private val container: AppContainer) : ViewModel() {

    private val library = container.libraryRepository

    private val snapshot = combine(
        library.movies(),
        library.shows(),
        container.watchRepository.observeAll(),
        library.episodeFiles(),
        library.allEpisodes(),
    ) { movies, shows, states, episodeFiles, episodes ->
        LibrarySnapshot(movies, shows, states, episodeFiles, episodes)
    }

    val state: StateFlow<HomeUiState> = combine(
        snapshot,
        combine(library.unmatched(), library.archives()) { unmatched, archives -> unmatched.size to archives.size },
        container.accountRepository.observeFolders(),
        container.scanner.state,
    ) { snap, counts, folders, scan -> build(snap, counts.first, folders, scan).copy(archiveCount = counts.second) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), HomeUiState())

    fun scanNow() = SyncWorker.runNow(container.appContext)

    suspend fun playTarget(isShow: Boolean, id: Int): String? =
        if (isShow) container.playback.showPlayTarget(id)?.file?.driveId else container.playback.movieFile(id)?.driveId

    private fun build(s: LibrarySnapshot, unmatched: Int, folders: List<LibraryFolderEntity>, scan: ScanState): HomeUiState {
        val statesByKey = s.states.associateBy { it.key }
        val moviesById = s.movies.associateBy { it.movie.tmdbId }
        val showsById = s.shows.associateBy { it.show.tmdbId }
        val episodesByKey = s.episodes.associateBy { Triple(it.showId, it.seasonNumber, it.episodeNumber) }

        fun moviePoster(row: MovieRow): PosterItem {
            val st = statesByKey["movie:${row.movie.tmdbId}"]
            return PosterItem(
                id = row.movie.tmdbId, isShow = false, title = row.movie.title,
                subtitle = listOfNotNull(row.movie.year?.toString(), Format.runtime(row.movie.runtimeMin)).joinToString(" · "),
                posterUrl = TmdbImages.poster(row.movie.posterPath),
                progress = st?.takeIf { !it.watched && it.positionMs > 0 }?.progress,
                watched = st?.watched == true,
            )
        }

        fun showPoster(row: ShowRow) = PosterItem(
            id = row.show.tmdbId, isShow = true, title = row.show.name,
            subtitle = "${row.availableEpisodes} episode${if (row.availableEpisodes == 1) "" else "s"}",
            posterUrl = TmdbImages.poster(row.show.posterPath),
        )

        // Continue watching: partly watched items, newest first.
        val continueWatching = s.states
            .filter { !it.watched && it.positionMs > 30_000 && it.lastFileId != null }
            .sortedByDescending { it.lastWatchedAt }
            .mapNotNull { st ->
                when {
                    st.movieId != null -> moviesById[st.movieId]?.let { row ->
                        PlayItem(
                            st.lastFileId!!, row.movie.title, Format.remaining(st.positionMs, st.durationMs),
                            TmdbImages.backdrop(row.movie.backdropPath, "w780"), st.progress, null, row.movie.tmdbId, null,
                        )
                    }
                    // Offline, episodeFiles only holds device copies, so this drops Drive-only episodes.
                    st.showId != null && s.episodeFiles.none { it.showId == st.showId && it.season == st.season && it.episode == st.episode } -> null
                    st.showId != null -> showsById[st.showId]?.let { row ->
                        val ep = episodesByKey[Triple(st.showId, st.season, st.episode)]
                        PlayItem(
                            st.lastFileId!!, row.show.name,
                            listOfNotNull(Format.episodeCode(st.season, st.episode), ep?.name).joinToString("  ·  "),
                            TmdbImages.still(ep?.stillPath, "w780") ?: TmdbImages.backdrop(row.show.backdropPath, "w780"),
                            st.progress, Format.remaining(st.positionMs, st.durationMs), null, row.show.tmdbId,
                        )
                    }
                    else -> null
                }
            }
            .take(20)

        // Next up: the next unwatched episode for every show the user has finished an episode of.
        val continuingShows = continueWatching.mapNotNull { it.showId }.toSet()
        val nextUp = s.episodeFiles.groupBy { it.showId!! }
            .filterKeys { it !in continuingShows }
            .mapNotNull { (showId, files) ->
                val showStates = s.states.filter { it.showId == showId }
                if (showStates.none { it.watched }) return@mapNotNull null
                val target = PlayTargets.nextEpisode(files, showStates) ?: return@mapNotNull null
                val row = showsById[showId] ?: return@mapNotNull null
                val f = target.file
                val ep = episodesByKey[Triple(showId, f.season, f.episode)]
                val lastActivity = showStates.maxOf { it.lastWatchedAt }
                lastActivity to PlayItem(
                    f.driveId, row.show.name,
                    listOfNotNull(Format.episodeCode(f.season, f.episode), ep?.name).joinToString("  ·  "),
                    TmdbImages.still(ep?.stillPath, "w780") ?: TmdbImages.backdrop(row.show.backdropPath, "w780"),
                    null, "Next", null, showId,
                )
            }
            .sortedByDescending { it.first }
            .map { it.second }
            .take(20)

        val recentMovies = s.movies.sortedByDescending { it.addedAt }.take(20).map(::moviePoster)
        val recentShows = s.shows.sortedByDescending { it.addedAt }.take(20).map(::showPoster)

        val featured = (s.movies.map { Triple(it.addedAt, false, it.movie.tmdbId) } + s.shows.map { Triple(it.addedAt, true, it.show.tmdbId) })
            .sortedByDescending { it.first }
            .mapNotNull { (_, isShow, id) ->
                if (isShow) showsById[id]?.show?.takeIf { it.backdropPath != null }?.let {
                    FeaturedItem(
                        id, true, it.name, TmdbImages.backdrop(it.backdropPath),
                        listOf(it.year?.toString(), it.certification, it.genres.split(',').firstOrNull(),
                            "${it.seasonCount} season${if (it.seasonCount == 1) "" else "s"}"),
                        it.overview, it.rating,
                    )
                } else moviesById[id]?.movie?.takeIf { it.backdropPath != null && statesByKey["movie:$id"]?.watched != true }?.let {
                    FeaturedItem(
                        id, false, it.title, TmdbImages.backdrop(it.backdropPath),
                        listOf(it.year?.toString(), it.certification, it.genres.split(',').firstOrNull(), Format.runtime(it.runtimeMin)),
                        it.overview, it.rating,
                    )
                }
            }
            // The hero is the first thing people see: prefer well-rated titles, but never leave it empty.
            .let { all -> all.filter { it.rating >= 5.5 }.ifEmpty { all } }
            .take(6)

        val topRated = (s.movies.map { it.movie.rating to moviePoster(it) } + s.shows.map { it.show.rating to showPoster(it) })
            .filter { it.first >= 7.0 }
            .sortedByDescending { it.first }
            .take(20)
            .map { it.second }

        val genreItems = s.movies.flatMap { row -> row.movie.genres.split(',').filter { it.isNotBlank() }.map { it to (row.movie.rating to moviePoster(row)) } } +
            s.shows.flatMap { row -> row.show.genres.split(',').filter { it.isNotBlank() }.map { it to (row.show.rating to showPoster(row)) } }
        val genreRows = genreItems.groupBy({ it.first }, { it.second })
            .filterValues { it.size >= 4 }
            .entries.sortedByDescending { it.value.size }
            .take(5)
            .map { (genre, items) -> genre to items.sortedByDescending { it.first }.map { it.second }.take(20) }

        return HomeUiState(
            loading = false,
            hasFolders = folders.isNotEmpty(),
            featured = featured,
            continueWatching = continueWatching,
            nextUp = nextUp,
            recentMovies = recentMovies,
            recentShows = recentShows,
            topRated = if (topRated.size >= 4) topRated else emptyList(),
            genreRows = genreRows,
            unmatchedCount = unmatched,
            scan = scan,
            heroes = s.movies.associate { row ->
                val m = row.movie
                heroKey(false, m.tmdbId) to HeroInfo(
                    m.title, TmdbImages.backdrop(m.backdropPath),
                    listOf(m.year?.toString(), m.certification, Format.runtime(m.runtimeMin)),
                    m.overview, m.rating, m.genres.split(',').filter { it.isNotBlank() },
                )
            } + s.shows.associate { row ->
                val sh = row.show
                heroKey(true, sh.tmdbId) to HeroInfo(
                    sh.name, TmdbImages.backdrop(sh.backdropPath),
                    listOf(sh.year?.toString(), sh.certification, "${sh.seasonCount} season${if (sh.seasonCount == 1) "" else "s"}"),
                    sh.overview, sh.rating, sh.genres.split(',').filter { it.isNotBlank() },
                )
            },
        )
    }
}
