package com.pntapps.veltoret.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.unit.dp

val VeltoretShapes = Shapes(
    extraSmall = RoundedCornerShape(6.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

@Composable
fun VeltoretTheme(oledBlack: Boolean = false, content: @Composable () -> Unit) {
    val background = if (oledBlack) VColors.BackgroundOled else VColors.Background
    val scheme = darkColorScheme(
        primary = VColors.Amber,
        onPrimary = VColors.OnAmber,
        primaryContainer = VColors.AmberDim,
        onPrimaryContainer = VColors.AmberSoft,
        secondary = VColors.TextMuted,
        onSecondary = VColors.Background,
        secondaryContainer = VColors.SurfaceHighest,
        onSecondaryContainer = VColors.Text,
        tertiary = VColors.AmberSoft,
        background = background,
        onBackground = VColors.Text,
        surface = background,
        onSurface = VColors.Text,
        surfaceVariant = VColors.SurfaceHigh,
        onSurfaceVariant = VColors.TextMuted,
        surfaceTint = background,
        surfaceContainerLowest = background,
        surfaceContainerLow = VColors.Surface,
        surfaceContainer = VColors.Surface,
        surfaceContainerHigh = VColors.SurfaceHigh,
        surfaceContainerHighest = VColors.SurfaceHighest,
        surfaceBright = VColors.SurfaceHighest,
        surfaceDim = background,
        outline = VColors.OutlineStrong,
        outlineVariant = VColors.Outline,
        error = VColors.Danger,
        onError = VColors.Background,
        inverseSurface = VColors.Text,
        inverseOnSurface = VColors.Background,
        inversePrimary = VColors.OnAmber,
        scrim = VColors.ImageDim,
    )
    MaterialTheme(
        colorScheme = scheme,
        typography = VeltoretTypography,
        shapes = VeltoretShapes,
    ) {
        // Screens draw on plain Boxes rather than Surfaces, so set the default text/icon color here.
        CompositionLocalProvider(LocalContentColor provides VColors.Text, content = content)
    }
}
