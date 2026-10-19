package com.pntapps.veltoret.ui.home

import com.pntapps.veltoret.ui.util.rememberOnline
import androidx.compose.material.icons.rounded.CloudOff
import com.pntapps.veltoret.ui.util.gutter
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.FolderZip
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.CardShape
import com.pntapps.veltoret.ui.components.EmptyState
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.MetaLine
import com.pntapps.veltoret.ui.components.Panel
import com.pntapps.veltoret.ui.components.PosterCard
import com.pntapps.veltoret.ui.components.RatingText
import com.pntapps.veltoret.ui.components.SectionHeader
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.components.WideCard
import com.pntapps.veltoret.ui.components.entrance
import com.pntapps.veltoret.ui.components.Wordmark
import com.pntapps.veltoret.ui.navigation.ArchivesRoute
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.MoviesRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.SearchRoute
import com.pntapps.veltoret.ui.navigation.SettingsRoute
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.navigation.ShowsRoute
import com.pntapps.veltoret.ui.navigation.UnmatchedRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.appViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun HomeScreen(navigator: Navigator) {
    val vm = appViewModel { HomeViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val width = LocalWidthClass.current
    val online = rememberOnline()
    val posterWidth = when (width) {
        WidthClass.Compact -> 124.dp
        WidthClass.Medium -> 150.dp
        WidthClass.Expanded -> 164.dp
    }
    val wideWidth = when (width) {
        WidthClass.Compact -> 260.dp
        WidthClass.Medium -> 320.dp
        WidthClass.Expanded -> 360.dp
    }

    fun open(item: PosterItem) = navigator.navigate(item.route())

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 32.dp)) {
        item("header") {
            Row(
                Modifier
                    .fillMaxWidth()
                    .windowInsetsPadding(WindowInsets.statusBars)
                    .padding(start = gutter(), end = 12.dp, top = 12.dp, bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Wordmark(Modifier.weight(1f))
                if (state.scan.running) {
                    ScanChip(state.scan.phase, state.scan.filesFound)
                    Spacer(Modifier.width(8.dp))
                }
                VIconButton(Icons.Rounded.Search, "Search", { navigator.navigate(SearchRoute) })
            }
        }

        when {
            state.loading -> item("loading") { LoadingBox(Modifier.height(400.dp)) }
            !state.hasFolders -> item("nofolders") {
                EmptyState(
                    Icons.Rounded.CreateNewFolder,
                    "Choose your library folders",
                    "Pick the Google Drive or device folders that hold your movies and TV shows.",
                    actionLabel = "Open Settings",
                    onAction = { navigator.selectTab(SettingsRoute) },
                )
            }
            state.isEmpty && state.scan.running -> item("building") {
                EmptyState(
                    Icons.Rounded.VideoLibrary,
                    "Building your library",
                    "Found ${state.scan.filesFound} videos so far. Posters will appear here as titles are matched.",
                )
            }
            state.isEmpty && !online -> item("offline-empty") {
                EmptyState(
                    Icons.Rounded.CloudOff,
                    "Nothing on this device",
                    "Your library is on Google Drive. Connect to the internet to watch it, or add a folder from this device in Settings.",
                )
            }
            state.isEmpty -> item("empty") {
                EmptyState(
                    Icons.Rounded.VideoLibrary,
                    "Nothing here yet",
                    state.scan.error ?: "No videos were found in your library folders. Add files to Drive and scan again.",
                    actionLabel = "Scan now",
                    onAction = vm::scanNow,
                )
            }
        }

        if (state.featured.isNotEmpty()) {
            item("featured") {
                FeaturedPager(
                    modifier = Modifier.entrance(0),
                    items = state.featured,
                    // Side by side only when there is real width; portrait tablets stack like phones.
                    wide = width == WidthClass.Expanded,
                    onPlay = { item ->
                        scope.launch { vm.playTarget(item.isShow, item.id)?.let { context.playFile(it) } }
                    },
                    onDetails = { navigator.navigate(if (it.isShow) ShowRoute(it.id) else MovieRoute(it.id)) },
                )
            }
        }

        // Matching needs TMDB, so the prompt waits until the device is back online.
        if (state.unmatchedCount > 0 && online) {
            item("unmatched") {
                Panel(
                    Modifier
                        .padding(horizontal = gutter(), vertical = 12.dp)
                        .clip(CardShape)
                        .clickable { navigator.navigate(UnmatchedRoute) },
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.ErrorOutline, null, tint = VColors.Amber)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text("${state.unmatchedCount} file${if (state.unmatchedCount == 1) "" else "s"} need a match", style = MaterialTheme.typography.titleSmall)
                            Text("Tap to identify them on TMDB", style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                        }
                    }
                }
            }
        }

        if (state.archiveCount > 0) {
            item("archives") {
                Panel(
                    Modifier
                        .padding(horizontal = gutter(), vertical = 6.dp)
                        .clip(CardShape)
                        .clickable { navigator.navigate(ArchivesRoute) },
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.FolderZip, null, tint = VColors.Amber)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                "${state.archiveCount} ZIP archive${if (state.archiveCount == 1) "" else "s"} in your library",
                                style = MaterialTheme.typography.titleSmall,
                            )
                            Text("Tap to unpack them so they can play", style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                        }
                    }
                }
            }
        }

        if (state.continueWatching.isNotEmpty()) {
            item("cw") {
                Box(Modifier.entrance(1)) {
                    PlayRow("Continue Watching", state.continueWatching, wideWidth) { context.playFile(it.fileId) }
                }
            }
        }
        if (state.nextUp.isNotEmpty()) {
            item("next") {
                PlayRow("Next Up", state.nextUp, wideWidth) { context.playFile(it.fileId) }
            }
        }
        if (state.watchlist.isNotEmpty()) {
            item("watchlist") { PosterRow("Watchlist", state.watchlist, posterWidth, ::open) }
        }
        if (state.comingUp.isNotEmpty()) {
            item("coming-up") { PosterRow("Coming Up", state.comingUp, posterWidth, ::open) }
        }
        if (state.recentMovies.isNotEmpty()) {
            item("rm") {
                PosterRow("Recently Added Movies", state.recentMovies, posterWidth, ::open, "See all") { navigator.selectTab(MoviesRoute) }
            }
        }
        if (state.recentShows.isNotEmpty()) {
            item("rs") {
                PosterRow("Recently Updated Shows", state.recentShows, posterWidth, ::open, "See all") { navigator.selectTab(ShowsRoute) }
            }
        }
        if (state.topRated.isNotEmpty()) {
            item("top") { PosterRow("Highly Rated", state.topRated, posterWidth, ::open) }
        }
        if (state.collections.isNotEmpty()) {
            item("collections") { PosterRow("Collections", state.collections, posterWidth, ::open) }
        }
        state.genreRows.forEach { (genre, items) ->
            item("genre-$genre") { PosterRow(genre, items, posterWidth, ::open) }
        }
    }
}

