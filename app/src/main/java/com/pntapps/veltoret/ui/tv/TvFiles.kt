package com.pntapps.veltoret.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.InsertDriveFile
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DriveFileRenameOutline
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.FolderZip
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Subtitles
import androidx.compose.material.icons.rounded.VideoFile
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.demo.DemoLibrary
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.data.storage.MediaLibrary
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.components.VImage
import com.pntapps.veltoret.ui.files.FilesViewModel
import com.pntapps.veltoret.ui.fixmatch.FixMatchViewModel
import com.pntapps.veltoret.ui.fixmatch.UnmatchedViewModel
import com.pntapps.veltoret.ui.navigation.FixMatchRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.SettingsRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.rememberOnline

private sealed interface FileAction {
    data class Menu(val file: DriveFile) : FileAction
    data class Rename(val file: DriveFile) : FileAction
    data class Delete(val file: DriveFile) : FileAction
}

private fun isVideo(f: DriveFile) = FilenameParser.isVideo(f.name, f.mimeType) || f.mimeType.startsWith("video/")

@Composable
fun TvFilesScreen(navigator: Navigator) {
    val vm = appViewModel("tv-files") { FilesViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    // The debug demo library has no real files behind it.
    val allAccounts by vm.accounts.collectAsStateWithLifecycle()
    val accounts = allAccounts.filter { it.email != DemoLibrary.EMAIL }
    LaunchedEffect(state.account, accounts.size) {
        if (state.account == DemoLibrary.EMAIL) accounts.firstOrNull()?.let { vm.selectAccount(it.email) }
    }
    val libraryFolders by vm.libraryFolders.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val online = rememberOnline()
    val local = LocalStorage.isLocal(state.account)
    var action by remember { mutableStateOf<FileAction?>(null) }
    val firstItem = remember { FocusRequester() }
    val firstChip = remember { FocusRequester() }

    BackHandler(enabled = state.stack.size > 1) { vm.back() }
    // After an action panel closes, focus returns to the file it was opened for.
    val list = remember { FocusRequester() }
    var opened by remember { mutableStateOf(false) }
    LaunchedEffect(action == null) { if (action != null) opened = true else if (opened) list.focusSoon() }
    LaunchedEffect(state.loading, state.current.id) {
        if (state.loading) return@LaunchedEffect
        (if (state.items.isNotEmpty()) firstItem else firstChip).focusSoon()
    }

    if (accounts.isEmpty()) {
        TvMessage(
            Icons.Rounded.FolderOpen, "Nothing connected yet",
            "Connect a Google account or add videos from this TV in Settings.",
            actionLabel = "Open Settings", onAction = { navigator.selectTab(SettingsRoute) }, actionRequester = firstChip,
        )
        LaunchedEffect(Unit) { firstChip.focusSoon() }
        return
    }

    Column(Modifier.fillMaxSize().padding(top = TvDimens.Top)) {
        Text("Files", style = MaterialTheme.typography.displaySmall, color = VColors.Text, modifier = Modifier.padding(start = TvDimens.Edge))
        Spacer(Modifier.height(12.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = TvDimens.Edge, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            items(accounts, key = { it.email }) { acc ->
                TvChip(
                    if (LocalStorage.isLocal(acc.email)) "This TV" else acc.email,
                    acc.email == state.account,
                    { vm.selectAccount(acc.email) },
                    focusRequester = if (acc.email == state.account) firstChip else null,
                )
            }
        }
        Text(
            state.stack.joinToString("  ›  ") { if (it.id == LocalStorage.ROOT) "This TV" else it.name },
            style = MaterialTheme.typography.titleSmall,
            color = VColors.Amber,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(start = TvDimens.Edge + 6.dp, top = 12.dp, bottom = 8.dp),
        )
        when {
            !local && !online -> TvMessage(Icons.Rounded.CloudOff, "You're offline", "Google Drive needs an internet connection. Videos on this TV still work.")
            state.loading -> Text("Loading…", style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted, modifier = Modifier.padding(start = TvDimens.Edge + 6.dp))
            state.error != null -> Text(state.error!!, style = MaterialTheme.typography.bodyLarge, color = VColors.Danger, modifier = Modifier.padding(start = TvDimens.Edge + 6.dp))
            state.items.isEmpty() -> Text(
                if (local && state.stack.size == 1) "No videos found on this TV or its USB drives yet." else "This folder is empty.",
                style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted, modifier = Modifier.padding(start = TvDimens.Edge + 6.dp),
            )
            else -> LazyColumn(
                Modifier
                    .padding(end = 220.dp)
                    .focusRequester(list)
                    .focusRestorer(),
                contentPadding = PaddingValues(start = TvDimens.Edge - 12.dp, bottom = 80.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                items(state.items, key = { it.id }) { file ->
                    val libType = libraryFolders[file.id]
                    TvListItem(
                        title = file.name,
                        subtitle = listOfNotNull(
                            libType?.let { if (it == LibraryType.MOVIES) "Movies library" else "TV library" },
                            if (file.isFolder) null else Format.bytes(file.sizeBytes),
                            Format.driveDate(file.modifiedTime),
                        ).joinToString(" · ").ifBlank { null },
                        leading = when {
                            file.isFolder -> Icons.Rounded.Folder
                            isVideo(file) -> Icons.Rounded.VideoFile
                            FilenameParser.isSubtitle(file.name) -> Icons.Rounded.Subtitles
                            FilenameParser.isArchive(file.name) -> Icons.Rounded.FolderZip
                            else -> Icons.AutoMirrored.Rounded.InsertDriveFile
                        },
                        onClick = {
                            when {
                                file.isFolder -> vm.open(file)
                                isVideo(file) -> context.playFile(file.id, state.account, title = file.name)
                                else -> action = FileAction.Menu(file)
                            }
                        },
                        onLongClick = { action = FileAction.Menu(file) },
                        focusRequester = if (file == state.items.first()) firstItem else null,
                    )
                }
            }
        }
    }

    when (val a = action) {
        is FileAction.Menu -> {
            val f = a.file
            val readOnly = MediaLibrary.isMediaLibraryId(f.id)
            TvActionsDialog(
                title = f.name,
                onDismiss = { action = null },
                actions = buildList {
                    if (isVideo(f)) add(TvAction("Play", Icons.Rounded.PlayArrow) { context.playFile(f.id, state.account, title = f.name) })
                    if (f.isFolder) {
                        add(TvAction("Open", Icons.Rounded.FolderOpen) { vm.open(f) })
                        if (libraryFolders[f.id] == null) {
                            add(TvAction("Use as Movies library", Icons.Rounded.Movie) { vm.setLibrary(f, LibraryType.MOVIES) })
                            add(TvAction("Use as TV library", Icons.Rounded.LiveTv) { vm.setLibrary(f, LibraryType.SHOWS) })
                        }
                    }
                    if (!readOnly && f.capabilities?.canRename != false) add(TvAction("Rename", Icons.Rounded.DriveFileRenameOutline) { action = FileAction.Rename(f) })
                    if (!readOnly && f.capabilities?.canTrash != false) add(
                        TvAction(if (local) "Delete" else "Move to trash", Icons.Rounded.Delete, detail = if (local) "Deleted permanently from this device" else "Restorable from Drive for 30 days") {
                            action = FileAction.Delete(f)
                        }
                    )
                },
            )
        }
        is FileAction.Rename -> TvTextDialog(
            title = "Rename", initial = a.file.name, confirm = "Rename",
            onDismiss = { action = null }, onConfirm = { vm.rename(a.file, it) },
        )
        is FileAction.Delete -> TvConfirmDialog(
            title = if (local) "Delete permanently?" else "Move to trash?",
            message = if (local) "\"${a.file.name}\" will be deleted from this device. This can't be undone."
            else "\"${a.file.name}\" will be moved to Google Drive's trash.",
            confirm = if (local) "Delete" else "Move to trash",
            onConfirm = { vm.trash(listOf(a.file.id)) },
            onDismiss = { action = null },
        )
        null -> Unit
    }
}

// ---------------------------------------------------------------------------------------------
// Unmatched files and Fix match
// ---------------------------------------------------------------------------------------------

@Composable
fun TvUnmatchedScreen(navigator: Navigator) {
    val vm = appViewModel("tv-unmatched") { UnmatchedViewModel(it) }
    val groups by vm.groups.collectAsStateWithLifecycle()
    val ignored by vm.ignored.collectAsStateWithLifecycle()
    val first = remember { FocusRequester() }
    LaunchedEffect(groups?.size, ignored.size) { first.focusSoon() }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = TvDimens.Edge, end = 220.dp, top = TvDimens.Top, bottom = 80.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        item {
            Text("Needs a match", style = MaterialTheme.typography.displaySmall, color = VColors.Text)
            Text(
                "OK to search TMDB · hold OK to ignore files that aren't movies or shows",
                style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted,
                modifier = Modifier.padding(top = 6.dp, bottom = 16.dp),
            )
        }
        val list = groups.orEmpty()
        if (list.isEmpty()) item { Text("Everything is matched.", style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted) }
        items(list, key = { "u-" + it.kind.name + it.title }) { g ->
            TvListItem(
                title = g.title,
                subtitle = "${if (g.kind == MediaKind.MOVIE) "Movie" else "TV"} · ${g.files.size} file${if (g.files.size == 1) "" else "s"} · ${g.files.first().name}",
                leading = if (g.kind == MediaKind.MOVIE) Icons.Rounded.Movie else Icons.Rounded.LiveTv,
                onClick = { navigator.navigate(FixMatchRoute(g.files.map { it.driveId }, g.kind.name, g.title)) },
                onLongClick = { vm.ignore(g) },
                focusRequester = if (g == list.first()) first else null,
            )
        }
        if (ignored.isNotEmpty()) {
            item { Text("IGNORED", style = MaterialTheme.typography.labelLarge, color = VColors.Amber, modifier = Modifier.padding(start = 18.dp, top = 24.dp, bottom = 8.dp)) }
            items(ignored, key = { "i-" + it.kind.name + it.title }) { g ->
                TvListItem(
                    title = g.title,
                    subtitle = "OK to restore",
                    leading = Icons.Rounded.VisibilityOff,
                    onClick = { vm.restore(g) },
                    focusRequester = if (list.isEmpty() && g == ignored.first()) first else null,
                )
            }
        }
    }
}

@Composable
fun TvFixMatchScreen(route: FixMatchRoute, navigator: Navigator) {
    val vm = appViewModel("tv-fix-${route.fileIds.hashCode()}") { FixMatchViewModel(it, route) }
    val state by vm.state.collectAsStateWithLifecycle()
    var editing by remember { mutableStateOf(false) }
    val searchButton = remember { FocusRequester() }
    val firstResult = remember { FocusRequester() }
    LaunchedEffect(state.done) { if (state.done) navigator.back() }
    LaunchedEffect(state.searching, state.results.size) {
        if (state.searching) return@LaunchedEffect
        (if (state.results.isNotEmpty()) firstResult else searchButton).focusSoon()
    }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = TvDimens.Edge, end = 160.dp, top = TvDimens.Top, bottom = 80.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        item {
            Text("Fix match", style = MaterialTheme.typography.displaySmall, color = VColors.Text)
            Text("${route.fileIds.size} file${if (route.fileIds.size == 1) "" else "s"}", style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                TvChip("Movie", state.kind == MediaKind.MOVIE, { vm.setKind(MediaKind.MOVIE) })
                TvChip("TV Show", state.kind == MediaKind.EPISODE, { vm.setKind(MediaKind.EPISODE) })
                Spacer(Modifier.width(8.dp))
                TvButton("Search: ${state.query}", { editing = true }, focusRequester = searchButton)
                TvButton("Ignore", vm::ignore, icon = Icons.Rounded.Visibility)
            }
            state.error?.let { Text(it, color = VColors.Danger, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(top = 12.dp)) }
            if (!state.searching && state.results.isEmpty() && state.error == null) {
                Text("No results. Try a shorter title, or switch between Movie and TV Show.", style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted, modifier = Modifier.padding(top = 16.dp))
            }
            Spacer(Modifier.height(12.dp))
        }
        items(state.results, key = { it.id }) { c ->
            TvSurface(
                onClick = { vm.apply(c) },
                shape = RoundedCornerShape(12.dp),
                color = androidx.compose.ui.graphics.Color.Transparent,
                focusedColor = VColors.SurfaceHigh,
                focusedScale = 1.02f,
                focusRequester = if (c == state.results.first()) firstResult else null,
                modifier = Modifier.padding(vertical = 2.dp),
            ) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    VImage(c.posterUrl, c.title, Modifier.width(56.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(8.dp)), fallbackText = c.title.take(1))
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(c.title, style = MaterialTheme.typography.titleMedium, color = VColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        c.year?.let { Text(it.toString(), style = MaterialTheme.typography.bodySmall, color = VColors.Amber) }
                        Text(c.overview, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    if (state.applyingId == c.id) Text("Applying…", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
                }
            }
        }
    }

    if (editing) {
        TvTextDialog(
            title = "Search TMDB", label = "Title (add a year to narrow)", initial = state.query, confirm = "Search",
            onDismiss = { editing = false },
            onConfirm = { vm.setQuery(it); vm.search() },
        )
    }
}
