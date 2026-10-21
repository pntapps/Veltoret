package com.pntapps.veltoret.ui.fixmatch

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.data.tmdb.TmdbRepository
import com.pntapps.veltoret.ui.components.CardShape
import com.pntapps.veltoret.ui.components.EmptyState
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.Panel
import com.pntapps.veltoret.ui.components.PosterShape
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.SelectChip
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.navigation.FixMatchRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.gutter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import com.pntapps.veltoret.data.library.SyncWorker
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.material3.TextButton

// ---------- Unmatched list ----------

data class UnmatchedGroup(val kind: MediaKind, val title: String, val files: List<MediaFileEntity>)

class UnmatchedViewModel(private val container: AppContainer) : ViewModel() {
    val groups: StateFlow<List<UnmatchedGroup>?> = container.libraryRepository.unmatched()
        .map { it.grouped() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val ignored: StateFlow<List<UnmatchedGroup>> = container.libraryRepository.ignored()
        .map { it.grouped() }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun ignore(group: UnmatchedGroup) = viewModelScope.launch { container.scanner.ignore(group.files.map { it.driveId }) }

    fun restore(group: UnmatchedGroup) = viewModelScope.launch {
        container.scanner.restore(group.files.map { it.driveId })
        SyncWorker.runNow(container.appContext)
    }

    private fun List<MediaFileEntity>.grouped() =
        groupBy { it.kind to it.parsedTitle.ifBlank { it.name } }
            .map { (key, list) -> UnmatchedGroup(key.first, key.second, list) }
            .sortedBy { it.title.lowercase() }
}

@Composable
fun UnmatchedScreen(navigator: Navigator) {
    val vm = appViewModel { UnmatchedViewModel(it) }
    val groups by vm.groups.collectAsStateWithLifecycle()
    val ignored by vm.ignored.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Needs a match", subtitle = "Files we couldn't identify automatically", onBack = navigator::back)
        val list = groups
        when {
            list == null -> LoadingBox()
            list.isEmpty() && ignored.isEmpty() -> EmptyState(Icons.Rounded.CheckCircle, "All matched", "Every file in your library has been identified.")
            else -> LazyVerticalGrid(
                columns = GridCells.Adaptive(420.dp),
                contentPadding = PaddingValues(horizontal = gutter(), vertical = 20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (list.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Text("Everything else is matched.", style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
                    }
                }
                items(list, key = { it.kind.name + it.title }) { g ->
                    Panel(
                        Modifier
                            .clip(CardShape)
                            .clickable {
                                navigator.navigate(FixMatchRoute(g.files.map { it.driveId }, g.kind.name, g.title))
                            },
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(g.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    "${if (g.kind == MediaKind.MOVIE) "Movie" else "TV"} · ${g.files.size} file${if (g.files.size == 1) "" else "s"}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = VColors.Amber,
                                )
                                Text(
                                    g.files.first().let { f -> listOf(f.relativePath, f.name).filter { it.isNotBlank() }.joinToString("/") },
                                    style = MaterialTheme.typography.bodySmall,
                                    color = VColors.TextMuted,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            TextButton({ vm.ignore(g) }) { Text("Ignore", color = VColors.TextMuted) }
                            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = VColors.TextMuted)
                        }
                    }
                }
                if (ignored.isNotEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Column(Modifier.padding(top = 18.dp)) {
                            Text("Ignored", style = MaterialTheme.typography.titleLarge)
                            Text(
                                "Kept out of your library. Restore one to match it again.",
                                style = MaterialTheme.typography.bodySmall,
                                color = VColors.TextMuted,
                            )
                        }
                    }
                    items(ignored, key = { "ignored-" + it.kind.name + it.title }) { g ->
                        Panel {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text(g.title, style = MaterialTheme.typography.titleSmall, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(
                                        g.files.first().name,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = VColors.TextFaint,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                                TextButton({ vm.restore(g) }) { Text("Restore", color = VColors.Amber) }
                            }
                        }
                    }
                }
            }
        }
    }
}

// ---------- Fix match ----------

data class MatchCandidate(val id: Int, val title: String, val year: Int?, val overview: String, val posterUrl: String?)

data class FixMatchState(
    val kind: MediaKind,
    val query: String,
    val searching: Boolean = false,
    val results: List<MatchCandidate> = emptyList(),
    val applyingId: Int? = null,
    val error: String? = null,
    val done: Boolean = false,
)

class FixMatchViewModel(private val container: AppContainer, private val route: FixMatchRoute) : ViewModel() {
    private val _state = MutableStateFlow(FixMatchState(MediaKind.valueOf(route.kind), route.query))
    val state = _state.asStateFlow()

    init { search() }

    fun setQuery(q: String) = _state.update { it.copy(query = q) }
    fun setKind(kind: MediaKind) {
        _state.update { it.copy(kind = kind) }
        search()
    }

