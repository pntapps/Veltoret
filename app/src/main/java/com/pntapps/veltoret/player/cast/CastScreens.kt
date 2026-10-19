package com.pntapps.veltoret.player.cast

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Audiotrack
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.CastConnected
import androidx.compose.material.icons.rounded.Forward10
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay10
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Subtitles
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import kotlinx.coroutines.launch
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.mediarouter.media.MediaRouter
import com.pntapps.veltoret.data.tvlink.LinkException
import com.pntapps.veltoret.data.tvlink.LinkStatus
import com.pntapps.veltoret.data.tvlink.LinkTrack
import com.pntapps.veltoret.data.tvlink.LinkTv
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.container
import com.pntapps.veltoret.ui.util.rememberLocalNetworkAccess

/**
 * The Cast button: amber while connected. Opens the device picker (Android 17+ asks for "Nearby
 * devices" first). Shows nothing where Cast isn't available (TV, no Play services).
 */
@Composable
fun CastButton(chrome: Boolean = false, size: Dp = if (chrome) 44.dp else 42.dp) {
    val context = LocalContext.current
    val cast = context.container.cast
    val state by cast.state.collectAsStateWithLifecycle()
    if (!state.available) return
    var picking by remember { mutableStateOf(false) }
    val withNetwork = rememberLocalNetworkAccess { Toast.makeText(context, it, Toast.LENGTH_LONG).show() }
    val icon = if (state.connected) Icons.Rounded.CastConnected else Icons.Rounded.Cast
    val label = if (state.connected) "Casting to ${state.deviceName ?: "TV"}" else "Cast to a TV"
    val tint = if (state.connected) VColors.Amber else VColors.Text
    if (chrome) {
        Box(
            Modifier
                .size(size)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.10f))
                .clickable { withNetwork { picking = true } },
            contentAlignment = Alignment.Center,
        ) { Icon(icon, label, tint = tint, modifier = Modifier.size(22.dp)) }
    } else {
        VIconButton(icon, label, { withNetwork { picking = true } }, size = size, tint = tint)
    }
    if (picking) CastDialog { picking = false }
}

/**
 * Lists TVs on the Wi-Fi: Veltoret TVs first ("Play on TV": full audio and subtitles, pairs with a code
 * the first time), then Chromecasts. A TV that has both shows once, as Veltoret, with "Use Chromecast
 * instead" for its Chromecast. While connected, shows the device with "Stop casting".
 */
