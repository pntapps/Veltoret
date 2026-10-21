package com.pntapps.veltoret.ui.files

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.DriveFileMove
import androidx.compose.material.icons.automirrored.rounded.InsertDriveFile
import androidx.compose.material.icons.automirrored.rounded.Sort
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.FolderOff
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DeleteForever
import androidx.compose.material.icons.rounded.DriveFileRenameOutline
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.FolderZip
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Subtitles
import androidx.compose.material.icons.rounded.VideoFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.work.WorkInfo
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.ui.util.rememberOnline
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.EmptyState
import com.pntapps.veltoret.ui.components.LoadingBox
import com.pntapps.veltoret.ui.components.Pill
import com.pntapps.veltoret.ui.components.SelectChip
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VProgress
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.SettingsRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.gutter

private sealed interface FileDialog {
    data class Rename(val file: DriveFile) : FileDialog
    data class Trash(val ids: Set<String>, val label: String) : FileDialog
    /** Drive only: skips the trash. */
    data class DeleteForever(val ids: Set<String>, val label: String, val hasFolder: Boolean) : FileDialog
    data class Move(val ids: Set<String>) : FileDialog
    data class Details(val file: DriveFile) : FileDialog
    data object NewFolder : FileDialog
    data class Extract(val file: DriveFile) : FileDialog
    data class AddToLibrary(val folder: DriveFile) : FileDialog
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FilesScreen(navigator: Navigator) {
    val vm = appViewModel { FilesViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val libraryFolders by vm.libraryFolders.collectAsStateWithLifecycle()
    val uploads by vm.uploads.collectAsStateWithLifecycle()
    val extractJobs by vm.extractions.collectAsStateWithLifecycle()
    val askNotifications = rememberNotificationPermission()
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    var dialog by remember { mutableStateOf<FileDialog?>(null) }
    var accountMenu by remember { mutableStateOf(false) }
    var sortMenu by remember { mutableStateOf(false) }
    var addMenu by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val local = LocalStorage.isLocal(state.account)
    val smb = SmbPath.isSmb(state.account)
    val drive = !local && !smb
    // Device and network-share deletes are permanent; only Drive has a trash.
    val permanent = local || smb
    val serverName = accounts.firstOrNull { it.email == state.account }?.displayName
    val online = rememberOnline()
    val driveOffline = !local && !online
    val pickDeviceFolder = rememberLocalFolderPicker { uri ->
        scope.launch { vm.adoptDeviceFolder(uri)?.let { dialog = FileDialog.AddToLibrary(it) } }
    }

    LaunchedEffect(Unit) { vm.messages.collect { snackbar.showSnackbar(it) } }
    // Back online: reload the Drive folder that couldn't load while offline.
    var wasOffline by remember { mutableStateOf(false) }
    LaunchedEffect(online) {
        if (online && wasOffline && !local) vm.load(refresh = true)
        wasOffline = !online
    }
    BackHandler(enabled = state.selecting || state.searchQuery != null || state.stack.size > 1) { vm.back() }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) {
            askNotifications()
            vm.upload(uris)
        }
    }

