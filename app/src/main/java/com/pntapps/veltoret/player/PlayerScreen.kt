package com.pntapps.veltoret.player

import android.content.Context
import android.media.AudioManager
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Audiotrack
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.BrightnessMedium
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.FastForward
import androidx.compose.material.icons.rounded.FastRewind
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.PictureInPictureAlt
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.ScreenRotation
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Subtitles
import androidx.compose.material.icons.rounded.VideoLibrary
import androidx.compose.material.icons.rounded.ZoomIn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.C
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import androidx.media3.ui.compose.ContentFrame
import androidx.media3.ui.compose.SURFACE_TYPE_SURFACE_VIEW
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

private enum class Sheet { Audio, Subtitles, DriveSubtitles, Speed, Episodes, More, Info, Sleep }

private data class Hud(val icon: ImageVector, val text: String)

/** Double-tap seek feedback; consecutive taps on the same side add up (+10, +20, +30…). */
private data class SeekFeedback(val forward: Boolean, val seconds: Int, val stamp: Long)

/** Fast-changing playback numbers live here so only the timeline and subtitles recompose. */
@Stable
internal class PlaybackClock {
    var position by mutableLongStateOf(0L)
    var duration by mutableLongStateOf(0L)
    var buffered by mutableLongStateOf(0L)
}

