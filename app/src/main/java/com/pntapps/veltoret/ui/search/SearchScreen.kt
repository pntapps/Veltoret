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
import androidx.compose.material.icons.rounded.Mic
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
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.SearchHit
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
import com.pntapps.veltoret.ui.util.rememberVoiceInput
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
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
    /** Counts spoken searches (the mic, or "search for … on Veltoret"), so screens can leave the keyboard closed. */
    val spoken = MutableStateFlow(0)

    init {
        viewModelScope.launch {
            container.spokenSearch.filterNotNull().collect {
                container.spokenSearch.value = null
                speak(it)
            }
        }
    }

    fun speak(text: String) {
        query.value = text.trim()
        spoken.value++
    }

    private val ids = query.debounce(200).mapLatest { q ->
        if (q.isBlank()) emptyList<SearchHit>() to emptyList() else library.search(q.trim())
    }

    val state: StateFlow<SearchState> = combine(query, ids, library.movies(), library.shows()) { q, (movieHits, showHits), movies, shows ->
        val movieMap = movies.associateBy { it.movie.tmdbId }
        val showMap = shows.associateBy { it.show.tmdbId }
        // The subtitle says why a title matched when it wasn't by name: "1994 · Tom Hanks".
        fun subtitle(year: Int?, reason: String?) = listOfNotNull(year?.toString(), reason).joinToString(" · ").ifEmpty { null }
        SearchState(
            q,
            movieHits.mapNotNull { hit -> movieMap[hit.id]?.let { it to hit.reason } }.map { (it, reason) ->
                PosterItem(it.movie.tmdbId, false, it.movie.title, subtitle(it.movie.year, reason), TmdbImages.poster(it.movie.posterPath))
            },
            showHits.mapNotNull { hit -> showMap[hit.id]?.let { it to hit.reason } }.map { (it, reason) ->
                PosterItem(it.show.tmdbId, true, it.show.name, subtitle(it.show.year, reason), TmdbImages.poster(it.show.posterPath))
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
    val spoken by vm.spoken.collectAsStateWithLifecycle()
    // A spoken search shows its results straight away; typing opens the keyboard.
    LaunchedEffect(Unit) { if (spoken == 0) focus.requestFocus() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(spoken) { if (spoken > 0) keyboard?.hide() }
    val voice = rememberVoiceInput("Say a title, actor or director", vm::speak)
    val compact = LocalWidthClass.current == WidthClass.Compact

    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Search", onBack = navigator::back)
        VTextField(
            value = query,
            onValueChange = { vm.query.value = it },
            label = "Titles, actors, directors, collections",
            leadingIcon = Icons.Rounded.Search,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            trailing = when {
                query.isNotEmpty() -> {
                    { IconButton(onClick = { vm.query.value = "" }) { Icon(Icons.Rounded.Close, "Clear", tint = VColors.TextMuted) } }
                }
                voice != null -> {
                    { IconButton(onClick = voice) { Icon(Icons.Rounded.Mic, "Search by voice", tint = VColors.Amber) } }
                }
                else -> null
            },
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
