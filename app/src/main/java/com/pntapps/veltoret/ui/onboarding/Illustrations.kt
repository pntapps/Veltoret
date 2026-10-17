package com.pntapps.veltoret.ui.onboarding

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.ui.theme.VColors
import kotlin.math.PI
import kotlin.math.sin

// ---------------------------------------------------------------------------------------------
// Minimalist "poster art": flat shapes in muted cinematic tones. Used across onboarding.
// ---------------------------------------------------------------------------------------------

private data class PosterArt(val bg: Color, val mid: Color, val dark: Color, val light: Color, val style: Int)

private val Cream = Color(0xFFF3E6CF)
private val PosterArts = listOf(
    PosterArt(Color(0xFF1F3B3A), Color(0xFF2E5552), Color(0xFF142726), VColors.Amber, 0),
    PosterArt(Color(0xFF3A2238), Color(0xFF55304F), Color(0xFF241522), Cream, 1),
    PosterArt(Color(0xFF1E2A44), Color(0xFF2C3D61), Color(0xFF131B2C), VColors.AmberSoft, 2),
    PosterArt(Color(0xFF4A2A1C), Color(0xFF6B3D28), Color(0xFF2E1A11), Cream, 3),
    PosterArt(Color(0xFF2A2D35), Color(0xFF3B3F4A), Color(0xFF1A1C21), VColors.Amber, 4),
    PosterArt(Color(0xFF33361F), Color(0xFF4A4F2D), Color(0xFF202213), VColors.AmberSoft, 1),
    PosterArt(Color(0xFF2B1F3D), Color(0xFF3F2E58), Color(0xFF1B1327), VColors.Amber, 0),
    PosterArt(Color(0xFF173238), Color(0xFF214751), Color(0xFF0F2125), Cream, 2),
    PosterArt(Color(0xFF402024), Color(0xFF5E2F35), Color(0xFF281416), VColors.AmberSoft, 4),
)

private fun DrawScope.drawPosterArt(art: PosterArt) {
    val w = size.width
    val h = size.height
    drawRect(art.bg)
    when (art.style) {
        0 -> { // sun over mountains
            drawCircle(art.light, w * 0.16f, Offset(w * 0.66f, h * 0.32f))
            drawPath(Path().apply { moveTo(-w * 0.1f, h * 0.72f); lineTo(w * 0.35f, h * 0.38f); lineTo(w * 0.8f, h * 0.72f); close() }, art.mid)
            drawPath(Path().apply { moveTo(w * 0.3f, h * 0.72f); lineTo(w * 0.72f, h * 0.46f); lineTo(w * 1.1f, h * 0.72f); close() }, art.dark)
            drawRect(art.dark, Offset(0f, h * 0.72f), Size(w, h * 0.28f))
        }
        1 -> { // big moon, horizon and reflection
            drawCircle(art.light.copy(alpha = 0.92f), w * 0.3f, Offset(w * 0.5f, h * 0.4f))
            drawRect(art.dark, Offset(0f, h * 0.58f), Size(w, h * 0.42f))
            drawRect(art.light.copy(alpha = 0.35f), Offset(w * 0.32f, h * 0.62f), Size(w * 0.36f, h * 0.015f))
            drawRect(art.light.copy(alpha = 0.2f), Offset(w * 0.4f, h * 0.66f), Size(w * 0.2f, h * 0.012f))
        }
        2 -> { // skyline at night
            drawCircle(art.light, w * 0.08f, Offset(w * 0.75f, h * 0.2f))
            val heights = floatArrayOf(0.36f, 0.5f, 0.3f, 0.58f, 0.42f, 0.33f)
            val bw = w / heights.size
            heights.forEachIndexed { i, fh ->
                drawRect(if (i % 2 == 0) art.mid else art.dark, Offset(i * bw, h * (0.76f - fh)), Size(bw + 1f, h * fh))
            }
            for (i in 0 until 6) {
                drawRect(art.light.copy(alpha = 0.6f), Offset(w * (0.1f + 0.15f * i), h * (0.5f + 0.03f * (i % 3))), Size(w * 0.03f, h * 0.02f))
            }
            drawRect(art.dark, Offset(0f, h * 0.76f), Size(w, h * 0.24f))
        }
        3 -> { // abstract overlapping discs
            drawCircle(art.mid, w * 0.38f, Offset(w * 0.32f, h * 0.36f))
            drawCircle(art.light.copy(alpha = 0.85f), w * 0.22f, Offset(w * 0.64f, h * 0.48f))
            drawRect(art.dark, Offset(0f, h * 0.7f), Size(w, h * 0.3f))
        }
        else -> { // lone figure in front of a sun
            drawCircle(art.light, w * 0.26f, Offset(w * 0.5f, h * 0.42f))
            drawCircle(art.dark, w * 0.07f, Offset(w * 0.5f, h * 0.44f))
            drawRoundRect(art.dark, Offset(w * 0.38f, h * 0.5f), Size(w * 0.24f, h * 0.3f), CornerRadius(w * 0.1f))
            drawRect(art.dark, Offset(0f, h * 0.74f), Size(w, h * 0.26f))
        }
    }
    // Title lines
    drawRoundRect(Cream.copy(alpha = 0.85f), Offset(w * 0.14f, h * 0.83f), Size(w * 0.6f, h * 0.035f), CornerRadius(h * 0.02f))
    drawRoundRect(Cream.copy(alpha = 0.45f), Offset(w * 0.14f, h * 0.89f), Size(w * 0.38f, h * 0.025f), CornerRadius(h * 0.02f))
}

