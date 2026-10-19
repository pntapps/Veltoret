package com.pntapps.veltoret.ui.details

import com.pntapps.veltoret.ui.util.canPlayNow
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.DoneAll
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.RemoveDone
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.CreditEntity
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.db.ShowEntity
import com.pntapps.veltoret.data.db.progress
import com.pntapps.veltoret.data.library.EpisodeTarget
import com.pntapps.veltoret.data.library.PlayTargets
import com.pntapps.veltoret.data.library.WatchKeys
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.CardShape
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.MetaLine
import com.pntapps.veltoret.ui.components.RatingText
import com.pntapps.veltoret.ui.components.SelectChip
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.components.VProgress
import com.pntapps.veltoret.ui.home.PosterItem
import com.pntapps.veltoret.ui.navigation.FixMatchRoute
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.gutter
import com.pntapps.veltoret.ui.util.rememberOnline
import kotlinx.coroutines.flow.MutableStateFlow
import com.pntapps.veltoret.data.plans.Plans
import java.time.LocalDate
import androidx.compose.foundation.combinedClickable
import androidx.compose.material.icons.rounded.NotificationsActive
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class EpisodeUi(
    val season: Int,
    val number: Int,
    val name: String,
    val overview: String,
    val stillUrl: String?,
    val runtime: String?,
    val airDate: String?,
    val file: MediaFileEntity?,
    val watched: Boolean,
    val progress: Float?,
    /** Offline and only stored on Drive. */
    val needsInternet: Boolean = false,
    /** TMDB's air date ("yyyy-MM-dd"), for "Remind me" on the day it airs. */
    val airDateIso: String? = null,
    /** Airs today or later. */
    val upcoming: Boolean = false,
)

data class SeasonUi(val number: Int, val label: String, val watched: Int, val available: Int)

data class ShowDetailState(
    val loading: Boolean = true,
    val show: ShowEntity? = null,
    val seasons: List<SeasonUi> = emptyList(),
    val selectedSeason: Int = 1,
    val episodes: List<EpisodeUi> = emptyList(),
    val target: EpisodeTarget? = null,
    val cast: List<CreditEntity> = emptyList(),
    val allFileIds: List<String> = emptyList(),
    /** "More like this": TMDB's recommendations that are in the library. */
    val related: List<PosterItem> = emptyList(),
)

class ShowDetailViewModel(private val container: AppContainer, private val id: Int) : ViewModel() {
    private val library = container.libraryRepository
    private val selected = MutableStateFlow<Int?>(null)

    private val base = combine(
        library.show(id), library.seasons(id), library.episodes(id), library.showFiles(id), container.watchRepository.observeForShow(id),
    ) { show, seasons, episodes, files, states -> Base(show, seasons, episodes, files, states) }

    private val related = library.relatedShows(id).map { rows ->
        rows.map { row ->
            PosterItem(
                id = row.show.tmdbId, isShow = true, title = row.show.name,
                subtitle = "${row.availableEpisodes} episode${if (row.availableEpisodes == 1) "" else "s"}",
                posterUrl = TmdbImages.poster(row.show.posterPath),
            )
        }
    }

