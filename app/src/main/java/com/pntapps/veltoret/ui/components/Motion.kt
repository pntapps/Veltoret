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
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
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
 *
 * Plays once: inside a lazy list the item leaves composition when scrolled away, and replaying the
 * entrance every time it scrolls back made scrolling stutter. Whether it played is saved state,
 * which lazy lists keep for items that scrolled out of view.
 */
fun Modifier.entrance(index: Int = 0, baseDelayMs: Int = 0, stepMs: Int = 70): Modifier = composed {
    var played by rememberSaveable { mutableStateOf(false) }
    val alpha = remember { Animatable(if (played) 1f else 0f) }
    val lift = remember { Animatable(if (played) 0f else 1f) }
    val distance = with(LocalDensity.current) { 18.dp.toPx() }
    LaunchedEffect(Unit) {
        if (played) return@LaunchedEffect
        delay((baseDelayMs + index * stepMs).toLong())
        launch { alpha.animateTo(1f, tween(420, easing = FastOutSlowInEasing)) }
        lift.animateTo(0f, spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessLow))
        played = true
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
    val scale = animateFloatAsState(
        if (isPressed) pressed else 1f,
        spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
        label = "press",
    )
    // Read inside the layer so the animation redraws without recomposing the card.
    return graphicsLayer {
        scaleX = scale.value
        scaleY = scale.value
    }
}

/**
 * Slow breathing alpha used for loading placeholders (flat, no shimmer gradient). Read `.value` inside
 * a draw or layer block (e.g. `graphicsLayer { alpha = pulse.value }`), never during composition: a
 * read in composition recomposes the caller on every frame, and many loading posters at once made
 * scrolling stutter.
 */
@Composable
fun rememberPulse(min: Float = 0.45f, max: Float = 1f, periodMs: Int = 900): State<Float> {
    val transition = rememberInfiniteTransition(label = "pulse")
    return transition.animateFloat(
        initialValue = min,
        targetValue = max,
        animationSpec = infiniteRepeatable(tween(periodMs, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "pulse",
    )
}