    fun search() {
        val s = _state.value
        if (s.query.isBlank()) return
        _state.update { it.copy(searching = true, error = null) }
        viewModelScope.launch {
            try {
                val (title, year) = splitYear(s.query)
                val results = if (s.kind == MediaKind.MOVIE) {
                    container.tmdbRepository.searchMovies(title, year).map {
                        MatchCandidate(it.id, it.title, TmdbRepository.yearOf(it.releaseDate), it.overview.orEmpty(), TmdbImages.poster(it.posterPath, "w185"))
                    }
                } else {
                    container.tmdbRepository.searchShows(title, year).map {
                        MatchCandidate(it.id, it.name, TmdbRepository.yearOf(it.firstAirDate), it.overview.orEmpty(), TmdbImages.poster(it.posterPath, "w185"))
                    }
                }
                _state.update { it.copy(searching = false, results = results) }
            } catch (e: Exception) {
                _state.update { it.copy(searching = false, error = e.message ?: "Search failed") }
            }
        }
    }

    /** For files that aren't a movie or show at all (or were matched to the wrong thing and have no match). */
    fun ignore() {
        viewModelScope.launch {
            container.scanner.ignore(route.fileIds)
            _state.update { it.copy(done = true) }
        }
    }

    fun apply(candidate: MatchCandidate) {
        _state.update { it.copy(applyingId = candidate.id, error = null) }
        viewModelScope.launch {
            try {
                container.scanner.applyManualMatch(route.fileIds, _state.value.kind, candidate.id)
                _state.update { it.copy(done = true) }
            } catch (e: Exception) {
                _state.update { it.copy(applyingId = null, error = e.message ?: "Could not apply match") }
            }
        }
    }

    /** "Heat 1995" → ("Heat", 1995) so users can narrow by year inline. */
    private fun splitYear(q: String): Pair<String, Int?> {
        val m = Regex("""^(.*?)\s*\(?((?:19|20)\d{2})\)?$""").find(q.trim())
        return if (m != null && m.groupValues[1].isNotBlank()) m.groupValues[1] to m.groupValues[2].toInt() else q.trim() to null
    }
}

@Composable
fun FixMatchScreen(route: FixMatchRoute, navigator: Navigator) {
    val vm = appViewModel("fix-${route.fileIds.hashCode()}") { FixMatchViewModel(it, route) }
    val state by vm.state.collectAsStateWithLifecycle()
    LaunchedEffect(state.done) { if (state.done) navigator.back() }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            "Fix match",
            subtitle = "${route.fileIds.size} file${if (route.fileIds.size == 1) "" else "s"}",
            onBack = navigator::back,
        )
        Row(Modifier.padding(horizontal = gutter()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SelectChip("Movie", state.kind == MediaKind.MOVIE, { vm.setKind(MediaKind.MOVIE) })
            SelectChip("TV Show", state.kind == MediaKind.EPISODE, { vm.setKind(MediaKind.EPISODE) })
        }
        Spacer(Modifier.height(12.dp))
        Row(Modifier.padding(horizontal = gutter()).widthIn(max = 760.dp), verticalAlignment = Alignment.CenterVertically) {
            VTextField(
                value = state.query,
                onValueChange = vm::setQuery,
                label = "Title (add a year to narrow)",
                leadingIcon = Icons.Rounded.Search,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { vm.search() }),
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(10.dp))
            VButton("Search", vm::search, loading = state.searching)
        }
        TextButton(vm::ignore, Modifier.padding(horizontal = gutter() - 12.dp)) {
            Text("Not a movie or show? Ignore ${if (route.fileIds.size == 1) "this file" else "these files"}", color = VColors.TextMuted)
        }
        state.error?.let {
            Text(it, color = VColors.Danger, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(20.dp))
        }
        if (!state.searching && state.results.isEmpty() && state.error == null) {
            EmptyState(Icons.Rounded.Movie, "No results", "Try a shorter title or switch between Movie and TV Show.")
        }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(420.dp),
            contentPadding = PaddingValues(horizontal = gutter(), vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(state.results, key = { it.id }) { c ->
                Panel(
                    Modifier
                        .clip(CardShape)
                        .clickable(enabled = state.applyingId == null) { vm.apply(c) },
                    padding = PaddingValues(12.dp),
                ) {
                    Row {
                        VImage(
                            c.posterUrl, c.title,
                            Modifier
                                .width(64.dp)
                                .aspectRatio(2f / 3f)
                                .clip(PosterShape)
                                .border(1.dp, VColors.Outline, PosterShape),
                            fallbackText = c.title.take(1),
                        )
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(c.title, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            if (c.year != null) Text(c.year.toString(), style = MaterialTheme.typography.bodySmall, color = VColors.Amber)
                            Spacer(Modifier.height(4.dp))
                            Text(c.overview, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
                        }
                        if (state.applyingId == c.id) {
                            androidx.compose.material3.CircularProgressIndicator(
                                color = VColors.Amber,
                                strokeWidth = 2.dp,
                                modifier = Modifier.padding(start = 8.dp).width(20.dp).height(20.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}
