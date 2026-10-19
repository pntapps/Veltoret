package com.pntapps.veltoret.ui.files

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.data.storage.StorageSpace
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format

/** "Google storage · 4.2 GB used of 15 GB · 10.8 GB free". */
fun storageSummary(space: StorageSpace): String {
    fun size(bytes: Long) = if (bytes <= 0) "0 B" else Format.bytes(bytes)
    return listOfNotNull(
        space.name,
        if (space.total != null && space.total > 0) "${size(space.used)} used of ${size(space.total)}" else "${size(space.used)} used",
        space.free?.let { "${size(it)} free" },
    ).joinToString(" · ")
}

/** One line of text over a thin flat bar showing how full the storage is (no bar when the size is unknown). */
@Composable
fun StorageSummary(space: StorageSpace, style: TextStyle, modifier: Modifier = Modifier) {
    val fraction = space.total?.takeIf { it > 0 }?.let { (space.used.toFloat() / it).coerceIn(0f, 1f) }
    Column(modifier) {
        Text(storageSummary(space), style = style, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (fraction != null) {
            Spacer(Modifier.height(6.dp))
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(VColors.Outline)
            ) {
                Box(
                    Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(fraction)
                        .background(if (fraction >= 0.9f) VColors.Danger else VColors.Amber)
                )
            }
        }
    }
}
