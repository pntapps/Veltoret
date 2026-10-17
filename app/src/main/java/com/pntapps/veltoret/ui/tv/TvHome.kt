package com.pntapps.veltoret.ui.tv

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.VideoLibrary
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.RatingText
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.home.HeroInfo
import com.pntapps.veltoret.ui.home.HomeViewModel
import com.pntapps.veltoret.ui.home.PlayItem
import com.pntapps.veltoret.ui.home.PosterItem
import com.pntapps.veltoret.ui.home.heroKey
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.SettingsRoute
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.rememberOnline
import kotlinx.coroutines.launch

/** What the header describes: a library title, optionally with an episode line. */
private data class Spotlight(val key: String, val extra: String? = null)

private sealed interface HomeRow {
    val title: String
    data class Wide(override val title: String, val items: List<PlayItem>) : HomeRow
    data class Posters(override val title: String, val items: List<PosterItem>) : HomeRow
}

@Composable
fun TvHomeScreen(navigator: Navigator) {
    val vm = appViewModel { HomeViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val online = rememberOnline()

    val rows = buildList {
        if (state.continueWatching.isNotEmpty()) add(HomeRow.Wide("Continue Watching", state.continueWatching))
        if (state.nextUp.isNotEmpty()) add(HomeRow.Wide("Next Up", state.nextUp))
        if (state.recentMovies.isNotEmpty()) add(HomeRow.Posters("Recently Added Movies", state.recentMovies))
        if (state.recentShows.isNotEmpty()) add(HomeRow.Posters("Recently Updated Shows", state.recentShows))
        if (state.topRated.isNotEmpty()) add(HomeRow.Posters("Highly Rated", state.topRated))
        state.genreRows.forEach { (genre, items) -> add(HomeRow.Posters(genre, items)) }
    }

    // The header follows focus. Before anything is focused it shows the first featured title.
    var spotlight by remember { mutableStateOf<Spotlight?>(null) }
    val fallback = state.featured.firstOrNull()?.let { Spotlight(heroKey(it.isShow, it.id)) }
    val shown = spotlight ?: fallback

    // Focus comes back to the last card used (e.g. after returning from a detail page).
    var lastFocused by rememberSaveable { mutableStateOf<String?>(null) }
    val requesters = remember { mutableMapOf<String, FocusRequester>() }
    fun requesterFor(key: String) = requesters.getOrPut(key) { FocusRequester() }
    LaunchedEffect(rows.isNotEmpty()) {
        if (rows.isEmpty()) return@LaunchedEffect
        val target = lastFocused?.let { requesters[it] } ?: rows.firstOrNull()?.let { firstKey(it)?.let(::requesterFor) }
        target?.focusSoon()
    }

    when {
        state.loading -> LoadingBox(Modifier.fillMaxSize())
        rows.isEmpty() -> TvHomeEmpty(state.hasFolders, online, state.scan.running, state.scan.filesFound) { navigator.selectTab(SettingsRoute) }
        else -> Box(Modifier.fillMaxSize()) {
            Header(shown?.let { state.heroes[it.key] }, shown?.extra)
            // Rows settle just below the header with their title visible.
            PivotScrolling(leading = 44.dp) {
                LazyColumn(
                    Modifier
                        .fillMaxSize()
                        .padding(top = HeaderHeight),
                    contentPadding = PaddingValues(bottom = 160.dp),
                ) {
                    rows.forEachIndexed { rowIndex, row ->
                        item(key = "row-${row.title}") {
                            Column(Modifier.padding(top = if (rowIndex == 0) 0.dp else 8.dp)) {
                                TvRowTitle(row.title)
                                PivotScrolling {
                                    when (row) {
                                        is HomeRow.Wide -> LazyRow(contentPadding = TvRowPadding, horizontalArrangement = TvRowArrangement) {
                                            items(row.items, key = { it.fileId }) { item ->
                                                val key = "${row.title}:${item.fileId}"
                                                TvWideCard(
                                                    title = item.title,
                                                    subtitle = item.subtitle,
                                                    imageUrl = item.imageUrl,
                                                    progress = item.progress,
                                                    caption = item.caption,
                                                    width = 232.dp,
                                                    focusRequester = requesterFor(key),
                                                    onFocused = {
                                                        lastFocused = key
                                                        spotlight = when {
                                                            item.showId != null -> Spotlight(heroKey(true, item.showId), item.subtitle)
                                                            item.movieId != null -> Spotlight(heroKey(false, item.movieId))
                                                            else -> null
                                                        }
                                                    },
                                                    // OK plays straight away; hold OK for the details page.
                                                    onClick = { context.playFile(item.fileId) },
                                                    onLongClick = {
                                                        item.showId?.let { navigator.navigate(ShowRoute(it)) }
                                                            ?: item.movieId?.let { navigator.navigate(MovieRoute(it)) }
                                                    },
                                                )
                                            }
                                        }
                                        is HomeRow.Posters -> LazyRow(contentPadding = TvRowPadding, horizontalArrangement = TvRowArrangement) {
                                            items(row.items, key = { "${it.isShow}-${it.id}" }) { item ->
                                                val key = "${row.title}:${item.isShow}-${item.id}"
                                                TvPosterCard(
                                                    title = item.title,
                                                    subtitle = item.subtitle,
                                                    imageUrl = item.posterUrl,
                                                    progress = item.progress,
                                                    watched = item.watched,
                                                    width = 116.dp,
                                                    focusRequester = requesterFor(key),
                                                    onFocused = {
                                                        lastFocused = key
                                                        spotlight = Spotlight(heroKey(item.isShow, item.id))
                                                    },
                                                    onClick = { navigator.navigate(if (item.isShow) ShowRoute(item.id) else MovieRoute(item.id)) },
                                                    onLongClick = {
                                                        scope.launch { vm.playTarget(item.isShow, item.id)?.let { context.playFile(it) } }
                                                    },
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun firstKey(row: HomeRow): String? = when (row) {
    is HomeRow.Wide -> row.items.firstOrNull()?.let { "${row.title}:${it.fileId}" }
    is HomeRow.Posters -> row.items.firstOrNull()?.let { "${row.title}:${it.isShow}-${it.id}" }
}

private val HeaderHeight = 272.dp

/** The top of Home: the focused title's artwork on the right, its details on the left. */
@Composable
private fun Header(hero: HeroInfo?, extra: String?) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(HeaderHeight)
    ) {
        AnimatedContent(
            targetState = hero,
            transitionSpec = { fadeIn(tween(320)) togetherWith fadeOut(tween(220)) },
            label = "hero",
            modifier = Modifier.fillMaxSize(),
        ) { h ->
            if (h == null) return@AnimatedContent
            Box(Modifier.fillMaxSize()) {
                VImage(
                    h.backdropUrl, h.title,
                    Modifier
                        .align(Alignment.TopEnd)
                        .width(470.dp)
                        .height(HeaderHeight - 8.dp)
                        .clip(RoundedCornerShape(bottomStart = 28.dp)),
                    fallbackText = null,
                )
                Column(
                    Modifier
                        .align(Alignment.CenterStart)
                        .padding(start = TvDimens.Edge, top = TvDimens.Top)
                        .width(360.dp),
                ) {
                    Text(
                        h.title,
                        style = MaterialTheme.typography.displaySmall,
                        color = VColors.Text,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (extra != null) {
                        Spacer(Modifier.height(4.dp))
                        Text(extra, style = MaterialTheme.typography.titleMedium, color = VColors.AmberSoft, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.height(10.dp))
                    // One line only: the header keeps a fixed rhythm as focus moves.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RatingText(h.rating)
                        if (h.rating > 0) Spacer(Modifier.width(12.dp))
                        Text(
                            (h.meta + h.genres.take(1)).filterNotNull().filter { it.isNotBlank() }.joinToString("  ·  "),
                            style = MaterialTheme.typography.bodyMedium,
                            color = VColors.TextMuted,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    if (h.overview.isNotBlank()) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            h.overview,
                            style = MaterialTheme.typography.bodyMedium,
                            color = VColors.TextMuted,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TvHomeEmpty(hasFolders: Boolean, online: Boolean, scanning: Boolean, found: Int, onSettings: () -> Unit) {
    val requester = remember { FocusRequester() }
    val (icon, title, body) = when {
        !hasFolders -> Triple(Icons.Rounded.CreateNewFolder, "Choose your library folders", "Add the Google Drive or TV folders that hold your movies and shows in Settings.")
        !online -> Triple(Icons.Rounded.CloudOff, "Nothing on this TV", "Your library is on Google Drive. Connect to the internet to watch it.")
        scanning -> Triple(Icons.Rounded.VideoLibrary, "Building your library", "Found $found videos so far. Posters appear here as titles are matched.")
        else -> Triple(Icons.Rounded.VideoLibrary, "Nothing here yet", "No videos were found in your library folders.")
    }
    LaunchedEffect(Unit) { requester.focusSoon() }
    TvMessage(icon, title, body, actionLabel = "Open Settings", onAction = onSettings, actionRequester = requester)
}

/** Centered illustration + text + optional button, used for empty and error states. */
@Composable
fun TvMessage(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    body: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
    actionRequester: FocusRequester? = null,
) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(520.dp)) {
            Box(
                Modifier
                    .clip(RoundedCornerShape(36.dp))
                    .padding(4.dp)
            ) {
                androidx.compose.material3.Icon(icon, null, tint = VColors.Amber, modifier = Modifier.padding(8.dp).width(56.dp).height(56.dp))
            }
            Spacer(Modifier.height(16.dp))
            Text(title, style = MaterialTheme.typography.headlineSmall, color = VColors.Text)
            Spacer(Modifier.height(8.dp))
            Text(body, style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            if (actionLabel != null && onAction != null) {
                Spacer(Modifier.height(24.dp))
                TvButton(actionLabel, onAction, focusRequester = actionRequester)
            }
        }
    }
}