@kotlin.OptIn(ExperimentalMaterial3Api::class)
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(
    viewModel: PlayerViewModel,
    inPip: Boolean,
    onExit: () -> Unit,
    onEnterPip: () -> Unit,
    onRotate: () -> Unit,
) {
    val player by viewModel.playerFlow.collectAsStateWithLifecycle()
    val ui by viewModel.ui.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val activity = LocalActivity.current
    val scope = rememberCoroutineScope()

    var isPlaying by remember { mutableStateOf(false) }
    var playbackState by remember { mutableIntStateOf(Player.STATE_IDLE) }
    var tracks by remember { mutableStateOf(Tracks.EMPTY) }
    var playerCues by remember { mutableStateOf(CueGroup.EMPTY_TIME_ZERO) }
    var speed by remember { mutableFloatStateOf(1f) }
    val clock = remember { PlaybackClock() }

    var controlsVisible by remember { mutableStateOf(true) }
    var locked by remember { mutableStateOf(false) }
    var resize by remember { mutableStateOf(viewModel.prefs.resizeMode) }
    var zoom by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var sheet by remember { mutableStateOf<Sheet?>(null) }
    var hud by remember { mutableStateOf<Hud?>(null) }
    var seekFeedback by remember { mutableStateOf<SeekFeedback?>(null) }
    var holdingFast by remember { mutableStateOf(false) }
    var interaction by remember { mutableIntStateOf(0) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }

    BackHandler { if (sheet != null) sheet = null else if (!locked) onExit() }
    LaunchedEffect(ui.finished) { if (ui.finished) onExit() }

    DisposableEffect(player) {
        isPlaying = player.isPlaying
        playbackState = player.playbackState
        tracks = player.currentTracks
        speed = player.playbackParameters.speed
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playing: Boolean) { isPlaying = playing }
            override fun onPlaybackStateChanged(state: Int) { playbackState = state }
            override fun onTracksChanged(t: Tracks) { tracks = t }
            override fun onCues(cueGroup: CueGroup) { playerCues = cueGroup }
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
            delay(100)
        }
    }

    // Auto-hide controls while playing.
    LaunchedEffect(controlsVisible, isPlaying, interaction, sheet, scrubbing) {
        if (controlsVisible && isPlaying && sheet == null && scrubbing == null) {
            delay(4_000)
            controlsVisible = false
        }
    }
    LaunchedEffect(hud) {
        if (hud != null) {
            delay(1_000)
            hud = null
        }
    }
    LaunchedEffect(seekFeedback?.stamp) {
        if (seekFeedback != null) {
            delay(900)
            seekFeedback = null
        }
    }
    LaunchedEffect(ui.notice) {
        ui.notice?.let {
            hud = Hud(Icons.Rounded.Info, it)
            viewModel.consumeNotice()
        }
    }
    LaunchedEffect(ui.resumedFrom) {
        if (ui.resumedFrom != null) {
            delay(7_000)
            viewModel.dismissResume()
        }
    }

    val audioManager = remember { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    val maxVolume = remember { audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1) }
    val seekStep = ui.settings.seekSeconds
    val edgeGuardPx = with(LocalDensity.current) { 28.dp.toPx() }

    fun doubleTapSeek(forward: Boolean) {
        val now = System.currentTimeMillis()
        val previous = seekFeedback
        val total = if (previous != null && previous.forward == forward && now - previous.stamp < 1_200) previous.seconds + seekStep else seekStep
        viewModel.seekBy(if (forward) seekStep * 1000L else -seekStep * 1000L)
        seekFeedback = SeekFeedback(forward, total, now)
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
    ) {
        // ---- Video ------------------------------------------------------------------------------
        ContentFrame(
            player = player,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = zoom
                    scaleY = zoom
                    translationX = pan.x
                    translationY = pan.y
                },
            surfaceType = SURFACE_TYPE_SURFACE_VIEW,
            contentScale = when (resize) {
                ResizeMode.Fit -> ContentScale.Fit
                ResizeMode.Fill -> ContentScale.Crop
                ResizeMode.Stretch -> ContentScale.FillBounds
            },
        )

        SubtitleLayer(viewModel, ui, clock, playerCues, inPip, controlsVisible && !inPip)

        if (inPip) return@Box

        // ---- Gestures -----------------------------------------------------------------------------
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(locked, seekStep) {
                    detectTapGestures(
                        onTap = { controlsVisible = !controlsVisible; interaction++ },
                        onDoubleTap = { offset ->
                            if (locked) return@detectTapGestures
                            when {
                                offset.x < size.width / 3f -> doubleTapSeek(forward = false)
                                offset.x > size.width * 2f / 3f -> doubleTapSeek(forward = true)
                                else -> if (player.isPlaying) player.pause() else player.play()
                            }
                        },
                        onLongPress = {
                            if (!locked && player.isPlaying) {
                                holdingFast = true
                                player.setPlaybackSpeed(2f)
                            }
                        },
                        onPress = {
                            val previousSpeed = player.playbackParameters.speed
                            tryAwaitRelease()
                            if (holdingFast) {
                                holdingFast = false
                                player.setPlaybackSpeed(if (previousSpeed == 2f) 1f else previousSpeed)
                            }
                        },
                    )
                }
                .pointerInput(locked, resize) {
                    if (locked) return@pointerInput
                    // One finger: brightness (left) / volume (right) / seek (horizontal).
                    // Two fingers: pinch to zoom and pan.
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val nearEdge = down.position.x < edgeGuardPx || down.position.x > size.width - edgeGuardPx ||
                            down.position.y < edgeGuardPx * 2 || down.position.y > size.height - edgeGuardPx * 2
                        var mode = 0 // 0 undecided, 1 brightness, 2 volume, 3 seek, 4 zoom, -1 ignore
                        var accumX = 0f
                        var accumY = 0f
                        var startValue = 0f
                        val seekBase = player.currentPosition
                        val slop = viewConfiguration.touchSlop
                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break
                            if (pressed.size >= 2) {
                                if (mode != 4) { mode = 4; hud = null }
                                val newZoom = (zoom * event.calculateZoom()).coerceIn(1f, 5f)
                                val maxX = (newZoom - 1f) * size.width / 2f
                                val maxY = (newZoom - 1f) * size.height / 2f
                                val p = pan + event.calculatePan()
                                zoom = newZoom
                                pan = Offset(p.x.coerceIn(-maxX, maxX), p.y.coerceIn(-maxY, maxY))
                                hud = Hud(Icons.Rounded.ZoomIn, String.format(Locale.US, "Zoom %.1f×", zoom))
                                event.changes.forEach { it.consume() }
                                continue
                            }
                            if (mode == 4 || mode == -1) continue
                            val change = pressed.first()
                            val delta = change.positionChange()
                            accumX += delta.x
                            accumY += delta.y
                            if (mode == 0 && (abs(accumX) > slop || abs(accumY) > slop)) {
                                mode = when {
                                    nearEdge -> -1 // leave edge swipes to Android (back / notifications)
                                    abs(accumX) > abs(accumY) -> 3
                                    down.position.x < size.width / 2f -> 1
                                    else -> 2
                                }
                                startValue = when (mode) {
                                    1 -> activity?.window?.attributes?.screenBrightness?.takeIf { it >= 0 }
                                        ?: (Settings.System.getInt(context.contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255f)
                                    2 -> {
                                        val vol = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                                        if (vol >= maxVolume) 1f + viewModel.ui.value.boost else vol.toFloat() / maxVolume
                                    }
                                    else -> 0f
                                }
                            }
                            when (mode) {
                                1 -> {
                                    val value = (startValue - accumY / (size.height * 0.7f)).coerceIn(0.01f, 1f)
                                    activity?.window?.let { w -> w.attributes = w.attributes.apply { screenBrightness = value } }
                                    hud = Hud(Icons.Rounded.BrightnessMedium, "Brightness ${(value * 100).roundToInt()}%")
                                }
                                2 -> {
                                    // 0–100% is the system volume; 100–200% is a loudness boost.
                                    val value = (startValue - accumY / (size.height * 0.7f)).coerceIn(0f, 2f)
                                    if (value <= 1f) {
                                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, (value * maxVolume).roundToInt(), 0)
                                        if (viewModel.ui.value.boost > 0f) viewModel.setBoost(0f)
                                    } else {
                                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, maxVolume, 0)
                                        viewModel.setBoost(value - 1f)
                                    }
                                    hud = Hud(
                                        Icons.AutoMirrored.Rounded.VolumeUp,
                                        "Volume ${(value * 100).roundToInt()}%" + if (value > 1f) " · Boost" else "",
                                    )
                                }
                                3 -> if (player.duration > 0) {
                                    // Full screen width ≈ 3 minutes.
                                    val target = (seekBase + (accumX / size.width) * 180_000).toLong().coerceIn(0, player.duration)
                                    scrubbing = target.toFloat() / player.duration
                                    val d = (target - seekBase) / 1000
                                    hud = Hud(
                                        if (d >= 0) Icons.Rounded.FastForward else Icons.Rounded.FastRewind,
                                        "${if (d >= 0) "+" else "−"}${Format.clock(abs(d) * 1000)}  ·  ${Format.clock(target)}",
                                    )
                                }
                            }
                            if (mode > 0) change.consume()
                        }
                        if (mode == 3) {
                            scrubbing?.let { player.seekTo((it * player.duration).toLong()) }
                            scrubbing = null
                        }
                        if (mode == 4 && zoom < 1.05f) {
                            zoom = 1f
                            pan = Offset.Zero
                        }
                    }
                }
        )

        // ---- Feedback overlays ---------------------------------------------------------------------
        seekFeedback?.let { SeekRipple(it) }

        if (playbackState == Player.STATE_BUFFERING && ui.error == null) {
            CircularProgressIndicator(
                color = VColors.Amber,
                strokeWidth = 3.dp,
                modifier = Modifier
                    .align(Alignment.Center)
                    .size(52.dp),
            )
        }

        AnimatedVisibility(holdingFast, Modifier.align(Alignment.TopCenter), enter = fadeIn() + scaleIn(), exit = fadeOut() + scaleOut()) {
            HudPill(Hud(Icons.Rounded.FastForward, "2× speed"), Modifier.padding(top = 32.dp))
        }
        hud?.let { HudPill(it, Modifier.align(Alignment.TopCenter).padding(top = 48.dp)) }

        if (locked) {
            AnimatedVisibility(controlsVisible, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.CenterStart)) {
                ChromeButton(Icons.Rounded.Lock, "Unlock", Modifier.padding(start = 32.dp)) { locked = false; interaction++ }
            }
        }

        // ---- Controls -----------------------------------------------------------------------------
        AnimatedVisibility(
            visible = controlsVisible && !locked,
            enter = fadeIn(tween(180)),
            exit = fadeOut(tween(220)),
        ) {
            BoxWithConstraints(
                Modifier
                    .fillMaxSize()
                    .background(VColors.PlayerChrome)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
            ) {
                val narrow = maxWidth < 600.dp

                // Top bar
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ChromeButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onClick = onExit)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(ui.title, style = MaterialTheme.typography.headlineSmall, color = VColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        ui.subtitle?.takeIf { it.isNotBlank() }?.let {
                            Text(it, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (ui.isEpisode) ChromeButton(Icons.Rounded.VideoLibrary, "Episodes") { sheet = Sheet.Episodes }
                        if (!narrow) ChromeButton(Icons.Rounded.PictureInPictureAlt, "Picture in picture", onClick = onEnterPip)
                        ChromeButton(Icons.Rounded.LockOpen, "Lock controls") { locked = true; controlsVisible = true; interaction++ }
                        ChromeButton(Icons.Rounded.MoreVert, "More") { sheet = Sheet.More }
                    }
                }

                // Centre transport
                Row(
                    Modifier.align(Alignment.Center),
                    horizontalArrangement = Arrangement.spacedBy(if (narrow) 18.dp else 32.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val episodeButton = if (narrow) 44.dp else 50.dp
                    val hasEpisodeNav = ui.previous != null || ui.next != null
                    // Placeholders keep play/pause centred when only one of previous/next exists.
                    if (ui.previous != null) ChromeButton(Icons.Rounded.SkipPrevious, "Previous episode", size = episodeButton) { viewModel.playPrevious() }
                    else if (hasEpisodeNav) Spacer(Modifier.size(episodeButton))
                    ChromeButton(Icons.Rounded.Replay10, "Back ${seekStep}s", size = if (narrow) 50.dp else 58.dp) {
                        viewModel.seekBy(-seekStep * 1000L); interaction++
                    }
                    Box(
                        Modifier
                            .size(if (narrow) 68.dp else 78.dp)
                            .clip(CircleShape)
                            .background(VColors.Amber)
                            .clickable {
                                if (player.playbackState == Player.STATE_ENDED) player.seekTo(0)
                                if (player.isPlaying) player.pause() else player.play()
                                interaction++
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            when {
                                playbackState == Player.STATE_ENDED -> Icons.Rounded.Replay
                                isPlaying -> Icons.Rounded.Pause
                                else -> Icons.Rounded.PlayArrow
                            },
                            if (isPlaying) "Pause" else "Play",
                            tint = VColors.OnAmber,
                            modifier = Modifier.size(40.dp),
                        )
                    }
                    ChromeButton(Icons.Rounded.Forward10, "Forward ${seekStep}s", size = if (narrow) 50.dp else 58.dp) {
                        viewModel.seekBy(seekStep * 1000L); interaction++
                    }
                    if (ui.next != null) ChromeButton(Icons.Rounded.SkipNext, "Next episode", size = episodeButton) { viewModel.playNext() }
                    else if (hasEpisodeNav) Spacer(Modifier.size(episodeButton))
                }

                // Bottom: timeline + actions
                Column(
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 12.dp)
                ) {
                    Timeline(clock, speed, scrubbing, onScrub = { scrubbing = it; interaction++ }) {
                        scrubbing?.let { player.seekTo((it * player.duration).toLong()) }
                        scrubbing = null
                    }
                    Spacer(Modifier.height(10.dp))
                    // Tools scroll on the left; "Next episode" is pinned to the far right on its own.
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Row(
                        Modifier
                            .weight(1f)
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ActionChip(Icons.Rounded.Audiotrack, "Audio") { sheet = Sheet.Audio }
                        ActionChip(Icons.Rounded.Subtitles, "Subtitles") { sheet = Sheet.Subtitles }
                        ActionChip(Icons.Rounded.Speed, if (speed == 1f) "Speed" else "${trim(speed)}×") { sheet = Sheet.Speed }
                        ActionChip(Icons.Rounded.AspectRatio, if (zoom > 1f) "Zoom" else resize.label) {
                            resize = ResizeMode.entries[(resize.ordinal + 1) % ResizeMode.entries.size]
                            viewModel.prefs.resizeMode = resize
                            zoom = 1f
                            pan = Offset.Zero
                            interaction++
                        }
                        ActionChip(Icons.Rounded.ScreenRotation, "Rotate") { onRotate(); interaction++ }
                        if (ui.isEpisode) ActionChip(Icons.Rounded.FastForward, "+${ui.settings.skipSeconds}s") { viewModel.skipIntro(); interaction++ }
                    }
                    if (ui.next != null) {
                        Spacer(Modifier.width(16.dp))
                        ActionChip(Icons.Rounded.SkipNext, "Next episode", accent = true) { viewModel.playNext() }
                    }
                    }
                }
            }
        }

        // ---- Floating prompts -------------------------------------------------------------------
        ResumePrompt(ui.resumedFrom, controlsVisible, onStartOver = viewModel::startOver)
        SkipIntroPrompt(clock, visible = ui.isEpisode && !ui.introSkipped && !controlsVisible && !locked, onSkip = viewModel::skipIntro)
        UpNextPrompt(clock, ui, controlsVisible, locked, onPlay = viewModel::playNext, onCancel = { viewModel.cancelAutoPlay(); interaction++ })

        ui.error?.let { message ->
            Column(
                Modifier
                    .align(Alignment.Center)
                    .padding(24.dp)
                    .widthIn(max = 440.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(VColors.SurfaceHigh)
                    .border(1.dp, VColors.Outline, RoundedCornerShape(20.dp))
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("Playback stopped", style = MaterialTheme.typography.headlineSmall, color = VColors.Text)
                Spacer(Modifier.height(8.dp))
                Text(message, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
                Spacer(Modifier.height(20.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    ActionChip(Icons.AutoMirrored.Rounded.ArrowBack, "Close", onClick = onExit)
                    if (!ui.softwareDecoding) ActionChip(Icons.Rounded.Info, "Try software") { viewModel.setSoftwareDecoding(true) }
                    ActionChip(Icons.Rounded.PlayArrow, "Retry", accent = true, onClick = viewModel::retry)
                }
            }
        }
    }

    // ---- Sheets ---------------------------------------------------------------------------------
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var subtitleError by remember { mutableStateOf<String?>(null) }
    var subtitleLoading by remember { mutableStateOf(false) }
    val subtitlePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            subtitleLoading = true
            scope.launch {
                subtitleError = viewModel.addDeviceSubtitle(uri, displayName(context, uri) ?: "subtitle.srt")
                subtitleLoading = false
                if (subtitleError == null) sheet = null
            }
        }
    }
    var driveSubs by remember { mutableStateOf<List<DriveFile>?>(null) }
    var episodes by remember { mutableStateOf<List<EpisodeItem>?>(null) }
    val decoders by viewModel.decoders.collectAsStateWithLifecycle()

    sheet?.let { current ->
        ModalBottomSheet(
            onDismissRequest = { sheet = null; subtitleError = null; interaction++ },
            sheetState = sheetState,
            containerColor = VColors.Surface,
            dragHandle = null,
        ) {
            KeepImmersive()
            Column(
                Modifier
                    .fillMaxWidth()
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(vertical = 16.dp)
            ) {
                when (current) {
                    Sheet.Audio -> AudioSheet(tracks) { group, i -> viewModel.selectTrack(group, i); sheet = null }
                    Sheet.Subtitles -> SubtitlesSheet(
                        tracks = tracks,
                        ui = ui,
                        loading = subtitleLoading,
                        error = subtitleError,
                        onOff = { viewModel.disableSubtitles(); sheet = null },
                        onEmbedded = { g, i -> viewModel.selectTrack(g, i); sheet = null },
                        onExternal = { viewModel.selectExternal(it) },
                        onOffset = viewModel::adjustSubtitleOffset,
                        onResetOffset = viewModel::resetSubtitleOffset,
                        onAddDrive = {
                            driveSubs = null
                            subtitleError = null
                            sheet = Sheet.DriveSubtitles
                            scope.launch { driveSubs = runCatching { viewModel.driveSubtitleCandidates() }.getOrDefault(emptyList()) }
                        },
                        onAddDevice = {
                            subtitleError = null
                            subtitlePicker.launch(arrayOf("application/x-subrip", "text/vtt", "text/x-ssa", "application/ttml+xml", "text/plain", "application/octet-stream", "*/*"))
                        },
                    )
                    Sheet.DriveSubtitles -> {
                        SheetTitle("Subtitles in this folder")
                        val list = driveSubs
                        subtitleError?.let { SheetNote(it, error = true) }
                        when {
                            list == null || subtitleLoading -> LoadingRow()
                            list.isEmpty() -> SheetNote("No .srt, .vtt or .ass files next to this video. Put one next to the video, or use “Choose a file…”.")
                            else -> LazyColumn {
                                items(list, key = { it.id }) { sub ->
                                    SheetOption(sub.name, Format.bytes(sub.sizeBytes), selected = false) {
                                        subtitleLoading = true
                                        scope.launch {
                                            subtitleError = viewModel.addDriveSubtitle(sub)
                                            subtitleLoading = false
                                            if (subtitleError == null) sheet = null
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Sheet.Speed -> {
                        SheetTitle("Playback speed")
                        SheetNote("Tip: press and hold the video for 2× speed.")
                        LazyColumn {
                            items(listOf(0.25f, 0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f, 2.5f, 3f)) { s ->
                                SheetOption(if (s == 1f) "Normal" else "${trim(s)}×", null, selected = s == speed) {
                                    player.setPlaybackSpeed(s); sheet = null
                                }
                            }
                        }
                    }
                    Sheet.Episodes -> {
                        SheetTitle("Episodes")
                        LaunchedEffect(Unit) { episodes = viewModel.episodeList() }
                        val list = episodes
                        if (list == null) LoadingRow() else EpisodesList(list) { viewModel.playEpisode(it); sheet = null }
                    }
                    Sheet.More -> {
                        SheetTitle("More")
                        SheetAction(Icons.Rounded.Bedtime, "Sleep timer", sleepLabel(ui.sleep)) { sheet = Sheet.Sleep }
                        SheetAction(Icons.Rounded.Info, "Video info & decoder", if (ui.softwareDecoding) "Software decoding" else "Hardware decoding") { sheet = Sheet.Info }
                        SheetAction(Icons.Rounded.PictureInPictureAlt, "Picture in picture", null) { sheet = null; onEnterPip() }
                        SheetAction(Icons.Rounded.ScreenRotation, "Rotate screen", null) { onRotate() }
                    }
                    Sheet.Sleep -> {
                        SheetTitle("Sleep timer")
                        SheetOption("Off", null, selected = ui.sleep == null) { viewModel.setSleepTimer(null); sheet = null }
                        listOf(15, 30, 45, 60, 90).forEach { m ->
                            SheetOption("$m minutes", null, selected = false) { viewModel.setSleepTimer(m); sheet = null }
                        }
                        SheetOption("End of this video", null, selected = ui.sleep?.endOfEpisode == true) { viewModel.setSleepAtEndOfEpisode(); sheet = null }
                    }
                    Sheet.Info -> InfoSheet(player, ui, decoders, onSoftware = { viewModel.setSoftwareDecoding(it) })
                }
            }
        }
    }
}

// =================================================================================================
// Layers
// =================================================================================================

@OptIn(UnstableApi::class)
@Composable
internal fun SubtitleLayer(
    viewModel: PlayerViewModel,
    ui: PlayerUi,
    clock: PlaybackClock,
    playerCues: CueGroup,
    inPip: Boolean,
    raised: Boolean,
) {
    // Reading the clock here (not in PlayerScreen) keeps the 10×/s updates local to subtitles.
    val cues = if (ui.selectedExternal != null) viewModel.externalCues(clock.position).orEmpty() else playerCues.cues
    AndroidView(
        factory = { SubtitleView(it) },
        update = { view ->
            view.setCues(cues)
            view.setApplyEmbeddedStyles(true)
            view.setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION * ui.settings.subtitleScale * if (inPip) 1.4f else 1f)
            view.setBottomPaddingFraction(if (raised) 0.2f else SubtitleView.DEFAULT_BOTTOM_PADDING_FRACTION)
            view.setStyle(
                CaptionStyleCompat(
                    android.graphics.Color.WHITE,
                    if (ui.settings.subtitleBackground) 0xB3000000.toInt() else android.graphics.Color.TRANSPARENT,
                    android.graphics.Color.TRANSPARENT,
                    CaptionStyleCompat.EDGE_TYPE_OUTLINE,
                    android.graphics.Color.BLACK,
                    null,
                )
            )
        },
        modifier = Modifier.fillMaxSize(),
    )
}

@Composable
private fun Timeline(
    clock: PlaybackClock,
    speed: Float,
    scrubbing: Float?,
    onScrub: (Float) -> Unit,
    onScrubEnd: () -> Unit,
) {
    val duration = clock.duration
    val shown = scrubbing?.let { (it * duration).toLong() } ?: clock.position
    Column {
        if (duration > 0) {
            val endsAt = System.currentTimeMillis() + ((duration - shown) / speed).toLong()
            Text(
                "Ends at " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(endsAt)),
                style = MaterialTheme.typography.labelMedium,
                color = VColors.TextMuted,
                modifier = Modifier.align(Alignment.End),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(Format.clock(shown), style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace), color = VColors.Text)
            SeekBar(
                progress = scrubbing ?: if (duration > 0) clock.position.toFloat() / duration else 0f,
                buffered = if (duration > 0) clock.buffered.toFloat() / duration else 0f,
                onScrub = onScrub,
                onScrubEnd = onScrubEnd,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 14.dp),
            )
            Text(
                if (duration > 0) "−" + Format.clock(duration - shown) else "--:--",
                style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace),
                color = VColors.TextMuted,
            )
        }
    }
}

@Composable
private fun SeekBar(
    progress: Float,
    buffered: Float,
    onScrub: (Float) -> Unit,
    onScrubEnd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var dragging by remember { mutableStateOf(false) }
    BoxWithConstraints(
        modifier
            .height(36.dp)
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    onScrub((offset.x / size.width).coerceIn(0f, 1f))
                    onScrubEnd()
                }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { dragging = true; onScrub((it.x / size.width).coerceIn(0f, 1f)) },
                    onDragEnd = { dragging = false; onScrubEnd() },
                    onDragCancel = { dragging = false; onScrubEnd() },
                ) { change, _ ->
                    change.consume()
                    onScrub((change.position.x / size.width).coerceIn(0f, 1f))
                }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        val w = maxWidth
        val trackHeight = if (dragging) 6.dp else 4.dp
        Box(Modifier.fillMaxWidth().height(trackHeight).clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.18f)))
        Box(Modifier.fillMaxWidth(buffered.coerceIn(0f, 1f)).height(trackHeight).clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.32f)))
        Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).height(trackHeight).clip(RoundedCornerShape(3.dp)).background(VColors.Amber))
        val thumb = if (dragging) 22.dp else 16.dp
        Box(
            Modifier
                .offset { IntOffset(((w.toPx() * progress.coerceIn(0f, 1f)) - thumb.toPx() / 2).roundToInt(), 0) }
                .size(thumb)
                .clip(CircleShape)
                .background(VColors.Amber)
        )
    }
}

