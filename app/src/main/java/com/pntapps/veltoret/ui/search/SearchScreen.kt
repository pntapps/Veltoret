package com.pntapps.veltoret.ui.search

import com.pntapps.veltoret.ui.util.gutter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SearchOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.ui.components.EmptyState
import com.pntapps.veltoret.ui.components.PosterCard
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.home.PosterItem
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.appViewModel
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn

data class SearchState(val query: String = "", val movies: List<PosterItem> = emptyList(), val shows: List<PosterItem> = emptyList())

@OptIn(FlowPreview::class, kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SearchViewModel(container: AppContainer) : ViewModel() {
    val query = MutableStateFlow("")
    private val library = container.libraryRepository

    private val ids = query.debounce(200).mapLatest { q ->
        if (q.isBlank()) emptyList<Int>() to emptyList() else library.searchIds(q.trim())
    }

    val state: StateFlow<SearchState> = combine(query, ids, library.movies(), library.shows()) { q, (movieIds, showIds), movies, shows ->
        val movieMap = movies.associateBy { it.movie.tmdbId }
        val showMap = shows.associateBy { it.show.tmdbId }
        SearchState(
            q,
            movieIds.mapNotNull { movieMap[it] }.map {
                PosterItem(it.movie.tmdbId, false, it.movie.title, it.movie.year?.toString(), TmdbImages.poster(it.movie.posterPath))
            },
            showIds.mapNotNull { showMap[it] }.map {
                PosterItem(it.show.tmdbId, true, it.show.name, it.show.year?.toString(), TmdbImages.poster(it.show.posterPath))
            },
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SearchState())
}

@Composable
fun SearchScreen(navigator: Navigator) {
    val vm = appViewModel { SearchViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    val query by vm.query.collectAsStateWithLifecycle()
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val compact = LocalWidthClass.current == WidthClass.Compact

    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Search", onBack = navigator::back)
        VTextField(
            value = query,
            onValueChange = { vm.query.value = it },
            label = "Titles, actors, collections",
            leadingIcon = Icons.Rounded.Search,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            trailing = if (query.isNotEmpty()) {
                { IconButton(onClick = { vm.query.value = "" }) { Icon(Icons.Rounded.Close, "Clear", tint = VColors.TextMuted) } }
            } else null,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = gutter())
                .widthIn(max = 720.dp)
                .focusRequester(focus),
        )
        if (query.isNotBlank() && state.movies.isEmpty() && state.shows.isEmpty()) {
            EmptyState(Icons.Rounded.SearchOff, "No results", "Nothing in your library matches \"$query\".")
        }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(if (compact) 108.dp else 150.dp),
            contentPadding = PaddingValues(horizontal = gutter(), vertical = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            if (state.movies.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) { Text("Movies", style = MaterialTheme.typography.headlineSmall) }
                items(state.movies, key = { "m${it.id}" }) {
                    PosterCard(it.title, it.subtitle, it.posterUrl, { navigator.navigate(MovieRoute(it.id)) })
                }
            }
            if (state.shows.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) { Text("TV Shows", style = MaterialTheme.typography.headlineSmall) }
                items(state.shows, key = { "s${it.id}" }) {
                    PosterCard(it.title, it.subtitle, it.posterUrl, { navigator.navigate(ShowRoute(it.id)) })
                }
            }
        }
    }
}
