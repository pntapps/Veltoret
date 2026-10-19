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
import com.pntapps.veltoret.ui.components.ButtonStyle
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

/** Lists Cast devices on the Wi-Fi; while connected, shows the device with "Stop casting". */
@Composable
fun CastDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val cast = context.container.cast
    val state by cast.state.collectAsStateWithLifecycle()
    val router = remember { MediaRouter.getInstance(context) }
    val selector = remember { cast.routeSelector() }
    var routes by remember { mutableStateOf(emptyList<MediaRouter.RouteInfo>()) }

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

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = VColors.SurfaceHigh,
        title = { Text(if (state.connected) "Casting" else "Cast to") },
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
                } else if (routes.isEmpty()) {
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
                    routes.forEach { route ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clip(MaterialTheme.shapes.medium)
                                .clickable { router.selectRoute(route); onDismiss() }
                                .padding(horizontal = 6.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Rounded.Tv, null, tint = VColors.Amber)
                            Spacer(Modifier.width(14.dp))
                            Column {
                                Text(route.name, style = MaterialTheme.typography.titleMedium)
                                route.description?.takeIf { it.isNotBlank() }?.let {
                                    Text(it, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (state.connected) TextButton({ cast.disconnect(); onDismiss() }) { Text("Stop casting", color = VColors.Danger) }
        },
        dismissButton = { TextButton(onDismiss) { Text(if (state.connected) "Close" else "Cancel", color = VColors.Text) } },
    )
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
    onExit: () -> Unit,
) {
    val context = LocalContext.current
    val cast = context.container.cast
    val media = state.media
    var scrub by remember { mutableStateOf<Float?>(null) }
    var subtitleMenu by remember { mutableStateOf(false) }

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
            (state.error ?: media?.audioWarning)?.let {
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
                if (!media?.subtitles.isNullOrEmpty()) {
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
