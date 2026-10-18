package com.pntapps.veltoret.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.BuildConfig
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.library.ScanState
import com.pntapps.veltoret.data.library.SyncWorker
import com.pntapps.veltoret.data.settings.AppSettings
import com.pntapps.veltoret.ui.accounts.rememberAccountConnector
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.CardShape
import com.pntapps.veltoret.ui.components.Panel
import com.pntapps.veltoret.ui.components.Pill
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.ui.files.AccountAvatar
import com.pntapps.veltoret.ui.files.LibraryTypeDialog
import com.pntapps.veltoret.ui.files.accountSubtitle
import com.pntapps.veltoret.ui.files.rememberLocalFolderPicker
import com.pntapps.veltoret.ui.files.rememberNotificationPermission
import com.pntapps.veltoret.ui.files.DriveFolderPicker
import com.pntapps.veltoret.ui.files.PickerAction
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.ArchivesRoute
import com.pntapps.veltoret.ui.navigation.UnmatchedRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.appViewModel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

val LANGUAGES = listOf(
    "en" to "English", "hi" to "Hindi", "es" to "Spanish", "fr" to "French", "de" to "German", "it" to "Italian",
    "pt" to "Portuguese", "ja" to "Japanese", "ko" to "Korean", "zh" to "Chinese", "ru" to "Russian", "ar" to "Arabic",
    "ta" to "Tamil", "te" to "Telugu", "ml" to "Malayalam", "bn" to "Bengali", "ur" to "Urdu", "tr" to "Turkish",
)

fun languageLabel(code: String) = LANGUAGES.firstOrNull { it.first == code }?.second ?: code.uppercase()

class SettingsViewModel(private val container: AppContainer) : ViewModel() {
    val settings = container.settings.settings.stateIn(viewModelScope, SharingStarted.Eagerly, AppSettings())
    val accounts = container.accountRepository.observeAccounts().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val folders = container.accountRepository.observeFolders().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val scan = container.scanner.state
    val unmatched = container.libraryRepository.unmatched().map { it.size }.stateIn(viewModelScope, SharingStarted.Eagerly, 0)
    val archives = container.libraryRepository.archives().map { it.size }.stateIn(viewModelScope, SharingStarted.Eagerly, 0)
    val folderCounts = container.libraryRepository.folderCounts().stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())
    val messages = MutableSharedFlow<String>(extraBufferCapacity = 4)

    private val s get() = container.settings

    fun scanNow() = SyncWorker.runNow(container.appContext, notify = true)

    fun scanFolder(folder: LibraryFolderEntity) {
        SyncWorker.runNow(container.appContext, setOf(folder.id), notify = true)
        messages.tryEmit("Scanning \"${folder.name}\"")
    }

    fun cancelScan() = SyncWorker.cancel(container.appContext)

    fun addFolder(email: String, id: String, name: String, type: LibraryType) = viewModelScope.launch {
        val folderId = container.accountRepository.addLibraryFolder(email, id, name, type)
        SyncWorker.schedulePeriodic(container.appContext)
        SyncWorker.runNow(container.appContext, folderId?.let { setOf(it) }, notify = true)
        messages.tryEmit("Added \"$name\" — scanning now")
    }

    /** Keeps access to a folder from the system folder picker; the caller then asks Movies or TV. */
    suspend fun adoptDeviceFolder(uri: android.net.Uri): DriveFile? = try {
        container.localStorage.adopt(uri)
    } catch (e: Exception) {
        messages.tryEmit(e.message ?: "Couldn't open that folder")
        null
    }

    fun removeFolder(folder: LibraryFolderEntity) = viewModelScope.launch {
        container.accountRepository.removeLibraryFolder(folder)
    }

    fun removeAccount(email: String) = viewModelScope.launch {
        container.accountRepository.removeAccount(email)
    }

    fun saveTmdbKey(key: String) = viewModelScope.launch {
        s.setTmdbKey(key)
        try {
            container.tmdbRepository.validateKey()
            messages.tryEmit("TMDB key saved")
            scanNow()
        } catch (e: Exception) {
            messages.tryEmit("TMDB rejected this key: ${e.message}")
        }
    }

    fun setOled(v: Boolean) = viewModelScope.launch { s.setOledBlack(v) }
    fun setAutoPlay(v: Boolean) = viewModelScope.launch { s.setAutoPlayNext(v) }
    fun setSkip(v: Int) = viewModelScope.launch { s.setSkipSeconds(v) }
    fun setSeek(v: Int) = viewModelScope.launch { s.setSeekSeconds(v) }
    fun setAudioLang(v: String) = viewModelScope.launch { s.setAudioLanguage(v) }
    fun setSubLang(v: String) = viewModelScope.launch { s.setSubtitleLanguage(v) }
    fun setSubScale(v: Float) = viewModelScope.launch { s.setSubtitleScale(v) }
    fun setSubBackground(v: Boolean) = viewModelScope.launch { s.setSubtitleBackground(v) }
}

