package com.pntapps.veltoret.player

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ClosedCaption
import androidx.compose.material.icons.rounded.FastForward
import androidx.compose.material.icons.rounded.FastRewind
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PlaylistPlay
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key

import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.C
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.compose.ContentFrame
import androidx.media3.ui.compose.SURFACE_TYPE_SURFACE_VIEW
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.tv.TvButton
import com.pntapps.veltoret.ui.tv.focusSoon
import com.pntapps.veltoret.ui.tv.TvChoiceDialog
import com.pntapps.veltoret.ui.tv.TvDimens
import com.pntapps.veltoret.ui.tv.TvListItem
import com.pntapps.veltoret.ui.tv.TvSidePanel
import com.pntapps.veltoret.ui.util.Format
import kotlinx.coroutines.delay
import kotlin.math.abs

private enum class TvSheet { Audio, Subtitles, Speed, Episodes, Info }

/** Seek feedback while the controls are hidden ("+30s" with a slim timeline). */
private data class SeekHint(val forward: Boolean, val seconds: Int, val stamp: Long)

/**
 * The 10-foot player. Remote mapping:
 *  - controls hidden: OK = pause/play (and show controls when pausing), ←/→ = seek (holding speeds up),
 *    ↑/↓ = show controls, Back = leave.
 *  - controls shown: arrows move between buttons; on the timeline ←/→ scrub. Back hides them.
 *  - media keys (play/pause, rewind, fast-forward, next, previous) work everywhere.
 */