@Composable
fun CastDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val container = context.container
    val cast = container.cast
    val state by cast.state.collectAsStateWithLifecycle()
    val router = remember { MediaRouter.getInstance(context) }
    val selector = remember { cast.routeSelector() }
    var routes by remember { mutableStateOf(emptyList<MediaRouter.RouteInfo>()) }
    val tvs = remember { mutableStateListOf<LinkTv>() }
    var showAllChromecasts by remember { mutableStateOf(false) }
    var pairing by remember { mutableStateOf<LinkTv?>(null) }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    DisposableEffect(selector) {
        fun refresh() {
            routes = if (selector == null) emptyList()
            else router.routes.filter { !it.isDefault && it.isEnabled && it.matchesSelector(selector) }
        }
        val callback = object : MediaRouter.Callback() {
            override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = refresh()
            override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = refresh()
            override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = refresh()
        }
        if (selector != null) router.addCallback(selector, callback, MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN)
        refresh()
        onDispose { router.removeCallback(callback) }
    }
    LaunchedEffect(state.connected) {
        if (state.connected) return@LaunchedEffect
        container.tvLink.find().collect { tv ->
            val i = tvs.indexOfFirst { it.id == tv.id }
            if (i >= 0) tvs[i] = tv else tvs += tv
        }
    }

    fun choose(tv: LinkTv) {
        if (busy) return
        if (tv.paired) {
            cast.connectLink(tv)
            onDismiss()
            return
        }
        busy = true
        message = null
        scope.launch {
            try {
                container.tvLink.startPairing(tv)
                code = ""
                pairing = tv
            } catch (e: LinkException) {
                message = e.message
            } finally {
                busy = false
            }
        }
    }

    fun pair(tv: LinkTv) {
        if (busy || code.length != 6) return
        busy = true
        message = null
        scope.launch {
            try {
                container.tvLink.pair(tv, code)
                cast.connectLink(tv.copy(paired = true))
                onDismiss()
            } catch (e: LinkException) {
                message = e.message
                code = ""
            } finally {
                busy = false
            }
        }
    }

    val linkNames = tvs.map { it.name.lowercase() }.toSet()
    val hidden = routes.filter { it.name.lowercase() in linkNames }
    val chromecasts = if (showAllChromecasts) routes else routes - hidden.toSet()
    val target = pairing

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = VColors.SurfaceHigh,
        title = { Text(if (state.connected) "Casting" else if (target != null) "Pair with ${target.name}" else "Cast to") },
        text = {
            Column {
                if (state.connected) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.CastConnected, null, tint = VColors.Amber)
                        Spacer(Modifier.width(14.dp))
                        Column(Modifier.weight(1f)) {
                            Text(state.deviceName ?: "TV", style = MaterialTheme.typography.titleMedium)
                            state.media?.let { Text(it.title, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1) }
                        }
                    }
                } else if (target != null) {
                    Text(
                        "Enter the 6-digit code shown on ${target.name}. You only do this once.",
                        style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted,
                    )
                    Spacer(Modifier.height(14.dp))
                    VTextField(
                        value = code,
                        onValueChange = { v -> code = v.filter(Char::isDigit).take(6); if (code.length == 6) pair(target) },
                        label = "Code",
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { pair(target) }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else if (routes.isEmpty() && tvs.isEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(color = VColors.Amber, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(14.dp))
                        Text("Looking for TVs…", style = MaterialTheme.typography.bodyLarge)
                    }
                    Spacer(Modifier.height(14.dp))
                    Text(
                        "Your phone and the TV or Chromecast must be on the same Wi-Fi.",
                        style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted,
                    )
                } else {
                    tvs.forEach { tv ->
                        DeviceRow(
                            icon = Icons.Rounded.Tv,
                            name = tv.name,
                            detail = if (tv.paired) "Veltoret · all audio tracks and subtitles" else "Veltoret · pair once with a code",
                        ) { choose(tv) }
                    }
                    chromecasts.forEach { route ->
                        DeviceRow(
                            icon = Icons.Rounded.Cast,
                            name = route.name,
                            detail = if (route in hidden) "Chromecast" else route.description?.takeIf { it.isNotBlank() } ?: "Chromecast",
                        ) { router.selectRoute(route); onDismiss() }
                    }
                    if (hidden.isNotEmpty() && !showAllChromecasts) {
                        TextButton({ showAllChromecasts = true }) { Text("Use Chromecast instead", color = VColors.TextMuted) }
                    }
                }
                if (busy && !state.connected) {
                    Spacer(Modifier.height(10.dp))
                    CircularProgressIndicator(color = VColors.Amber, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                }
                message?.let {
                    Spacer(Modifier.height(10.dp))
                    Text(it, style = MaterialTheme.typography.bodySmall, color = VColors.Danger)
                }
            }
        },
        confirmButton = {
            when {
                state.connected -> TextButton({ cast.disconnect(); onDismiss() }) { Text("Stop casting", color = VColors.Danger) }
                target != null -> TextButton({ pair(target) }, enabled = code.length == 6 && !busy) { Text("Pair", color = VColors.Amber) }
            }
        },
        dismissButton = {
            TextButton({ if (target != null) { pairing = null; message = null } else onDismiss() }) {
                Text(if (state.connected) "Close" else if (target != null) "Back" else "Cancel", color = VColors.Text)
            }
        },
    )
}

@Composable
private fun DeviceRow(icon: ImageVector, name: String, detail: String?, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.medium)
            .clickable(onClick = onClick)
            .padding(horizontal = 6.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = VColors.Amber)
        Spacer(Modifier.width(14.dp))
        Column {
            Text(name, style = MaterialTheme.typography.titleMedium)
            detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1) }
        }
    }
}

/**
 * The player while casting: the phone is the remote. Artwork, what's playing on which TV, a seek bar,
 * transport, subtitles and "Stop casting".
 */
