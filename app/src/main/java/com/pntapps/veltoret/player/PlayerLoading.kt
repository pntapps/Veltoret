package com.pntapps.veltoret.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.ui.theme.VColors
import kotlinx.coroutines.delay

/** How long the player has been loading: 0 = just started (or not loading), 1 = a while, 2 = slow. */
@Composable
fun rememberLoadingStage(loading: Boolean): Int {
    var stage by remember { mutableIntStateOf(0) }
    LaunchedEffect(loading) {
        stage = 0
        if (!loading) return@LaunchedEffect
        delay(SLOW_AFTER_MS)
        stage = 1
        delay(VERY_SLOW_AFTER_MS - SLOW_AFTER_MS)
        stage = 2
    }
    return stage
}

/**
 * A line under the spinner once loading takes a while, so a slow server or connection doesn't look
 * like a frozen player. [from] names the source ("MyNAS", "Google Drive"); null for device files.
 */
@Composable
fun LoadingHint(stage: Int, from: String?, modifier: Modifier = Modifier) {
    AnimatedVisibility(stage > 0, modifier, enter = fadeIn(), exit = fadeOut()) {
        Text(
            when {
                stage >= 2 && from != null -> "Slow connection, still loading…"
                stage >= 2 -> "Still loading…"
                from != null -> "Loading from $from…"
                else -> "Loading…"
            },
            style = MaterialTheme.typography.bodyMedium,
            color = VColors.Text,
            modifier = Modifier
                .clip(RoundedCornerShape(10.dp))
                .background(VColors.SurfaceHigh.copy(alpha = 0.85f))
                .padding(horizontal = 14.dp, vertical = 6.dp),
        )
    }
}

private const val SLOW_AFTER_MS = 5_000L
private const val VERY_SLOW_AFTER_MS = 15_000L
