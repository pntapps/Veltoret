package com.pntapps.veltoret.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.home.HomeViewModel
import com.pntapps.veltoret.ui.library.LibraryFilter
import com.pntapps.veltoret.ui.library.LibrarySort
import com.pntapps.veltoret.ui.library.MoviesViewModel
import com.pntapps.veltoret.ui.library.ShowsViewModel
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.SettingsRoute
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.rememberOnline
import kotlinx.coroutines.launch

private const val Columns = 6

@Composable
fun TvLibraryScreen(isShows: Boolean, navigator: Navigator) {
    val vm = if (isShows) appViewModel("tv-shows") { ShowsViewModel(it) } else appViewModel("tv-movies") { MoviesViewModel(it) }
    // Only used to resolve what "hold OK to play" starts.
    val home = appViewModel("tv-library-play") { HomeViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val online = rememberOnline()
    val title = if (isShows) "TV Shows" else "Movies"
    var genrePicker by remember { mutableStateOf(false) }
    var sourcePicker by remember { mutableStateOf(false) }
    fun sourceLabel(id: String?) = when {
        id == null -> "All sources"
        LocalStorage.isLocal(id) -> "This TV"
        else -> state.sources.firstOrNull { it.id == id }?.label ?: id
    }

    var lastFocused by rememberSaveable { mutableStateOf<String?>(null) }
    val requesters = remember { mutableMapOf<String, FocusRequester>() }
    fun requesterFor(key: String) = requesters.getOrPut(key) { FocusRequester() }
    val firstChip = remember { FocusRequester() }
    LaunchedEffect(state.loading) {
        if (state.loading) return@LaunchedEffect
        val target = lastFocused?.let { requesters[it] }
            ?: state.items.firstOrNull()?.let { requesterFor("${it.isShow}-${it.id}") }
            ?: firstChip
        target.focusSoon()
    }

    when {
        state.loading -> LoadingBox(Modifier.fillMaxSize())
        state.total == 0 -> TvMessage(
            if (!online) Icons.Rounded.CloudOff else if (isShows) Icons.Rounded.LiveTv else Icons.Rounded.Movie,
            if (!online) "No ${title.lowercase()} on this TV" else "No ${title.lowercase()} yet",
            if (!online) "Your ${title.lowercase()} are on Google Drive. Connect to the internet to watch them."
            else "Add a ${title.lowercase()} folder in Settings, or wait for the library scan to finish.",
            actionLabel = "Open Settings",
            onAction = { navigator.selectTab(SettingsRoute) },
            actionRequester = firstChip,
        )
        else -> PivotScrolling(leading = 150.dp) { // keeps the title and filters in view on the first row
            LazyVerticalGrid(
                columns = GridCells.Fixed(Columns),
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = TvDimens.Edge, end = TvDimens.Edge, top = TvDimens.Top, bottom = 80.dp),
                horizontalArrangement = Arrangement.spacedBy(22.dp),
                verticalArrangement = Arrangement.spacedBy(26.dp),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "header") {
                    Column {
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(title, style = MaterialTheme.typography.displaySmall, color = VColors.Text)
                            Spacer(Modifier.width(16.dp))
                            Text(
                                "${state.items.size} of ${state.total}",
                                style = MaterialTheme.typography.titleMedium,
                                color = VColors.TextMuted,
                                modifier = Modifier.padding(bottom = 6.dp),
                            )
                        }
                        Spacer(Modifier.height(16.dp))
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 6.dp)) {
                            items(LibraryFilter.entries.toList(), key = { it.name }) { f ->
                                TvChip(
                                    f.label, state.filter == f, { vm.setFilter(f) },
                                    focusRequester = if (f == LibraryFilter.All) firstChip else null,
                                )
                            }
                            item("genre") {
                                TvChip(state.genre ?: "All genres", state.genre != null, { genrePicker = true })
                            }
                            if (state.sources.isNotEmpty()) item("source") {
                                TvChip("Source: ${sourceLabel(state.source)}", state.source != null, { sourcePicker = true })
                            }
                            item("sort") {
                                // OK cycles through the sort orders.
                                TvChip("Sort: ${state.sort.label}", false, {
                                    val all = LibrarySort.entries
                                    vm.setSort(all[(all.indexOf(state.sort) + 1) % all.size])
                                })
                            }
                        }
                    }
                }
                if (state.items.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }, key = "none") {
                        Text("Nothing matches these filters.", style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted)
                    }
                }
                items(state.items, key = { "${it.isShow}-${it.id}" }) { item ->
                    val key = "${item.isShow}-${item.id}"
                    TvPosterCard(
                        title = item.title,
                        subtitle = item.subtitle,
                        imageUrl = item.posterUrl,
                        progress = item.progress,
                        watched = item.watched,
                        width = 999.dp, // fills the grid cell
                        focusRequester = requesterFor(key),
                        onFocused = { lastFocused = key },
                        onClick = { navigator.navigate(if (item.isShow) ShowRoute(item.id) else MovieRoute(item.id)) },
                        onLongClick = { scope.launch { home.playTarget(item.isShow, item.id)?.let { context.playFile(it) } } },
                    )
                }
            }
        }
    }

    if (genrePicker) {
        TvChoiceDialog(
            title = "Genre",
            options = listOf<String?>(null) + state.genres,
            label = { it ?: "All genres" },
            selected = state.genre,
            onDismiss = { genrePicker = false },
            onSelect = { vm.setGenre(it); genrePicker = false },
        )
    }
    if (sourcePicker) {
        TvChoiceDialog(
            title = "Source",
            options = listOf<String?>(null) + state.sources.map { it.id },
            label = { sourceLabel(it) },
            selected = state.source,
            onDismiss = { sourcePicker = false },
            onSelect = { vm.setSource(it); sourcePicker = false },
        )
    }
}