@Composable
fun CastingScreen(
    state: CastState,
    /** The player's title, shown until the TV has the video (and when it couldn't be opened). */
    title: String,
    hasPrevious: Boolean,
    hasNext: Boolean,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onAudio: (Long) -> Unit,
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val cast = context.container.cast
    val media = state.media
    var scrub by remember { mutableStateOf<Float?>(null) }
    var subtitleMenu by remember { mutableStateOf(false) }
    var audioMenu by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        VImage(media?.backdropUrl ?: media?.posterUrl, null, Modifier.fillMaxSize(), fallbackText = null)
        Box(Modifier.fillMaxSize().background(VColors.BackdropDim))
        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                RoundButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onClick = onExit)
                Spacer(Modifier.weight(1f))
                CastButton(chrome = true)
            }
            Spacer(Modifier.weight(1f))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.CastConnected, null, tint = VColors.Amber, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Playing on ${state.deviceName ?: "TV"}", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
            }
            Spacer(Modifier.height(10.dp))
            Text(
                media?.title ?: title, style = MaterialTheme.typography.headlineMedium, color = VColors.Text,
                textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            media?.subtitle?.takeIf { it.isNotBlank() }?.let {
                Spacer(Modifier.height(4.dp))
                Text(it, style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted, textAlign = TextAlign.Center, maxLines = 1)
            }
            if (state.link != null && state.linkSource != null) {
                Spacer(Modifier.height(6.dp))
                Text(
                    if (state.linkSource == LinkStatus.SOURCE_PHONE) "Streaming from this phone · keep it on the Wi-Fi" else "Playing the TV's own copy",
                    style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, textAlign = TextAlign.Center,
                )
            }
            (state.error ?: media?.audioWarning?.takeIf { state.link == null })?.let {
                Spacer(Modifier.height(12.dp))
                Text(
                    it, style = MaterialTheme.typography.bodyMedium, color = if (state.error != null) VColors.Danger else VColors.AmberSoft,
                    textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 520.dp),
                )
            }
            Spacer(Modifier.height(28.dp))

            // Seek bar
            val duration = state.durationMs.coerceAtLeast(1)
            val shown = scrub ?: (state.positionMs.toFloat() / duration).coerceIn(0f, 1f)
            Column(Modifier.widthIn(max = 720.dp).fillMaxWidth()) {
                Slider(
                    value = shown,
                    onValueChange = { scrub = it },
                    onValueChangeFinished = { scrub?.let { cast.seekTo((it * duration).toLong()) }; scrub = null },
                    colors = SliderDefaults.colors(thumbColor = VColors.Amber, activeTrackColor = VColors.Amber, inactiveTrackColor = Color.White.copy(alpha = 0.25f)),
                )
                Row {
                    Text(Format.clock((shown * duration).toLong()), style = MaterialTheme.typography.labelMedium, color = VColors.TextMuted)
                    Spacer(Modifier.weight(1f))
                    Text(if (state.durationMs > 0) Format.clock(state.durationMs) else "", style = MaterialTheme.typography.labelMedium, color = VColors.TextMuted)
                }
            }
            Spacer(Modifier.height(18.dp))

            // Transport
            Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
                if (hasPrevious) RoundButton(Icons.Rounded.SkipPrevious, "Previous episode", onClick = onPrevious)
                RoundButton(Icons.Rounded.Replay10, "Back 10 seconds", size = 54.dp) { cast.seekBy(-10_000) }
                Box(
                    Modifier
                        .size(76.dp)
                        .clip(CircleShape)
                        .background(VColors.Amber)
                        .clickable { if (state.playing) cast.pause() else cast.play() },
                    contentAlignment = Alignment.Center,
                ) {
                    if (state.buffering) CircularProgressIndicator(color = VColors.OnAmber, strokeWidth = 3.dp, modifier = Modifier.size(34.dp))
                    else Icon(
                        if (state.playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        if (state.playing) "Pause" else "Play", tint = VColors.OnAmber, modifier = Modifier.size(40.dp),
                    )
                }
                RoundButton(Icons.Rounded.Forward10, "Forward 10 seconds", size = 54.dp) { cast.seekBy(10_000) }
                if (hasNext) RoundButton(Icons.Rounded.SkipNext, "Next episode", onClick = onNext)
            }
            Spacer(Modifier.weight(1f))

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                if (state.link != null) {
                    // Veltoret on the TV: its real tracks, switched instantly.
                    if (state.linkAudio.size > 1) {
                        TrackMenu(
                            icon = Icons.Rounded.Audiotrack,
                            label = state.linkAudio.firstOrNull { it.id == state.linkAudioSelected }?.label ?: "Audio",
                            options = state.linkAudio, selected = state.linkAudioSelected, offLabel = null,
                        ) { id -> id?.let(cast::selectLinkAudio) }
                    }
                    if (state.linkSubtitles.isNotEmpty()) {
                        TrackMenu(
                            icon = Icons.Rounded.Subtitles,
                            label = state.linkSubtitles.firstOrNull { it.id == state.linkSubtitleSelected }?.label ?: "Subtitles off",
                            options = state.linkSubtitles, selected = state.linkSubtitleSelected, offLabel = "Off",
                        ) { id -> cast.selectLinkSubtitle(id) }
                    }
                } else if ((media?.audioOptions?.size ?: 0) > 1) {
                    Box {
                        VButton(
                            media?.audioOptions?.firstOrNull { it.track == media.audioTrack }?.label ?: "Audio",
                            { audioMenu = true }, icon = Icons.Rounded.Audiotrack, style = ButtonStyle.Ghost,
                        )
                        DropdownMenu(audioMenu, { audioMenu = false }, containerColor = VColors.SurfaceHigh) {
                            media?.audioOptions?.forEach { option ->
                                DropdownMenuItem(
                                    text = { Text(option.label, color = if (option.track == media.audioTrack) VColors.Amber else VColors.Text) },
                                    onClick = { audioMenu = false; onAudio(option.track) },
                                )
                            }
                        }
                    }
                }
                if (state.link == null && !media?.subtitles.isNullOrEmpty()) {
                    Box {
                        VButton(
                            media?.subtitles?.firstOrNull { it.id == state.activeSubtitle }?.label ?: "Subtitles off",
                            { subtitleMenu = true }, icon = Icons.Rounded.Subtitles, style = ButtonStyle.Ghost,
                        )
                        DropdownMenu(subtitleMenu, { subtitleMenu = false }, containerColor = VColors.SurfaceHigh) {
                            DropdownMenuItem(text = { Text("Off", color = if (state.activeSubtitle == null) VColors.Amber else VColors.Text) }, onClick = { subtitleMenu = false; cast.selectSubtitle(null) })
                            media?.subtitles?.forEach { sub ->
                                DropdownMenuItem(
                                    text = { Text(sub.label, color = if (sub.id == state.activeSubtitle) VColors.Amber else VColors.Text) },
                                    onClick = { subtitleMenu = false; cast.selectSubtitle(sub.id) },
                                )
                            }
                        }
                    }
                }
                VButton("Stop casting", { cast.disconnect() }, icon = Icons.Rounded.Cast, style = ButtonStyle.Ghost)
            }
        }
    }
}