@Composable
private fun BoxScope.SeekRipple(feedback: SeekFeedback) {
    val shape = if (feedback.forward) RoundedCornerShape(topStartPercent = 50, bottomStartPercent = 50)
    else RoundedCornerShape(topEndPercent = 50, bottomEndPercent = 50)
    Box(
        Modifier
            .align(if (feedback.forward) Alignment.CenterEnd else Alignment.CenterStart)
            .fillMaxHeight(0.8f)
            .fillMaxWidth(0.3f)
            .clip(shape)
            .background(Color.White.copy(alpha = 0.10f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(if (feedback.forward) Icons.Rounded.FastForward else Icons.Rounded.FastRewind, null, tint = VColors.Text, modifier = Modifier.size(36.dp))
            Text("${feedback.seconds} seconds", style = MaterialTheme.typography.labelLarge, color = VColors.Text)
        }
    }
}

@Composable
private fun BoxScope.ResumePrompt(resumedFrom: Long?, controlsVisible: Boolean, onStartOver: () -> Unit) {
    AnimatedVisibility(
        resumedFrom != null,
        modifier = Modifier
            .align(Alignment.BottomStart)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(start = 24.dp, bottom = if (controlsVisible) 132.dp else 28.dp),
        enter = fadeIn(),
        exit = fadeOut(),
    ) {
        Row(
            Modifier
                .clip(RoundedCornerShape(14.dp))
                .background(VColors.SurfaceHigh)
                .border(1.dp, VColors.Outline, RoundedCornerShape(14.dp))
                .padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Resumed at ${Format.clock(resumedFrom ?: 0)}", style = MaterialTheme.typography.labelLarge, color = VColors.Text)
            Spacer(Modifier.width(10.dp))
            ActionChip(Icons.Rounded.Replay, "Start over", onClick = onStartOver)
        }
    }
}

@Composable
private fun BoxScope.SkipIntroPrompt(clock: PlaybackClock, visible: Boolean, onSkip: () -> Unit) {
    if (!visible || clock.position !in 5_000..180_000) return
    ActionChip(
        Icons.Rounded.FastForward, "Skip intro",
        modifier = Modifier
            .align(Alignment.BottomEnd)
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(28.dp),
        accent = true,
        onClick = onSkip,
    )
}

@Composable
private fun BoxScope.UpNextPrompt(
    clock: PlaybackClock,
    ui: PlayerUi,
    controlsVisible: Boolean,
    locked: Boolean,
    onPlay: () -> Unit,
    onCancel: () -> Unit,
) {
    val remaining = clock.duration - clock.position
    val show = ui.next != null && clock.duration > 0 && remaining in 1..30_000 &&
        !ui.autoPlayCancelled && !locked && ui.sleep?.endOfEpisode != true
    if (!show) return
    val autoPlay = ui.settings.autoPlayNext
    Column(
        Modifier
            .align(Alignment.BottomEnd)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(bottom = if (controlsVisible) 132.dp else 24.dp, end = 24.dp)
            .width(300.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(VColors.SurfaceHigh)
            .border(1.dp, VColors.Outline, RoundedCornerShape(18.dp))
            .padding(16.dp)
    ) {
        Text("UP NEXT", style = MaterialTheme.typography.labelSmall, color = VColors.Amber)
        Spacer(Modifier.height(4.dp))
        Text(ui.nextLabel.orEmpty(), style = MaterialTheme.typography.titleMedium, color = VColors.Text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ActionChip(Icons.Rounded.SkipNext, if (autoPlay) "Play in ${remaining / 1000}s" else "Play now", accent = true, onClick = onPlay)
            if (autoPlay) ActionChip(Icons.Rounded.Pause, "Cancel", onClick = onCancel)
        }
    }
}

// =================================================================================================
// Sheets
// =================================================================================================

@Composable
private fun AudioSheet(tracks: Tracks, onSelect: (Tracks.Group, Int) -> Unit) {
    SheetTitle("Audio")
    val entries = tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }.flatMap { g -> (0 until g.length).map { g to it } }
    if (entries.isEmpty()) SheetNote("No audio tracks")
    val titles = MediaFormats.trackTitles(entries.map { (g, i) -> g.getTrackFormat(i) }, "Track", PlayerViewModel::languageName)
    LazyColumn {
        items(entries.indices.toList()) { n ->
            val (group, i) = entries[n]
            val f = group.getTrackFormat(i)
            SheetOption(
                title = titles[n],
                detail = listOfNotNull(
                    MediaFormats.cleanLabel(f.label)?.takeIf { it != PlayerViewModel.languageName(f.language) },
                    MediaFormats.audioCodec(f.sampleMimeType),
                    MediaFormats.channels(f.channelCount),
                    if (!group.isTrackSupported(i)) "not supported on this device" else null,
                ).joinToString(" · "),
                selected = group.isTrackSelected(i),
                enabled = group.isTrackSupported(i),
            ) { onSelect(group, i) }
        }
    }
}

@Composable
private fun SubtitlesSheet(
    tracks: Tracks,
    ui: PlayerUi,
    loading: Boolean,
    error: String?,
    onOff: () -> Unit,
    onEmbedded: (Tracks.Group, Int) -> Unit,
    onExternal: (String) -> Unit,
    onOffset: (Long) -> Unit,
    onResetOffset: () -> Unit,
    onAddDrive: () -> Unit,
    onAddDevice: () -> Unit,
) {
    SheetTitle("Subtitles")
    val groups = tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
    val embeddedSelected = groups.any { it.isSelected }
    LazyColumn {
        item { SheetOption("Off", null, selected = ui.selectedExternal == null && !embeddedSelected, onClick = onOff) }
        val entries = groups.flatMap { g -> (0 until g.length).map { g to it } }
        val titles = MediaFormats.trackTitles(entries.map { (g, i) -> g.getTrackFormat(i) }, "Subtitle", PlayerViewModel::languageName)
        items(entries.indices.toList()) { n ->
            val (group, i) = entries[n]
            val f = group.getTrackFormat(i)
            SheetOption(
                title = titles[n],
                detail = listOfNotNull(
                    MediaFormats.cleanLabel(f.label)?.takeIf { it != PlayerViewModel.languageName(f.language) },
                    if (f.selectionFlags and C.SELECTION_FLAG_FORCED != 0) "Forced" else null,
                    MediaFormats.subtitleFormat(f),
                    "In video",
                ).joinToString(" · "),
                selected = ui.selectedExternal == null && group.isTrackSelected(i),
                enabled = group.isTrackSupported(i),
            ) { onEmbedded(group, i) }
        }
        items(ui.externalSubs, key = { it.id }) { sub ->
            SheetOption(sub.label, listOfNotNull(PlayerViewModel.languageName(sub.language).takeIf { sub.label != it }, "File").joinToString(" · "), selected = ui.selectedExternal == sub.id) {
                onExternal(sub.id)
            }
        }
        if (ui.selectedExternal != null) {
            item { SyncControl(ui.subtitleOffsetMs, onOffset, onResetOffset) }
        }
        item {
            if (loading) LoadingRow()
            error?.let { SheetNote(it, error = true) }
            Spacer(Modifier.height(8.dp))
            // Lists subtitle files next to the video, on Drive or on the device alike.
            SheetAction(Icons.Rounded.FolderOpen, "From the video's folder", null, onAddDrive)
            SheetAction(Icons.Rounded.PhoneAndroid, "Choose a file…", null, onAddDevice)
        }
    }
}

@Composable
private fun SyncControl(offsetMs: Long, onOffset: (Long) -> Unit, onReset: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(VColors.SurfaceHigh)
            .padding(14.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Sync", style = MaterialTheme.typography.titleSmall, color = VColors.Text, modifier = Modifier.weight(1f))
            Text(
                when {
                    offsetMs == 0L -> "In sync"
                    offsetMs > 0 -> String.format(Locale.US, "%.1f s later", offsetMs / 1000f)
                    else -> String.format(Locale.US, "%.1f s earlier", -offsetMs / 1000f)
                },
                style = MaterialTheme.typography.labelLarge,
                color = VColors.Amber,
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.horizontalScroll(rememberScrollState())) {
            SmallChip("−1 s") { onOffset(-1_000) }
            SmallChip("−0.1 s") { onOffset(-100) }
            SmallChip("Reset", onClick = onReset)
            SmallChip("+0.1 s") { onOffset(100) }
            SmallChip("+1 s") { onOffset(1_000) }
        }
        Spacer(Modifier.height(6.dp))
        Text("Use + if subtitles appear before the speech, − if they're late.", style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
    }
}

@Composable
private fun EpisodesList(list: List<EpisodeItem>, onPlay: (EpisodeItem) -> Unit) {
    val startIndex = list.indexOfFirst { it.current }.coerceAtLeast(0)
    val state = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = startIndex)
    LazyColumn(state = state, contentPadding = PaddingValues(bottom = 8.dp)) {
        items(list, key = { it.fileId }) { ep ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable(enabled = !ep.current) { onPlay(ep) }
                    .background(if (ep.current) VColors.AmberDim else Color.Transparent)
                    .padding(horizontal = 24.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                VImage(
                    ep.stillUrl, ep.name,
                    Modifier
                        .width(120.dp)
                        .aspectRatio(16f / 9f)
                        .clip(RoundedCornerShape(10.dp)),
                    fallbackText = "E${ep.episode}",
                )
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(Format.episodeCode(ep.season, ep.episode), style = MaterialTheme.typography.labelMedium, color = if (ep.current) VColors.Amber else VColors.TextMuted)
                    Text(ep.name, style = MaterialTheme.typography.titleSmall, color = VColors.Text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    if (ep.current) Text("Now playing", style = MaterialTheme.typography.bodySmall, color = VColors.AmberSoft)
                }
                if (ep.watched) Icon(Icons.Rounded.CheckCircle, "Watched", tint = VColors.Amber, modifier = Modifier.size(20.dp))
            }
        }
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun InfoSheet(player: ExoPlayer, ui: PlayerUi, decoders: DecoderStats, onSoftware: (Boolean) -> Unit) {
    val video = player.videoFormat
    val audio = player.audioFormat
    SheetTitle("Video info")
    Column(Modifier.padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        InfoGroup(
            "File",
            listOf(
                "Name" to ui.fileName,
                "Size" to Format.bytes(ui.fileSize),
                "Container" to ui.fileName.substringAfterLast('.', "").uppercase(Locale.US).ifBlank { null },
            ),
        )
        InfoGroup(
            "Video",
            listOf(
                "Codec" to MediaFormats.videoCodec(video?.sampleMimeType),
                "Resolution" to MediaFormats.resolution(video),
                "Frame rate" to video?.frameRate?.let { MediaFormats.frameRate(it) },
                "HDR" to (MediaFormats.hdr(video) ?: "SDR"),
                "Bitrate" to video?.bitrate?.let { MediaFormats.bitrate(it) },
                "Decoder" to listOfNotNull(MediaFormats.decoderKind(decoders.video), decoders.video).joinToString(" · ").ifBlank { null },
                "Dropped frames" to decoders.droppedFrames.toString(),
            ),
        )
        InfoGroup(
            "Audio",
            listOf(
                "Codec" to MediaFormats.audioCodec(audio?.sampleMimeType),
                "Channels" to audio?.channelCount?.let { MediaFormats.channels(it) },
                "Sample rate" to audio?.sampleRate?.takeIf { it > 0 }?.let { "${it / 1000.0} kHz" },
                "Language" to PlayerViewModel.languageName(audio?.language),
                "Decoder" to listOfNotNull(MediaFormats.decoderKind(decoders.audio), decoders.audio).joinToString(" · ").ifBlank { null },
            ),
        )
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(VColors.SurfaceHigh)
                .clickable { onSoftware(!ui.softwareDecoding) }
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Software video decoding", style = MaterialTheme.typography.titleSmall, color = VColors.Text)
                Text(
                    "Uses Android's built-in software decoders. Try it if the picture is green, frozen or glitchy. Uses more battery; 4K may stutter.",
                    style = MaterialTheme.typography.bodySmall,
                    color = VColors.TextMuted,
                )
            }
            Spacer(Modifier.width(12.dp))
            Switch(
                checked = ui.softwareDecoding,
                onCheckedChange = onSoftware,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = VColors.OnAmber, checkedTrackColor = VColors.Amber,
                    uncheckedThumbColor = VColors.TextMuted, uncheckedTrackColor = VColors.Surface, uncheckedBorderColor = VColors.OutlineStrong,
                ),
            )
        }
        Spacer(Modifier.height(4.dp))
    }
}

