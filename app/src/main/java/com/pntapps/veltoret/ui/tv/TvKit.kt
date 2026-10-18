package com.pntapps.veltoret.ui.tv

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.AndroidUiDispatcher
import androidx.compose.ui.zIndex
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.components.VProgress
import com.pntapps.veltoret.ui.theme.VColors

/*
 * Veltoret's 10-foot design kit. Everything a remote can reach is a TvSurface, so focus always
 * looks the same: the item grows a little, gains an amber ring, and brightens. Flat colours only,
 * as on phones (no gradients).
 */

/** TV safe area: content keeps clear of the screen edges (overscan). */
object TvDimens {
    val Edge = 48.dp
    val Top = 28.dp
    val RailCollapsed = 76.dp
    val RailExpanded = 232.dp
    val RowGap = 18.dp
}

val FocusRing = VColors.Amber

/**
 * The single focusable building block. [content] receives whether it's focused so it can
 * restyle text or icons. OK/Enter clicks; holding OK triggers [onLongClick].
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TvSurface(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(14.dp),
    color: Color = VColors.Surface,
    focusedColor: Color = color,
    focusedScale: Float = 1.06f,
    ringWidth: Dp = 3.dp,
    showRing: Boolean = true,
    enabled: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    onFocused: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val scale by animateFloatAsState(if (focused) focusedScale else 1f, tween(160), label = "tvScale")
    // Every surface can be focused again by TvFocusMemory, so side panels hand focus back to their opener.
    val requester = focusRequester ?: remember { FocusRequester() }
    val memory = LocalTvFocusMemory.current
    LaunchedEffect(focused) {
        if (focused) {
            memory.last = requester
            onFocused?.invoke()
        }
    }
    Box(
        modifier
            .zIndex(if (focused) 1f else 0f)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .focusRequester(requester)
            .clip(shape)
            .background(if (focused) focusedColor else color)
            .then(if (focused && showRing) Modifier.border(ringWidth, FocusRing, shape) else Modifier)
            .combinedClickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
                onLongClick = onLongClick,
                onClick = onClick,
            ),
    ) { content(focused) }
}

/** Primary actions. Focused: solid amber. Resting: dark chip. */
@Composable
fun TvButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    focusRequester: FocusRequester? = null,
    onFocused: (() -> Unit)? = null,
) {
    TvSurface(
        onClick = onClick,
        modifier = modifier.height(48.dp),
        shape = RoundedCornerShape(24.dp),
        color = VColors.SurfaceHigh,
        focusedColor = VColors.Amber,
        focusedScale = 1.05f,
        showRing = false,
        enabled = enabled,
        focusRequester = focusRequester,
        onFocused = onFocused,
    ) { focused ->
        Row(
            Modifier
                .align(Alignment.Center)
                .padding(horizontal = 22.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val tint = when {
                !enabled -> VColors.TextFaint
                focused -> VColors.OnAmber
                else -> VColors.Text
            }
            if (icon != null) {
                Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(10.dp))
            }
            Text(text, style = MaterialTheme.typography.titleSmall, color = tint, maxLines = 1)
        }
    }
}

/** Round icon-only button (player controls, small actions). */
@Composable
fun TvIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 52.dp,
    focusRequester: FocusRequester? = null,
    onFocused: (() -> Unit)? = null,
) {
    TvSurface(
        onClick = onClick,
        modifier = modifier.size(size),
        shape = CircleShape,
        color = VColors.SurfaceHigh,
        focusedColor = VColors.Amber,
        focusedScale = 1.1f,
        showRing = false,
        focusRequester = focusRequester,
        onFocused = onFocused,
    ) { focused ->
        Icon(
            icon, contentDescription,
            tint = if (focused) VColors.OnAmber else VColors.Text,
            modifier = Modifier
                .align(Alignment.Center)
                .size(size * 0.46f),
        )
    }
}

/** Filter / season chips. [selected] stays visible even when focus is elsewhere. */
@Composable
fun TvChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    onFocused: (() -> Unit)? = null,
) {
    TvSurface(
        onClick = onClick,
        modifier = modifier.height(40.dp),
        shape = RoundedCornerShape(20.dp),
        color = if (selected) VColors.AmberDim else VColors.Surface,
        focusedColor = VColors.Amber,
        focusedScale = 1.05f,
        showRing = false,
        focusRequester = focusRequester,
        onFocused = onFocused,
    ) { focused ->
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = when {
                focused -> VColors.OnAmber
                selected -> VColors.Amber
                else -> VColors.TextMuted
            },
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 18.dp),
        )
    }
}