@Composable
private fun PosterTile(index: Int, modifier: Modifier = Modifier, corner: Dp = 10.dp) {
    val art = PosterArts[index.mod(PosterArts.size)]
    Canvas(
        modifier
            .aspectRatio(2f / 3f)
            .clip(RoundedCornerShape(corner))
    ) { drawPosterArt(art) }
}

// ---------------------------------------------------------------------------------------------
// Welcome: an endlessly drifting wall of posters with a pulsing play button.
// ---------------------------------------------------------------------------------------------

@Composable
fun PosterWallIllustration(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "wall")
    val drift by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(26_000, easing = LinearEasing)), label = "drift")
    val pulse by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(2_200, easing = FastOutSlowInEasing)), label = "pulse")
    val density = LocalDensity.current
    val shape = RoundedCornerShape(28.dp)

    BoxWithConstraints(
        modifier
            .clip(shape)
            .background(VColors.Surface)
            .border(1.dp, VColors.Outline, shape)
    ) {
        val columns = 4
        val gap = 10.dp
        val colWidth = (maxWidth - gap * (columns + 1)) / columns
        val tileHeight = colWidth * 1.5f
        val perColumn = 4
        val setHeightPx = with(density) { ((tileHeight + gap) * perColumn).toPx() }

        Row(
            Modifier
                .fillMaxSize()
                .padding(horizontal = gap),
            horizontalArrangement = Arrangement.spacedBy(gap),
        ) {
            repeat(columns) { col ->
                val up = col % 2 == 0
                val shift = ((drift + col * 0.17f) % 1f) * setHeightPx
                Column(
                    Modifier
                        .width(colWidth)
                        // Lay out the whole strip, not just the visible 300dp, so it can scroll through.
                        .wrapContentHeight(align = Alignment.Top, unbounded = true)
                        .graphicsLayer { translationY = if (up) -shift else shift - setHeightPx },
                    verticalArrangement = Arrangement.spacedBy(gap),
                ) {
                    Spacer(Modifier.height(gap))
                    // Two copies of the set so the loop is seamless.
                    repeat(perColumn * 2 + 1) { i -> PosterTile(col * 3 + i % perColumn, Modifier.fillMaxWidth()) }
                }
            }
        }

        // Flat dim + pulsing play button in the middle.
        Box(
            Modifier
                .fillMaxSize()
                .background(VColors.Background.copy(alpha = 0.35f))
        )
        Box(Modifier.align(Alignment.Center), contentAlignment = Alignment.Center) {
            Box(
                Modifier
                    .size(84.dp)
                    .graphicsLayer {
                        scaleX = 1f + pulse * 0.7f
                        scaleY = 1f + pulse * 0.7f
                        alpha = (1f - pulse) * 0.6f
                    }
                    .border(2.dp, VColors.Amber, CircleShape)
            )
            Box(
                Modifier
                    .size(76.dp)
                    .clip(CircleShape)
                    .background(VColors.Amber),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Rounded.PlayArrow, null, tint = VColors.OnAmber, modifier = Modifier.size(42.dp))
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Connect: phone ⇄ Drive cloud with data flowing along a dashed line.
// ---------------------------------------------------------------------------------------------

@Composable
fun ConnectIllustration(connected: Boolean, working: Boolean, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "connect")
    val flow by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(1_600, easing = LinearEasing)), label = "flow")
    val bob by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(3_200, easing = LinearEasing)), label = "bob")
    val active = connected || working
    val badgeScale by animateFloatAsState(if (connected) 1f else 0.85f, spring(dampingRatio = 0.45f, stiffness = Spring.StiffnessLow), label = "badge")

    Box(modifier.height(210.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height
            val phoneBob = sin(bob * 2 * PI).toFloat() * 4.dp.toPx()
            val cloudBob = sin(bob * 2 * PI + PI / 2).toFloat() * 6.dp.toPx()

            // Dashed link
            val start = Offset(w * 0.3f, h * 0.5f)
            val end = Offset(w * 0.68f, h * 0.5f)
            drawLine(
                if (active) VColors.Amber.copy(alpha = 0.7f) else VColors.OutlineStrong,
                start, end, strokeWidth = 3.dp.toPx(), cap = StrokeCap.Round,
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(14f, 12f), -flow * 26f * 4),
            )
            if (active) {
                repeat(3) { i ->
                    val t = (flow + i / 3f) % 1f
                    drawCircle(VColors.Amber, 4.dp.toPx(), Offset(start.x + (end.x - start.x) * t, start.y))
                }
            }

            // Phone
            val pw = 76.dp.toPx()
            val ph = 132.dp.toPx()
            val pLeft = w * 0.2f - pw / 2
            val pTop = h / 2 - ph / 2 + phoneBob
            drawRoundRect(VColors.SurfaceHigh, Offset(pLeft, pTop), Size(pw, ph), CornerRadius(16.dp.toPx()))
            drawRoundRect(VColors.OutlineStrong, Offset(pLeft, pTop), Size(pw, ph), CornerRadius(16.dp.toPx()), style = Stroke(1.5.dp.toPx()))
            val inset = 9.dp.toPx()
            val tileW = (pw - inset * 3) / 2
            val tileH = tileW * 1.45f
            for (r in 0 until 2) for (c in 0 until 2) {
                val art = PosterArts[(r * 2 + c + 1) % PosterArts.size]
                drawRoundRect(art.bg, Offset(pLeft + inset + c * (tileW + inset), pTop + 18.dp.toPx() + r * (tileH + inset)), Size(tileW, tileH), CornerRadius(4.dp.toPx()))
                drawCircle(art.light, tileW * 0.18f, Offset(pLeft + inset + c * (tileW + inset) + tileW * 0.6f, pTop + 18.dp.toPx() + r * (tileH + inset) + tileH * 0.35f))
            }
            drawRoundRect(VColors.OutlineStrong, Offset(pLeft + pw * 0.35f, pTop + ph - 9.dp.toPx()), Size(pw * 0.3f, 3.dp.toPx()), CornerRadius(2f))

            // Cloud built from flat circles
            val cx = w * 0.8f
            val cy = h * 0.5f + cloudBob
            val u = 26.dp.toPx()
            val cloud = if (active) VColors.SurfaceHighest else VColors.SurfaceHigh
            drawCircle(cloud, u * 1.05f, Offset(cx - u * 0.2f, cy - u * 0.35f))
            drawCircle(cloud, u * 0.8f, Offset(cx - u * 1.1f, cy + u * 0.15f))
            drawCircle(cloud, u * 0.85f, Offset(cx + u * 0.8f, cy + u * 0.1f))
            drawRoundRect(cloud, Offset(cx - u * 1.9f, cy + u * 0.1f), Size(u * 3.6f, u * 0.85f), CornerRadius(u * 0.42f))
            // Drive-like triangle mark
            val m = u * 0.55f
            val mx = cx - u * 0.15f
            val my = cy + u * 0.05f
            drawPath(Path().apply { moveTo(mx - m * 0.5f, my + m * 0.45f); lineTo(mx, my - m * 0.45f); lineTo(mx + m * 0.25f, my); close() }, VColors.Amber)
            drawPath(Path().apply { moveTo(mx, my - m * 0.45f); lineTo(mx + m * 0.5f, my - m * 0.45f); lineTo(mx + m, my + m * 0.45f); lineTo(mx + m * 0.25f, my); close() }, VColors.AmberSoft)
            drawPath(Path().apply { moveTo(mx - m * 0.5f, my + m * 0.45f); lineTo(mx + m, my + m * 0.45f); lineTo(mx + m * 0.75f, my + m * 0.95f); lineTo(mx - m * 0.25f, my + m * 0.95f); close() }, Cream)
        }
        // Lock / check badge sitting on the link
        Box(
            Modifier
                .graphicsLayer { scaleX = badgeScale; scaleY = badgeScale }
                .size(46.dp)
                .clip(CircleShape)
                .background(if (connected) VColors.Amber else VColors.Surface)
                .border(1.dp, if (connected) VColors.Amber else VColors.OutlineStrong, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (connected) Icons.Rounded.Check else Icons.Rounded.Lock,
                null,
                tint = if (connected) VColors.OnAmber else VColors.AmberSoft,
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Folders: two folders with posters peeking out and bobbing.
// ---------------------------------------------------------------------------------------------

@Composable
fun FoldersIllustration(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "folders")
    val t by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(3_000, easing = LinearEasing)), label = "t")
    Row(
        modifier.height(200.dp),
        horizontalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.Bottom,
    ) {
        FolderArt("Movies", Icons.Rounded.Movie, posters = listOf(0, 3), phase = t)
        FolderArt("TV Shows", Icons.Rounded.LiveTv, posters = listOf(2, 7), phase = (t + 0.5f) % 1f)
    }
}

