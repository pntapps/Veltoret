package com.pntapps.veltoret.ui.library

import com.pntapps.veltoret.ui.util.rememberOnline
import androidx.compose.material.icons.rounded.CloudOff
import com.pntapps.veltoret.ui.util.gutter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Sort
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.data.db.progress
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.ui.components.EmptyState
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.PosterCard
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.SelectChip
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.home.PosterItem
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.SearchRoute
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.navigation.UnmatchedRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.appViewModel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

enum class LibraryFilter(val label: String) {
    All("All"), Unwatched("Unwatched"), InProgress("In progress"), Watched("Watched"), UltraHd("4K")
}

enum class LibrarySort(val label: String) { Recent("Recently added"), Title("Title"), Year("Release year"), Rating("Rating") }

/** A place titles are stored: an account email, [LocalStorage.ACCOUNT] or "smb://host". */
data class LibrarySource(val id: String, val label: String)

data class LibraryUiState(
    val loading: Boolean = true,
    val items: List<PosterItem> = emptyList(),
    val total: Int = 0,
    val genres: List<String> = emptyList(),
    val filter: LibraryFilter = LibraryFilter.All,
    val genre: String? = null,
    val sort: LibrarySort = LibrarySort.Recent,
    val unmatched: Int = 0,
    /** Sources to filter by; empty when there's only one (or offline, where only device copies show). */
    val sources: List<LibrarySource> = emptyList(),
    /** The chosen source, or null for all of them. */
    val source: String? = null,
)

private data class Controls(val filter: LibraryFilter, val genre: String?, val sort: LibrarySort, val source: String? = null)

class LibraryEntry(
    val item: PosterItem,
    val added: Long,
    val year: Int,
    val rating: Double,
    val genres: List<String>,
    val status: LibraryFilter,
    val uhd: Boolean,
    /** Sources holding a copy of the movie or any episode of the show. */
    val sources: Set<String>,
)

abstract class LibraryViewModel : ViewModel() {
    private val controls = MutableStateFlow(Controls(LibraryFilter.All, null, LibrarySort.Recent))
    abstract val state: StateFlow<LibraryUiState>

    fun setFilter(f: LibraryFilter) { controls.value = controls.value.copy(filter = f) }
    fun setGenre(g: String?) { controls.value = controls.value.copy(genre = g) }
    fun setSort(s: LibrarySort) { controls.value = controls.value.copy(sort = s) }
    fun setSource(source: String?) { controls.value = controls.value.copy(source = source) }

    protected fun build(
        entriesFlow: Flow<List<LibraryEntry>>,
        unmatched: Flow<Int>,
        accounts: Flow<List<AccountEntity>>,
        online: Flow<Boolean>,
    ): StateFlow<LibraryUiState> =
        combine(entriesFlow, controls, unmatched, accounts, online) { entries, c, unmatchedCount, accountList, isOnline ->
            // Device first, then Google accounts, then network servers; only sources that hold something.
            val present = entries.flatMapTo(HashSet()) { it.sources }
            val sources = if (!isOnline) emptyList() else accountList
                .filter { it.email in present }
                .sortedBy { if (LocalStorage.isLocal(it.email)) 0 else if (SmbPath.isSmb(it.email)) 2 else 1 }
                .map { LibrarySource(it.email, if (LocalStorage.isLocal(it.email)) LocalStorage.DISPLAY_NAME else if (SmbPath.isSmb(it.email)) it.displayName else it.email) }
                .takeIf { it.size > 1 }.orEmpty()
            // A source that's gone (removed, or offline) means all of them.
            val source = c.source?.takeIf { id -> sources.any { it.id == id } }
            val filtered = entries.filter { e ->
                (source == null || source in e.sources) && (c.genre == null || c.genre in e.genres) && when (c.filter) {
                    LibraryFilter.All -> true
                    LibraryFilter.UltraHd -> e.uhd
                    else -> e.status == c.filter
                }
            }
            val sorted = when (c.sort) {
                LibrarySort.Recent -> filtered.sortedByDescending { it.added }
                LibrarySort.Title -> filtered.sortedBy { it.item.title.removePrefix("The ").lowercase() }
                LibrarySort.Year -> filtered.sortedByDescending { it.year }
                LibrarySort.Rating -> filtered.sortedByDescending { it.rating }
            }
            LibraryUiState(
                loading = false,
                items = sorted.map { it.item },
                total = entries.size,
                genres = entries.flatMap { it.genres }.groupingBy { it }.eachCount().entries.sortedByDescending { it.value }.map { it.key },
                filter = c.filter,
                genre = c.genre,
                sort = c.sort,
                unmatched = unmatchedCount,
                sources = sources,
                source = source,
            )
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), LibraryUiState())
}