/** A button with a menu of tracks; [offLabel] adds an "Off" entry (null id). */
@Composable
private fun TrackMenu(icon: ImageVector, label: String, options: List<LinkTrack>, selected: String?, offLabel: String?, onSelect: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        VButton(label, { open = true }, icon = icon, style = ButtonStyle.Ghost)
        DropdownMenu(open, { open = false }, containerColor = VColors.SurfaceHigh) {
            offLabel?.let {
                DropdownMenuItem(text = { Text(it, color = if (selected == null) VColors.Amber else VColors.Text) }, onClick = { open = false; onSelect(null) })
            }
            options.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(option.label, color = if (option.id == selected) VColors.Amber else VColors.Text)
                            if (option.detail.isNotBlank()) Text(option.detail, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                        }
                    },
                    onClick = { open = false; onSelect(option.id) },
                )
            }
        }
    }
}

/**
 * "Which audio on the TV?": asked before casting a video with several audio tracks, since the TV plays
 * only the one it's given. [current] is preselected; dismissing keeps it.
 */
@Composable
fun CastAudioDialog(deviceName: String?, options: List<CastAudioOption>, current: Long?, onChoose: (Long?) -> Unit) {
    AlertDialog(
        onDismissRequest = { onChoose(null) },
        containerColor = VColors.SurfaceHigh,
        icon = { Icon(Icons.Rounded.Audiotrack, null, tint = VColors.Amber) },
        title = { Text("Audio on ${deviceName ?: "the TV"}") },
        text = {
            Column {
                options.forEach { option ->
                    val selected = option.track == current
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(MaterialTheme.shapes.medium)
                            .clickable { onChoose(option.track) }
                            .padding(horizontal = 6.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(option.label, style = MaterialTheme.typography.titleMedium, color = if (selected) VColors.Amber else VColors.Text)
                            if (option.detail.isNotBlank()) {
                                Text(option.detail, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1)
                            }
                        }
                        if (selected) Text("Current", style = MaterialTheme.typography.labelMedium, color = VColors.Amber)
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    "You can switch later from the casting screen.",
                    style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted,
                )
            }
        },
        confirmButton = {},
        dismissButton = { TextButton({ onChoose(null) }) { Text("Keep current", color = VColors.Text) } },
    )
}

@Composable
private fun RoundButton(icon: ImageVector, description: String, size: Dp = 46.dp, onClick: () -> Unit) {
    Box(
        Modifier
            .size(size)
            .clip(CircleShape)
            .background(Color.White.copy(alpha = 0.12f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, description, tint = VColors.Text, modifier = Modifier.size(size * 0.5f)) }
}