@Composable
private fun FolderArt(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, posters: List<Int>, phase: Float) {
    val lift = (sin(phase * 2 * PI).toFloat() + 1f) / 2f
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(width = 132.dp, height = 150.dp), contentAlignment = Alignment.BottomCenter) {
            // Back of folder
            Canvas(Modifier.size(132.dp, 104.dp)) {
                val tab = Path().apply {
                    moveTo(0f, 14.dp.toPx())
                    lineTo(0f, 0f + 8.dp.toPx())
                    quadraticTo(0f, 0f, 8.dp.toPx(), 0f)
                    lineTo(size.width * 0.38f, 0f)
                    lineTo(size.width * 0.46f, 12.dp.toPx())
                    lineTo(size.width, 12.dp.toPx())
                    lineTo(size.width, size.height)
                    lineTo(0f, size.height)
                    close()
                }
                drawPath(tab, Color(0xFF6B4D22))
            }
            // Posters rising out of the folder
            Row(
                Modifier
                    .padding(bottom = 30.dp)
                    .graphicsLayer { translationY = -lift * 18.dp.toPx() },
                horizontalArrangement = Arrangement.spacedBy((-14).dp),
            ) {
                posters.forEachIndexed { i, p ->
                    PosterTile(
                        p,
                        Modifier
                            .width(56.dp)
                            .graphicsLayer { rotationZ = if (i == 0) -8f else 8f },
                        corner = 6.dp,
                    )
                }
            }
            // Front of folder
            Box(
                Modifier
                    .size(132.dp, 78.dp)
                    .clip(RoundedCornerShape(topStart = 6.dp, topEnd = 6.dp, bottomStart = 14.dp, bottomEnd = 14.dp))
                    .background(VColors.Amber),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = VColors.OnAmber.copy(alpha = 0.75f), modifier = Modifier.size(30.dp))
            }
        }
        Spacer(Modifier.height(10.dp))
        Text(label, style = MaterialTheme.typography.labelLarge, color = VColors.TextMuted)
    }
}