class MoviesViewModel(container: AppContainer) : LibraryViewModel() {
    override val state = build(
        combine(container.libraryRepository.movies(), container.watchRepository.observeAll(), container.libraryRepository.movieSources()) { movies, states, sourceRows ->
            val byKey = states.associateBy { it.key }
            val sourcesByMovie = sourceRows.groupBy({ it.titleId }, { it.accountEmail }).mapValues { it.value.toSet() }
            movies.map { row ->
                val m = row.movie
                val st = byKey["movie:${m.tmdbId}"]
                val status = when {
                    st?.watched == true -> LibraryFilter.Watched
                    st != null && st.positionMs > 30_000 -> LibraryFilter.InProgress
                    else -> LibraryFilter.Unwatched
                }
                LibraryEntry(
                    PosterItem(
                        m.tmdbId, false, m.title,
                        listOfNotNull(m.year?.toString(), Format.runtime(m.runtimeMin)).joinToString(" · "),
                        TmdbImages.poster(m.posterPath),
                        progress = st?.takeIf { status == LibraryFilter.InProgress }?.progress,
                        watched = status == LibraryFilter.Watched,
                    ),
                    row.addedAt, m.year ?: 0, m.rating, m.genres.split(',').filter { it.isNotBlank() }, status, row.maxHeight >= 1600,
                    sourcesByMovie[m.tmdbId].orEmpty(),
                )
            }
        },
        container.libraryRepository.unmatched().map { list -> list.count { it.kind == MediaKind.MOVIE } },
        container.accountRepository.observeAccounts(),
        container.connectivity.online,
    )
}

class ShowsViewModel(container: AppContainer) : LibraryViewModel() {
    override val state = build(
        combine(container.libraryRepository.shows(), container.watchRepository.observeAll(), container.libraryRepository.episodeFiles()) { shows, states, files ->
            val watchedByShow = states.filter { it.watched && it.showId != null }.groupBy { it.showId!! }
                .mapValues { (_, list) -> list.mapTo(HashSet()) { it.season to it.episode } }
            val uhdShows = files.filter { it.height >= 1600 }.mapNotNullTo(HashSet()) { it.showId }
            val sourcesByShow = files.filter { it.showId != null }.groupBy({ it.showId!! }, { it.accountEmail }).mapValues { it.value.toSet() }
            shows.map { row ->
                val s = row.show
                val watched = watchedByShow[s.tmdbId].orEmpty()
                val status = when {
                    watched.isEmpty() -> LibraryFilter.Unwatched
                    watched.size >= row.availableEpisodes -> LibraryFilter.Watched
                    else -> LibraryFilter.InProgress
                }
                val subtitle = when (status) {
                    LibraryFilter.InProgress -> "${watched.size} of ${row.availableEpisodes} watched"
                    else -> "${row.availableEpisodes} episode${if (row.availableEpisodes == 1) "" else "s"}"
                }
                LibraryEntry(
                    PosterItem(
                        s.tmdbId, true, s.name, subtitle, TmdbImages.poster(s.posterPath),
                        progress = if (status == LibraryFilter.InProgress) watched.size.toFloat() / row.availableEpisodes else null,
                        watched = status == LibraryFilter.Watched,
                    ),
                    row.addedAt, s.year ?: 0, s.rating, s.genres.split(',').filter { it.isNotBlank() }, status, s.tmdbId in uhdShows,
                    sourcesByShow[s.tmdbId].orEmpty(),
                )
            }
        },
        container.libraryRepository.unmatched().map { list -> list.count { it.kind == MediaKind.EPISODE } },
        container.accountRepository.observeAccounts(),
        container.connectivity.online,
    )
}

@Composable
fun MoviesScreen(navigator: Navigator) {
    val vm = appViewModel { MoviesViewModel(it) }
    LibraryGridScreen("Movies", Icons.Rounded.Movie, vm, navigator) { navigator.navigate(MovieRoute(it.id)) }
}

@Composable
fun ShowsScreen(navigator: Navigator) {
    val vm = appViewModel { ShowsViewModel(it) }
    LibraryGridScreen("TV Shows", Icons.Rounded.LiveTv, vm, navigator) { navigator.navigate(ShowRoute(it.id)) }
}

