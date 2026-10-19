package com.pntapps.veltoret.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.Pill
import com.pntapps.veltoret.ui.details.CollectionViewModel
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel

/** A movie collection on TV: its backdrop, "2 of 4 in your library", and every part (owned ones open). */
@Composable
fun TvCollectionScreen(id: Int, navigator: Navigator) {
    val vm = appViewModel("tv-collection-$id") { CollectionViewModel(it, id) }
    val state by vm.state.collectAsStateWithLifecycle()
    var lastOpened by rememberSaveable { mutableStateOf<Int?>(null) }
    val requesters = remember { mutableMapOf<Int, FocusRequester>() }
    fun requesterFor(key: Int) = requesters.getOrPut(key) { FocusRequester() }
    // Back from a movie lands on its card; otherwise the first movie in the library.
    LaunchedEffect(state.loading, state.parts.size) {
        if (state.loading) return@LaunchedEffect
        val key = lastOpened ?: state.parts.firstOrNull { it.owned }?.id ?: state.parts.firstOrNull()?.id ?: return@LaunchedEffect
        requesterFor(key).focusSoon()
    }

    if (state.loading) {
        LoadingBox(Modifier.fillMaxSize())
        return
    }
    if (state.owned == 0) {
        LaunchedEffect(Unit) { navigator.back() }
        return
    }

    Box(Modifier.fillMaxSize()) {
        TvBackdrop(state.backdropUrl)
        PivotScrolling(leading = 260.dp) {
            LazyVerticalGrid(
                columns = GridCells.Fixed(6),
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = TvDimens.Edge, end = TvDimens.Edge, top = TvDimens.Top, bottom = 80.dp),
                horizontalArrangement = Arrangement.spacedBy(22.dp),
                verticalArrangement = Arrangement.spacedBy(26.dp),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }, key = "header") {
                    Column(Modifier.widthIn(max = 560.dp)) {
                        Text(state.name, style = MaterialTheme.typography.displaySmall, color = VColors.Text)
                        Spacer(Modifier.height(12.dp))
                        Pill(state.badge, accent = true)
                        if (state.overview.isNotBlank()) {
                            Spacer(Modifier.height(14.dp))
                            Text(
                                state.overview, style = MaterialTheme.typography.bodyLarge, color = VColors.Text.copy(alpha = 0.88f),
                                maxLines = 4, overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
                items(state.parts, key = { it.id }) { part ->
                    TvPosterCard(
                        title = part.title,
                        subtitle = listOfNotNull(part.year?.toString(), if (part.owned) null else "Not in your library").joinToString(" · "),
                        imageUrl = part.posterUrl,
                        progress = part.progress,
                        watched = part.watched,
                        width = 999.dp, // fills the grid cell
                        focusRequester = requesterFor(part.id),
                        onClick = {
                            if (part.owned) {
                                lastOpened = part.id
                                navigator.navigate(MovieRoute(part.id))
                            }
                        },
                        modifier = Modifier.alpha(if (part.owned) 1f else 0.42f),
                    )
                }
            }
        }
    }
}