@Composable
private fun ScanChip(phase: String, count: Int) {
    Row(
        Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(VColors.Surface)
            .border(1.dp, VColors.Outline, RoundedCornerShape(10.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(Modifier.size(12.dp), color = VColors.Amber, strokeWidth = 1.5.dp)
        Spacer(Modifier.width(8.dp))
        Text(
            if (phase.startsWith("Matching")) "Matching" else "Syncing $count",
            style = MaterialTheme.typography.labelMedium,
            color = VColors.TextMuted,
        )
    }
}

@Composable
private fun FeaturedPager(
    modifier: Modifier = Modifier,
    items: List<FeaturedItem>,
    wide: Boolean,
    onPlay: (FeaturedItem) -> Unit,
    onDetails: (FeaturedItem) -> Unit,
) {
    val pager = rememberPagerState { items.size }
    LaunchedEffect(pager.settledPage, items.size) {
        if (items.size > 1) {
            delay(8_000)
            pager.animateScrollToPage((pager.settledPage + 1) % items.size)
        }
    }
    Column(modifier.padding(bottom = 8.dp)) {
        HorizontalPager(
            state = pager,
            contentPadding = PaddingValues(horizontal = gutter()),
            // Spacing equal to the margin keeps neighbouring pages fully out of view.
            pageSpacing = gutter(),
        ) { page ->
            val item = items[page]
            if (wide) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FeaturedImage(item, Modifier.weight(1.2f), onDetails)
                    Spacer(Modifier.width(36.dp))
                    FeaturedInfo(item, Modifier.weight(1f), onPlay, onDetails, titleLines = 3)
                }
            } else {
                Column {
                    FeaturedImage(item, Modifier.fillMaxWidth(), onDetails)
                    Spacer(Modifier.height(16.dp))
                    FeaturedInfo(item, Modifier.fillMaxWidth(), onPlay, onDetails, titleLines = 2)
                }
            }
        }
        if (items.size > 1) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 16.dp, start = gutter()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                repeat(items.size) { i ->
                    Box(
                        Modifier
                            .height(3.dp)
                            .width(if (i == pager.currentPage) 22.dp else 8.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(if (i == pager.currentPage) VColors.Amber else VColors.OutlineStrong)
                    )
                }
            }
        }
    }
}

