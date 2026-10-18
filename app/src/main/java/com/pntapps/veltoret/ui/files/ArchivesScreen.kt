package com.pntapps.veltoret.ui.files

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.FolderZip
import androidx.compose.material.icons.rounded.Inventory2
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.ArchiveFileEntity
import com.pntapps.veltoret.data.drive.ExtractWorker
import com.pntapps.veltoret.data.drive.ZipAfterExtract
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.EmptyState
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.Panel
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.gutter
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

data class ArchiveRow(val archive: ArchiveFileEntity, val job: ExtractUi?)

class ArchivesViewModel(private val container: AppContainer) : ViewModel() {
    val rows: StateFlow<List<ArchiveRow>?> = combine(container.libraryRepository.archives(), extractions(container.appContext)) { archives, jobs ->
        val latest = jobs.groupBy { it.zipId }.mapValues { (_, list) -> list.firstOrNull { it.active } ?: list.last() }
        archives.map { ArchiveRow(it, latest[it.driveId]) }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun extract(archive: ArchiveFileEntity, wifiOnly: Boolean, after: ZipAfterExtract) {
        ExtractWorker.enqueue(
            container.appContext, archive.accountEmail, archive.driveId, archive.name, archive.parentId, wifiOnly, after,
        )
    }
}

/** ZIP archives found in library folders, with one-tap extraction into Drive. */
@Composable
fun ArchivesScreen(navigator: Navigator) {
    val vm = appViewModel { ArchivesViewModel(it) }
    val rows by vm.rows.collectAsStateWithLifecycle()
    val askNotifications = rememberNotificationPermission()
    var confirm by remember { mutableStateOf<ArchiveFileEntity?>(null) }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Archives", subtitle = "ZIP files in your library folders", onBack = navigator::back)
        val list = rows
        when {
            list == null -> LoadingBox()
            list.isEmpty() -> EmptyState(
                Icons.Rounded.Inventory2, "No archives",
                "When a ZIP turns up in your Movies or TV folders, it appears here so you can unpack it into Drive.",
            )
            else -> LazyVerticalGrid(
                columns = GridCells.Adaptive(420.dp),
                contentPadding = PaddingValues(horizontal = gutter(), vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Text(
                        "Videos inside a ZIP can't be streamed. Extracting unpacks them into a folder next to the ZIP " +
                            "without saving anything on this phone.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = VColors.TextMuted,
                        modifier = Modifier.padding(bottom = 6.dp),
                    )
                }
                items(list, key = { it.archive.driveId }) { row ->
                    ArchiveCard(row) { confirm = row.archive }
                }
            }
        }
    }

    confirm?.let { archive ->
        ExtractDialog(
            name = archive.name,
            sizeBytes = archive.sizeBytes,
            account = archive.accountEmail,
            parentId = archive.parentId,
            onDismiss = { confirm = null },
            onConfirm = { wifi, after ->
                askNotifications()
                vm.extract(archive, wifi, after)
                confirm = null
            },
        )
    }
}

@Composable
private fun ArchiveCard(row: ArchiveRow, onExtract: () -> Unit) {
    val job = row.job
    Panel {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(44.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(VColors.AmberDim)
                        .border(1.dp, VColors.Amber.copy(alpha = 0.4f), RoundedCornerShape(12.dp)),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Rounded.FolderZip, null, tint = VColors.Amber) }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(row.archive.name, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(
                        listOf(Format.bytes(row.archive.sizeBytes), row.archive.relativePath.ifBlank { null }, row.archive.accountEmail)
                            .filterNotNull().joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextMuted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            if (job != null && (job.active || job.state == androidx.work.WorkInfo.State.SUCCEEDED || job.error != null)) {
                TransferCard(ExtractIcon, if (job.active) "Extracting" else "Extraction", job.detail(), job.progress, job.state)
                if (job.error != null) {
                    Spacer(Modifier.height(10.dp))
                    VButton("Try again", onExtract, icon = ExtractIcon, style = ButtonStyle.Secondary)
                }
            } else {
                VButton("Extract to Drive", onExtract, icon = ExtractIcon)
            }
        }
    }
}
