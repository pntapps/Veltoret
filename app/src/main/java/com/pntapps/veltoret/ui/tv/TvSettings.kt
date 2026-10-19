package com.pntapps.veltoret.ui.tv

import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.PrivacyTip
import com.pntapps.veltoret.ui.components.Developer
import com.pntapps.veltoret.ui.components.TmdbAttribution
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.BuildConfig
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.storage.LocalStorage
import androidx.compose.material.icons.rounded.Dns
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.ui.accounts.rememberAccountConnector
import com.pntapps.veltoret.ui.files.Crumb
import com.pntapps.veltoret.ui.files.rememberLocalFolderPicker
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.UnmatchedRoute
import com.pntapps.veltoret.ui.settings.LANGUAGES
import com.pntapps.veltoret.ui.settings.ScanText
import com.pntapps.veltoret.ui.settings.SettingsViewModel
import com.pntapps.veltoret.ui.settings.languageLabel
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.container
import kotlinx.coroutines.launch

private sealed interface SettingsDialog {
    data class AccountActions(val account: AccountEntity) : SettingsDialog
    data class FolderActions(val folder: LibraryFolderEntity) : SettingsDialog
    data class Pick(val email: String, val startAt: List<Crumb> = emptyList()) : SettingsDialog
    data object AddServer : SettingsDialog
    data class TypeFor(val folder: DriveFile) : SettingsDialog
    data object Skip : SettingsDialog
    data object Seek : SettingsDialog
    data object Audio : SettingsDialog
    data object Subs : SettingsDialog
    data object SubSize : SettingsDialog
    data object TmdbKey : SettingsDialog
    data class Message(val text: String) : SettingsDialog
}

