package com.pntapps.veltoret.ui.tv

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Layers
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Undo
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.Dp
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.data.db.CreditEntity
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.MetaLine
import com.pntapps.veltoret.ui.components.Pill
import com.pntapps.veltoret.ui.components.RatingText
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.details.EpisodeUi
import com.pntapps.veltoret.ui.details.MovieDetailViewModel
import com.pntapps.veltoret.ui.details.TrailerIcon
import com.pntapps.veltoret.ui.navigation.CollectionRoute
import com.pntapps.veltoret.data.plans.Plans
import java.time.LocalDate
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.Collections
import com.pntapps.veltoret.ui.details.openTrailer
import com.pntapps.veltoret.ui.details.ShowDetailViewModel
import com.pntapps.veltoret.ui.home.PosterItem
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.canPlayNow
import com.pntapps.veltoret.ui.util.rememberOnline

// ---------------------------------------------------------------------------------------------
// Shared header: artwork on the right, details on the left (no gradients; text never sits on art)
// ---------------------------------------------------------------------------------------------

@Composable
private fun DetailHeader(
    title: String,
    tagline: String?,
    rating: Double,
    meta: List<String?>,
    pills: List<String>,
    overview: String,
    /** The header's height, so focused rows scroll to where the buttons sit ([PivotScrolling]). */
    onHeight: (Dp) -> Unit,
) {
    val density = LocalDensity.current
    // The backdrop itself is drawn full-screen behind the page (TvBackdrop); this is the text over it.
    // As tall as its text, so the buttons follow the description at an even gap (a fixed height left a
    // big hole under short descriptions and let long ones run into the buttons).
    Box(
        Modifier
            .fillMaxWidth()
            .onSizeChanged { onHeight(with(density) { it.height.toDp() }) }
    ) {
        Column(
            Modifier
                .padding(start = TvDimens.Edge, top = TvDimens.Top + 12.dp, bottom = 20.dp)
                .width(560.dp)
        ) {
            Text(title, style = MaterialTheme.typography.displaySmall, color = VColors.Text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (!tagline.isNullOrBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    tagline,
                    style = MaterialTheme.typography.titleMedium.copy(fontStyle = FontStyle.Italic),
                    color = VColors.TextMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                RatingText(rating)
                if (rating > 0) Spacer(Modifier.width(12.dp))
                MetaLine(meta)
            }
            if (pills.isNotEmpty()) {
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) { pills.take(4).forEach { Pill(it, accent = it == pills.first()) } }
            }
            if (overview.isNotBlank()) {
                Spacer(Modifier.height(12.dp))
                Text(overview, style = MaterialTheme.typography.bodyMedium, color = VColors.Text.copy(alpha = 0.82f), maxLines = 4, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun CastRow(cast: List<CreditEntity>) {
    if (cast.isEmpty()) return
    Column(Modifier.padding(top = 18.dp)) {
        TvRowTitle("Cast")
        PivotScrolling {
            LazyRow(contentPadding = TvRowPadding, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                items(cast.take(20), key = { it.personId }) { person ->
                    Column(Modifier.width(96.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        // Focusable so the row can be scrolled with the remote.
                        TvSurface(onClick = {}, shape = CircleShape, color = VColors.SurfaceHigh, focusedScale = 1.08f, modifier = Modifier.size(84.dp)) {
                            VImage(TmdbImages.profile(person.profilePath), person.name, Modifier.fillMaxSize(), fallbackText = person.name.take(1))
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(person.name, style = MaterialTheme.typography.labelLarge, color = VColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                        person.character?.let {
                            Text(it, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                        }
                    }
                }
            }
        }
    }
}

/** "More like this": recommended titles from the library. Opening one remembers it so Back refocuses it. */
@Composable
private fun RelatedRow(items: List<PosterItem>, requesterFor: (Int) -> FocusRequester, onOpen: (PosterItem) -> Unit) {
    if (items.isEmpty()) return
    Column(Modifier.padding(top = 18.dp)) {
        TvRowTitle("More like this")
        PivotScrolling {
            LazyRow(contentPadding = TvRowPadding, horizontalArrangement = TvRowArrangement) {
                items(items, key = { it.id }) { item ->
                    TvPosterCard(
                        title = item.title,
                        subtitle = item.subtitle,
                        imageUrl = item.posterUrl,
                        progress = item.progress,
                        watched = item.watched,
                        width = 116.dp,
                        focusRequester = requesterFor(item.id),
                        onClick = { onOpen(item) },
                    )
                }
            }
        }
    }
}

/** Focuses the related title that was opened (coming back from its page), else [primary]. */
private suspend fun focusOnArrival(lastOpened: Int?, requesterFor: (Int) -> FocusRequester, primary: FocusRequester) {
    if (lastOpened == null || !requesterFor(lastOpened).tryFocusSoon()) primary.focusSoon()
}

// ---------------------------------------------------------------------------------------------
// Movie
// ---------------------------------------------------------------------------------------------

@Composable
fun TvMovieDetailScreen(id: Int, navigator: Navigator) {
    val vm = appViewModel("tv-movie-$id") { MovieDetailViewModel(it, id) }
    val trailer by vm.trailer.collectAsStateWithLifecycle()
    val saved by vm.plans.saved.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val online = rememberOnline()
    val primary = remember { FocusRequester() }
    var versions by remember { mutableStateOf(false) }
    var lastOpened by rememberSaveable { mutableStateOf<Int?>(null) }
    val relatedRequesters = remember { mutableMapOf<Int, FocusRequester>() }
    val requesterFor = { key: Int -> relatedRequesters.getOrPut(key) { FocusRequester() } }

    val movie = state.movie
    if (state.loading || movie == null) {
        LoadingBox(Modifier.fillMaxSize())
        return
    }
    val best = state.files.firstOrNull { canPlayNow(it.accountEmail, online) }
    val watch = state.watch
    val inProgress = watch != null && !watch.watched && watch.positionMs > 30_000
    LaunchedEffect(Unit) { focusOnArrival(lastOpened, requesterFor, primary) }

    // The action buttons sit just under the header, so the title never scrolls away while they're focused.
    Box(Modifier.fillMaxSize()) {
    TvBackdrop(TmdbImages.backdrop(movie.backdropPath))
    var header by remember { mutableStateOf(318.dp) }
    PivotScrolling(leading = header + 4.dp) { LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 60.dp)) {
        item("header") {
            DetailHeader(
                onHeight = { header = it },
                title = movie.title,
                tagline = movie.tagline,
                rating = movie.rating,
                meta = listOf(movie.year?.toString(), movie.certification, Format.runtime(movie.runtimeMin), movie.director?.let { "Dir. $it" }),
                pills = best?.let { FilenameParser.qualityTags(it.name, it.height) }.orEmpty() + movie.genres.split(',').filter { it.isNotBlank() }.take(2),
                overview = movie.overview,
            )
        }
        item("actions") {
            val primaryLabel = when {
                best == null -> if (state.files.isEmpty()) "No file" else "Needs internet"
                inProgress -> "Resume · ${Format.remaining(watch!!.positionMs, watch.durationMs)}"
                watch?.watched == true -> "Watch again"
                else -> "Play"
            }
            TvActionRow(
                title = movie.title,
                primaryLabel = primaryLabel,
                primary = {
                    TvButton(
                        primaryLabel,
                        { best?.let { context.playFile(it.driveId, it.accountEmail, fromStart = !inProgress && watch?.watched == true) } },
                        icon = Icons.Rounded.PlayArrow, enabled = best != null, focusRequester = primary,
                    )
                },
                // Most important first; the last ones move into More when the row is full.
                actions = buildList {
                    if (best != null && inProgress) add(TvRowAction("Start over", Icons.Rounded.Replay) { context.playFile(best.driveId, best.accountEmail, fromStart = true) })
                    if (watch?.watched == true) add(TvRowAction("Mark unwatched", Icons.Rounded.Undo) { vm.setWatched(false) })
                    else add(TvRowAction("Mark watched", Icons.Rounded.Check) { vm.setWatched(true) })
                    add(watchlistAction(saved, vm.plans::toggleWatchlist))
                    if (state.files.size > 1) add(TvRowAction("Versions (${state.files.size})", Icons.Rounded.Layers) { versions = true })
                    movie.collectionId?.let { cid -> add(TvRowAction("Collection", Icons.Rounded.Collections) { navigator.navigate(CollectionRoute(cid)) }) }
                    trailer?.takeIf { online }?.let { key -> add(TvRowAction("Trailer", TrailerIcon) { context.openTrailer(key) }) }
                },
            )
        }
        item("cast") { CastRow(state.cast) }
        item("related") {
            RelatedRow(state.related, requesterFor) {
                lastOpened = it.id
                navigator.navigate(MovieRoute(it.id))
            }
        }
    } }
    }

    if (versions) {
        TvChoiceDialog(
            title = "Choose a version",
            options = state.files,
            label = { it.name },
            selected = best,
            detail = { f -> versionDetail(f, online) },
            onDismiss = { versions = false },
            onSelect = { f ->
                versions = false
                if (canPlayNow(f.accountEmail, online)) context.playFile(f.driveId, f.accountEmail)
            },
        )
    }
}

/** Toggling changes only its text and icon (same place in the row), so focus stays on it. */
private fun watchlistAction(saved: Boolean, onToggle: () -> Unit) =
    TvRowAction(if (saved) "On Watchlist" else "Watch later", if (saved) Icons.Rounded.Bookmark else Icons.Rounded.BookmarkBorder, onToggle)

/** One button in a TV detail page's action row. */
private class TvRowAction(val label: String, val icon: ImageVector, val run: () -> Unit)

/**
 * The action row, always one line: [primary] (Play/Resume) then [actions], most important first. What
 * doesn't fit the screen moves into a "More" panel, least important (last) first: a full row ran off
 * the right edge ("Trai") on movies with Resume, Start over and a trailer.
 */
@Composable
private fun TvActionRow(title: String, primaryLabel: String, primary: @Composable () -> Unit, actions: List<TvRowAction>) {
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = MaterialTheme.typography.titleSmall
    // TvButton: 22 dp padding each side, a 22 dp icon and 10 dp before the text.
    fun width(label: String): Dp = with(density) { measurer.measure(label, style).size.width.toDp() } + 22.dp * 2 + 32.dp
    var more by remember { mutableStateOf(false) }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Room for the focused button's zoom at the right edge.
        val available = maxWidth - TvDimens.Edge - 32.dp
        val widths = actions.map { width(it.label) }
        val primaryWidth = width(primaryLabel)
        val shown = (actions.size downTo 0).first { k ->
            val overflow = k < actions.size
            primaryWidth + widths.take(k).fold(0.dp) { a, w -> a + w + ROW_GAP } + (if (overflow) ROW_GAP + MORE_SIZE else 0.dp) <= available
        }
        Row(
            Modifier.padding(start = TvDimens.Edge, top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(ROW_GAP),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            primary()
            actions.take(shown).forEach { TvButton(it.label, it.run, icon = it.icon) }
            if (shown < actions.size) TvIconButton(Icons.Rounded.MoreVert, "More", { more = true }, size = MORE_SIZE)
        }
        if (more) {
            TvActionsDialog(
                title = title,
                actions = actions.drop(shown).map { TvAction(it.label, it.icon, run = it.run) },
                onDismiss = { more = false },
            )
        }
    }
}

private val ROW_GAP = 12.dp
private val MORE_SIZE = 48.dp

private fun versionDetail(f: MediaFileEntity, online: Boolean): String = listOfNotNull(
    FilenameParser.qualityTags(f.name, f.height).take(3).joinToString(" · ").ifBlank { null },
    Format.bytes(f.sizeBytes),
    when {
        LocalStorage.isLocal(f.accountEmail) -> "On this TV"
        !online -> "Google Drive · needs internet"
        else -> f.accountEmail
    },
).joinToString("  ·  ")

// ---------------------------------------------------------------------------------------------
// Show
// ---------------------------------------------------------------------------------------------

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun TvShowDetailScreen(id: Int, navigator: Navigator) {
    val vm = appViewModel("tv-show-$id") { ShowDetailViewModel(it, id) }
    val trailer by vm.trailer.collectAsStateWithLifecycle()
    val saved by vm.plans.saved.collectAsStateWithLifecycle()
    val online = rememberOnline()
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val primary = remember { FocusRequester() }
    var actionsFor by remember { mutableStateOf<EpisodeUi?>(null) }
    var lastOpened by rememberSaveable { mutableStateOf<Int?>(null) }
    val relatedRequesters = remember { mutableMapOf<Int, FocusRequester>() }
    val requesterFor = { key: Int -> relatedRequesters.getOrPut(key) { FocusRequester() } }

    val show = state.show
    if (state.loading || show == null) {
        LoadingBox(Modifier.fillMaxSize())
        return
    }
    val target = state.target
    LaunchedEffect(Unit) { focusOnArrival(lastOpened, requesterFor, primary) }
    val seasonWatched = state.episodes.filter { it.file != null }.let { eps -> eps.isNotEmpty() && eps.all { it.watched } }

    // The action buttons sit just under the header, so the title never scrolls away while they're focused.
    Box(Modifier.fillMaxSize()) {
    TvBackdrop(TmdbImages.backdrop(show.backdropPath))
    var header by remember { mutableStateOf(318.dp) }
    PivotScrolling(leading = header + 4.dp) { LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 60.dp)) {
        item("header") {
            DetailHeader(
                onHeight = { header = it },
                title = show.name,
                tagline = show.tagline,
                rating = show.rating,
                meta = listOf(
                    show.year?.toString(), show.certification, show.network, "${show.seasonCount} season${if (show.seasonCount == 1) "" else "s"}",
                    Plans.airLabel(show.nextEpisodeAirDate, LocalDate.now())?.let { day ->
                        "Next episode ${Format.episodeCode(show.nextEpisodeSeason, show.nextEpisodeNumber)} · $day"
                    },
                ),
                pills = show.genres.split(',').filter { it.isNotBlank() }.take(3),
                overview = show.overview,
            )
        }
        item("actions") {
            val primaryLabel = target?.let {
                val code = Format.episodeCode(it.file.season, it.file.episode)
                if (it.resuming) "Resume $code" else "Play $code"
            } ?: "All caught up"
            TvActionRow(
                title = show.name,
                primaryLabel = primaryLabel,
                primary = {
                    TvButton(
                        primaryLabel,
                        { target?.let { context.playFile(it.file.driveId, it.file.accountEmail) } },
                        icon = if (target != null) Icons.Rounded.PlayArrow else Icons.Rounded.Check,
                        enabled = target != null, focusRequester = primary,
                    )
                },
                actions = buildList {
                    add(
                        TvRowAction(
                            if (seasonWatched) "Mark season unwatched" else "Mark season watched",
                            if (seasonWatched) Icons.Rounded.Undo else Icons.Rounded.Check,
                        ) { vm.setSeasonWatched(!seasonWatched) }
                    )
                    add(watchlistAction(saved, vm.plans::toggleWatchlist))
                    trailer?.takeIf { online }?.let { key -> add(TvRowAction("Trailer", TrailerIcon) { context.openTrailer(key) }) }
                },
            )
        }
        if (state.seasons.size > 1) {
            item("seasons") {
                // Coming back up from the episodes lands on the selected season, not the chip that happens to be
                // above: chips select on focus, so the nearest one would switch seasons under the user.
                val seasonRequesters = remember { mutableMapOf<Int, FocusRequester>() }
                PivotScrolling {
                    LazyRow(
                        Modifier
                            .padding(top = 22.dp)
                            .focusProperties { enter = { seasonRequesters[state.selectedSeason] ?: FocusRequester.Default } }
                            .focusGroup(),
                        contentPadding = PaddingValues(horizontal = TvDimens.Edge, vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        items(state.seasons, key = { it.number }) { s ->
                            TvChip(
                                "${s.label}  ${s.watched}/${s.available}",
                                selected = s.number == state.selectedSeason,
                                focusRequester = seasonRequesters.getOrPut(s.number) { FocusRequester() },
                                // Focusing a season shows its episodes: no extra press needed.
                                onClick = { vm.selectSeason(s.number) },
                                onFocused = { vm.selectSeason(s.number) },
                            )
                        }
                    }
                }
            }
        }
        item("episodes") {
            Column(Modifier.padding(top = 18.dp)) {
                TvRowTitle(state.seasons.firstOrNull { it.number == state.selectedSeason }?.label ?: "Episodes")
                PivotScrolling {
                    LazyRow(contentPadding = TvRowPadding, horizontalArrangement = TvRowArrangement) {
                        items(state.episodes, key = { "${it.season}-${it.number}" }) { ep ->
                            val playable = ep.file != null && !ep.needsInternet
                            TvWideCard(
                                title = "${ep.number}. ${ep.name}",
                                subtitle = when {
                                    ep.needsInternet -> "On Google Drive · needs internet"
                                    ep.file == null -> "Not in library"
                                    else -> listOfNotNull(ep.runtime, ep.airDate).joinToString(" · ")
                                },
                                imageUrl = ep.stillUrl,
                                progress = ep.progress,
                                watched = ep.watched,
                                dimmed = !playable,
                                width = 248.dp,
                                onClick = { if (playable) ep.file?.let { context.playFile(it.driveId, it.accountEmail, fromStart = ep.watched) } },
                                onLongClick = { if (ep.file != null) actionsFor = ep },
                            )
                        }
                    }
                }
            }
        }
        item("cast") { CastRow(state.cast) }
        item("related") {
            RelatedRow(state.related, requesterFor) {
                lastOpened = it.id
                navigator.navigate(ShowRoute(it.id))
            }
        }
    } }
    }

    actionsFor?.let { ep ->
        val file = ep.file
        TvActionsDialog(
            title = "${Format.episodeCode(ep.season, ep.number)} · ${ep.name}",
            onDismiss = { actionsFor = null },
            actions = listOfNotNull(
                file?.takeIf { !ep.needsInternet }?.let { f -> TvAction("Play from the beginning", Icons.Rounded.Replay) { context.playFile(f.driveId, f.accountEmail, fromStart = true) } },
                TvAction(if (ep.watched) "Mark unwatched" else "Mark watched", if (ep.watched) Icons.Rounded.Undo else Icons.Rounded.Check) { vm.toggleEpisode(ep) },
            ),
        )
    }
}
