package com.pntapps.veltoret.ui.files

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.FolderOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.drive.DriveRepository
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.EmptyState
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.SelectChip
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.container

data class Crumb(val id: String, val name: String)

class PickerAction(val label: String, val style: ButtonStyle = ButtonStyle.Primary, val onPick: (Crumb) -> Unit)

/**
 * Full-screen Drive folder browser. Used to choose library folders and as the "Move to" target.
 * [disabledIds] are folders that may not be picked or entered (e.g. the items being moved).
 */
@Composable
fun DriveFolderPicker(
    email: String,
    title: String,
    actions: List<PickerAction>,
    onDismiss: () -> Unit,
    disabledIds: Set<String> = emptySet(),
) {
    val container = LocalContext.current.container
    val drive = container.driveRepository
    val storage = container.storage
    val local = storage.isLocal(email)
    var sharedRoot by remember { mutableStateOf(false) }
    val stack: SnapshotStateList<Crumb> = remember { listOf(Crumb(storage.rootId(email), storage.rootName(email))).toMutableStateList() }
    var folders by remember { mutableStateOf<List<DriveFile>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val current = stack.last()

    LaunchedEffect(current.id, sharedRoot) {
        folders = null
        error = null
        folders = try {
            val items = if (sharedRoot && stack.size == 1) drive.listSharedWithMe(email) else storage.list(email, current.id)
            items.filter { it.isFolder }
        } catch (e: Exception) {
            error = e.message
            emptyList()
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
        ) {
            ScreenHeader(title, subtitle = if (local) storage.rootName(email) else email) {
                VIconButton(Icons.Rounded.Close, "Close", onDismiss)
            }
            if (!local) Row(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SelectChip("My Drive", !sharedRoot, {
                    sharedRoot = false
                    stack.clear(); stack.add(Crumb(DriveRepository.ROOT, "My Drive"))
                })
                SelectChip("Shared with me", sharedRoot, {
                    sharedRoot = true
                    stack.clear(); stack.add(Crumb("shared", "Shared with me"))
                })
            }
            Breadcrumbs(stack) { index -> while (stack.size > index + 1) stack.removeAt(stack.lastIndex) }
            Box(Modifier.weight(1f)) {
                val list = folders
                when {
                    list == null -> LoadingBox()
                    error != null -> EmptyState(Icons.Rounded.FolderOff, "Couldn't load folders", error!!)
                    list.isEmpty() -> EmptyState(Icons.Rounded.Folder, "No subfolders", "You can pick this folder, or go back up.")
                    else -> LazyColumn(
                        Modifier
                            .align(Alignment.TopCenter)
                            .widthIn(max = 840.dp),
                        contentPadding = PaddingValues(vertical = 4.dp),
                    ) {
                        items(list, key = { it.id }) { folder ->
                            val disabled = folder.id in disabledIds
                            Row(
                                Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = !disabled) { stack.add(Crumb(folder.id, folder.name)) }
                                    .padding(horizontal = 20.dp, vertical = 14.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Rounded.Folder, null, tint = if (disabled) VColors.TextFaint else VColors.Amber)
                                Spacer(Modifier.width(16.dp))
                                Text(
                                    folder.name,
                                    style = MaterialTheme.typography.bodyLarge,
                                    color = if (disabled) VColors.TextFaint else VColors.Text,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = VColors.TextFaint)
                            }
                        }
                    }
                }
            }
            // The device root is only a list of granted folders; nothing can go there.
            val pickable = !(sharedRoot && stack.size == 1) && !(local && stack.size == 1) && current.id !in disabledIds
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(VColors.Surface)
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(16.dp),
            ) {
                Text(
                    "Current folder: ${current.name}",
                    style = MaterialTheme.typography.bodySmall,
                    color = VColors.TextMuted,
                    modifier = Modifier.padding(bottom = 10.dp),
                )
                Row(Modifier.widthIn(max = 720.dp).align(Alignment.CenterHorizontally), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    actions.forEach { action ->
                        VButton(
                            action.label,
                            { action.onPick(current) },
                            style = action.style,
                            enabled = pickable,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun Breadcrumbs(stack: List<Crumb>, horizontalPadding: Dp = 14.dp, onSelect: (Int) -> Unit) {
    LazyRow(
        // Crumbs carry 6dp of their own padding, so this lines their text up with the page margin.
        contentPadding = PaddingValues(horizontal = horizontalPadding, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        itemsIndexed(stack, key = { i, c -> "$i-${c.id}" }) { index, crumb ->
            if (index > 0) Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = VColors.TextFaint, modifier = Modifier.size(18.dp))
            val last = index == stack.lastIndex
            Text(
                crumb.name,
                style = MaterialTheme.typography.labelLarge,
                color = if (last) VColors.Amber else VColors.TextMuted,
                maxLines = 1,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(enabled = !last) { onSelect(index) }
                    .padding(horizontal = 6.dp, vertical = 4.dp),
            )
        }
    }
}

