package com.pntapps.veltoret.ui.details

import com.pntapps.veltoret.ui.util.rememberOnline
import com.pntapps.veltoret.ui.util.canPlayNow
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.CreditEntity
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.db.MovieEntity
import com.pntapps.veltoret.data.db.WatchStateEntity
import com.pntapps.veltoret.data.db.progress
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.library.WatchKeys
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.MetaLine
import com.pntapps.veltoret.ui.components.RatingText
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VProgress
import com.pntapps.veltoret.ui.home.PosterItem
import com.pntapps.veltoret.ui.navigation.FixMatchRoute
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.gutter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class MovieDetailState(
    val loading: Boolean = true,
    val movie: MovieEntity? = null,
    val files: List<MediaFileEntity> = emptyList(),
    val cast: List<CreditEntity> = emptyList(),
    val watch: WatchStateEntity? = null,
    /** "More like this": TMDB's recommendations that are in the library. */
    val related: List<PosterItem> = emptyList(),
)

class MovieDetailViewModel(private val container: AppContainer, private val id: Int) : ViewModel() {
    private val library = container.libraryRepository

    private val related = combine(library.relatedMovies(id), container.watchRepository.observeAll()) { rows, states ->
        val statesByKey = states.associateBy { it.key }
        rows.map { row ->
            val st = statesByKey[WatchKeys.movie(row.movie.tmdbId)]
            PosterItem(
                id = row.movie.tmdbId, isShow = false, title = row.movie.title,
                subtitle = listOfNotNull(row.movie.year?.toString(), Format.runtime(row.movie.runtimeMin)).joinToString(" · "),
                posterUrl = TmdbImages.poster(row.movie.posterPath),
                progress = st?.takeIf { !it.watched && it.positionMs > 0 }?.progress,
                watched = st?.watched == true,
            )
        }
    }

    val state: StateFlow<MovieDetailState> = combine(
        library.movie(id), library.movieFiles(id), library.credits("movie", id), container.watchRepository.observe(WatchKeys.movie(id)), related,
    ) { movie, files, cast, watch, related -> MovieDetailState(false, movie, files, cast, watch, related) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), MovieDetailState())

    private val _trailer = MutableStateFlow<String?>(null)
    /** YouTube id of the trailer, once TMDB answers; null when there is none (or offline). */
    val trailer: StateFlow<String?> = _trailer

    init {
        // Titles matched before "More like this" existed (or a month ago) get their list now rather than at the next scan.
        if (container.connectivity.isOnline) viewModelScope.launch {
            runCatching { container.tmdbRepository.ensureRecommendations("movie", id) }
        }
        if (container.connectivity.isOnline) viewModelScope.launch {
            _trailer.value = runCatching { container.tmdbRepository.trailer("movie", id) }.getOrNull()
        }
    }

    fun setWatched(watched: Boolean) {
        viewModelScope.launch { container.watchRepository.setMovieWatched(id, watched) }
    }
}

@Composable
fun MovieDetailScreen(id: Int, navigator: Navigator) {
    val vm = appViewModel("movie-$id") { MovieDetailViewModel(it, id) }
    val state by vm.state.collectAsStateWithLifecycle()
    val trailer by vm.trailer.collectAsStateWithLifecycle()
    val online = rememberOnline()
    val context = LocalContext.current
    val wide = LocalWidthClass.current != WidthClass.Compact
    var menuOpen by remember { mutableStateOf(false) }

    val movie = state.movie
    if (movie == null) {
        LoadingBox()
        // The movie disappeared (e.g. its files were re-matched elsewhere): leave the page.
        LaunchedEffect(state.loading) { if (!state.loading) navigator.back() }
        return
    }
    val best = state.files.firstOrNull()
    val watch = state.watch
    val resumable = watch != null && !watch.watched && watch.positionMs > 30_000

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp)) {
        item("header") {
            DetailHeader(
                title = movie.title,
                backdropUrl = TmdbImages.backdrop(movie.backdropPath),
                posterUrl = TmdbImages.poster(movie.posterPath, "w500"),
                onBack = navigator::back,
            ) {
                DetailTitle(movie.title, movie.tagline)
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RatingText(movie.rating)
                    if (movie.rating > 0) Spacer(Modifier.width(12.dp))
                    MetaLine(listOf(movie.year?.toString(), movie.certification, Format.runtime(movie.runtimeMin)))
                }
                TagRow(
                    genres = movie.genres.split(',').filter { it.isNotBlank() },
                    quality = best?.let { FilenameParser.qualityTags(it.name, it.height) }.orEmpty().take(4),
                )
                Spacer(Modifier.height(20.dp))
                if (resumable) {
                    VProgress(watch.progress, Modifier.padding(bottom = 6.dp))
                    Text(Format.remaining(watch.positionMs, watch.durationMs), style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                    Spacer(Modifier.height(12.dp))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    VButton(
                        text = when {
                            resumable -> "Resume"
                            watch?.watched == true -> "Watch again"
                            else -> "Play"
                        },
                        onClick = { best?.let { context.playFile(it.driveId, it.accountEmail, fromStart = watch?.watched == true) } },
                        icon = if (watch?.watched == true) Icons.Rounded.Replay else Icons.Rounded.PlayArrow,
                        enabled = best != null && canPlayNow(best.accountEmail, online),
                        modifier = Modifier.weight(1f, fill = !wide),
                    )
                    VButton(
                        text = if (watch?.watched == true) "Watched" else "Mark watched",
                        onClick = { vm.setWatched(watch?.watched != true) },
                        icon = Icons.Rounded.Check,
                        style = if (watch?.watched == true) ButtonStyle.Secondary else ButtonStyle.Ghost,
                    )
                    // Play, Mark watched and More already fill the row at every width: a labelled button squeezed Play to "Pla".
                    trailer?.takeIf { online }?.let { TrailerButton(it, compact = true) }
                    Box {
                        VIconButton(Icons.Rounded.MoreVert, "More", { menuOpen = true }, size = 48.dp)
                        DropdownMenu(menuOpen, { menuOpen = false }, containerColor = VColors.SurfaceHigh) {
                            DropdownMenuItem(
                                text = { Text("Fix match") },
                                leadingIcon = { Icon(Icons.Rounded.Edit, null) },
                                onClick = {
                                    menuOpen = false
                                    navigator.navigate(FixMatchRoute(state.files.map { it.driveId }, MediaKind.MOVIE.name, movie.title))
                                },
                            )
                        }
                    }
                }
                Overview(movie.overview)
                CreditLine("Director", movie.director)
                CreditLine("Collection", movie.collectionName)
                CreditLine("Released", Format.date(movie.releaseDate))
            }
        }
        item("cast") { CastRow(state.cast) }
        item("files") {
            VersionsSection(state.files) { f -> context.playFile(f.driveId, f.accountEmail) }
        }
        item("related") { RelatedRow(state.related) { navigator.navigate(MovieRoute(it.id)) } }
        item("attribution") {
            Text(
                "Metadata and artwork from TMDB",
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextFaint,
                modifier = Modifier.padding(start = gutter(), top = 32.dp),
            )
        }
    }
}