@Composable
private fun FeaturedImage(item: FeaturedItem, modifier: Modifier, onClick: (FeaturedItem) -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    VImage(
        item.backdropUrl,
        item.title,
        modifier
            .aspectRatio(16f / 9f)
            .clip(shape)
            .border(1.dp, VColors.Outline, shape)
            .clickable { onClick(item) },
        fallbackText = item.title,
    )
}

@Composable
private fun FeaturedInfo(
    item: FeaturedItem,
    modifier: Modifier,
    onPlay: (FeaturedItem) -> Unit,
    onDetails: (FeaturedItem) -> Unit,
    titleLines: Int,
) {
    Column(modifier) {
        Text(
            if (item.isShow) "SERIES" else "FILM",
            style = MaterialTheme.typography.labelSmall,
            color = VColors.Amber,
        )
        Spacer(Modifier.height(6.dp))
        Text(item.title, style = MaterialTheme.typography.displaySmall, maxLines = titleLines, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            RatingText(item.rating)
            if (item.rating > 0) Spacer(Modifier.width(12.dp))
            MetaLine(item.meta)
        }
        if (item.overview.isNotBlank()) {
            Spacer(Modifier.height(10.dp))
            Text(
                item.overview,
                style = MaterialTheme.typography.bodyMedium,
                color = VColors.TextMuted,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            VButton("Play", { onPlay(item) }, icon = Icons.Rounded.PlayArrow)
            VButton("Details", { onDetails(item) }, icon = Icons.Rounded.Info, style = ButtonStyle.Secondary)
        }
    }
}

@Composable
private fun PlayRow(title: String, items: List<PlayItem>, cardWidth: androidx.compose.ui.unit.Dp, onPlay: (PlayItem) -> Unit) {
    Column(Modifier.padding(top = 28.dp)) {
        SectionHeader(title)
        Spacer(Modifier.height(12.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = gutter()), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            items(items, key = { it.fileId }) { item ->
                WideCard(
                    title = item.title,
                    subtitle = item.subtitle,
                    imageUrl = item.imageUrl,
                    onClick = { onPlay(item) },
                    progress = item.progress,
                    caption = item.caption,
                    modifier = Modifier.width(cardWidth),
                )
            }
        }
    }
}

@Composable
fun PosterRow(
    title: String,
    items: List<PosterItem>,
    posterWidth: androidx.compose.ui.unit.Dp,
    onOpen: (PosterItem) -> Unit,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(Modifier.padding(top = 28.dp)) {
        SectionHeader(title, actionLabel = actionLabel, onAction = onAction)
        Spacer(Modifier.height(12.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = gutter()), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            items(items, key = { (if (it.isShow) "s" else "m") + it.id }) { item ->
                PosterCard(
                    title = item.title,
                    subtitle = item.subtitle,
                    imageUrl = item.posterUrl,
                    onClick = { onOpen(item) },
                    progress = item.progress,
                    watched = item.watched,
                    badge = item.badge,
                    modifier = Modifier.width(posterWidth),
                )
            }
        }
    }
}