    if (accounts.isEmpty()) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars)) {
            EmptyState(
                Icons.Rounded.FolderOpen, "Nothing connected yet",
                "Add a folder from your phone storage, SD card or USB drive. To browse Google Drive, connect an account in Settings.",
                actionLabel = "Add a folder from this device", onAction = pickDeviceFolder,
            )
        }
        return
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            // Header: either the selection bar or title + account switcher.
            Row(
                Modifier
                    .fillMaxWidth()
                    .windowInsetsPadding(WindowInsets.statusBars)
                    .padding(start = gutter(), end = 12.dp, top = 12.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (state.selecting) {
                    VIconButton(Icons.Rounded.Close, "Cancel selection", vm::clearSelection)
                    Spacer(Modifier.width(12.dp))
                    Text("${state.selection.size} selected", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
                    VIconButton(Icons.AutoMirrored.Rounded.DriveFileMove, "Move", { dialog = FileDialog.Move(state.selection) })
                    Spacer(Modifier.width(8.dp))
                    VIconButton(Icons.Rounded.Delete, if (permanent) "Delete" else "Move to trash", {
                        dialog = FileDialog.Trash(state.selection, "${state.selection.size} items")
                    }, tint = VColors.Danger)
                    // Only the owner can skip Drive's trash, so offer it when every selected item allows it.
                    val selected = state.items.filter { it.id in state.selection }
                    if (drive && selected.isNotEmpty() && selected.all { it.capabilities?.canDelete == true }) {
                        Spacer(Modifier.width(8.dp))
                        VIconButton(Icons.Rounded.DeleteForever, "Delete permanently", {
                            dialog = FileDialog.DeleteForever(state.selection, "${state.selection.size} items", selected.any { it.isFolder })
                        }, tint = VColors.Danger)
                    }
                } else {
                    Column(Modifier.weight(1f)) {
                        Text("Files", style = MaterialTheme.typography.headlineLarge)
                        Box {
                            Text(
                                (if (local) LocalStorage.DISPLAY_NAME else if (smb) serverName ?: "" else state.account ?: "") + "  ▾",
                                style = MaterialTheme.typography.bodySmall,
                                color = VColors.TextMuted,
                                maxLines = 1,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .combinedClickable(onClick = { accountMenu = true })
                                    .padding(vertical = 2.dp),
                            )
                            DropdownMenu(accountMenu, { accountMenu = false }, containerColor = VColors.SurfaceHigh) {
                                accounts.forEach { acc ->
                                    DropdownMenuItem(
                                        text = {
                                            Column {
                                                Text(acc.displayName)
                                                Text(accountSubtitle(acc), style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                                            }
                                        },
                                        leadingIcon = { AccountAvatar(acc) },
                                        trailingIcon = if (acc.email == state.account) {
                                            { Icon(Icons.Rounded.CheckCircle, null, tint = VColors.Amber) }
                                        } else null,
                                        onClick = { accountMenu = false; vm.selectAccount(acc.email) },
                                    )
                                }
                                if (accounts.none { LocalStorage.isLocal(it.email) }) {
                                    DropdownMenuItem(
                                        text = { Text("Files on this device") },
                                        leadingIcon = { Icon(Icons.Rounded.PhoneAndroid, null, tint = VColors.AmberSoft) },
                                        onClick = { accountMenu = false; vm.useDevice() },
                                    )
                                }
                            }
                        }
                    }
                    VIconButton(Icons.Rounded.Search, if (drive) "Search Drive" else "Search this folder", { vm.setSearch(if (state.searchQuery == null) "" else null) })
                    Spacer(Modifier.width(8.dp))
                    Box {
                        VIconButton(Icons.AutoMirrored.Rounded.Sort, "Sort", { sortMenu = true })
                        DropdownMenu(sortMenu, { sortMenu = false }, containerColor = VColors.SurfaceHigh) {
                            FileSort.entries.forEach { s ->
                                DropdownMenuItem(
                                    text = { Text(s.label, color = if (s == state.sort) VColors.Amber else VColors.Text) },
                                    onClick = { vm.setSort(s); sortMenu = false },
                                )
                            }
                        }
                    }
                }
            }

            if (state.searchQuery != null) {
                VTextField(
                    value = state.searchQuery.orEmpty(),
                    onValueChange = vm::setSearch,
                    label = if (drive) "Search this Drive" else "Search this folder",
                    leadingIcon = Icons.Rounded.Search,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = gutter(), vertical = 4.dp)
                        .widthIn(max = 720.dp),
                )
            } else {
                if (drive && !driveOffline) Row(Modifier.padding(horizontal = gutter()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SelectChip("My Drive", !state.sharedRoot, { vm.setSharedRoot(false) })
                    SelectChip("Shared with me", state.sharedRoot, { vm.setSharedRoot(true) })
                }
                if (!driveOffline) Breadcrumbs(state.stack, horizontalPadding = gutter() - 6.dp) { vm.goTo(it) }
                state.space?.takeIf { !driveOffline }?.let {
                    StorageSummary(
                        it, MaterialTheme.typography.bodySmall,
                        Modifier.padding(start = gutter(), end = gutter(), top = 2.dp, bottom = 8.dp).widthIn(max = 480.dp),
                    )
                }
            }

            PullToRefreshBox(
                isRefreshing = state.refreshing,
                onRefresh = { vm.load(refresh = true) },
                modifier = Modifier.weight(1f),
            ) {
                when {
                    driveOffline -> EmptyState(
                        Icons.Rounded.CloudOff, "You're offline",
                        if (smb) "Network servers need this device to be on their network. Folders on this device still work."
                        else "Google Drive needs an internet connection. Folders on this device still work.",
                        actionLabel = "Show this device", onAction = vm::useDevice,
                    )
                    state.loading -> LoadingBox()
                    state.error != null -> EmptyState(
                        if (local) Icons.Rounded.FolderOff else Icons.Rounded.CloudOff,
                        when {
                            local -> "Couldn't open this folder"
                            smb -> "Couldn't reach ${serverName ?: "the server"}"
                            else -> "Couldn't reach Drive"
                        },
                        state.error!!, actionLabel = "Retry", onAction = { vm.load() },
                    )
                    state.items.isEmpty() && local && state.stack.size == 1 -> EmptyState(
                        Icons.Rounded.PhoneAndroid, "No folders yet",
                        "Pick a folder on your phone storage, SD card or USB drive. Veltoret only sees the folders you choose.",
                        actionLabel = "Add a folder", onAction = pickDeviceFolder,
                    )
                    state.items.isEmpty() -> EmptyState(
                        Icons.Rounded.FolderOpen, "This folder is empty",
                        if (drive) "Upload files or create a folder with the + button." else "Create a folder with the + button.",
                    )
                    // One column on phones; several columns of rows on tablets.
                    else -> LazyVerticalGrid(
                        columns = GridCells.Adaptive(360.dp),
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(start = gutter() - 20.dp, end = gutter() - 20.dp, bottom = 120.dp),
                    ) {
                        items(state.items, key = { it.id }) { file ->
                            FileListRow(
                                file = file,
                                selected = file.id in state.selection,
                                selecting = state.selecting,
                                libraryType = libraryFolders[file.id],
                                local = permanent,
                                // Device roots are granted folders and a server's root lists its shares: neither can move.
                                movable = !(permanent && state.stack.size == 1),
                                onClick = {
                                    when {
                                        state.selecting -> vm.toggleSelection(file.id)
                                        file.isFolder -> vm.open(file)
                                        isVideo(file) -> context.playFile(file.id, state.account, title = file.name)
                                        FilenameParser.isArchive(file.name) && drive -> dialog = FileDialog.Extract(file)
                                        else -> dialog = FileDialog.Details(file)
                                    }
                                },
                                onLongClick = { vm.toggleSelection(file.id) },
                                onRename = { dialog = FileDialog.Rename(file) },
                                onMove = { dialog = FileDialog.Move(setOf(file.id)) },
                                onTrash = { dialog = FileDialog.Trash(setOf(file.id), file.name) },
                                onDeleteForever = if (drive && file.capabilities?.canDelete == true) {
                                    { dialog = FileDialog.DeleteForever(setOf(file.id), file.name, file.isFolder) }
                                } else null,
                                onDetails = { dialog = FileDialog.Details(file) },
                                onExtract = { dialog = FileDialog.Extract(file) },
                                onPlay = { context.playFile(file.id, state.account, title = file.name) },
                                onSetLibrary = { type -> vm.setLibrary(file, type) },
                            )
                        }
                    }
                }
            }
        }

        // Upload progress + add button.
        Column(
            Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp),
            horizontalAlignment = Alignment.End,
        ) {
            // Transfers: running extractions and uploads (recent failures stay visible too).
            extractJobs.filter { it.active || it.error != null }.take(2).forEach { job ->
                TransferCard(ExtractIcon, job.name, job.detail(), job.progress, job.state, Modifier.padding(bottom = 10.dp).width(300.dp))
            }
            uploads.take(3).forEach { up ->
                TransferCard(UploadIcon, up.name, null, up.progress, up.state, Modifier.padding(bottom = 10.dp).width(300.dp))
            }
            if (!state.selecting && !state.atSharedRoot && !driveOffline && !(smb && state.stack.size == 1)) {
                Box {
                    Box(
                        Modifier
                            .size(58.dp)
                            .clip(RoundedCornerShape(18.dp))
                            .background(VColors.Amber)
                            .combinedClickable(onClick = { addMenu = true }),
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Rounded.Add, "Add", tint = VColors.OnAmber, modifier = Modifier.size(28.dp)) }
                    DropdownMenu(addMenu, { addMenu = false }, containerColor = VColors.SurfaceHigh) {
                        if (local && state.stack.size == 1) {
                            DropdownMenuItem(
                                text = { Text("Add a folder from this device") },
                                leadingIcon = { Icon(Icons.Rounded.PhoneAndroid, null) },
                                onClick = { addMenu = false; pickDeviceFolder() },
                            )
                        } else {
                            DropdownMenuItem(
                                text = { Text("New folder") },
                                leadingIcon = { Icon(Icons.Rounded.CreateNewFolder, null) },
                                onClick = { addMenu = false; dialog = FileDialog.NewFolder },
                            )
                        }
                        if (drive) DropdownMenuItem(
                            text = { Text("Upload files") },
                            leadingIcon = { Icon(Icons.Rounded.CloudUpload, null) },
                            onClick = { addMenu = false; picker.launch(arrayOf("*/*")) },
                        )
                    }
                }
            }
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = 90.dp))
    }

    when (val d = dialog) {
        is FileDialog.Rename -> TextInputDialog(
            title = "Rename", initial = d.file.name, confirm = "Rename",
            selectBase = !d.file.isFolder,
            onDismiss = { dialog = null },
            onConfirm = { vm.rename(d.file, it); dialog = null },
        )
        FileDialog.NewFolder -> TextInputDialog(
            title = "New folder", initial = "", confirm = "Create",
            onDismiss = { dialog = null },
            onConfirm = { vm.createFolder(it); dialog = null },
        )
        is FileDialog.Trash -> AlertDialog(
            onDismissRequest = { dialog = null },
            containerColor = VColors.SurfaceHigh,
            title = { Text(if (permanent) "Delete permanently?" else "Move to trash?") },
            text = {
                Text(
                    when {
                        local -> "\"${d.label}\" will be deleted permanently from this device. This can't be undone."
                        smb -> "\"${d.label}\" will be deleted permanently from ${serverName ?: "the server"}. Network shares have no trash, so this can't be undone."
                        else -> "\"${d.label}\" will be moved to Google Drive's trash. You can restore it from Drive for 30 days."
                    }
                )
            },
            confirmButton = {
                TextButton({ vm.trash(d.ids); dialog = null }) { Text(if (permanent) "Delete" else "Move to trash", color = VColors.Danger) }
            },
            dismissButton = { TextButton({ dialog = null }) { Text("Cancel", color = VColors.Text) } },
        )
        is FileDialog.DeleteForever -> AlertDialog(
            onDismissRequest = { dialog = null },
            containerColor = VColors.SurfaceHigh,
            title = { Text("Delete permanently?") },
            text = {
                Text(
                    "\"${d.label}\"" + (if (d.hasFolder) " and everything in it" else "") +
                        " will be deleted from Google Drive right away. It won't go to the trash, so this can't be undone."
                )
            },
            confirmButton = {
                TextButton({ vm.deletePermanently(d.ids); dialog = null }) { Text("Delete", color = VColors.Danger) }
            },
            dismissButton = { TextButton({ dialog = null }) { Text("Cancel", color = VColors.Text) } },
        )
        is FileDialog.Move -> DriveFolderPicker(
            email = state.account ?: return,
            title = "Move to",
            disabledIds = d.ids,
            actions = listOf(PickerAction("Move here") { target -> vm.move(d.ids, target); dialog = null }),
            onDismiss = { dialog = null },
        )
        is FileDialog.Extract -> ExtractDialog(
            name = d.file.name,
            sizeBytes = d.file.sizeBytes,
            account = state.account ?: return,
            parentId = d.file.parents.firstOrNull() ?: state.current.id,
            onDismiss = { dialog = null },
            onConfirm = { wifi, after ->
                askNotifications()
                vm.extract(d.file, wifi, after)
                dialog = null
            },
        )
        is FileDialog.Details -> AlertDialog(
            onDismissRequest = { dialog = null },
            containerColor = VColors.SurfaceHigh,
            title = { Text(d.file.name, maxLines = 3, overflow = TextOverflow.Ellipsis) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    DetailLine("Type", d.file.mimeType)
                    if (!d.file.isFolder) DetailLine("Size", Format.bytes(d.file.sizeBytes))
                    DetailLine("Modified", Format.driveDate(d.file.modifiedTime) ?: "—")
                    d.file.videoMediaMetadata?.let { m ->
                        if (m.width != null && m.height != null) DetailLine("Resolution", "${m.width} × ${m.height}")
                        m.durationMillis?.toLongOrNull()?.let { DetailLine("Duration", Format.clock(it)) }
                    }
                }
            },
            confirmButton = { TextButton({ dialog = null }) { Text("Close", color = VColors.Amber) } },
        )
        is FileDialog.AddToLibrary -> LibraryTypeDialog(d.folder.name, { dialog = null }) { type ->
            vm.setLibrary(d.folder, type)
            dialog = null
        }
        null -> Unit
    }
}