    val state: StateFlow<ShowDetailState> = combine(
        base, library.credits("tv", id), selected, container.connectivity.online, related,
    ) { b, cast, sel, online, related ->
        val statesByKey = b.states.associateBy { it.key }
        val filesByEpisode = b.files.filter { it.season != null && it.episode != null }
            .groupBy { it.season!! to it.episode!! }
        val tmdbEpisodes = b.episodes.associateBy { it.seasonNumber to it.episodeNumber }
        val keys = (filesByEpisode.keys + tmdbEpisodes.keys.filter { (s, _) -> filesByEpisode.keys.any { it.first == s } })
        val seasonNumbers = keys.map { it.first }.distinct().sortedBy { if (it == 0) Int.MAX_VALUE else it }
        // Offline, "Play" picks among the episodes stored on this device.
        val target = PlayTargets.nextEpisode(b.files.filter { canPlayNow(it.accountEmail, online) }, b.states)
        val current = sel ?: target?.file?.season ?: seasonNumbers.firstOrNull() ?: 1

        fun isWatched(s: Int, e: Int) = statesByKey[WatchKeys.episode(id, s, e)]?.watched == true

        val seasons = seasonNumbers.map { s ->
            val available = filesByEpisode.keys.filter { it.first == s }
            SeasonUi(
                number = s,
                label = if (s == 0) "Specials" else "Season $s",
                watched = available.count { (ss, e) -> isWatched(ss, e) },
                available = available.size,
            )
        }
        val episodes = keys.filter { it.first == current }.distinct().sortedBy { it.second }.map { key ->
            val meta = tmdbEpisodes[key]
            val file = filesByEpisode[key]?.firstOrNull()
            val st = statesByKey[WatchKeys.episode(id, key.first, key.second)]
            EpisodeUi(
                season = key.first,
                number = key.second,
                name = meta?.name?.takeIf { it.isNotBlank() } ?: "Episode ${key.second}",
                overview = meta?.overview.orEmpty(),
                stillUrl = TmdbImages.still(meta?.stillPath),
                runtime = Format.runtime(meta?.runtimeMin) ?: file?.let { Format.runtimeMs(it.durationMs) },
                airDate = Format.date(meta?.airDate),
                file = file,
                watched = st?.watched == true,
                progress = st?.takeIf { !it.watched && it.positionMs > 30_000 }?.progress,
                needsInternet = file != null && !canPlayNow(file.accountEmail, online),
                airDateIso = meta?.airDate,
                upcoming = Plans.isUpcoming(meta?.airDate, LocalDate.now()),
            )
        }
        ShowDetailState(false, b.show, seasons, current, episodes, target, cast, b.files.map { it.driveId }, related)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ShowDetailState())

    /** Watch later (with new-episode alerts) and reminders. */
    val plans = TitlePlans(container, viewModelScope, Plans.TV, id)

    private val _trailer = MutableStateFlow<String?>(null)
    /** YouTube id of the show's latest trailer, once TMDB answers; null when there is none (or offline). */
    val trailer: StateFlow<String?> = _trailer

    init {
        // Shows matched before "More like this" existed (or a month ago) get their list now rather than at the next scan.
        if (container.connectivity.isOnline) viewModelScope.launch {
            runCatching { container.tmdbRepository.ensureRecommendations("tv", id) }
        }
        if (container.connectivity.isOnline) viewModelScope.launch {
            _trailer.value = runCatching { container.tmdbRepository.trailer("tv", id) }.getOrNull()
        }
    }

    fun selectSeason(season: Int) { selected.value = season }

    fun toggleEpisode(ep: EpisodeUi) {
        viewModelScope.launch { container.watchRepository.setEpisodeWatched(id, ep.season, ep.number, !ep.watched) }
    }

    fun setSeasonWatched(watched: Boolean) {
        val s = state.value
        val eps = s.episodes.filter { it.file != null }.map { it.season to it.number }
        viewModelScope.launch { container.watchRepository.setEpisodesWatched(id, eps, watched) }
    }

    private data class Base(
        val show: ShowEntity?,
        val seasons: List<com.pntapps.veltoret.data.db.SeasonEntity>,
        val episodes: List<com.pntapps.veltoret.data.db.EpisodeEntity>,
        val files: List<MediaFileEntity>,
        val states: List<com.pntapps.veltoret.data.db.WatchStateEntity>,
    )
}