@Composable
fun TvSettingsScreen(navigator: Navigator) {
    val vm = appViewModel("tv-settings") { SettingsViewModel(it) }
    val settings by vm.settings.collectAsStateWithLifecycle()
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val folders by vm.folders.collectAsStateWithLifecycle()
    val scan by vm.scan.collectAsStateWithLifecycle()
    val unmatched by vm.unmatched.collectAsStateWithLifecycle()
    val folderCounts by vm.folderCounts.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var dialog by remember { mutableStateOf<SettingsDialog?>(null) }
    val first = remember { FocusRequester() }
    // Accounts load a moment after the screen appears; until then "first" sits on "Add Google account", so
    // focus again once they arrive.
    LaunchedEffect(accounts.isEmpty()) { first.focusSoon() }

    val connector = rememberAccountConnector(
        onConnected = { dialog = SettingsDialog.Message("Connected ${it.email}. Add its library folders below.") },
        onError = { dialog = SettingsDialog.Message("${it.title}. ${it.message}") },
    )
    val deviceSource = rememberTvDeviceSource(
        onReady = { dialog = SettingsDialog.Pick(LocalStorage.ACCOUNT) },
        onPicked = { dialog = SettingsDialog.TypeFor(it) },
        onDenied = { dialog = SettingsDialog.Message("Veltoret needs access to the TV's videos to show them. You can allow it in the TV's Settings → Apps → Veltoret → Permissions.") },
    )
    val hasDevice = accounts.any { LocalStorage.isLocal(it.email) }

    // After a panel or picker closes, focus goes back to the row that opened it (TvFocusMemory); the
    // list is the fallback when that row is gone.
    val list = remember { FocusRequester() }
    val focusMemory = LocalTvFocusMemory.current
    var opened by remember { mutableStateOf(false) }
    LaunchedEffect(dialog == null) {
        if (dialog != null) opened = true else if (opened && !focusMemory.awaitReturn()) list.focusSoon()
    }

    LazyColumn(
        Modifier
            .fillMaxSize()
            .focusRequester(list)
            .focusRestorer(),
        contentPadding = PaddingValues(start = TvDimens.Edge, end = 260.dp, top = TvDimens.Top, bottom = 80.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        item { Text("Settings", style = MaterialTheme.typography.displaySmall, color = VColors.Text, modifier = Modifier.padding(bottom = 12.dp)) }

        item { Section("Sources") }
        accounts.forEachIndexed { i, acc ->
            val local = LocalStorage.isLocal(acc.email)
            item("acc-${acc.email}") {
                TvListItem(
                    title = acc.displayName,
                    subtitle = when {
                        local -> "Videos on this TV and USB drives"
                        SmbPath.isSmb(acc.email) -> "Network server · ${SmbPath.parse(acc.email).host}"
                        else -> acc.email
                    },
                    leading = if (local) Icons.Rounded.Tv else if (SmbPath.isSmb(acc.email)) Icons.Rounded.Dns else Icons.Rounded.Person,
                    onClick = { dialog = SettingsDialog.AccountActions(acc) },
                    focusRequester = if (i == 0) first else null,
                )
            }
            val own = folders.filter { it.accountEmail == acc.email }
            items(own, key = { "folder-${it.id}" }) { f ->
                TvListItem(
                    title = f.name,
                    subtitle = ScanText.folder(f, folderCounts[f.id] ?: 0, scan),
                    leading = if (f.type == LibraryType.MOVIES) Icons.Rounded.Movie else Icons.Rounded.LiveTv,
                    trailing = if (f.type == LibraryType.MOVIES) "Movies" else "TV Shows",
                    onClick = { dialog = SettingsDialog.FolderActions(f) },
                    modifier = Modifier.padding(start = 28.dp),
                )
            }
            item("add-${acc.email}") {
                TvListItem(
                    title = "Add library folder",
                    leading = Icons.Rounded.CreateNewFolder,
                    onClick = { if (local) deviceSource.open() else dialog = SettingsDialog.Pick(acc.email) },
                    modifier = Modifier.padding(start = 28.dp),
                )
            }
        }
        item("add-google") {
            TvListItem(
                title = if (connector.busy()) "Connecting…" else "Add Google account",
                subtitle = "Sign in with the account whose Drive holds your videos",
                leading = Icons.Rounded.PersonAdd,
                onClick = { connector.connect() },
                focusRequester = if (accounts.isEmpty()) first else null,
            )
        }
        item("add-server") {
            TvListItem(
                title = "Add network server",
                subtitle = "Shared folders on a router, NAS or computer",
                leading = Icons.Rounded.Dns,
                onClick = { dialog = SettingsDialog.AddServer },
            )
        }
        if (!hasDevice) {
            item("add-device") {
                TvListItem(
                    title = "Use videos on this TV",
                    subtitle = "Internal storage and USB drives",
                    leading = Icons.Rounded.Tv,
                    onClick = { deviceSource.open() },
                )
            }
        }

        item { Section("Library") }
        item {
            // One item for both states: swapping composables would drop the focus to the rail mid-scan.
            TvListItem(
                title = if (scan.running) ScanText.title(scan) + (scan.progress?.let { " · ${(it * 100).toInt()}%" } ?: "")
                else "Scan library now",
                subtitle = if (scan.running) "${ScanText.step(scan)} · ${ScanText.counts(scan)}"
                else ScanText.idle(scan, settings.lastScanAt),
                leading = Icons.Rounded.Sync,
                trailing = if (scan.running) "Cancel" else null,
                onClick = { if (scan.running) vm.cancelScan() else vm.scanNow() },
            )
        }
        if (unmatched > 0) {
            item {
                TvListItem(
                    title = "Unmatched files",
                    subtitle = "$unmatched file${if (unmatched == 1) "" else "s"} need identifying",
                    leading = Icons.Rounded.ErrorOutline,
                    onClick = { navigator.navigate(UnmatchedRoute) },
                )
            }
        }

        item { Section("Playback") }
        item { Toggle("Auto-play next episode", "Counts down at the end of an episode", settings.autoPlayNext, vm::setAutoPlay) }
        item { TvListItem("Skip button", { dialog = SettingsDialog.Skip }, trailing = "+${settings.skipSeconds}s") }
        item { TvListItem("Seek step", { dialog = SettingsDialog.Seek }, subtitle = "How far ← and → jump in the player", trailing = "${settings.seekSeconds}s") }
        item { TvListItem("Preferred audio", { dialog = SettingsDialog.Audio }, trailing = languageLabel(settings.preferredAudioLanguage)) }
        item {
            TvListItem(
                "Default subtitles", { dialog = SettingsDialog.Subs },
                trailing = settings.preferredSubtitleLanguage.ifBlank { null }?.let(::languageLabel) ?: "Off",
            )
        }

        item { Section("Subtitles") }
        item { TvListItem("Text size", { dialog = SettingsDialog.SubSize }, trailing = subtitleSizes.firstOrNull { it.first == settings.subtitleScale }?.second ?: "Normal") }
        item { Toggle("Background box", "Dark box behind subtitle text", settings.subtitleBackground, vm::setSubBackground) }

        item { Section("Appearance") }
        item { Toggle("Pure black", "True black background for OLED TVs", settings.oledBlack, vm::setOled) }

        item { Section("TMDB") }
        item {
            TvListItem(
                title = "TMDB key",
                subtitle = when {
                    settings.tmdbKeyOverride.isNotBlank() -> "Using your key"
                    BuildConfig.BUNDLED_TMDB_KEY.isNotBlank() -> "Using the key built into this copy"
                    else -> "Not set: posters and details need a free key from themoviedb.org"
                },
                leading = Icons.Rounded.Key,
                onClick = { dialog = SettingsDialog.TmdbKey },
            )
        }

        item { Section("About") }
        item { TvListItem("Veltoret ${BuildConfig.VERSION_NAME}", {}, subtitle = "Free and open source · Developed by ${Developer.NAME}", leading = Icons.Rounded.Info) }
        // TVs often have no browser: show the addresses to type on a phone instead of links.
        item { TvListItem("Website", {}, subtitle = "pntapps.com", leading = Icons.Rounded.Language) }
        item { TvListItem("About us", {}, subtitle = "pntapps.com/about", leading = Icons.Rounded.Groups) }
        item { TvListItem("Privacy policy", {}, subtitle = "pntapps.com/privacy", leading = Icons.Rounded.PrivacyTip) }
        item { TmdbAttribution(Modifier.padding(start = 18.dp, top = 12.dp), logoHeight = 16.dp) }
    }

    when (val d = dialog) {
        is SettingsDialog.AccountActions -> TvActionsDialog(
            title = d.account.displayName,
            subtitle = if (LocalStorage.isLocal(d.account.email) || SmbPath.isSmb(d.account.email)) null else d.account.email,
            onDismiss = { dialog = null },
            actions = listOf(
                TvAction("Add library folder", Icons.Rounded.Add) {
                    if (LocalStorage.isLocal(d.account.email)) deviceSource.open() else dialog = SettingsDialog.Pick(d.account.email)
                },
                TvAction(
                    "Remove", Icons.Rounded.Delete,
                    detail = when {
                        LocalStorage.isLocal(d.account.email) -> "Nothing is deleted from this TV"
                        SmbPath.isSmb(d.account.email) -> "Nothing is deleted from the server"
                        else -> "Nothing is deleted from Google Drive"
                    },
                ) { vm.removeAccount(d.account.email) },
            ),
        )
        is SettingsDialog.FolderActions -> TvActionsDialog(
            title = d.folder.name,
            onDismiss = { dialog = null },
            actions = listOf(
                TvAction("Scan this folder", Icons.Rounded.Sync, detail = "Looks for new, renamed and removed videos") { vm.scanFolder(d.folder) },
                TvAction("Remove from library", Icons.Rounded.Delete, detail = "The folder itself isn't deleted") { vm.removeFolder(d.folder) },
            ),
        )
        is SettingsDialog.Pick -> TvFolderPicker(
            email = d.email,
            onDismiss = { dialog = null },
            startAt = d.startAt,
            onPick = { crumb, type -> vm.addFolder(d.email, crumb.id, crumb.name, type); dialog = null },
        )
        SettingsDialog.AddServer -> TvAddServerScreen(
            onDismiss = { dialog = null },
            // Straight on to choosing a library folder, inside the typed path if there was one.
            onAdded = { server, crumbs -> dialog = SettingsDialog.Pick(server.account, crumbs) },
        )
        is SettingsDialog.TypeFor -> TvChoiceDialog(
            title = "What's in \"${d.folder.name}\"?",
            options = listOf(LibraryType.MOVIES, LibraryType.SHOWS),
            label = { if (it == LibraryType.MOVIES) "Movies" else "TV Shows" },
            selected = null,
            onDismiss = { dialog = null },
            onSelect = { vm.addFolder(LocalStorage.ACCOUNT, d.folder.id, d.folder.name, it); dialog = null },
        )
        SettingsDialog.Skip -> TvChoiceDialog("Skip button", listOf(30, 60, 85, 90, 120), { "+${it}s" }, settings.skipSeconds, { dialog = null }, { vm.setSkip(it); dialog = null })
        SettingsDialog.Seek -> TvChoiceDialog("Seek step", listOf(5, 10, 15, 30), { "${it}s" }, settings.seekSeconds, { dialog = null }, { vm.setSeek(it); dialog = null })
        SettingsDialog.Audio -> TvChoiceDialog("Preferred audio", LANGUAGES.map { it.first }, ::languageLabel, settings.preferredAudioLanguage, { dialog = null }, { vm.setAudioLang(it); dialog = null })
        SettingsDialog.Subs -> TvChoiceDialog(
            "Default subtitles", listOf("") + LANGUAGES.map { it.first }, { if (it.isBlank()) "Off" else languageLabel(it) },
            settings.preferredSubtitleLanguage, { dialog = null }, { vm.setSubLang(it); dialog = null },
        )
        SettingsDialog.SubSize -> TvChoiceDialog(
            "Subtitle size", subtitleSizes.map { it.first }, { v -> subtitleSizes.first { it.first == v }.second },
            settings.subtitleScale, { dialog = null }, { vm.setSubScale(it); dialog = null },
        )
        SettingsDialog.TmdbKey -> TvTextDialog(
            title = "TMDB key",
            subtitle = "Paste your API key or Read Access Token from themoviedb.org → Settings → API.",
            initial = settings.tmdbKeyOverride,
            confirm = "Save",
            secret = true,
            onDismiss = { dialog = null },
            onConfirm = { vm.saveTmdbKey(it) },
        )
        is SettingsDialog.Message -> {
            val ok = remember { FocusRequester() }
            TvSidePanel("Veltoret", { dialog = null }, initialFocus = ok) {
                Text(d.text, style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted)
                Spacer(Modifier.height(24.dp))
                TvButton("OK", { dialog = null }, focusRequester = ok)
            }
        }
        null -> Unit
    }
}

private val subtitleSizes = listOf(0.8f to "Small", 1f to "Normal", 1.25f to "Large", 1.5f to "Extra large")

@Composable
private fun Section(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelLarge,
        color = VColors.Amber,
        modifier = Modifier.padding(start = 18.dp, top = 24.dp, bottom = 8.dp),
    )
}