@Composable
private fun InfoGroup(title: String, rows: List<Pair<String, String?>>) {
    Column {
        Text(title.uppercase(Locale.US), style = MaterialTheme.typography.labelSmall, color = VColors.Amber)
        Spacer(Modifier.height(6.dp))
        rows.filter { !it.second.isNullOrBlank() }.forEach { (k, v) ->
            Row(Modifier.padding(vertical = 3.dp)) {
                Text(k, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, modifier = Modifier.width(120.dp))
                Text(v!!, style = MaterialTheme.typography.bodySmall, color = VColors.Text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

// =================================================================================================
// Small pieces
// =================================================================================================

@Composable
private fun HudPill(hud: Hud, modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(VColors.PlayerChrome)
            .padding(horizontal = 18.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(hud.icon, null, tint = VColors.Amber, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Text(hud.text, style = MaterialTheme.typography.titleMedium, color = VColors.Text)
    }
}

@Composable
private fun ChromeButton(
    icon: ImageVector,
    description: String,
    modifier: Modifier = Modifier,
    size: Dp = 44.dp,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.10f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, description, tint = VColors.Text, modifier = Modifier.size(size * 0.52f))
    }
}

@Composable
private fun ActionChip(
    icon: ImageVector,
    label: String,
    modifier: Modifier = Modifier,
    accent: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (accent) VColors.Amber else Color.White.copy(alpha = 0.10f))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = if (accent) VColors.OnAmber else VColors.Text, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = MaterialTheme.typography.labelLarge, color = if (accent) VColors.OnAmber else VColors.Text, maxLines = 1)
    }
}

@Composable
private fun SmallChip(label: String, onClick: () -> Unit) {
    Text(
        label,
        style = MaterialTheme.typography.labelLarge,
        color = VColors.Text,
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(VColors.SurfaceHighest)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
    )
}

@Composable
private fun SheetTitle(text: String) {
    Text(text, style = MaterialTheme.typography.headlineSmall, color = VColors.Text, modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp))
}

