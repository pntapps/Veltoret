package com.pntapps.veltoret.ui.details

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.progress
import com.pntapps.veltoret.data.library.WatchKeys
import com.pntapps.veltoret.data.tmdb.TmdbCollection
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.data.tmdb.TmdbRepository
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.Pill
import com.pntapps.veltoret.ui.components.PosterCard
import com.pntapps.veltoret.ui.components.SectionHeader
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
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

/** One movie of a collection; [owned] ones open their page, the rest are shown dimmed. */
data class CollectionPart(
    val id: Int,
    val title: String,
    val year: Int?,
    val posterUrl: String?,
    val owned: Boolean,
    val watched: Boolean = false,
    val progress: Float? = null,
)

data class CollectionState(
    val loading: Boolean = true,
    val name: String = "",
    val overview: String = "",
    val backdropUrl: String? = null,
    val posterUrl: String? = null,
    val parts: List<CollectionPart> = emptyList(),
    val owned: Int = 0,
    /** Movies in the whole collection; null until TMDB answers (or offline), when only owned ones are known. */
    val total: Int? = null,
) {
    val badge: String get() = if (total != null) "$owned of $total in your library" else "$owned in your library"
}

/**
 * A movie collection: TMDB's list of parts (fetched when the page opens, kept for the session) merged
 * with the library. Offline, it lists the movies in the library only.
 */
class CollectionViewModel(container: AppContainer, private val id: Int) : ViewModel() {
    private val remote = MutableStateFlow<TmdbCollection?>(null)

    init {
        if (container.connectivity.isOnline) viewModelScope.launch {
            remote.value = runCatching { container.tmdbRepository.collection(id) }.getOrNull()
        }
    }

    val state: StateFlow<CollectionState> = combine(
        container.libraryRepository.movies(), container.watchRepository.observeAll(), remote,
    ) { movies, states, collection ->
        val statesByKey = states.associateBy { it.key }
        val owned = movies.filter { it.movie.collectionId == id }.associateBy { it.movie.tmdbId }
        fun ownedPart(movieId: Int): CollectionPart? = owned[movieId]?.movie?.let { m ->
            val st = statesByKey[WatchKeys.movie(m.tmdbId)]
            CollectionPart(
                m.tmdbId, m.title, m.year, TmdbImages.poster(m.posterPath), owned = true,
                watched = st?.watched == true, progress = st?.takeIf { !it.watched && it.positionMs > 0 }?.progress,
            )
        }
        val parts = collection?.parts?.map { p ->
            ownedPart(p.id) ?: CollectionPart(p.id, p.title, TmdbRepository.yearOf(p.releaseDate), TmdbImages.poster(p.posterPath), owned = false)
        } ?: owned.values.sortedBy { it.movie.releaseDate.orEmpty() }.mapNotNull { ownedPart(it.movie.tmdbId) }
        val first = owned.values.minByOrNull { it.movie.releaseDate.orEmpty() }?.movie
        CollectionState(
            loading = false,
            name = collection?.name ?: first?.collectionName.orEmpty(),
            overview = collection?.overview.orEmpty(),
            backdropUrl = TmdbImages.backdrop(collection?.backdropPath ?: first?.backdropPath),
            posterUrl = TmdbImages.poster(collection?.posterPath ?: first?.posterPath, "w500"),
            parts = parts,
            owned = owned.size,
            total = collection?.parts?.size,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), CollectionState())
}

@Composable
fun CollectionScreen(id: Int, navigator: Navigator) {
    val vm = appViewModel("collection-$id") { CollectionViewModel(it, id) }
    val state by vm.state.collectAsStateWithLifecycle()
    if (state.loading) {
        LoadingBox()
        return
    }
    // Nothing of it left in the library (e.g. re-matched elsewhere): leave the page.
    if (state.owned == 0) {
        LaunchedEffect(Unit) { navigator.back() }
        return
    }
    val columns = when (LocalWidthClass.current) {
        WidthClass.Compact -> 3
        WidthClass.Medium -> 4
        WidthClass.Expanded -> 6
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp)) {
        item("header") {
            DetailHeader(title = state.name, backdropUrl = state.backdropUrl, posterUrl = state.posterUrl, onBack = navigator::back) {
                DetailTitle(state.name, null)
                Spacer(Modifier.height(12.dp))
                Pill(state.badge, accent = true)
                Overview(state.overview)
            }
        }
        item("parts-title") {
            SectionHeader("Movies", Modifier.padding(top = 28.dp, bottom = 12.dp))
        }
        items(state.parts.chunked(columns), key = { row -> row.joinToString { it.id.toString() } }) { row ->
            Row(
                Modifier.padding(horizontal = gutter()).padding(bottom = 20.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                row.forEach { part ->
                    PosterCard(
                        title = part.title,
                        subtitle = listOfNotNull(part.year?.toString(), if (part.owned) null else "Not in your library").joinToString(" · "),
                        imageUrl = part.posterUrl,
                        onClick = { if (part.owned) navigator.navigate(MovieRoute(part.id)) },
                        progress = part.progress,
                        watched = part.watched,
                        modifier = Modifier.weight(1f).alpha(if (part.owned) 1f else 0.42f),
                    )
                }
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}