private fun isVideo(file: DriveFile) = FilenameParser.isVideo(file.name, file.mimeType) || file.mimeType.startsWith("video/")

private fun iconFor(file: DriveFile): Pair<ImageVector, androidx.compose.ui.graphics.Color> = when {
    file.isFolder -> Icons.Rounded.Folder to VColors.Amber
    isVideo(file) -> Icons.Rounded.VideoFile to VColors.Text
    FilenameParser.isSubtitle(file.name) -> Icons.Rounded.Subtitles to VColors.TextMuted
    FilenameParser.isArchive(file.name) -> Icons.Rounded.FolderZip to VColors.AmberSoft
    file.mimeType.startsWith("image/") -> Icons.Rounded.Image to VColors.TextMuted
    else -> Icons.AutoMirrored.Rounded.InsertDriveFile to VColors.TextMuted
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FileListRow(
    file: DriveFile,
    selected: Boolean,
    selecting: Boolean,
    libraryType: LibraryType?,
    local: Boolean,
    movable: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onRename: () -> Unit,
    onMove: () -> Unit,
    onTrash: () -> Unit,
    /** Drive files the user owns; null hides "Delete permanently". */
    onDeleteForever: (() -> Unit)?,
    onDetails: () -> Unit,
    onExtract: () -> Unit,
    onPlay: () -> Unit,
    onSetLibrary: (LibraryType) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val (icon, tint) = iconFor(file)
    Row(
        Modifier
            .fillMaxWidth()
            .background(if (selected) VColors.AmberDim else MaterialTheme.colorScheme.background)
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(start = 20.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(VColors.Surface)
                .border(1.dp, if (selected) VColors.Amber else VColors.Outline, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(if (selected) Icons.Rounded.CheckCircle else icon, null, tint = if (selected) VColors.Amber else tint, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(file.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (libraryType != null) {
                    Pill(if (libraryType == LibraryType.MOVIES) "Movies library" else "TV library", Modifier.padding(end = 6.dp, top = 2.dp), accent = true)
                }
                Text(
                    listOfNotNull(if (file.isFolder) null else Format.bytes(file.sizeBytes), Format.driveDate(file.modifiedTime)).joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = VColors.TextMuted,
                )
            }
        }
        if (!selecting) {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "More", tint = VColors.TextMuted) }
                DropdownMenu(menu, { menu = false }, containerColor = VColors.SurfaceHigh) {
                    if (isVideo(file)) MenuItem("Play", Icons.Rounded.PlayArrow) { menu = false; onPlay() }
                    if (file.isFolder && libraryType == null) {
                        MenuItem("Use as Movies library", Icons.Rounded.Movie) { menu = false; onSetLibrary(LibraryType.MOVIES) }
                        MenuItem("Use as TV library", Icons.Rounded.LiveTv) { menu = false; onSetLibrary(LibraryType.SHOWS) }
                    }
                    if (file.capabilities?.canRename != false) MenuItem("Rename", Icons.Rounded.DriveFileRenameOutline) { menu = false; onRename() }
                    if (movable) MenuItem("Move", Icons.AutoMirrored.Rounded.DriveFileMove) { menu = false; onMove() }
                    if (FilenameParser.isArchive(file.name) && !local) {
                        MenuItem("Extract to Drive", ExtractIcon) { menu = false; onExtract() }
                    }
                    MenuItem("Details", Icons.Rounded.Info) { menu = false; onDetails() }
                    if (file.capabilities?.canTrash != false && movable) {
                        MenuItem(if (local) "Delete" else "Move to trash", Icons.Rounded.Delete, VColors.Danger) { menu = false; onTrash() }
                    }
                    if (onDeleteForever != null && movable) {
                        MenuItem("Delete permanently", Icons.Rounded.DeleteForever, VColors.Danger) { menu = false; onDeleteForever() }
                    }
                }
            }
        }
    }
}