@Composable
private fun Toggle(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    TvListItem(title, { onChange(!checked) }, subtitle = subtitle, trailing = if (checked) "On" else "Off")
}

// ---------------------------------------------------------------------------------------------
// Device videos on a TV
// ---------------------------------------------------------------------------------------------

class TvDeviceSource(val open: () -> Unit)

/**
 * "Videos on this TV": uses the system folder picker where it exists (some Android TV boxes);
 * otherwise asks for the video permission and browses the TV's media library.
 */
@Composable
fun rememberTvDeviceSource(onReady: () -> Unit, onPicked: (DriveFile) -> Unit, onDenied: () -> Unit): TvDeviceSource {
    val context = LocalContext.current
    val container = context.container
    val scope = rememberCoroutineScope()
    val media = container.localStorage.media
    val safPicker = rememberLocalFolderPicker { uri ->
        scope.launch {
            container.accountRepository.ensureDeviceAccount()
            runCatching { container.localStorage.adopt(uri) }.getOrNull()?.let(onPicked)
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scope.launch { container.accountRepository.ensureDeviceAccount(); onReady() } else onDenied()
    }
    return remember(media) {
        TvDeviceSource {
            when {
                media.folderPickerAvailable -> safPicker()
                context.checkSelfPermission(media.permission) == PackageManager.PERMISSION_GRANTED ->
                    scope.launch { container.accountRepository.ensureDeviceAccount(); onReady() }
                else -> permission.launch(media.permission)
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Folder picker
// ---------------------------------------------------------------------------------------------

/**
 * Full-screen folder browser for choosing a library folder with the remote. OK opens a folder,
 * Back goes up a level (or closes at the top), and the two buttons use the current folder.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun TvFolderPicker(email: String, onDismiss: () -> Unit, startAt: List<Crumb> = emptyList(), onPick: (Crumb, LibraryType) -> Unit) {
    val storage = LocalContext.current.container.storage
    val stack = remember { mutableStateOf(listOf(Crumb(storage.rootId(email), if (storage.isLocal(email)) "This TV" else storage.rootName(email))) + startAt) }
    val current = stack.value.last()
    var folders by remember { mutableStateOf<List<DriveFile>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val itemRequesters = remember { mutableMapOf<String, FocusRequester>() }
    val useMovies = remember { FocusRequester() }
    // Back goes up a level and focuses the folder you came out of.
    var leftFolder by remember { mutableStateOf<String?>(null) }
    // The top of "This TV" is only the list of drives, and a server's top its shared folders; a real folder has to be chosen.
    val pickable = !((storage.isLocal(email) || storage.isSmb(email)) && stack.value.size == 1)

    LaunchedEffect(current.id) {
        folders = null
        error = null
        folders = try {
            storage.list(email, current.id).filter { it.isFolder }
        } catch (e: Exception) {
            error = e.message ?: "Couldn't open this folder"
            emptyList()
        }
    }
    LaunchedEffect(folders) {
        if (folders == null) return@LaunchedEffect
        val list = folders!!
        val target = (list.firstOrNull { it.id == leftFolder } ?: list.firstOrNull())?.let { itemRequesters[it.id] }
        leftFolder = null
        (target ?: useMovies).focusSoon()
    }
    ReturnFocusWhenClosed()

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler {
            if (stack.value.size > 1) {
                leftFolder = current.id
                stack.value = stack.value.dropLast(1)
            } else onDismiss()
        }
        Box(
            Modifier
                .fillMaxSize()
                .background(VColors.Background)
                .padding(horizontal = TvDimens.Edge + 16.dp, vertical = TvDimens.Top + 8.dp)
        ) {
            Column(Modifier.fillMaxSize()) {
                Text("Choose a library folder", style = MaterialTheme.typography.headlineMedium, color = VColors.Text)
                Spacer(Modifier.height(6.dp))
                Text(
                    stack.value.joinToString("  ›  ") { it.name },
                    style = MaterialTheme.typography.titleSmall,
                    color = VColors.Amber,
                    maxLines = 1,
                )
                Spacer(Modifier.height(18.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    TvButton("Use for Movies", { onPick(current, LibraryType.MOVIES) }, icon = Icons.Rounded.Movie, enabled = pickable, focusRequester = useMovies)
                    TvButton("Use for TV Shows", { onPick(current, LibraryType.SHOWS) }, icon = Icons.Rounded.LiveTv, enabled = pickable)
                    if (stack.value.size > 1) TvButton("Up", { stack.value = stack.value.dropLast(1) }, icon = Icons.AutoMirrored.Rounded.ArrowBack)
                }
                Spacer(Modifier.height(18.dp))
                val list = folders
                when {
                    list == null -> Text("Loading…", style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted)
                    error != null -> Text(error!!, style = MaterialTheme.typography.bodyLarge, color = VColors.Danger)
                    list.isEmpty() -> Text(
                        when {
                            storage.isLocal(email) && stack.value.size == 1 -> "No videos found on this TV or its USB drives."
                            storage.isSmb(email) && stack.value.size == 1 -> "This server doesn't share any folders this user can open."
                            else -> "No folders inside. You can use this folder."
                        },
                        style = MaterialTheme.typography.bodyLarge,
                        color = VColors.TextMuted,
                    )
                    // ↑ out of the list always lands on "Use for Movies", never the nearest button.
                    else -> LazyColumn(
                        Modifier
                            .width(620.dp)
                            .focusProperties { exit = { if (it == FocusDirection.Up) useMovies else FocusRequester.Default } },
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        items(list, key = { it.id }) { folder ->
                            TvListItem(
                                title = folder.name,
                                leading = Icons.Rounded.Folder,
                                onClick = { stack.value = stack.value + Crumb(folder.id, folder.name) },
                                focusRequester = itemRequesters.getOrPut(folder.id) { FocusRequester() },
                            )
                        }
                    }
                }
            }
        }
    }
}
