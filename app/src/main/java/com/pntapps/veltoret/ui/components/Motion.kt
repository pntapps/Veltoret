package com.pntapps.veltoret.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Fades and lifts content in when it first appears. Give siblings increasing [index] values for a
 * staggered, "assembling" entrance.
 */
fun Modifier.entrance(index: Int = 0, baseDelayMs: Int = 0, stepMs: Int = 70): Modifier = composed {
    val alpha = remember { Animatable(0f) }
    val lift = remember { Animatable(1f) }
    val distance = with(LocalDensity.current) { 18.dp.toPx() }
    LaunchedEffect(Unit) {
        delay((baseDelayMs + index * stepMs).toLong())
        launch { alpha.animateTo(1f, tween(420, easing = FastOutSlowInEasing)) }
        lift.animateTo(0f, spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessLow))
    }
    graphicsLayer {
        this.alpha = alpha.value
        translationY = lift.value * distance
    }
}

/** Subtle squeeze while pressed; pass the same [interactionSource] to the clickable. */
@Composable
fun Modifier.pressScale(interactionSource: MutableInteractionSource, pressed: Float = 0.96f): Modifier {
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        if (isPressed) pressed else 1f,
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
        label = "press",
    )
    return graphicsLayer {
        scaleX = scale
        scaleY = scale
    }
}

/** Slow breathing alpha used for loading placeholders (flat, no shimmer gradient). */
@Composable
fun rememberPulse(min: Float = 0.45f, max: Float = 1f, periodMs: Int = 900): Float {
    val transition = rememberInfiniteTransition(label = "pulse")
    val value by transition.animateFloat(
        initialValue = min,
        targetValue = max,
        animationSpec = infiniteRepeatable(tween(periodMs, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "pulse",
    )
    return value
}