@Composable
private fun MenuItem(label: String, icon: ImageVector, color: androidx.compose.ui.graphics.Color = VColors.Text, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label, color = color) },
        leadingIcon = { Icon(icon, null, tint = color) },
        onClick = onClick,
    )
}

@Composable
fun Avatar(name: String, size: androidx.compose.ui.unit.Dp = 32.dp) {
    Box(
        Modifier
            .size(size)
            .clip(CircleShape)
            .background(VColors.AmberDim),
        contentAlignment = Alignment.Center,
    ) {
        Text(name.firstOrNull()?.uppercase() ?: "?", style = MaterialTheme.typography.labelLarge, color = VColors.AmberSoft)
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row {
        Text(label, style = MaterialTheme.typography.labelLarge, color = VColors.TextMuted, modifier = Modifier.width(90.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
fun TextInputDialog(
    title: String,
    initial: String,
    confirm: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
    selectBase: Boolean = false,
) {
    var value by remember {
        val end = if (selectBase && '.' in initial) initial.lastIndexOf('.') else initial.length
        mutableStateOf(androidx.compose.ui.text.input.TextFieldValue(initial, androidx.compose.ui.text.TextRange(0, end)))
    }
    val focus = remember { androidx.compose.ui.focus.FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = VColors.SurfaceHigh,
        title = { Text(title) },
        text = {
            androidx.compose.material3.OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = VColors.Amber, cursorColor = VColors.Amber, unfocusedBorderColor = VColors.Outline,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focus),
            )
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(value.text) }, enabled = value.text.isNotBlank()) { Text(confirm, color = VColors.Amber) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = VColors.Text) } },
    )
}