/** Settings rows, file rows, track lists. */
@Composable
fun TvListItem(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    leading: ImageVector? = null,
    trailing: String? = null,
    selected: Boolean = false,
    enabled: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
    onFocused: (() -> Unit)? = null,
) {
    TvSurface(
        onClick = onClick,
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
        color = Color.Transparent,
        focusedColor = VColors.SurfaceHigh,
        focusedScale = 1.02f,
        ringWidth = 2.dp,
        enabled = enabled,
        onLongClick = onLongClick,
        focusRequester = focusRequester,
        onFocused = onFocused,
    ) { focused ->
        Row(
            Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (leading != null) {
                Icon(leading, null, tint = if (focused || selected) VColors.Amber else VColors.TextMuted, modifier = Modifier.size(24.dp))
                Spacer(Modifier.width(16.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleMedium,
                    color = when {
                        !enabled -> VColors.TextFaint
                        focused -> VColors.Text
                        else -> VColors.Text.copy(alpha = 0.86f)
                    },
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (subtitle != null) {
                    Text(subtitle, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            if (trailing != null) {
                Spacer(Modifier.width(12.dp))
                Text(trailing, style = MaterialTheme.typography.titleSmall, color = VColors.Amber, maxLines = 1)
            }
            if (selected) {
                Spacer(Modifier.width(12.dp))
                Icon(Icons.Rounded.CheckCircle, "Selected", tint = VColors.Amber, modifier = Modifier.size(22.dp))
            }
        }
    }
}

/** Portrait poster with title underneath; the title lights up with focus. */
@Composable
fun TvPosterCard(
    title: String,
    subtitle: String?,
    imageUrl: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = 132.dp,
    progress: Float? = null,
    watched: Boolean = false,
    onFocused: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
) {
    Column(modifier.width(width)) {
        TvSurface(
            onClick = onClick,
            shape = RoundedCornerShape(12.dp),
            color = VColors.SurfaceHigh,
            focusedScale = 1.08f,
            onFocused = onFocused,
            onLongClick = onLongClick,
            focusRequester = focusRequester,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f),
        ) {
            VImage(imageUrl, title, Modifier.fillMaxSize(), fallbackText = title)
            if (progress != null) {
                VProgress(
                    progress,
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .padding(8.dp),
                    height = 4.dp,
                )
            }
            if (watched) WatchedBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
        }
        Spacer(Modifier.height(10.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, color = VColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) {
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** 16:9 card for Continue Watching, Next Up and episodes. */
@Composable
fun TvWideCard(
    title: String,
    subtitle: String?,
    imageUrl: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    width: Dp = 240.dp,
    progress: Float? = null,
    caption: String? = null,
    watched: Boolean = false,
    dimmed: Boolean = false,
    onFocused: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    focusRequester: FocusRequester? = null,
) {
    Column(modifier.width(width)) {
        TvSurface(
            onClick = onClick,
            shape = RoundedCornerShape(12.dp),
            color = VColors.SurfaceHigh,
            focusedScale = 1.06f,
            onFocused = onFocused,
            onLongClick = onLongClick,
            focusRequester = focusRequester,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .graphicsLayer { alpha = if (dimmed) 0.45f else 1f },
        ) {
            VImage(imageUrl, title, Modifier.fillMaxSize(), fallbackText = title)
            if (caption != null) {
                Text(
                    caption,
                    style = MaterialTheme.typography.labelSmall,
                    color = VColors.Text,
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .padding(8.dp)
                        .clip(RoundedCornerShape(6.dp))
                        .background(VColors.Background.copy(alpha = 0.82f))
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
            if (progress != null) {
                VProgress(
                    progress,
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .padding(8.dp),
                    height = 4.dp,
                )
            }
            if (watched) WatchedBadge(Modifier.align(Alignment.TopEnd).padding(8.dp))
        }
        Spacer(Modifier.height(10.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, color = VColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) {
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun WatchedBadge(modifier: Modifier) {
    Box(
        modifier
            .size(26.dp)
            .clip(CircleShape)
            .background(VColors.Amber),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Rounded.CheckCircle, "Watched", tint = VColors.OnAmber, modifier = Modifier.size(22.dp))
    }
}

@Composable
fun TvRowTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.titleLarge,
        color = VColors.Text,
        modifier = modifier.padding(start = TvDimens.Edge, bottom = 12.dp),
    )
}

/**
 * Google-TV style scrolling: the focused item is kept [leadingPx] from the leading edge instead of
 * scrolling only when it reaches the screen edge, so the eye always knows where focus is.
 */
@OptIn(ExperimentalFoundationApi::class)
class PivotBringIntoView(private val leadingPx: Float) : BringIntoViewSpec {
    override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float =
        offset - leadingPx
}

/** Provides [PivotBringIntoView] for everything inside [content] (rows, grids, columns). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PivotScrolling(leading: Dp = TvDimens.Edge, content: @Composable () -> Unit) {
    val px = with(androidx.compose.ui.platform.LocalDensity.current) { leading.toPx() }
    val spec = remember(px) { PivotBringIntoView(px) }
    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.foundation.gestures.LocalBringIntoViewSpec provides spec) {
        content()
    }
}

val TvRowPadding = PaddingValues(horizontal = TvDimens.Edge, vertical = 14.dp)
val TvRowArrangement = Arrangement.spacedBy(TvDimens.RowGap)

/**
 * Text fields keep arrow keys for moving the cursor, which traps the remote. On TV, ↑ ↓ ← leave the
 * field like any other control; → still moves the cursor.
 */
@Composable
fun Modifier.tvTextFieldExit(): Modifier {
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    return onPreviewKeyEvent { e ->
        if (e.type != androidx.compose.ui.input.key.KeyEventType.KeyDown) return@onPreviewKeyEvent false
        val direction = when (e.key) {
            androidx.compose.ui.input.key.Key.DirectionDown -> androidx.compose.ui.focus.FocusDirection.Down
            androidx.compose.ui.input.key.Key.DirectionUp -> androidx.compose.ui.focus.FocusDirection.Up
            androidx.compose.ui.input.key.Key.DirectionLeft -> androidx.compose.ui.focus.FocusDirection.Left
            else -> return@onPreviewKeyEvent false
        }
        focus.moveFocus(direction)
    }
}

/**
 * Requests focus once the target is laid out. A request made in the same frame a screen appears can
 * be dropped, which leaves the remote with nothing focused; this retries for a few frames.
 */
suspend fun FocusRequester.focusSoon() {
    tryFocusSoon()
}

/** [focusSoon] that says whether it worked (false when the target never appeared or left the screen). */
suspend fun FocusRequester.tryFocusSoon(): Boolean {
    repeat(8) {
        androidx.compose.runtime.withFrameNanos { }
        if (runCatching { requestFocus() }.getOrDefault(false)) return true
    }
    return false
}

/**
 * Remembers the last focused [TvSurface], so a side panel or picker can give focus back to the item
 * that opened it (Google TV behaviour). Panels are separate windows; without this, the screen behind
 * could only refocus its list, which lands on the first row.
 */
@Stable
class TvFocusMemory {
    internal var last: FocusRequester? = null
    private var target: FocusRequester? = null
    private var restore: Deferred<Boolean>? = null

    /** The item a panel opening now should return to: a pending return target (panel after panel), or the last focused. */
    internal fun opener(): FocusRequester? = target ?: last

    internal fun returnTo(opener: FocusRequester?) {
        target = opener
        // The opener often never lost focus inside its own window, so it won't report focus again; record it
        // now, or the next panel would capture the closed panel's item as its opener.
        last = opener
        restore = opener?.let { t ->
            // The panel's own scope is gone once it closes; the UI dispatcher carries the frame clock focusSoon needs.
            CoroutineScope(AndroidUiDispatcher.Main).async {
                t.tryFocusSoon().also { ok ->
                    if (target === t) target = null
                    if (!ok && last === t) last = null
                }
            }
        }
    }

    /** After a panel closes: true if focus went back to the item that opened it. Screens refocus their list otherwise. */
    suspend fun awaitReturn(): Boolean = restore?.await() ?: false
}

val LocalTvFocusMemory = staticCompositionLocalOf { TvFocusMemory() }

/** Put in a panel or picker: when it closes, focus goes back to the item that opened it. */
@Composable
fun ReturnFocusWhenClosed() {
    val memory = LocalTvFocusMemory.current
    val opener = remember { memory.opener() }
    DisposableEffect(Unit) { onDispose { memory.returnTo(opener) } }
}