@Composable
private fun LibraryGridScreen(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    vm: LibraryViewModel,
    navigator: Navigator,
    onOpen: (PosterItem) -> Unit,
) {
    val state by vm.state.collectAsStateWithLifecycle()
    val width = LocalWidthClass.current
    val online = rememberOnline()
    var sortOpen by remember { mutableStateOf(false) }
    var genreOpen by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            title = title,
            subtitle = when {
                state.loading -> null
                state.source != null -> "${state.items.size} of ${state.total} titles · ${state.sources.first { it.id == state.source }.label}"
                else -> "${state.total} title${if (state.total == 1) "" else "s"}"
            },
        ) {
            VIconButton(Icons.Rounded.Search, "Search", { navigator.navigate(SearchRoute) })
            Box {
                VIconButton(Icons.AutoMirrored.Rounded.Sort, "Sort", { sortOpen = true })
                DropdownMenu(sortOpen, { sortOpen = false }, containerColor = VColors.SurfaceHigh) {
                    LibrarySort.entries.forEach { s ->
                        DropdownMenuItem(
                            text = { Text(s.label, color = if (s == state.sort) VColors.Amber else VColors.Text) },
                            onClick = { vm.setSort(s); sortOpen = false },
                        )
                    }
                    // Source filter: only what's stored on one account, this device or one server.
                    if (state.sources.isNotEmpty()) {
                        HorizontalDivider(Modifier.padding(vertical = 4.dp), color = VColors.Outline)
                        Text(
                            "SOURCE", style = MaterialTheme.typography.labelSmall, color = VColors.TextMuted,
                            modifier = Modifier.padding(start = 12.dp, top = 6.dp, bottom = 2.dp),
                        )
                        (listOf<LibrarySource?>(null) + state.sources).forEach { src ->
                            DropdownMenuItem(
                                text = { Text(src?.label ?: "All sources", color = if (src?.id == state.source) VColors.Amber else VColors.Text) },
                                onClick = { vm.setSource(src?.id); sortOpen = false },
                            )
                        }
                    }
                }
            }
        }

        when {
            state.loading -> LoadingBox()
            state.total == 0 && !online -> EmptyState(
                Icons.Rounded.CloudOff, "No ${title.lowercase()} on this device",
                "Your ${title.lowercase()} are on Google Drive. Connect to the internet to watch them, " +
                    "or add a folder from this device in Settings.",
            )
            state.total == 0 && state.unmatched == 0 -> EmptyState(
                icon, "No ${title.lowercase()} yet",
                "Add a ${title.lowercase()} folder in Settings, or wait for the library scan to finish.",
            )
            else -> LazyVerticalGrid(
                columns = GridCells.Adaptive(
                    when (width) {
                        WidthClass.Compact -> 108.dp
                        WidthClass.Medium -> 140.dp
                        WidthClass.Expanded -> 156.dp
                    }
                ),
                contentPadding = PaddingValues(start = gutter(), end = gutter(), bottom = 32.dp),
                horizontalArrangement = Arrangement.spacedBy(if (width == WidthClass.Compact) 14.dp else 20.dp),
                verticalArrangement = Arrangement.spacedBy(if (width == WidthClass.Compact) 20.dp else 28.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "chips") {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(bottom = 4.dp)) {
                        if (state.unmatched > 0 && online) {
                            item {
                                SelectChip("${state.unmatched} unmatched", false, { navigator.navigate(UnmatchedRoute) }, icon = Icons.Rounded.ErrorOutline)
                            }
                        }
                        items(LibraryFilter.entries) { f ->
                            SelectChip(f.label, f == state.filter, { vm.setFilter(f) })
                        }
                        if (state.genres.isNotEmpty()) {
                            item {
                                Box {
                                    SelectChip(state.genre ?: "Genre", state.genre != null, { genreOpen = true }, icon = Icons.Rounded.Tune)
                                    DropdownMenu(genreOpen, { genreOpen = false }, containerColor = VColors.SurfaceHigh) {
                                        DropdownMenuItem(text = { Text("All genres") }, onClick = { vm.setGenre(null); genreOpen = false })
                                        state.genres.forEach { g ->
                                            DropdownMenuItem(
                                                text = { Text(g, color = if (g == state.genre) VColors.Amber else VColors.Text) },
                                                onClick = { vm.setGenre(g); genreOpen = false },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (state.items.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Text("Nothing matches these filters.", color = VColors.TextMuted, modifier = Modifier.padding(vertical = 40.dp))
                    }
                }
                items(state.items, key = { it.id }) { item ->
                    PosterCard(
                        title = item.title,
                        subtitle = item.subtitle,
                        imageUrl = item.posterUrl,
                        onClick = { onOpen(item) },
                        progress = item.progress,
                        watched = item.watched,
                    )
                }
            }
        }
    }
}