@Composable
private fun SheetNote(text: String, error: Boolean = false) {
    Text(
        text,
        style = MaterialTheme.typography.bodyMedium,
        color = if (error) VColors.Danger else VColors.TextMuted,
        modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
    )
}

@Composable
private fun LoadingRow() {
    Box(Modifier.fillMaxWidth().height(96.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = VColors.Amber, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
    }
}

@Composable
private fun SheetOption(title: String, detail: String?, selected: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 24.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = if (enabled) VColors.Text else VColors.TextFaint)
            if (!detail.isNullOrBlank()) Text(detail, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
        }
        if (selected) Icon(Icons.Rounded.Check, "Selected", tint = VColors.Amber)
    }
}

@Composable
private fun SheetAction(icon: ImageVector, label: String, detail: String?, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 24.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = VColors.Amber)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyLarge, color = VColors.Text)
            if (detail != null) Text(detail, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
        }
    }
}

/** Bottom sheets live in their own window, which would otherwise show the system bars over the video. */
@Composable
private fun KeepImmersive() {
    val view = LocalView.current
    LaunchedEffect(view) {
        var parent: android.view.ViewParent? = view.parent
        while (parent != null && parent !is DialogWindowProvider) parent = parent.parent
        (parent as? DialogWindowProvider)?.window?.let { w ->
            WindowCompat.getInsetsController(w, w.decorView).apply {
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsetsCompat.Type.systemBars())
            }
        }
    }
}

private fun sleepLabel(sleep: SleepTimer?): String = when {
    sleep == null -> "Off"
    sleep.endOfEpisode -> "At the end of this video"
    sleep.endsAtMs != null -> "Stops at " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(sleep.endsAtMs))
    else -> "On"
}

private fun trim(speed: Float): String = if (speed % 1f == 0f) speed.toInt().toString() else speed.toString()

private fun displayName(context: Context, uri: Uri): String? =
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
        if (c.moveToFirst()) c.getString(0) else null
    }