@Composable
fun SettingsScreen(navigator: Navigator) {
    val vm = appViewModel { SettingsViewModel(it) }
    val settings by vm.settings.collectAsStateWithLifecycle()
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val folders by vm.folders.collectAsStateWithLifecycle()
    val scan by vm.scan.collectAsStateWithLifecycle()
    val unmatched by vm.unmatched.collectAsStateWithLifecycle()
    val archives by vm.archives.collectAsStateWithLifecycle()
    val folderCounts by vm.folderCounts.collectAsStateWithLifecycle()
    val askNotifications = rememberNotificationPermission()
    val snackbar = remember { SnackbarHostState() }
    var pickerFor by remember { mutableStateOf<String?>(null) }
    var confirmRemove by remember { mutableStateOf<AccountEntity?>(null) }
    var deviceFolder by remember { mutableStateOf<DriveFile?>(null) }
    val scope = rememberCoroutineScope()
    val pickDeviceFolder = rememberLocalFolderPicker { uri -> scope.launch { deviceFolder = vm.adoptDeviceFolder(uri) } }

    LaunchedEffect(Unit) { vm.messages.collect { snackbar.showSnackbar(it) } }

    val connector = rememberAccountConnector(
        onConnected = { vm.messages.tryEmit("Connected ${it.email}") },
        onError = { vm.messages.tryEmit("${it.title}. ${it.message}") },
    )

    // Left: accounts & library. Right: playback, look and about. Side by side on landscape tablets.
    val leftColumn: LazyListScope.() -> Unit = {
            item { GroupTitle("Sources") }
            accounts.forEach { account ->
                item(account.email) {
                    AccountPanel(
                        account = account,
                        folders = folders.filter { it.accountEmail == account.email },
                        folderCounts = folderCounts,
                        scan = scan,
                        onScanFolder = { askNotifications(); vm.scanFolder(it) },
                        onAddFolder = { if (LocalStorage.isLocal(account.email)) pickDeviceFolder() else pickerFor = account.email },
                        onRemoveFolder = vm::removeFolder,
                        onRemoveAccount = { confirmRemove = account },
                    )
                }
            }
            item {
                VButton(
                    "Add Google account",
                    connector.connect,
                    icon = Icons.Rounded.PersonAdd,
                    style = ButtonStyle.Secondary,
                    loading = connector.busy(),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 4.dp),
                )
            }
            if (accounts.none { LocalStorage.isLocal(it.email) }) {
                item {
                    VButton(
                        "Use files on this device",
                        pickDeviceFolder,
                        icon = Icons.Rounded.PhoneAndroid,
                        style = ButtonStyle.Secondary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp, vertical = 4.dp),
                    )
                }
            }

            item { GroupTitle("Library") }
            item {
                Group {
                    if (scan.running) {
                        ScanProgress(scan, onCancel = vm::cancelScan)
                    } else {
                        SettingRow(
                            "Scan library now",
                            ScanText.idle(scan, settings.lastScanAt),
                            icon = Icons.Rounded.Sync,
                            onClick = { askNotifications(); vm.scanNow() },
                        )
                    }
                    if (unmatched > 0) {
                        Divider()
                        SettingRow("Unmatched files", "$unmatched file${if (unmatched == 1) "" else "s"} need identifying", onClick = { navigator.navigate(UnmatchedRoute) })
                    }
                    Divider()
                    SettingRow(
                        "ZIP archives",
                        if (archives == 0) "None found in your library" else "$archives waiting to be extracted",
                        onClick = { navigator.navigate(ArchivesRoute) },
                    )
                }
            }

    }
    val rightColumn: LazyListScope.() -> Unit = {
            item { GroupTitle("Playback") }
            item {
                Group {
                    SwitchRow("Auto-play next episode", "Counts down at the end of an episode", settings.autoPlayNext, vm::setAutoPlay)
                    Divider()
                    ChoiceRow("Skip button", listOf(30, 60, 85, 90, 120).map { it to "+${it}s" }, settings.skipSeconds, vm::setSkip)
                    Divider()
                    ChoiceRow("Double-tap seek", listOf(5, 10, 15, 30).map { it to "${it}s" }, settings.seekSeconds, vm::setSeek)
                    Divider()
                    ChoiceRow("Preferred audio", LANGUAGES, settings.preferredAudioLanguage, vm::setAudioLang)
                    Divider()
                    ChoiceRow("Default subtitles", listOf("" to "Off") + LANGUAGES, settings.preferredSubtitleLanguage, vm::setSubLang)
                }
            }

            item { GroupTitle("Subtitles") }
            item {
                Group {
                    ChoiceRow(
                        "Text size",
                        listOf(0.8f to "Small", 1f to "Normal", 1.25f to "Large", 1.5f to "Extra large"),
                        settings.subtitleScale, vm::setSubScale,
                    )
                    Divider()
                    SwitchRow("Background box", "Dark box behind subtitle text", settings.subtitleBackground, vm::setSubBackground)
                }
            }

            item { GroupTitle("Appearance") }
            item {
                Group {
                    SwitchRow("Pure black", "True black background for OLED screens", settings.oledBlack, vm::setOled)
                }
            }

            item { GroupTitle("TMDB") }
            item { TmdbKeyPanel(settings.tmdbKeyOverride, vm::saveTmdbKey) }

            item { GroupTitle("About") }
            item {
                Group {
                    SettingRow("Veltoret", "Version ${BuildConfig.VERSION_NAME} · open source")
                    Divider()
                    Text(
                        "This product uses the TMDB API but is not endorsed or certified by TMDB.",
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextMuted,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
    }

    Box(Modifier.fillMaxSize()) {
        if (LocalWidthClass.current == WidthClass.Expanded) {
            Column(Modifier.fillMaxSize()) {
                ScreenHeader("Settings")
                Row(Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
                    LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 40.dp), content = leftColumn)
                    LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 40.dp), content = rightColumn)
                }
            }
        } else {
            LazyColumn(
                Modifier
                    .fillMaxSize()
                    .align(Alignment.TopCenter)
                    .widthIn(max = 760.dp),
                contentPadding = PaddingValues(bottom = 40.dp),
            ) {
                item { ScreenHeader("Settings") }
                leftColumn()
                rightColumn()
            }
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter))
    }

    pickerFor?.let { email ->
        DriveFolderPicker(
            email = email,
            title = "Choose a library folder",
            actions = listOf(
                PickerAction("Movies") { vm.addFolder(email, it.id, it.name, LibraryType.MOVIES); pickerFor = null },
                PickerAction("TV Shows") { vm.addFolder(email, it.id, it.name, LibraryType.SHOWS); pickerFor = null },
            ),
            onDismiss = { pickerFor = null },
        )
    }

    deviceFolder?.let { folder ->
        LibraryTypeDialog(folder.name, { deviceFolder = null }, dismissLabel = "Cancel") { type ->
            vm.addFolder(LocalStorage.ACCOUNT, folder.id, folder.name, type)
            deviceFolder = null
        }
    }

    confirmRemove?.let { acc ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            containerColor = VColors.SurfaceHigh,
            title = { Text("Remove ${if (LocalStorage.isLocal(acc.email)) acc.displayName else acc.email}?") },
            text = {
                Text(
                    if (LocalStorage.isLocal(acc.email)) "Its folders will be removed from your library. Nothing is deleted from this device."
                    else "Its folders will be removed from your library. Nothing is deleted from Google Drive."
                )
            },
            confirmButton = { TextButton({ vm.removeAccount(acc.email); confirmRemove = null }) { Text("Remove", color = VColors.Danger) } },
            dismissButton = { TextButton({ confirmRemove = null }) { Text("Cancel", color = VColors.Text) } },
        )
    }
}

