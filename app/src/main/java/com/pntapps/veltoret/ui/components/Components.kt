package com.pntapps.veltoret.ui.components

import com.pntapps.veltoret.ui.util.gutter
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import coil3.compose.AsyncImagePainter
import com.pntapps.veltoret.ui.theme.VColors

val PosterShape = RoundedCornerShape(12.dp)
val CardShape = RoundedCornerShape(14.dp)

/** Image with a flat placeholder; shows [fallbackText] in serif when there is no artwork. */
@Composable
fun VImage(
    url: String?,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    fallbackText: String? = null,
    contentScale: ContentScale = ContentScale.Crop,
) {
    var loading by remember(url) { mutableStateOf(url != null) }
    Box(modifier, contentAlignment = Alignment.Center) {
        // Placeholder breathes gently while the artwork loads (read in the layer: no recomposition per frame).
        if (loading) {
            val pulse = rememberPulse(0.55f, 1f)
            Box(
                Modifier
                    .matchParentSize()
                    .graphicsLayer { alpha = pulse.value }
                    .background(VColors.SurfaceHigh)
            )
        } else {
            Box(Modifier.matchParentSize().background(VColors.SurfaceHigh))
        }
        if (url == null && fallbackText != null) {
            Text(
                fallbackText,
                style = MaterialTheme.typography.titleMedium.copy(fontFamily = MaterialTheme.typography.headlineSmall.fontFamily),
                color = VColors.TextMuted,
                textAlign = TextAlign.Center,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(12.dp),
            )
        }
        if (url != null) {
            AsyncImage(
                model = url,
                contentDescription = contentDescription,
                contentScale = contentScale,
                onState = { loading = it is AsyncImagePainter.State.Loading },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
fun VProgress(progress: Float, modifier: Modifier = Modifier, height: Dp = 3.dp, track: Color = VColors.Outline) {
    Box(
        modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(height))
            .background(track)
    ) {
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(progress.coerceIn(0f, 1f))
                .background(VColors.Amber)
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PosterCard(
    title: String,
    subtitle: String?,
    imageUrl: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    progress: Float? = null,
    watched: Boolean = false,
    badge: String? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    Column(modifier.pressScale(interaction)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(PosterShape)
                .border(1.dp, VColors.Outline, PosterShape)
                .combinedClickable(
                    interactionSource = interaction,
                    indication = LocalIndication.current,
                    onClick = onClick,
                    onLongClick = onLongClick,
                )
        ) {
            VImage(imageUrl, title, Modifier.fillMaxSize(), fallbackText = title)
            if (badge != null) {
                Pill(badge, Modifier.align(Alignment.TopStart).padding(8.dp), solid = true)
            }
            if (watched) {
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .padding(8.dp)
                        .size(22.dp)
                        .clip(CircleShape)
                        .background(VColors.Amber),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Rounded.Check, "Watched", tint = VColors.OnAmber, modifier = Modifier.size(15.dp))
                }
            }
            if (progress != null && progress > 0f) {
                VProgress(
                    progress,
                    Modifier
                        .align(Alignment.BottomCenter)
                        .padding(8.dp),
                    track = VColors.ImageDim,
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) {
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** 16:9 card used for Continue Watching, Next Up and episodes. */
@Composable
fun WideCard(
    title: String,
    subtitle: String?,
    imageUrl: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    progress: Float? = null,
    caption: String? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    Column(modifier.pressScale(interaction)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(CardShape)
                .border(1.dp, VColors.Outline, CardShape)
                .clickable(interactionSource = interaction, indication = LocalIndication.current, onClick = onClick)
        ) {
            VImage(imageUrl, title, Modifier.fillMaxSize(), fallbackText = title)
            Box(
                Modifier
                    .align(Alignment.BottomStart)
                    .padding(10.dp)
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(VColors.ImageDim),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Rounded.PlayArrow, null, tint = VColors.Text, modifier = Modifier.size(20.dp))
            }
            if (caption != null) {
                Pill(caption, Modifier.align(Alignment.TopEnd).padding(8.dp), solid = true)
            }
        }
        if (progress != null) {
            Spacer(Modifier.height(8.dp))
            VProgress(progress)
        }
        Spacer(Modifier.height(8.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) {
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
fun Pill(text: String, modifier: Modifier = Modifier, solid: Boolean = false, accent: Boolean = false) {
    val shape = RoundedCornerShape(6.dp)
    val bg = when {
        accent -> VColors.AmberDim
        solid -> Color(0xD90B0B0D)
        else -> Color.Transparent
    }
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = if (accent) VColors.AmberSoft else VColors.Text,
        modifier = modifier
            .clip(shape)
            .background(bg)
            .border(1.dp, if (accent) VColors.Amber.copy(alpha = 0.5f) else VColors.OutlineStrong, shape)
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

@Composable
fun RatingText(rating: Double, modifier: Modifier = Modifier) {
    if (rating <= 0) return
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.Star, null, tint = VColors.Amber, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(3.dp))
        Text(
            String.format(java.util.Locale.US, "%.1f", rating),
            style = MaterialTheme.typography.labelLarge,
            color = VColors.Text,
        )
    }
}

enum class ButtonStyle { Primary, Secondary, Ghost }

@Composable
fun VButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    style: ButtonStyle = ButtonStyle.Primary,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    val shape = RoundedCornerShape(12.dp)
    val (bg, fg, border) = when (style) {
        ButtonStyle.Primary -> Triple(VColors.Amber, VColors.OnAmber, VColors.Amber)
        ButtonStyle.Secondary -> Triple(VColors.SurfaceHigh, VColors.Text, VColors.OutlineStrong)
        ButtonStyle.Ghost -> Triple(Color.Transparent, VColors.Text, VColors.Outline)
    }
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier
            .pressScale(interaction, 0.97f)
            .heightIn(min = 48.dp)
            .clip(shape)
            .background(if (enabled) bg else VColors.SurfaceHigh)
            .border(1.dp, if (enabled) border else VColors.Outline, shape)
            .clickable(
                interactionSource = interaction,
                indication = LocalIndication.current,
                enabled = enabled && !loading,
                onClick = onClick,
            )
            .padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val color = if (enabled) fg else VColors.TextFaint
        if (loading) {
            CircularProgressIndicator(Modifier.size(18.dp), color = color, strokeWidth = 2.dp)
            Spacer(Modifier.width(10.dp))
        } else if (icon != null) {
            Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, style = MaterialTheme.typography.labelLarge, color = color, maxLines = 1)
    }
}

/** Round icon button on a flat surface disc; readable over artwork without gradients. */
@Composable
fun VIconButton(
    icon: ImageVector,
    contentDescription: String?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 42.dp,
    onImage: Boolean = false,
    tint: Color = VColors.Text,
) {
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(if (onImage) VColors.ImageDim else VColors.SurfaceHigh)
            .border(1.dp, if (onImage) Color.Transparent else VColors.Outline, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription, tint = tint, modifier = Modifier.size(size * 0.5f))
    }
}

@Composable
fun SelectChip(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null) {
    val shape = RoundedCornerShape(10.dp)
    Row(
        modifier
            .height(36.dp)
            .clip(shape)
            .background(if (selected) VColors.AmberDim else VColors.Surface)
            .border(1.dp, if (selected) VColors.Amber.copy(alpha = 0.6f) else VColors.Outline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = if (selected) VColors.AmberSoft else VColors.TextMuted, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(label, style = MaterialTheme.typography.labelLarge, color = if (selected) VColors.AmberSoft else VColors.Text)
    }
}

@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Row(
        modifier
            .fillMaxWidth()
            .padding(horizontal = gutter()),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
        if (actionLabel != null && onAction != null) {
            Text(
                actionLabel,
                style = MaterialTheme.typography.labelLarge,
                color = VColors.Amber,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onAction)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
            )
        }
    }
}

/** Page header with a large serif title. Handles the status bar inset. */
@Composable
fun ScreenHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.statusBars)
            .padding(start = if (onBack != null) 12.dp else gutter(), end = 12.dp, top = 12.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            VIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onBack)
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.headlineLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (subtitle != null) {
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically, content = actions)
    }
}

@Composable
fun EmptyState(
    icon: ImageVector,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Column(
        modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier
                .size(72.dp)
                .clip(CircleShape)
                .background(VColors.Surface)
                .border(1.dp, VColors.Outline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = VColors.Amber, modifier = Modifier.size(32.dp))
        }
        Spacer(Modifier.height(20.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(message, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted, textAlign = TextAlign.Center)
        if (actionLabel != null && onAction != null) {
            Spacer(Modifier.height(24.dp))
            VButton(actionLabel, onAction)
        }
    }
}

@Composable
fun LoadingBox(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = VColors.Amber, strokeWidth = 2.5.dp, modifier = Modifier.size(32.dp))
    }
}

