package com.pntapps.veltoret.ui.details

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CloudQueue
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.data.db.CreditEntity
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.ui.components.CardShape
import com.pntapps.veltoret.ui.components.Panel
import com.pntapps.veltoret.ui.components.Pill
import com.pntapps.veltoret.ui.components.PosterShape
import com.pntapps.veltoret.ui.components.SectionHeader
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.gutter
import com.pntapps.veltoret.ui.components.entrance

/**
 * Detail page header. No text ever sits on artwork, so no gradient scrim is needed.
 * - Phone: full-width backdrop, then information below.
 * - Tablet portrait / unfolded: wide backdrop, then poster beside the information.
 * - Tablet landscape: information on the left, framed backdrop with poster on the right.
 */
@Composable
fun DetailHeader(
    title: String,
    backdropUrl: String?,
    posterUrl: String?,
    onBack: () -> Unit,
    info: @Composable ColumnScope.() -> Unit,
) {
    when (LocalWidthClass.current) {
        WidthClass.Expanded -> Row(
            Modifier
                .windowInsetsPadding(WindowInsets.statusBars)
                .padding(start = 40.dp, end = 40.dp, top = 16.dp, bottom = 12.dp),
        ) {
            Column(Modifier.weight(1f).padding(end = 40.dp)) {
                VIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onBack)
                Spacer(Modifier.height(24.dp))
                info()
            }
            Box(Modifier.weight(1.1f).padding(top = 58.dp, bottom = 48.dp)) {
                val frame = RoundedCornerShape(24.dp)
                VImage(
                    backdropUrl, null,
                    Modifier
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f)
                        .clip(frame)
                        .border(1.dp, VColors.Outline, frame)
                        .entrance(1),
                )
                VImage(
                    posterUrl, title,
                    Modifier
                        .align(Alignment.BottomStart)
                        .padding(start = 20.dp)
                        .offset(y = 48.dp)
                        .width(124.dp)
                        .aspectRatio(2f / 3f)
                        .clip(PosterShape)
                        .border(2.dp, MaterialTheme.colorScheme.background, PosterShape)
                        .entrance(2),
                    fallbackText = title,
                )
            }
        }
        WidthClass.Medium -> Column {
            Box {
                VImage(backdropUrl, null, Modifier.fillMaxWidth().aspectRatio(2.4f))
                Row(Modifier.windowInsetsPadding(WindowInsets.statusBars).padding(12.dp)) {
                    VIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onBack, onImage = true)
                }
            }
            Row(Modifier.padding(horizontal = 28.dp, vertical = 28.dp)) {
                VImage(
                    posterUrl, title,
                    Modifier
                        .width(180.dp)
                        .aspectRatio(2f / 3f)
                        .clip(PosterShape)
                        .border(1.dp, VColors.Outline, PosterShape),
                    fallbackText = title,
                )
                Spacer(Modifier.width(28.dp))
                Column(Modifier.weight(1f), content = info)
            }
        }
        WidthClass.Compact -> Column {
            Box {
                VImage(backdropUrl, null, Modifier.fillMaxWidth().aspectRatio(16f / 9f))
                Row(Modifier.windowInsetsPadding(WindowInsets.statusBars).padding(12.dp)) {
                    VIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onBack, onImage = true)
                }
            }
            Column(Modifier.padding(horizontal = 20.dp, vertical = 20.dp), content = info)
        }
    }
}

@Composable
fun DetailTitle(title: String, tagline: String?) {
    Text(title, style = MaterialTheme.typography.displaySmall)
    if (!tagline.isNullOrBlank()) {
        Spacer(Modifier.height(6.dp))
        Text(
            tagline,
            style = MaterialTheme.typography.titleMedium.copy(
                fontFamily = MaterialTheme.typography.headlineSmall.fontFamily,
                fontStyle = FontStyle.Italic,
            ),
            color = VColors.TextMuted,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TagRow(genres: List<String>, quality: List<String>) {
    if (genres.isEmpty() && quality.isEmpty()) return
    Spacer(Modifier.height(12.dp))
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        quality.forEach { Pill(it, accent = true) }
        genres.forEach { Pill(it) }
    }
}

@Composable
fun Overview(text: String) {
    if (text.isBlank()) return
    Spacer(Modifier.height(20.dp))
    Text(text, style = MaterialTheme.typography.bodyLarge, color = VColors.Text.copy(alpha = 0.88f))
}

@Composable
fun CreditLine(label: String, value: String?) {
    if (value.isNullOrBlank()) return
    Spacer(Modifier.height(10.dp))
    Row {
        Text(label, style = MaterialTheme.typography.labelLarge, color = VColors.TextMuted, modifier = Modifier.width(96.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
fun CastRow(cast: List<CreditEntity>) {
    if (cast.isEmpty()) return
    Column(Modifier.padding(top = 32.dp)) {
        SectionHeader("Cast")
        Spacer(Modifier.height(14.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = gutter()), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            items(cast, key = { it.personId }) { person ->
                Column(Modifier.width(84.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    VImage(
                        TmdbImages.profile(person.profilePath), person.name,
                        Modifier
                            .size(76.dp)
                            .clip(CircleShape)
                            .border(1.dp, VColors.Outline, CircleShape),
                        fallbackText = person.name.split(' ').mapNotNull { it.firstOrNull()?.toString() }.take(2).joinToString(""),
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(person.name, style = MaterialTheme.typography.labelMedium, maxLines = 2, textAlign = TextAlign.Center, overflow = TextOverflow.Ellipsis)
                    if (!person.character.isNullOrBlank()) {
                        Text(person.character, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1, textAlign = TextAlign.Center, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** Lists every copy of a title in the library so users can pick a specific version or account. */
@Composable
fun VersionsSection(files: List<MediaFileEntity>, onPlay: (MediaFileEntity) -> Unit) {
    if (files.isEmpty()) return
    Column(Modifier.padding(top = 32.dp)) {
        SectionHeader(if (files.size > 1) "Versions" else "File")
        Spacer(Modifier.height(12.dp))
        // Versions sit side by side on landscape tablets.
        val perRow = if (LocalWidthClass.current == WidthClass.Expanded) 2 else 1
        Column(Modifier.padding(horizontal = gutter()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            files.chunked(perRow).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    row.forEach { f -> Box(Modifier.weight(1f)) { FileRow(f) { onPlay(f) } } }
                    repeat(perRow - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
fun FileRow(file: MediaFileEntity, onClick: () -> Unit) {
    Panel(
        Modifier
            .clip(CardShape)
            .clickable(onClick = onClick),
        padding = PaddingValues(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.PlayArrow, null, tint = VColors.Amber)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(file.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FilenameParser.qualityTags(file.name, file.height).take(3).forEach {
                        Pill(it, Modifier.padding(end = 6.dp), accent = true)
                    }
                    Text(
                        listOfNotNull(Format.bytes(file.sizeBytes), Format.runtimeMs(file.durationMs)).joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextMuted,
                    )
                }
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    val onDevice = com.pntapps.veltoret.data.storage.LocalStorage.isLocal(file.accountEmail)
                    Icon(
                        if (onDevice) Icons.Rounded.PhoneAndroid else Icons.Rounded.CloudQueue, null,
                        tint = if (onDevice) VColors.AmberSoft else VColors.TextFaint, modifier = Modifier.size(13.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (onDevice) "On this device" else file.accountEmail,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (onDevice) VColors.AmberSoft else VColors.TextFaint,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}