@OptIn(UnstableApi::class)
@Composable
fun TvPlayerScreen(viewModel: PlayerViewModel, onExit: () -> Unit) {
    val player by viewModel.playerFlow.collectAsStateWithLifecycle()
    val ui by viewModel.ui.collectAsStateWithLifecycle()

    var isPlaying by remember { mutableStateOf(false) }
    var playbackState by remember { mutableIntStateOf(Player.STATE_IDLE) }
    var tracks by remember { mutableStateOf(Tracks.EMPTY) }
    var cues by remember { mutableStateOf(CueGroup.EMPTY_TIME_ZERO) }
    var speed by remember { mutableFloatStateOf(1f) }
    val clock = remember { PlaybackClock() }

    var controls by remember { mutableStateOf(true) }
    var interaction by remember { mutableIntStateOf(0) }
    var sheet by remember { mutableStateOf<TvSheet?>(null) }
    // Picture size: Fit (whole picture), Fill (zoom to fill the screen, crops edges) or Stretch. Shared with the
    // phone player's setting.
    var resize by remember { mutableStateOf(viewModel.prefs.resizeMode) }
    var hint by remember { mutableStateOf<SeekHint?>(null) }

    val root = remember { FocusRequester() }
    var rootFocused by remember { mutableStateOf(false) }
    val playButton = remember { FocusRequester() }
    val skipIntro = remember { FocusRequester() }
    val upNext = remember { FocusRequester() }
    val seekStepMs = ui.settings.seekSeconds * 1000L

    DisposableEffect(player) {
        isPlaying = player.isPlaying
        playbackState = player.playbackState
        tracks = player.currentTracks
        speed = player.playbackParameters.speed
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing }
            override fun onPlaybackStateChanged(state: Int) { playbackState = state }
            override fun onTracksChanged(t: Tracks) { tracks = t }
            override fun onCues(cueGroup: CueGroup) { cues = cueGroup }
            override fun onPlaybackParametersChanged(p: PlaybackParameters) { speed = p.speed }
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }
    LaunchedEffect(player) {
        while (true) {
            clock.position = player.currentPosition
            clock.duration = player.duration.coerceAtLeast(0)
            clock.buffered = player.bufferedPosition
            delay(200)
        }
    }
    LaunchedEffect(ui.finished) { if (ui.finished) onExit() }

    // Controls fade out after a few idle seconds while playing.
    LaunchedEffect(controls, isPlaying, interaction, sheet) {
        if (controls && isPlaying && sheet == null && ui.error == null) {
            delay(5_000)
            controls = false
        }
    }
    LaunchedEffect(hint?.stamp) { if (hint != null) { delay(1_400); hint = null } }
    LaunchedEffect(ui.resumedFrom) { if (ui.resumedFrom != null) { delay(7_000); viewModel.dismissResume() } }

    val skipIntroVisible = ui.isEpisode && !ui.introSkipped && clock.position in 5_000..180_000 && ui.error == null
    val remaining = clock.duration - clock.position
    val upNextVisible = ui.next != null && clock.duration > 0 && remaining in 1..30_000 && !ui.autoPlayCancelled &&
        ui.sleep?.endOfEpisode != true && ui.error == null

    // Where focus lives: the play button with controls, a prompt if one is showing, else the root.
    // (Not keyed on the side panels: closing one hands focus back to the button that opened it.)
    LaunchedEffect(controls, skipIntroVisible, upNextVisible, ui.error) {
        if (sheet != null || ui.error != null) return@LaunchedEffect
        when {
            controls -> playButton
            upNextVisible -> upNext
            skipIntroVisible -> skipIntro
            else -> root
        }.focusSoon()
    }

    fun show() { controls = true; interaction++ }
    fun togglePlay() {
        if (player.isPlaying) { player.pause(); show() } else player.play()
        interaction++
    }
    fun seek(forward: Boolean, repeat: Int) {
        // Holding the button accelerates: 1×, then 3×, then 6× the step.
        val step = seekStepMs * when { repeat > 20 -> 6; repeat > 6 -> 3; else -> 1 }
        viewModel.seekBy(if (forward) step else -step)
        val now = System.currentTimeMillis()
        val prev = hint
        val total = if (prev != null && prev.forward == forward && now - prev.stamp < 1_500) prev.seconds + (step / 1000).toInt() else (step / 1000).toInt()
        hint = SeekHint(forward, total, now)
        interaction++
    }

    BackHandler {
        when {
            sheet != null -> sheet = null
            controls && ui.error == null -> controls = false
            else -> onExit()
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            // Media keys and "wake the controls" handling, whatever is focused.
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                interaction++
                when (e.key) {
                    Key.MediaPlayPause -> { togglePlay(); true }
                    Key.MediaPlay -> { player.play(); true }
                    Key.MediaPause -> { player.pause(); show(); true }
                    Key.MediaFastForward -> { seek(true, e.nativeKeyEvent.repeatCount); true }
                    Key.MediaRewind -> { seek(false, e.nativeKeyEvent.repeatCount); true }
                    Key.MediaNext -> { if (ui.next != null) viewModel.playNext(); true }
                    Key.MediaPrevious -> { if (ui.previous != null) viewModel.playPrevious() else player.seekTo(0); true }
                    else -> false
                }
            }
            .focusRequester(root)
            .onFocusChanged { rootFocused = it.isFocused }
            .onKeyEvent { e ->
                // Key events bubble up from focused buttons too; act only when the root itself has focus
                // (controls hidden), otherwise arrows must move between buttons.
                if (!rootFocused || e.type != KeyEventType.KeyDown) return@onKeyEvent false
                when (e.key) {
                    Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> { togglePlay(); true }
                    Key.DirectionLeft -> { seek(false, e.nativeKeyEvent.repeatCount); true }
                    Key.DirectionRight -> { seek(true, e.nativeKeyEvent.repeatCount); true }
                    Key.DirectionUp, Key.DirectionDown -> { show(); true }
                    else -> false
                }
            }
            .focusable(),
    ) {
        ContentFrame(player = player, modifier = Modifier.fillMaxSize(), surfaceType = SURFACE_TYPE_SURFACE_VIEW, contentScale = when (resize) {
            ResizeMode.Fit -> ContentScale.Fit
            ResizeMode.Fill -> ContentScale.Crop
            ResizeMode.Stretch -> ContentScale.FillBounds
        })
        SubtitleLayer(viewModel, ui, clock, cues, inPip = false, raised = controls)

        if (playbackState == Player.STATE_BUFFERING && ui.error == null) {
            CircularProgressIndicator(Modifier.align(Alignment.Center).size(56.dp), color = VColors.Amber, strokeWidth = 4.dp)
        }

        // Seek hint while the controls are hidden.
        AnimatedVisibility(hint != null && !controls, enter = fadeIn(tween(120)), exit = fadeOut(tween(300)), modifier = Modifier.align(Alignment.BottomCenter)) {
            val h = hint
            Column(Modifier.fillMaxWidth().padding(horizontal = TvDimens.Edge, vertical = 36.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (h?.forward != false) Icons.Rounded.FastForward else Icons.Rounded.FastRewind, null, tint = VColors.Amber, modifier = Modifier.size(28.dp))
                    Spacer(Modifier.width(10.dp))
                    Text("${if (h?.forward != false) "+" else "−"}${h?.seconds ?: 0}s", style = MaterialTheme.typography.titleLarge, color = VColors.Text)
                    Spacer(Modifier.weight(1f))
                    Text("${Format.clock(clock.position)} / ${Format.clock(clock.duration)}", style = MaterialTheme.typography.titleMedium, color = VColors.Text)
                }
                Spacer(Modifier.height(10.dp))
                TimelineBar(clock, focused = false)
            }
        }

        // Prompts.
        if (skipIntroVisible && !controls && !upNextVisible) {
            PromptButton(
                "Skip intro", Icons.Rounded.FastForward, skipIntro,
                onClick = { viewModel.skipIntro() },
                onSeek = { forward, repeat -> seek(forward, repeat) },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = TvDimens.Edge, bottom = 40.dp),
            )
        }
        if (upNextVisible && !controls) {
            UpNextCard(
                label = ui.nextLabel.orEmpty(),
                seconds = (remaining / 1000).toInt(),
                autoPlay = ui.settings.autoPlayNext,
                requester = upNext,
                onPlay = viewModel::playNext,
                onCancel = { viewModel.cancelAutoPlay(); runCatching { root.requestFocus() } },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = TvDimens.Edge, bottom = 40.dp),
            )
        }
        ui.resumedFrom?.let { from ->
            if (!controls) {
                Text(
                    "Resumed at ${Format.clock(from)} · press ↓ for Start over",
                    style = MaterialTheme.typography.titleSmall,
                    color = VColors.Text,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 28.dp, end = TvDimens.Edge)
                        .clip(RoundedCornerShape(20.dp))
                        .background(VColors.SurfaceHigh.copy(alpha = 0.92f))
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }

        // Controls.
        AnimatedVisibility(controls && ui.error == null, enter = fadeIn(tween(180)), exit = fadeOut(tween(260)), modifier = Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize()) { Controls(
                ui = ui,
                clock = clock,
                isPlaying = isPlaying,
                speed = speed,
                playButton = playButton,
                onInteract = { interaction++ },
                onTogglePlay = ::togglePlay,
                onSeekBy = { viewModel.seekBy(it); interaction++ },
                onSheet = { sheet = it },
                resize = resize,
                onResize = {
                    resize = ResizeMode.entries[(resize.ordinal + 1) % ResizeMode.entries.size]
                    viewModel.prefs.resizeMode = resize
                    interaction++
                },
                onStartOver = { viewModel.startOver() },
                onPrevious = viewModel::playPrevious,
                onNext = viewModel::playNext,
            ) }
        }

        ui.error?.let { message -> ErrorPanel(message, ui.softwareDecoding, onExit, viewModel) }
    }

    when (sheet) {
        TvSheet.Audio -> AudioPanel(tracks, onDismiss = { sheet = null }) { g, i -> viewModel.selectTrack(g, i); sheet = null }
        TvSheet.Subtitles -> SubtitlePanel(tracks, ui, viewModel, onDismiss = { sheet = null })
        TvSheet.Speed -> TvChoiceDialog(
            title = "Playback speed",
            options = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 2f),
            label = { if (it == 1f) "Normal" else "${it}×" },
            selected = speed,
            onDismiss = { sheet = null },
            onSelect = { player.setPlaybackSpeed(it); sheet = null },
        )
        TvSheet.Episodes -> EpisodesPanel(viewModel, onDismiss = { sheet = null })
        TvSheet.Info -> InfoPanel(player, ui, viewModel, onDismiss = { sheet = null })
        null -> Unit
    }
}