@Composable
fun ShowDetailScreen(id: Int, navigator: Navigator) {
    val vm = appViewModel("show-$id") { ShowDetailViewModel(it, id) }
    val state by vm.state.collectAsStateWithLifecycle()
    val trailer by vm.trailer.collectAsStateWithLifecycle()
    val saved by vm.plans.saved.collectAsStateWithLifecycle()
    val reminders by vm.plans.reminders.collectAsStateWithLifecycle()
    // What "Remind me" is for: the whole show (null episode) or one episode.
    var reminding by remember { mutableStateOf<Pair<String, EpisodeUi?>?>(null) }
    val online = rememberOnline()
    val context = LocalContext.current
    val widthClass = LocalWidthClass.current
    val wide = widthClass != WidthClass.Compact
    val gutter = gutter()

    val show = state.show
    if (show == null) {
        LoadingBox()
        LaunchedEffect(state.loading) { if (!state.loading) navigator.back() }
        return
    }
    val target = state.target

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp)) {
        item("header") {
            DetailHeader(
                title = show.name,
                backdropUrl = TmdbImages.backdrop(show.backdropPath),
                posterUrl = TmdbImages.poster(show.posterPath, "w500"),
                onBack = navigator::back,
            ) {
                DetailTitle(show.name, show.tagline)
                Spacer(Modifier.height(12.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RatingText(show.rating)
                    if (show.rating > 0) Spacer(Modifier.width(12.dp))
                    MetaLine(
                        listOf(
                            show.year?.toString(), show.certification, show.network,
                            "${show.seasonCount} season${if (show.seasonCount == 1) "" else "s"}",
                        )
                    )
                }
                TagRow(show.genres.split(',').filter { it.isNotBlank() }, listOfNotNull(show.status?.takeIf { it == "Returning Series" }?.let { "Returning" }))
                Spacer(Modifier.height(20.dp))
                if (target?.resuming == true && target.state != null) {
                    VProgress(target.state.progress, Modifier.padding(bottom = 12.dp))
                }
                // One line: Play, Trailer, Watchlist, ⋮ (the least used move into ⋮ when crowded).
                val label = when {
                    target == null -> "All caught up"
                    target.resuming -> "Resume ${Format.episodeCode(target.file.season, target.file.episode)}"
                    else -> "Play ${Format.episodeCode(target.file.season, target.file.episode)}"
                }
                DetailActionRow(
                    playLabel = label,
                    play = {
                        DetailPlayButton(label, Icons.Rounded.PlayArrow, enabled = target != null, fill = !wide) {
                            target?.let { context.playFile(it.file.driveId, it.file.accountEmail) }
                        }
                    },
                    trailerKey = trailer?.takeIf { online },
                    labelledTrailer = wide,
                    saved = saved,
                    onToggleWatchlist = vm.plans::toggleWatchlist,
                    menu = listOf(
                        DetailMenuItem("Remind me…", Icons.Rounded.NotificationsActive) { reminding = show.name to null },
                        DetailMenuItem("Mark season watched", Icons.Rounded.DoneAll) { vm.setSeasonWatched(true) },
                        DetailMenuItem("Mark season unwatched", Icons.Rounded.RemoveDone) { vm.setSeasonWatched(false) },
                        DetailMenuItem("Fix match", Icons.Rounded.Edit) {
                            navigator.navigate(FixMatchRoute(state.allFileIds, MediaKind.EPISODE.name, show.name))
                        },
                    ),
                )
                ReminderList(reminders, vm.plans::cancelReminder)
                Overview(show.overview)
                // "Next episode  S3 · E2 "Title" · Friday" while one is announced.
                if (Plans.isUpcoming(show.nextEpisodeAirDate, LocalDate.now())) {
                    CreditLine(
                        "Next episode",
                        listOfNotNull(
                            Format.episodeCode(show.nextEpisodeSeason, show.nextEpisodeNumber).ifEmpty { null },
                            show.nextEpisodeName?.let { "“$it”" },
                            Plans.airLabel(show.nextEpisodeAirDate, LocalDate.now()),
                        ).joinToString("  ·  "),
                    )
                }
                CreditLine("Created by", show.creator)
                CreditLine("First aired", Format.date(show.firstAirDate))
            }
        }

        item("seasons") {
            LazyRow(
                contentPadding = PaddingValues(horizontal = gutter),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(top = if (widthClass == WidthClass.Expanded) 40.dp else 8.dp, bottom = 16.dp),
            ) {
                items(state.seasons, key = { it.number }) { s ->
                    SelectChip(
                        if (s.watched == s.available && s.available > 0) "${s.label}  ✓" else s.label,
                        s.number == state.selectedSeason,
                        { vm.selectSeason(s.number) },
                    )
                }
            }
        }

        // Two columns of episodes on landscape tablets.
        val perRow = if (widthClass == WidthClass.Expanded) 2 else 1
        items(state.episodes.chunked(perRow), key = { row -> row.joinToString { "${it.season}-${it.number}" } }) { row ->
            Row(Modifier.padding(horizontal = gutter - 20.dp)) {
                row.forEach { ep ->
                    EpisodeRow(
                        ep,
                        wide = wide,
                        onPlay = { ep.file?.let { context.playFile(it.driveId, it.accountEmail, fromStart = ep.watched) } },
                        onToggleWatched = { vm.toggleEpisode(ep) },
                        onRemind = { reminding = "${show.name} · ${Format.episodeCode(ep.season, ep.number)}" to ep },
                        modifier = Modifier.weight(1f),
                    )
                }
                repeat(perRow - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }

        item("cast") { CastRow(state.cast) }
        item("related") { RelatedRow(state.related) { navigator.navigate(ShowRoute(it.id)) } }
    }
    // Outside the list: a dialog inside a lazy item disappears when that item scrolls out of view.
    reminding?.let { (label, ep) ->
        // An episode that hasn't aired yet can be reminded about on its air day.
        val airDay = ep?.takeIf { it.upcoming }?.airDateIso?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        ReminderDialog(
            label,
            onDismiss = { reminding = null },
            onPick = { at -> vm.plans.remind(label, at, ep?.season, ep?.number); reminding = null },
            extra = listOfNotNull(airDay?.let { "When it airs (${Plans.airLabel(it.toString(), LocalDate.now())}, 8 PM)" to it.atTime(20, 0) }),
        )
    }
}

@Composable
private fun EpisodeRow(
    ep: EpisodeUi,
    wide: Boolean,
    onPlay: () -> Unit,
    onToggleWatched: () -> Unit,
    onRemind: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val available = ep.file != null && !ep.needsInternet
    var menu by remember { mutableStateOf(false) }
    Box(modifier) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(CardShape)
            // Tapping an episode that can't play opens its menu (Remind me) instead of doing nothing.
            .combinedClickable(onClick = { if (available) onPlay() else menu = true }, onLongClick = { menu = true })
            .padding(horizontal = 20.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        // Unavailable episodes are dimmed; an upcoming one's bell stays bright.
        val dim = if (available) 1f else 0.45f
        Box(
            Modifier
                .alpha(dim)
                .width(if (wide) 200.dp else 136.dp)
                .aspectRatio(16f / 9f)
                .clip(CardShape)
                .border(1.dp, VColors.Outline, CardShape)
        ) {
            VImage(ep.stillUrl, ep.name, Modifier.fillMaxSize(), fallbackText = "E${ep.number}")
            if (available) {
                Box(
                    Modifier
                        .align(Alignment.Center)
                        .size(34.dp)
                        .clip(CircleShape)
                        .background(VColors.ImageDim),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Rounded.PlayArrow, null, tint = VColors.Text, modifier = Modifier.size(20.dp)) }
            }
            if (ep.progress != null) {
                VProgress(ep.progress, Modifier.align(Alignment.BottomCenter).padding(6.dp), track = VColors.ImageDim)
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f).alpha(dim)) {
            Text(
                "${ep.number}. ${ep.name}",
                style = MaterialTheme.typography.titleSmall,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(3.dp))
            Text(
                listOfNotNull(ep.runtime, ep.airDate, when {
                    ep.needsInternet -> "On Google Drive · needs internet"
                    ep.file == null -> "Not in library"
                    else -> null
                }).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextMuted,
            )
            if (ep.overview.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    ep.overview,
                    style = MaterialTheme.typography.bodySmall,
                    color = VColors.TextMuted,
                    maxLines = if (wide) 3 else 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (available) {
            Icon(
                if (ep.watched) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
                if (ep.watched) "Mark unwatched" else "Mark watched",
                tint = if (ep.watched) VColors.Amber else VColors.TextFaint,
                modifier = Modifier
                    .padding(start = 8.dp)
                    .clip(RoundedCornerShape(50))
                    .clickable(onClick = onToggleWatched)
                    .padding(6.dp)
                    .size(24.dp),
            )
        } else if (ep.upcoming) {
            Icon(
                Icons.Rounded.NotificationsActive, "Remind me",
                tint = VColors.Amber,
                modifier = Modifier
                    .padding(start = 8.dp)
                    .clip(RoundedCornerShape(50))
                    .clickable(onClick = onRemind)
                    .padding(6.dp)
                    .size(24.dp),
            )
        }
    }
    DropdownMenu(menu, { menu = false }, containerColor = VColors.SurfaceHigh) {
        DropdownMenuItem(
            text = { Text("Remind me…") },
            leadingIcon = { Icon(Icons.Rounded.NotificationsActive, null) },
            onClick = { menu = false; onRemind() },
        )
        if (available) DropdownMenuItem(
            text = { Text(if (ep.watched) "Mark unwatched" else "Mark watched") },
            leadingIcon = { Icon(if (ep.watched) Icons.Rounded.RadioButtonUnchecked else Icons.Rounded.CheckCircle, null) },
            onClick = { menu = false; onToggleWatched() },
        )
    }
    }
}