@Composable
private fun AccountPanel(
    account: AccountEntity,
    folders: List<LibraryFolderEntity>,
    folderCounts: Map<Long, Int>,
    scan: ScanState,
    onScanFolder: (LibraryFolderEntity) -> Unit,
    onAddFolder: () -> Unit,
    onRemoveFolder: (LibraryFolderEntity) -> Unit,
    onRemoveAccount: () -> Unit,
) {
    Panel(Modifier.padding(horizontal = 20.dp, vertical = 6.dp)) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AccountAvatar(account, 40.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(account.displayName, style = MaterialTheme.typography.titleMedium)
                    Text(accountSubtitle(account), style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                }
                TextButton(onClick = onRemoveAccount) { Text("Remove", color = VColors.TextMuted) }
            }
            Spacer(Modifier.height(12.dp))
            if (folders.isEmpty()) {
                Text("No library folders yet.", style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
            }
            folders.forEach { folder ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        if (folder.type == LibraryType.MOVIES) Icons.Rounded.Movie else Icons.Rounded.LiveTv,
                        null, tint = VColors.Amber, modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(folder.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            ScanText.folder(folder, folderCounts[folder.id] ?: 0, scan),
                            style = MaterialTheme.typography.bodySmall,
                            color = if (folder.id in scan.folderErrors) VColors.Danger else VColors.TextFaint,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Spacer(Modifier.width(8.dp))
                    Pill(if (folder.type == LibraryType.MOVIES) "Movies" else "TV")
                    if (scan.running && scan.currentFolderId == folder.id) {
                        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(Modifier.size(18.dp), color = VColors.Amber, strokeWidth = 2.dp)
                        }
                    } else {
                        IconButton(onClick = { onScanFolder(folder) }, enabled = !scan.waiting(folder.id)) {
                            Icon(
                                Icons.Rounded.Sync, "Scan this folder",
                                tint = if (scan.waiting(folder.id)) VColors.TextFaint else VColors.TextMuted,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                    IconButton(onClick = { onRemoveFolder(folder) }) {
                        Icon(Icons.Rounded.Close, "Remove folder", tint = VColors.TextMuted, modifier = Modifier.size(18.dp))
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            VButton("Add library folder", onAddFolder, icon = Icons.Rounded.CreateNewFolder, style = ButtonStyle.Ghost, modifier = Modifier.fillMaxWidth())
        }
    }
}

/** The running scan: what it's doing, a progress bar, live counts and Cancel. */
@Composable
private fun ScanProgress(scan: ScanState, onCancel: () -> Unit) {
    val target = scan.progress
    val animated by animateFloatAsState(target ?: 0f, tween(400), label = "scan-progress")
    Column(Modifier.padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(20.dp), color = VColors.Amber, strokeWidth = 2.dp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(ScanText.title(scan), style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(ScanText.step(scan), style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            TextButton(onClick = onCancel) { Text("Cancel", color = VColors.Amber) }
        }
        Spacer(Modifier.height(12.dp))
        if (target != null) {
            LinearProgressIndicator(
                progress = { animated },
                modifier = Modifier.fillMaxWidth(),
                color = VColors.Amber,
                trackColor = VColors.Outline,
                drawStopIndicator = {},
            )
        } else {
            LinearProgressIndicator(Modifier.fillMaxWidth(), color = VColors.Amber, trackColor = VColors.Outline)
        }
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(ScanText.counts(scan), style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted, modifier = Modifier.weight(1f))
            if (target != null) Text("${(target * 100).toInt()}%", style = MaterialTheme.typography.labelMedium, color = VColors.TextMuted)
        }
        if (scan.currentPath.isNotEmpty() && scan.toMatch == 0) {
            Text(
                scan.currentPath,
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextFaint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            "Keeps going if you leave the app.",
            style = MaterialTheme.typography.bodySmall,
            color = VColors.TextFaint,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

@Composable
private fun TmdbKeyPanel(current: String, onSave: (String) -> Unit) {
    var key by remember(current) { mutableStateOf(current) }
    var visible by remember { mutableStateOf(false) }
    Panel(Modifier.padding(horizontal = 20.dp)) {
        Column {
            Text(
                "Paste your TMDB API key or API Read Access Token. Get one free at themoviedb.org → Settings → API." +
                    if (current.isBlank() && BuildConfig.BUNDLED_TMDB_KEY.isNotBlank()) "\nCurrently using the key built into this copy of the app. Paste your own to replace it." else "",
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextMuted,
            )
            Spacer(Modifier.height(12.dp))
            VTextField(
                value = key,
                onValueChange = { key = it },
                label = "TMDB key",
                leadingIcon = Icons.Rounded.Key,
                visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailing = {
                    IconButton(onClick = { visible = !visible }) {
                        Icon(if (visible) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, "Show key", tint = VColors.TextMuted)
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            VButton("Save key", { onSave(key) }, enabled = key != current, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun GroupTitle(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = VColors.Amber,
        modifier = Modifier.padding(start = 24.dp, top = 28.dp, bottom = 10.dp),
    )
}

@Composable
private fun Group(content: @Composable () -> Unit) {
    Panel(Modifier.padding(horizontal = 20.dp), padding = PaddingValues(0.dp)) {
        Column { content() }
    }
}

@Composable
private fun Divider() {
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .height(1.dp)
            .background(VColors.Outline)
    )
}

@Composable
private fun SettingRow(title: String, subtitle: String?, icon: ImageVector? = null, onClick: (() -> Unit)? = null) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(CardShape)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = VColors.Amber)
            Spacer(Modifier.width(14.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
        }
        if (onClick != null) Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = VColors.TextFaint)
    }
}

@Composable
private fun SwitchRow(title: String, subtitle: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { onChange(!checked) }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = VColors.OnAmber,
                checkedTrackColor = VColors.Amber,
                uncheckedThumbColor = VColors.TextMuted,
                uncheckedTrackColor = VColors.SurfaceHigh,
                uncheckedBorderColor = VColors.OutlineStrong,
            ),
        )
    }
}

@Composable
private fun <T> ChoiceRow(title: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { open = true }
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(options.firstOrNull { it.first == selected }?.second ?: "—", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
        }
        DropdownMenu(open, { open = false }, containerColor = VColors.SurfaceHigh) {
            options.forEach { (value, label) ->
                DropdownMenuItem(
                    text = { Text(label, color = if (value == selected) VColors.Amber else VColors.Text) },
                    onClick = { onSelect(value); open = false },
                )
            }
        }
    }
}