// ---------------------------------------------------------------------------------------------

@Composable
private fun BoxScope.Controls(
    ui: PlayerUi,
    clock: PlaybackClock,
    isPlaying: Boolean,
    speed: Float,
    playButton: FocusRequester,
    onInteract: () -> Unit,
    onTogglePlay: () -> Unit,
    onSeekBy: (Long) -> Unit,
    onSheet: (TvSheet) -> Unit,
    resize: ResizeMode,
    onResize: () -> Unit,
    onStartOver: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
) {
    // Flat dim (no gradient) so white text is readable over any picture.
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)))

    Column(
        Modifier
            .align(Alignment.TopStart)
            .padding(start = TvDimens.Edge, top = TvDimens.Top + 8.dp, end = TvDimens.Edge)
    ) {
        Text(ui.title, style = MaterialTheme.typography.headlineMedium, color = VColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        ui.subtitle?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = MaterialTheme.typography.titleMedium, color = VColors.AmberSoft, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }

    Column(
        Modifier
            .align(Alignment.BottomCenter)
            .fillMaxWidth()
            .padding(horizontal = TvDimens.Edge, vertical = 32.dp)
    ) {
        SeekBar(clock, speed, onSeekBy, onInteract, seekStepMs = ui.settings.seekSeconds * 1000L)
        Spacer(Modifier.height(22.dp))
        var caption by remember { mutableStateOf("") }
        var buttonsFocused by remember { mutableStateOf(false) }
        val focusedAs: (String) -> Unit = { caption = it; onInteract() }
        Row(Modifier.fillMaxWidth().onFocusChanged { buttonsFocused = it.hasFocus }, verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
                if (ui.previous != null) PlayerButton(Icons.Rounded.SkipPrevious, "Previous episode", onPrevious, focusedAs)
                PlayerButton(Icons.Rounded.Replay10, "Back ${ui.settings.seekSeconds} seconds", { onSeekBy(-ui.settings.seekSeconds * 1000L) }, focusedAs)
                PlayerButton(
                    if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    if (isPlaying) "Pause" else "Play",
                    onTogglePlay, focusedAs, big = true, requester = playButton,
                )
                PlayerButton(Icons.Rounded.Forward10, "Forward ${ui.settings.seekSeconds} seconds", { onSeekBy(ui.settings.seekSeconds * 1000L) }, focusedAs)
                if (ui.next != null) PlayerButton(Icons.Rounded.SkipNext, ui.nextLabel?.let { "Next: $it" } ?: "Next episode", onNext, focusedAs)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
                if (ui.resumedFrom != null || clock.position > 60_000) PlayerButton(Icons.Rounded.Replay, "Start over", onStartOver, focusedAs)
                if (ui.isEpisode) PlayerButton(Icons.Rounded.PlaylistPlay, "Episodes", { onSheet(TvSheet.Episodes) }, focusedAs)
                PlayerButton(Icons.Rounded.GraphicEq, "Audio", { onSheet(TvSheet.Audio) }, focusedAs)
                PlayerButton(Icons.Rounded.ClosedCaption, "Subtitles", { onSheet(TvSheet.Subtitles) }, focusedAs)
                PlayerButton(Icons.Rounded.Speed, if (speed == 1f) "Playback speed" else "Playback speed · ${speed}×", { onSheet(TvSheet.Speed) }, focusedAs)
                PlayerButton(Icons.Rounded.AspectRatio, resizeLabel(resize), {
                    onResize()
                    // The caption shows the new mode right away (it otherwise changes only when focus moves).
                    caption = resizeLabel(ResizeMode.entries[(resize.ordinal + 1) % ResizeMode.entries.size])
                }, focusedAs)
                PlayerButton(Icons.Rounded.Info, "Video info", { onSheet(TvSheet.Info) }, focusedAs)
            }
        }
        Spacer(Modifier.height(12.dp))
        Text(if (buttonsFocused) caption else "", style = MaterialTheme.typography.titleSmall, color = VColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun resizeLabel(mode: ResizeMode) = "Picture size · " + when (mode) {
    ResizeMode.Fit -> "Fit (whole picture)"
    ResizeMode.Fill -> "Fill screen (zoom)"
    ResizeMode.Stretch -> "Stretch"
}

/** Round control; the focused one's name is shown in the caption under the row. */
@Composable
private fun PlayerButton(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    onFocused: (String) -> Unit,
    big: Boolean = false,
    requester: FocusRequester? = null,
) {
    val size = if (big) 64.dp else 52.dp
    com.pntapps.veltoret.ui.tv.TvSurface(
        onClick = onClick,
        modifier = Modifier.size(size),
        shape = CircleShape,
        color = if (big) VColors.Text.copy(alpha = 0.16f) else Color.Transparent,
        focusedColor = VColors.Amber,
        focusedScale = 1.12f,
        showRing = false,
        focusRequester = requester,
        onFocused = { onFocused(label) },
    ) { f ->
        Icon(icon, label, tint = if (f) VColors.OnAmber else VColors.Text, modifier = Modifier.align(Alignment.Center).size(size * 0.55f))
    }
}

@Composable
private fun SeekBar(clock: PlaybackClock, speed: Float, onSeekBy: (Long) -> Unit, onInteract: () -> Unit, seekStepMs: Long) {
    var focused by remember { mutableStateOf(false) }
    // While scrubbing, presses add up into a pending jump that's applied once the user pauses.
    var pending by remember { mutableLongStateOf(0L) }
    var pendingStamp by remember { mutableLongStateOf(0L) }
    LaunchedEffect(pendingStamp) {
        if (pending == 0L) return@LaunchedEffect
        delay(650)
        onSeekBy(pending)
        pending = 0L
    }
    val target = (clock.position + pending).coerceIn(0, clock.duration.coerceAtLeast(0))
    Column(
        Modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .onKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onKeyEvent false
                val repeat = e.nativeKeyEvent.repeatCount
                val step = seekStepMs * when { repeat > 20 -> 6; repeat > 6 -> 3; else -> 1 }
                when (e.key) {
                    Key.DirectionLeft -> { pending -= step; pendingStamp = System.nanoTime(); onInteract(); true }
                    Key.DirectionRight -> { pending += step; pendingStamp = System.nanoTime(); onInteract(); true }
                    Key.DirectionCenter, Key.Enter -> {
                        if (pending != 0L) { onSeekBy(pending); pending = 0L }
                        true
                    }
                    else -> false
                }
            }
            .focusable(),
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(Format.clock(target), style = MaterialTheme.typography.titleMedium, color = if (pending != 0L) VColors.Amber else VColors.Text)
            if (pending != 0L) {
                Spacer(Modifier.width(10.dp))
                Text("${if (pending > 0) "+" else "−"}${Format.clock(abs(pending))}", style = MaterialTheme.typography.titleSmall, color = VColors.AmberSoft)
            }
            Spacer(Modifier.weight(1f))
            if (clock.duration > 0) {
                Text(
                    "−${Format.clock(clock.duration - target)}  ·  ends ${endsAt(clock.duration - target, speed)}",
                    style = MaterialTheme.typography.titleSmall,
                    color = VColors.TextMuted,
                )
            }
        }
        Spacer(Modifier.height(10.dp))
        TimelineBar(clock, focused, overridePosition = if (pending != 0L) target else null)
        if (focused) {
            Spacer(Modifier.height(6.dp))
            Text("← → to scrub · OK to jump", style = MaterialTheme.typography.labelSmall, color = VColors.TextMuted)
        }
    }
}