@Composable
fun MetaLine(parts: List<String?>, modifier: Modifier = Modifier, color: Color = VColors.TextMuted) {
    val text = parts.filterNotNull().filter { it.isNotBlank() }.joinToString("  ·  ")
    if (text.isNotEmpty()) {
        Text(text, style = MaterialTheme.typography.bodyMedium, color = color, modifier = modifier, maxLines = 2)
    }
}

@Composable
fun VTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    singleLine: Boolean = true,
    leadingIcon: ImageVector? = null,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    trailing: (@Composable () -> Unit)? = null,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it, color = VColors.TextFaint) } },
        singleLine = singleLine,
        leadingIcon = leadingIcon?.let { { Icon(it, null, tint = VColors.TextMuted) } },
        trailingIcon = trailing,
        visualTransformation = visualTransformation,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        shape = RoundedCornerShape(12.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = VColors.Amber,
            unfocusedBorderColor = VColors.Outline,
            focusedLabelColor = VColors.Amber,
            unfocusedLabelColor = VColors.TextMuted,
            cursorColor = VColors.Amber,
            focusedContainerColor = VColors.Surface,
            unfocusedContainerColor = VColors.Surface,
        ),
        modifier = modifier,
    )
}

/** Flat card container used for grouped settings and panels. */
@Composable
fun Panel(modifier: Modifier = Modifier, padding: PaddingValues = PaddingValues(16.dp), content: @Composable () -> Unit) {
    Box(
        modifier
            .fillMaxWidth()
            .clip(CardShape)
            .background(VColors.Surface)
            .border(1.dp, VColors.Outline, CardShape)
            .padding(padding)
    ) { content() }
}

@Composable
fun Wordmark(modifier: Modifier = Modifier, large: Boolean = false) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Text(
            "Veltoret",
            style = if (large) MaterialTheme.typography.displayMedium else MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Box(
            Modifier
                .padding(start = 3.dp, top = if (large) 14.dp else 8.dp)
                .size(if (large) 9.dp else 6.dp)
                .clip(CircleShape)
                .background(VColors.Amber)
        )
    }
}