// ---------------------------------------------------------------------------------------------
// TMDB: a fanned stack of posters with a rating chip and a key.
// ---------------------------------------------------------------------------------------------

@Composable
fun MetadataIllustration(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "meta")
    val sway by transition.animateFloat(-1f, 1f, infiniteRepeatable(tween(2_600, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "sway")
    Box(modifier.height(210.dp), contentAlignment = Alignment.Center) {
        listOf(-16f to 5, 16f to 6, 0f to 1).forEachIndexed { i, (angle, art) ->
            PosterTile(
                art,
                Modifier
                    .width(if (i == 2) 112.dp else 96.dp)
                    .graphicsLayer {
                        rotationZ = angle + sway * (if (i == 2) 1.5f else 3f) * (if (angle < 0) -1 else 1)
                        translationX = angle * 3.2f * density
                        translationY = if (i == 2) 0f else 10.dp.toPx()
                    }
                    .border(1.dp, VColors.Outline, RoundedCornerShape(10.dp)),
            )
        }
        Row(
            Modifier
                .align(Alignment.TopCenter)
                .padding(top = 4.dp)
                .graphicsLayer { translationY = sway * 4.dp.toPx() }
                .clip(RoundedCornerShape(12.dp))
                .background(VColors.SurfaceHigh)
                .border(1.dp, VColors.OutlineStrong, RoundedCornerShape(12.dp))
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Rounded.Star, null, tint = VColors.Amber, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(4.dp))
            Text("8.6", style = MaterialTheme.typography.labelLarge, color = VColors.Text)
        }
        Box(
            Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 48.dp, bottom = 6.dp)
                .graphicsLayer { rotationZ = sway * 14f }
                .size(52.dp)
                .clip(CircleShape)
                .background(VColors.Amber),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.Key, null, tint = VColors.OnAmber, modifier = Modifier.size(26.dp))
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Scan: posters fill a grid while a scan line sweeps across it.
// ---------------------------------------------------------------------------------------------

@Composable
fun ScanIllustration(finished: Boolean, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "scan")
    val sweep by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(1_800, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "sweep")
    val cycle by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(4_800, easing = LinearEasing)), label = "cycle")
    val columns = 4
    val rows = 2
    val count = columns * rows
    val revealed = if (finished) count else (cycle * (count + 3)).toInt()
    val shape = RoundedCornerShape(24.dp)

    Box(
        modifier
            .clip(shape)
            .background(VColors.Surface)
            .border(1.dp, VColors.Outline, shape)
            .padding(14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            repeat(rows) { r ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    repeat(columns) { c ->
                        val i = r * columns + c
                        val shown by animateFloatAsState(if (i < revealed) 1f else 0f, spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessLow), label = "tile$i")
                        Box(Modifier.weight(1f)) {
                            Box(
                                Modifier
                                    .fillMaxWidth()
                                    .aspectRatio(2f / 3f)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(VColors.SurfaceHigh)
                            )
                            PosterTile(
                                i + 2,
                                Modifier
                                    .fillMaxWidth()
                                    .graphicsLayer {
                                        alpha = shown
                                        scaleX = 0.8f + 0.2f * shown
                                        scaleY = 0.8f + 0.2f * shown
                                    },
                                corner = 8.dp,
                            )
                        }
                    }
                }
            }
        }
        if (!finished) {
            BoxWithConstraints(Modifier.matchParentSize()) {
                Box(
                    Modifier
                        .offset(y = maxHeight * sweep - 1.dp)
                        .fillMaxWidth()
                        .height(2.dp)
                        .background(VColors.Amber)
                )
            }
        }
    }
}