@Composable
private fun TimelineBar(clock: PlaybackClock, focused: Boolean, overridePosition: Long? = null) {
    // Unknown duration (still loading, or a live/unseekable file): show an empty bar, not a full one.
    val duration = clock.duration
    val played = if (duration <= 0) 0f else ((overridePosition ?: clock.position).toFloat() / duration).coerceIn(0f, 1f)
    val buffered = if (duration <= 0) 0f else (clock.buffered.toFloat() / duration).coerceIn(0f, 1f)
    val height = if (focused) 8.dp else 5.dp
    Box(Modifier.fillMaxWidth().height(18.dp), contentAlignment = Alignment.CenterStart) {
        Box(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(4.dp)).background(VColors.Text.copy(alpha = 0.22f)))
        Box(Modifier.fillMaxWidth(buffered).height(height).clip(RoundedCornerShape(4.dp)).background(VColors.Text.copy(alpha = 0.32f)))
        Box(Modifier.fillMaxWidth(played).height(height).clip(RoundedCornerShape(4.dp)).background(VColors.Amber))
        if (focused) {
            Box(Modifier.fillMaxWidth(played), contentAlignment = Alignment.CenterEnd) {
                Box(Modifier.size(18.dp).clip(CircleShape).background(VColors.Amber).border(3.dp, VColors.Text, CircleShape))
            }
        }
    }
}

