package com.pntapps.veltoret.ui.details

import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.theme.VColors

/** One entry in a detail page's ⋮ menu. */
class DetailMenuItem(val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector, val run: () -> Unit)

/**
 * The action row on movie and show pages, always one line: Play, then Trailer, Watchlist and ⋮. When they
 * don't fit beside Play's label (narrow phones, "Resume S1 · E10", a landscape tablet's text column), the
 * least used go into ⋮: the Trailer button loses its label, then Trailer moves into ⋮, then Watchlist.
 * Two rows looked unbalanced, and one squeezed row cut Play to "Pla" and "Resume" to "Resu".
 */
@Composable
fun DetailActionRow(
    playLabel: String,
    play: @Composable RowScope.() -> Unit,
    trailerKey: String?,
    /** Show "Trailer" with its label when there's room (show pages on wider screens). */
    labelledTrailer: Boolean,
    saved: Boolean,
    onToggleWatchlist: () -> Unit,
    menu: List<DetailMenuItem>,
) {
    val context = LocalContext.current
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val style = MaterialTheme.typography.labelLarge
    fun buttonWidth(label: String): Dp = with(density) { measurer.measure(label, style).size.width.toDp() } + BUTTON_CHROME

    BoxWithConstraints {
        val playWidth = buttonWidth(playLabel)
        val labelled = buttonWidth("Trailer")
        fun fits(widths: List<Dp>): Boolean = playWidth + ICON + widths.fold(0.dp) { a, w -> a + w + GAP } + GAP <= maxWidth
        val trailer = trailerKey != null
        // What stays in the row, most important first.
        val trailerMode = when {
            !trailer -> TrailerMode.None
            labelledTrailer && fits(listOf(ICON, labelled)) -> TrailerMode.Labelled
            fits(listOf(ICON, ICON)) -> TrailerMode.Icon
            else -> TrailerMode.Menu
        }
        val watchlistInRow = when (trailerMode) {
            TrailerMode.Menu, TrailerMode.None -> fits(listOf(ICON))
            else -> true
        }
        var open by remember { mutableStateOf(false) }

        Row(horizontalArrangement = Arrangement.spacedBy(GAP), verticalAlignment = Alignment.CenterVertically) {
            play()
            when (trailerMode) {
                TrailerMode.Labelled -> TrailerButton(trailerKey!!, compact = false)
                TrailerMode.Icon -> TrailerButton(trailerKey!!, compact = true)
                else -> Unit
            }
            if (watchlistInRow) WatchlistButton(saved, onToggleWatchlist)
            Box {
                VIconButton(Icons.Rounded.MoreVert, "More", { open = true }, size = ICON)
                DropdownMenu(open, { open = false }, containerColor = VColors.SurfaceHigh) {
                    if (trailerMode == TrailerMode.Menu) {
                        DropdownMenuItem(
                            text = { Text("Watch trailer") },
                            leadingIcon = { Icon(TrailerIcon, null) },
                            onClick = { open = false; context.openTrailer(trailerKey!!) },
                        )
                    }
                    if (!watchlistInRow) {
                        DropdownMenuItem(
                            text = { Text(if (saved) "Remove from Watchlist" else "Watch later") },
                            leadingIcon = { Icon(if (saved) Icons.Rounded.Bookmark else Icons.Rounded.BookmarkBorder, null) },
                            onClick = {
                                open = false
                                Toast.makeText(context, if (saved) "Removed from your Watchlist" else "Added to your Watchlist", Toast.LENGTH_SHORT).show()
                                onToggleWatchlist()
                            },
                        )
                    }
                    menu.forEach { item ->
                        DropdownMenuItem(
                            text = { Text(item.label) },
                            leadingIcon = { Icon(item.icon, null) },
                            onClick = { open = false; item.run() },
                        )
                    }
                }
            }
        }
    }
}

private enum class TrailerMode { None, Labelled, Icon, Menu }

private val ICON = 48.dp
private val GAP = 10.dp
/** VButton around its label: 20 dp padding each side, a 20 dp icon, 8 dp before the text, the border. */
private val BUTTON_CHROME = 20.dp * 2 + 20.dp + 8.dp + 2.dp

/** Play with [label], for [DetailActionRow]: hugs its label on wide screens, takes the spare width on phones. */
@Composable
fun RowScope.DetailPlayButton(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean, fill: Boolean, onClick: () -> Unit) {
    VButton(label, onClick, icon = icon, enabled = enabled, style = ButtonStyle.Primary, modifier = Modifier.weight(1f, fill = fill))
}