private fun endsAt(remainingMs: Long, speed: Float): String {
    val at = System.currentTimeMillis() + (remainingMs / speed.coerceAtLeast(0.25f)).toLong()
    return java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(at))
}

@Composable
private fun PromptButton(
    label: String,
    icon: ImageVector,
    requester: FocusRequester,
    onClick: () -> Unit,
    onSeek: (Boolean, Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    TvButton(
        label, onClick, icon = icon, focusRequester = requester,
        modifier = modifier.onKeyEvent { e ->
            // Seeking still works while the prompt holds focus.
            if (e.type != KeyEventType.KeyDown) return@onKeyEvent false
            when (e.key) {
                Key.DirectionLeft -> { onSeek(false, e.nativeKeyEvent.repeatCount); true }
                Key.DirectionRight -> { onSeek(true, e.nativeKeyEvent.repeatCount); true }
                else -> false
            }
        },
    )
}

@Composable
private fun UpNextCard(
    label: String,
    seconds: Int,
    autoPlay: Boolean,
    requester: FocusRequester,
    onPlay: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .width(380.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(VColors.SurfaceHigh)
            .padding(20.dp)
    ) {
        Text("UP NEXT", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
        Spacer(Modifier.height(4.dp))
        Text(label, style = MaterialTheme.typography.titleLarge, color = VColors.Text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton(if (autoPlay) "Play in ${seconds}s" else "Play now", onPlay, icon = Icons.Rounded.SkipNext, focusRequester = requester)
            if (autoPlay) TvButton("Cancel", onCancel)
        }
    }
}

@Composable
private fun BoxScope.ErrorPanel(message: String, software: Boolean, onExit: () -> Unit, viewModel: PlayerViewModel) {
    val retry = remember { FocusRequester() }
    LaunchedEffect(message) { retry.focusSoon() }
    Column(
        Modifier
            .align(Alignment.Center)
            .width(560.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(VColors.SurfaceHigh)
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Playback stopped", style = MaterialTheme.typography.headlineSmall, color = VColors.Text)
        Spacer(Modifier.height(10.dp))
        Text(message, style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted)
        Spacer(Modifier.height(24.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TvButton("Retry", viewModel::retry, icon = Icons.Rounded.PlayArrow, focusRequester = retry)
            if (!software) TvButton("Try software decoding", { viewModel.setSoftwareDecoding(true) }, icon = Icons.Rounded.Info)
            TvButton("Close", onExit, icon = Icons.AutoMirrored.Rounded.ArrowBack)
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Panels
// ---------------------------------------------------------------------------------------------

@Composable
private fun AudioPanel(tracks: Tracks, onDismiss: () -> Unit, onSelect: (Tracks.Group, Int) -> Unit) {
    val entries = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }.flatMap { g -> (0 until g.length).map { g to it } }
    val titles = MediaFormats.trackTitles(entries.map { (g, i) -> g.getTrackFormat(i) }, "Track", PlayerViewModel::languageName)
    val requesters = remember(entries.size) { List(entries.size) { FocusRequester() } }
    val start = entries.indexOfFirst { (g, i) -> g.isTrackSelected(i) }.coerceAtLeast(0)
    TvSidePanel("Audio", onDismiss, initialFocus = requesters.getOrNull(start)) {
        if (entries.isEmpty()) Text("No audio tracks", color = VColors.TextMuted)
        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(entries.indices.toList()) { n ->
                val (group, i) = entries[n]
                val f = group.getTrackFormat(i)
                TvListItem(
                    title = titles[n],
                    subtitle = listOfNotNull(
                        MediaFormats.cleanLabel(f.label)?.takeIf { it != PlayerViewModel.languageName(f.language) },
                        MediaFormats.audioCodec(f.sampleMimeType),
                        MediaFormats.channels(f.channelCount),
                        if (!group.isTrackSupported(i)) "not supported on this TV" else null,
                    ).joinToString(" · ").ifBlank { null },
                    selected = group.isTrackSelected(i),
                    enabled = group.isTrackSupported(i),
                    onClick = { onSelect(group, i) },
                    focusRequester = requesters[n],
                )
            }
        }
    }
}

@Composable
private fun SubtitlePanel(tracks: Tracks, ui: PlayerUi, viewModel: PlayerViewModel, onDismiss: () -> Unit) {
    val groups = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
    val entries = groups.flatMap { g -> (0 until g.length).map { g to it } }
    val titles = MediaFormats.trackTitles(entries.map { (g, i) -> g.getTrackFormat(i) }, "Subtitle", PlayerViewModel::languageName)
    val embeddedSelected = groups.any { it.isSelected }
    val off = remember { FocusRequester() }
    TvSidePanel("Subtitles", onDismiss, width = 460.dp, initialFocus = off) {
        LazyColumn(Modifier.weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            item {
                TvListItem("Off", { viewModel.disableSubtitles(); onDismiss() }, selected = ui.selectedExternal == null && !embeddedSelected, focusRequester = off)
            }
            items(entries.indices.toList()) { n ->
                val (group, i) = entries[n]
                val f = group.getTrackFormat(i)
                TvListItem(
                    title = titles[n],
                    subtitle = listOfNotNull(
                        MediaFormats.cleanLabel(f.label)?.takeIf { it != PlayerViewModel.languageName(f.language) },
                        MediaFormats.subtitleFormat(f),
                        if (f.selectionFlags and C.SELECTION_FLAG_FORCED != 0) "Forced" else null,
                    ).joinToString(" · ").ifBlank { null },
                    selected = ui.selectedExternal == null && group.isTrackSelected(i),
                    onClick = { viewModel.selectTrack(group, i); onDismiss() },
                )
            }
            items(ui.externalSubs, key = { it.id }) { s ->
                TvListItem(s.label, { viewModel.selectExternal(s.id); onDismiss() }, subtitle = "From the video's folder", selected = ui.selectedExternal == s.id)
            }
        }
        Spacer(Modifier.height(18.dp))
        Text("SYNC", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
        Spacer(Modifier.height(4.dp))
        Text(
            when {
                ui.subtitleOffsetMs == 0L -> "In sync with the video"
                ui.subtitleOffsetMs > 0 -> "Shown ${ui.subtitleOffsetMs / 1000.0}s later"
                else -> "Shown ${-ui.subtitleOffsetMs / 1000.0}s earlier"
            },
            style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted,
        )
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TvButton("−0.25s", { viewModel.adjustSubtitleOffset(-250) })
            TvButton("+0.25s", { viewModel.adjustSubtitleOffset(250) })
            if (ui.subtitleOffsetMs != 0L) TvButton("Reset", viewModel::resetSubtitleOffset)
        }
    }
}

@Composable
private fun EpisodesPanel(viewModel: PlayerViewModel, onDismiss: () -> Unit) {
    var list by remember { mutableStateOf<List<EpisodeItem>?>(null) }
    LaunchedEffect(Unit) { list = runCatching { viewModel.episodeList() }.getOrDefault(emptyList()) }
    val episodes = list
    val requesters = remember(episodes?.size) { List(episodes?.size ?: 0) { FocusRequester() } }
    val current = episodes?.indexOfFirst { it.current }?.coerceAtLeast(0) ?: 0
    TvSidePanel("Episodes", onDismiss, width = 480.dp, initialFocus = requesters.getOrNull(current)) {
        if (episodes == null) Text("Loading…", color = VColors.TextMuted)
        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp), contentPadding = PaddingValues(bottom = 24.dp)) {
            items(episodes.orEmpty().indices.toList()) { n ->
                val ep = episodes!![n]
                TvListItem(
                    title = "${Format.episodeCode(ep.season, ep.episode)} · ${ep.name}",
                    subtitle = when {
                        ep.current -> "Playing now"
                        ep.watched -> "Watched"
                        else -> null
                    },
                    selected = ep.current,
                    onClick = { if (!ep.current) viewModel.playEpisode(ep); onDismiss() },
                    focusRequester = requesters[n],
                )
            }
        }
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun InfoPanel(player: Player, ui: PlayerUi, viewModel: PlayerViewModel, onDismiss: () -> Unit) {
    val decoders by viewModel.decoders.collectAsStateWithLifecycle()
    val first = remember { FocusRequester() }
    val video = player.currentTracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO && it.isSelected }?.let { g ->
        (0 until g.length).firstOrNull { g.isTrackSelected(it) }?.let { g.getTrackFormat(it) }
    }
    TvSidePanel("Video info", onDismiss, width = 480.dp, initialFocus = first) {
        InfoLine("File", ui.fileName)
        InfoLine("Size", Format.bytes(ui.fileSize))
        InfoLine("Video", listOfNotNull(MediaFormats.resolution(video), MediaFormats.videoCodec(video?.sampleMimeType)).joinToString(" · ").ifBlank { null })
        InfoLine("Video decoder", decoders.video)
        InfoLine("Audio decoder", decoders.audio)
        if (decoders.droppedFrames > 0) InfoLine("Dropped frames", decoders.droppedFrames.toString())
        Spacer(Modifier.height(18.dp))
        TvListItem(
            title = "Software decoding",
            subtitle = "Use if the picture stutters or shows errors. Slower, uses more power.",
            trailing = if (ui.softwareDecoding) "On" else "Off",
            onClick = { viewModel.setSoftwareDecoding(!ui.softwareDecoding) },
            focusRequester = first,
        )
    }
}

@Composable
private fun InfoLine(label: String, value: String?) {
    if (value.isNullOrBlank()) return
    Row(Modifier.padding(vertical = 4.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted, modifier = Modifier.width(140.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = VColors.Text, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}
