package com.pntapps.veltoret.ui.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateIntAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.draw.scale
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import com.pntapps.veltoret.ui.components.TmdbAttribution
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
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
import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.demo.DemoLibrary
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.library.SyncWorker
import com.pntapps.veltoret.ui.accounts.ConnectError
import com.pntapps.veltoret.ui.accounts.rememberAccountConnector
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.Panel
import com.pntapps.veltoret.ui.components.Pill
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VProgress
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.components.Wordmark
import com.pntapps.veltoret.ui.components.entrance
import com.pntapps.veltoret.ui.files.Avatar
import com.pntapps.veltoret.ui.files.DriveFolderPicker
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.ui.files.AccountAvatar
import com.pntapps.veltoret.ui.settings.AddServerDialog
import com.pntapps.veltoret.ui.files.LibraryTypeDialog
import com.pntapps.veltoret.ui.files.accountSubtitle
import com.pntapps.veltoret.ui.files.rememberLocalFolderPicker
import com.pntapps.veltoret.ui.files.PickerAction
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.AppIdentity
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass
import com.pntapps.veltoret.ui.util.appViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

enum class OnboardingStep { Welcome, Accounts, Folders, Tmdb, Scan }

private typealias Step = OnboardingStep

class OnboardingViewModel(private val container: AppContainer) : ViewModel() {
    val accounts = container.accountRepository.observeAccounts().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val folders = container.accountRepository.observeFolders().stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())
    val scan = container.scanner.state
    /** This copy was built with a TMDB key (debug builds, or a private release for friends and family). */
    val hasBundledKey: Boolean get() = BuildConfig.BUNDLED_TMDB_KEY.isNotBlank()

    private val _keyStatus = MutableStateFlow<KeyStatus>(KeyStatus.Idle)
    val keyStatus = _keyStatus.asStateFlow()

    sealed interface KeyStatus {
        data object Idle : KeyStatus
        data object Checking : KeyStatus
        data object Valid : KeyStatus
        data class Invalid(val message: String) : KeyStatus
    }

    fun addFolder(email: String, id: String, name: String, type: LibraryType) = viewModelScope.launch {
        container.accountRepository.addLibraryFolder(email, id, name, type)
    }

    fun removeFolder(folder: LibraryFolderEntity) = viewModelScope.launch {
        container.accountRepository.removeLibraryFolder(folder)
    }

    fun useDevice() = viewModelScope.launch { container.accountRepository.ensureDeviceAccount() }

    suspend fun adoptDeviceFolder(uri: android.net.Uri): DriveFile? =
        runCatching { container.localStorage.adopt(uri) }.getOrNull()

    fun resetKeyStatus() {
        _keyStatus.value = KeyStatus.Idle
    }

    fun checkKey(key: String) {
        _keyStatus.value = KeyStatus.Checking
        viewModelScope.launch {
            container.settings.setTmdbKey(key)
            _keyStatus.value = try {
                container.tmdbRepository.validateKey()
                KeyStatus.Valid
            } catch (e: Exception) {
                KeyStatus.Invalid(
                    if (e.message?.contains("401") == true) "TMDB didn't accept this key. Copy it again from your TMDB account."
                    else e.message ?: "Couldn't reach TMDB. Check your connection."
                )
            }
        }
    }

    fun startScan() {
        // App scope: the first scan keeps going even if the user leaves onboarding early.
        container.appScope.launch { container.scanner.scanAll() }
        SyncWorker.schedulePeriodic(container.appContext)
        com.pntapps.veltoret.data.plans.UpcomingWorker.schedule(container.appContext)
    }

    fun finish() = viewModelScope.launch { container.settings.setOnboardingComplete(true) }

    /** Debug builds only: fills the library with sample titles (see [DemoLibrary]). */
    private val _demoProgress = MutableStateFlow<Float?>(null)
    val demoProgress = _demoProgress.asStateFlow()

    fun loadDemo() {
        if (_demoProgress.value != null) return
        _demoProgress.value = 0f
        container.appScope.launch { DemoLibrary.seed(container) { _demoProgress.value = it } }
    }
}

@Composable
fun OnboardingScreen(startStep: OnboardingStep = OnboardingStep.Welcome) {
    val vm = appViewModel { OnboardingViewModel(it) }
    var step by rememberSaveable { mutableStateOf(startStep) }
    val goBack = { if (step.ordinal > 0) step = Step.entries[step.ordinal - 1] }
    BackHandler(enabled = step != Step.Welcome && step != Step.Scan) { goBack() }

    Box(
        Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing),
        contentAlignment = Alignment.TopCenter,
    ) {
        AnimatedContent(
            targetState = step,
            transitionSpec = {
                val forward = targetState.ordinal > initialState.ordinal
                (slideInHorizontally(tween(420)) { if (forward) it / 3 else -it / 3 } + fadeIn(tween(360))) togetherWith
                    (slideOutHorizontally(tween(320)) { if (forward) -it / 4 else it / 4 } + fadeOut(tween(220)))
            },
            label = "onboarding",
        ) { current ->
            val expanded = LocalWidthClass.current == WidthClass.Expanded
            Column(
                Modifier
                    .fillMaxSize()
                    .wrapContentWidth(Alignment.CenterHorizontally)
                    // Phones use the full width; tablets get a centred, readable column.
                    .widthIn(max = if (expanded) 1200.dp else 640.dp)
                    .padding(horizontal = if (expanded) 48.dp else 24.dp, vertical = 12.dp),
            ) {
                if (current != Step.Welcome) {
                    TopProgress(current, onBack = if (current == Step.Scan) null else goBack)
                    Spacer(Modifier.height(12.dp))
                }
                when (current) {
                    Step.Welcome -> WelcomeStep(vm) { step = Step.Accounts }
                    Step.Accounts -> AccountsStep(vm) { step = Step.Folders }
                    Step.Folders -> FoldersStep(vm) { step = Step.Tmdb }
                    Step.Tmdb -> TmdbStep(vm) { vm.startScan(); step = Step.Scan }
                    Step.Scan -> ScanStep(vm) { vm.finish() }
                }
            }
        }
    }
}

@Composable
private fun TopProgress(step: Step, onBack: (() -> Unit)?) {
    val total = Step.entries.size - 1
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (onBack != null) {
            VIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onBack, size = 38.dp)
            Spacer(Modifier.width(14.dp))
        }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            repeat(total) { i ->
                val fill by animateFloatAsState(if (i < step.ordinal) 1f else 0f, tween(600), label = "bar$i")
                Box(
                    Modifier
                        .weight(1f)
                        .height(4.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(VColors.Outline)
                ) {
                    Box(
                        Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(fill)
                            .background(VColors.Amber)
                    )
                }
            }
        }
        Spacer(Modifier.width(14.dp))
        Text("${step.ordinal} of $total", style = MaterialTheme.typography.labelMedium, color = VColors.TextMuted)
    }
}

/**
 * Shared step layout: illustration on top (or beside the content on wide screens), scrollable
 * content, and the primary button pinned to the bottom.
 */
@Composable
private fun ColumnScope.StepLayout(
    illustration: @Composable (Modifier) -> Unit,
    /** Enlargement for small, fixed-size illustrations on wide screens. Full-width art should use 1f. */
    wideScale: Float = 1f,
    bottom: @Composable ColumnScope.() -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val wide = LocalWidthClass.current == WidthClass.Expanded
    if (wide) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f).padding(end = 56.dp), contentAlignment = Alignment.Center) {
                illustration(Modifier.fillMaxWidth().scale(wideScale).entrance(0))
            }
            Column(Modifier.weight(1f).widthIn(max = 520.dp).fillMaxHeight()) {
                Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.Center) {
                    content()
                }
                bottom()
            }
        }
    } else {
        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
        ) {
            illustration(Modifier.fillMaxWidth().entrance(0))
            Spacer(Modifier.height(20.dp))
            content()
            Spacer(Modifier.height(16.dp))
        }
        bottom()
    }
}

@Composable
private fun StepHeader(eyebrow: String, title: String, body: String, index: Int = 1) {
    Text(eyebrow.uppercase(), style = MaterialTheme.typography.labelSmall, color = VColors.Amber, modifier = Modifier.entrance(index))
    Spacer(Modifier.height(8.dp))
    Text(title, style = MaterialTheme.typography.displaySmall, modifier = Modifier.entrance(index + 1))
    Spacer(Modifier.height(10.dp))
    Text(body, style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted, modifier = Modifier.entrance(index + 2))
    Spacer(Modifier.height(24.dp))
}

// ---------------------------------------------------------------------------------------------

@Composable
private fun ColumnScope.WelcomeStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    val demo by vm.demoProgress.collectAsStateWithLifecycle()
    StepLayout(
        illustration = {
            val expanded = LocalWidthClass.current == WidthClass.Expanded
            // On tablets the wall is drawn at its natural size instead of being scaled up.
            PosterWallIllustration(if (expanded) Modifier.fillMaxWidth().aspectRatio(1f).entrance(0) else it.height(300.dp))
        },
        bottom = {
            VButton("Get started", onNext, icon = Icons.AutoMirrored.Rounded.ArrowForward, modifier = Modifier.fillMaxWidth().entrance(7))
            Text(
                "Free and open source · Your files stay in your Drive and on your device",
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextFaint,
                modifier = Modifier
                    .align(Alignment.CenterHorizontally)
                    .padding(top = 12.dp)
                    .entrance(8),
            )
            if (BuildConfig.DEBUG) {
                Text(
                    demo?.let { "Loading demo library… ${(it * 100).toInt()}%" } ?: "Explore a demo library (debug build)",
                    style = MaterialTheme.typography.labelLarge,
                    color = VColors.Amber,
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .padding(top = 6.dp)
                        .entrance(9)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(enabled = demo == null) { vm.loadDemo() }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                )
            }
        },
    ) {
        Wordmark(Modifier.entrance(1), large = true)
        Spacer(Modifier.height(10.dp))
        Text(
            "Your movies and shows,\nas a private cinema.",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.entrance(2),
        )
        Spacer(Modifier.height(24.dp))
        Feature(Icons.Rounded.AutoAwesome, "Organized for you", "Posters, cast and episode guides added automatically.", 3)
        Feature(Icons.Rounded.PlayCircle, "Plays everything", "MKV, MP4 and more, with any audio track or subtitle.", 4)
        Feature(Icons.Rounded.Devices, "Picks up where you left off", "Continue Watching and Next Up remember your place.", 5)
    }
}

@Composable
private fun Feature(icon: ImageVector, title: String, body: String, index: Int) {
    Row(
        Modifier
            .padding(vertical = 8.dp)
            .entrance(index),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(VColors.Surface)
                .border(1.dp, VColors.Outline, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = VColors.Amber) }
        Spacer(Modifier.width(16.dp))
        Column {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
        }
    }
}

// ---------------------------------------------------------------------------------------------

@Composable
private fun ColumnScope.AccountsStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    var error by remember { mutableStateOf<ConnectError?>(null) }
    val connector = rememberAccountConnector(onConnected = { error = null }, onError = { error = it })
    var addingServer by remember { mutableStateOf(false) }

    StepLayout(
        illustration = { ConnectIllustration(connected = accounts.isNotEmpty(), working = connector.busy(), modifier = it.widthIn(max = 520.dp)) },
        bottom = {
            VButton("Continue", onNext, enabled = accounts.isNotEmpty(), icon = Icons.AutoMirrored.Rounded.ArrowForward, modifier = Modifier.fillMaxWidth())
        },
    ) {
        StepHeader(
            "Step 1 · Connect", "Where are your videos?",
            "Connect the Google Drive that holds them, use folders on this device (phone storage, SD card or USB), " +
                "a network server (SMB) at home, or all of them. You can change this any time.",
        )
        accounts.forEachIndexed { i, acc ->
            Panel(
                Modifier
                    .padding(bottom = 10.dp)
                    .entrance(i)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    AccountAvatar(acc, 40.dp)
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(acc.displayName, style = MaterialTheme.typography.titleMedium)
                        Text(accountSubtitle(acc), style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                    }
                    Icon(Icons.Rounded.CheckCircle, "Connected", tint = VColors.Amber)
                }
            }
        }
        val hasGoogle = accounts.any { !LocalStorage.isLocal(it.email) && !SmbPath.isSmb(it.email) }
        VButton(
            if (hasGoogle) "Add another Google account" else "Connect Google account",
            { error = null; connector.connect() },
            icon = Icons.Rounded.PersonAdd,
            style = if (accounts.isEmpty()) ButtonStyle.Primary else ButtonStyle.Secondary,
            loading = connector.busy(),
            modifier = Modifier
                .fillMaxWidth()
                .entrance(4),
        )
        if (accounts.none { LocalStorage.isLocal(it.email) }) {
            VButton(
                "Use files on this device",
                { vm.useDevice() },
                icon = Icons.Rounded.PhoneAndroid,
                style = ButtonStyle.Secondary,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 10.dp)
                    .entrance(4),
            )
        }
        VButton(
            "Add network server",
            { addingServer = true },
            icon = Icons.Rounded.Dns,
            style = ButtonStyle.Secondary,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 10.dp)
                .entrance(4),
        )
        AnimatedVisibility(error != null, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
            error?.let { ErrorCard(it, Modifier.padding(top = 14.dp)) }
        }
        Spacer(Modifier.height(16.dp))
        Row(
            Modifier
                .clip(RoundedCornerShape(14.dp))
                .background(VColors.Surface)
                .padding(14.dp)
                .entrance(5),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(Icons.Rounded.Lock, null, tint = VColors.AmberSoft, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(12.dp))
            Text(
                "Private by design. Veltoret talks to Google and your network servers directly from this device and only sees the folders you pick — no servers of ours, no tracking. " +
                    "You can disconnect at any time in Settings.",
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextMuted,
            )
        }
    }

    if (addingServer) {
        // Folders on the server are chosen in the next step, like Drive and device folders.
        AddServerDialog(onDismiss = { addingServer = false }, onAdded = { _, _ -> addingServer = false })
    }
}

@Composable
private fun ErrorCard(error: ConnectError, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var showDetails by rememberSaveable { mutableStateOf(error.setupProblem) }
    val shape = RoundedCornerShape(16.dp)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(VColors.Surface)
            .border(1.dp, VColors.Danger.copy(alpha = 0.45f), shape)
            .padding(16.dp)
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(Icons.Rounded.ErrorOutline, null, tint = VColors.Danger)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(error.title, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text(error.message, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
            }
        }
        if (error.setupProblem) {
            Spacer(Modifier.height(12.dp))
            Row(
                Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { showDetails = !showDetails }
                    .padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Setup details for this build", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
                Icon(if (showDetails) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore, null, tint = VColors.Amber)
            }
            AnimatedVisibility(showDetails) {
                Column(Modifier.padding(top = 8.dp)) {
                    Text(
                        "In Google Cloud → Credentials, create an OAuth client of type Android with:",
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextMuted,
                    )
                    Spacer(Modifier.height(10.dp))
                    CopyField("Package name", AppIdentity.packageName(context)) { clipboard.setText(AnnotatedString(it)) }
                    Spacer(Modifier.height(8.dp))
                    CopyField("SHA-1", AppIdentity.signingSha1(context) ?: "Unavailable") { clipboard.setText(AnnotatedString(it)) }
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "Also enable the Google Drive API and add your Google account as a test user on the OAuth consent screen. Full guide: SETUP.md.",
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextMuted,
                    )
                }
            }
        }
    }
}

@Composable
private fun CopyField(label: String, value: String, onCopy: (String) -> Unit) {
    var copied by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(VColors.SurfaceHigh)
            .clickable { onCopy(value); copied = true }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.labelSmall, color = VColors.TextFaint)
            Text(value, style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace), color = VColors.Text)
        }
        Icon(if (copied) Icons.Rounded.CheckCircle else Icons.Rounded.ContentCopy, "Copy", tint = if (copied) VColors.Amber else VColors.TextMuted, modifier = Modifier.size(18.dp))
    }
}

// ---------------------------------------------------------------------------------------------

@Composable
private fun ColumnScope.FoldersStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val folders by vm.folders.collectAsStateWithLifecycle()
    var pickerFor by remember { mutableStateOf<String?>(null) }
    var deviceFolder by remember { mutableStateOf<DriveFile?>(null) }
    val scope = rememberCoroutineScope()
    val pickDeviceFolder = rememberLocalFolderPicker { uri -> scope.launch { deviceFolder = vm.adoptDeviceFolder(uri) } }

    StepLayout(
        illustration = { FoldersIllustration(it) },
        wideScale = 1.3f,
        bottom = {
            VButton("Continue", onNext, enabled = folders.isNotEmpty(), icon = Icons.AutoMirrored.Rounded.ArrowForward, modifier = Modifier.fillMaxWidth())
        },
    ) {
        StepHeader("Step 2 · Library", "Choose your folders", "Tell Veltoret where your movies and TV shows live. You can add several folders of each kind.")
        accounts.forEach { acc ->
            if (accounts.size > 1) {
                Text(
                    if (LocalStorage.isLocal(acc.email) || SmbPath.isSmb(acc.email)) acc.displayName else acc.email,
                    style = MaterialTheme.typography.labelLarge, color = VColors.TextMuted, modifier = Modifier.padding(bottom = 8.dp),
                )
            }
            folders.filter { it.accountEmail == acc.email }.forEach { f ->
                Panel(
                    Modifier
                        .padding(bottom = 8.dp)
                        .entrance()
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (f.type == LibraryType.MOVIES) Icons.Rounded.Movie else Icons.Rounded.LiveTv, null, tint = VColors.Amber)
                        Spacer(Modifier.width(12.dp))
                        Text(f.name, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Pill(if (f.type == LibraryType.MOVIES) "Movies" else "TV Shows", accent = true)
                        IconButton(onClick = { vm.removeFolder(f) }) { Icon(Icons.Rounded.Close, "Remove", tint = VColors.TextMuted) }
                    }
                }
            }
            VButton(
                when {
                    folders.any { it.accountEmail == acc.email } -> "Add another folder"
                    LocalStorage.isLocal(acc.email) && accounts.size > 1 -> "Choose a folder on this device"
                    LocalStorage.isLocal(acc.email) -> "Choose a folder"
                    SmbPath.isSmb(acc.email) && accounts.size > 1 -> "Choose a folder on ${acc.displayName}"
                    accounts.size > 1 -> "Choose a Drive folder"
                    else -> "Choose a folder"
                },
                { if (LocalStorage.isLocal(acc.email)) pickDeviceFolder() else pickerFor = acc.email },
                icon = when {
                    LocalStorage.isLocal(acc.email) -> Icons.Rounded.PhoneAndroid
                    SmbPath.isSmb(acc.email) -> Icons.Rounded.Dns
                    else -> Icons.Rounded.CreateNewFolder
                },
                style = if (folders.isEmpty()) ButtonStyle.Primary else ButtonStyle.Secondary,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp)
                    .entrance(4),
            )
        }
        Panel(Modifier.entrance(5)) {
            Column {
                Text("Works best like this", style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.height(10.dp))
                Text(
                    "Movies/\n  Inception (2010)/Inception.mkv\nTV Shows/\n  Breaking Bad/\n    Season 1/S01E01.mkv",
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = VColors.AmberSoft,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "Messy names are fine too — anything Veltoret can't recognise can be fixed later in a couple of taps.",
                    style = MaterialTheme.typography.bodySmall,
                    color = VColors.TextMuted,
                )
            }
        }
    }

    pickerFor?.let { email ->
        DriveFolderPicker(
            email = email,
            title = "Choose a folder",
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
}

// ---------------------------------------------------------------------------------------------

@Composable
private fun ColumnScope.TmdbStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    var key by rememberSaveable { mutableStateOf("") }
    var visible by remember { mutableStateOf(false) }
    val status by vm.keyStatus.collectAsStateWithLifecycle()
    val uri = LocalUriHandler.current
    // With a built-in key there's nothing to set up; people can still switch to their own key.
    var useOwnKey by rememberSaveable { mutableStateOf(false) }
    if (vm.hasBundledKey && !useOwnKey) {
        StepLayout(
            illustration = { MetadataIllustration(it.widthIn(max = 420.dp)) },
            wideScale = 1.15f,
            bottom = {
                VButton("Build my library", onNext, icon = Icons.AutoMirrored.Rounded.ArrowForward, modifier = Modifier.fillMaxWidth())
            },
        ) {
            StepHeader(
                "Step 3 · Artwork", "Posters & details are ready",
                "This copy of Veltoret comes with a TMDB key, so posters, cast and episode guides work without any setup.",
            )
            Row(
                Modifier
                    .padding(top = 4.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable { useOwnKey = true }
                    .padding(vertical = 6.dp)
                    .entrance(4),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Rounded.Key, null, tint = VColors.Amber, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Text("Use my own TMDB key instead", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
            }
            Spacer(Modifier.height(16.dp))
            TmdbAttribution()
        }
        return
    }

    StepLayout(
        illustration = { MetadataIllustration(it.widthIn(max = 420.dp)) },
        wideScale = 1.15f,
        bottom = {
            if (status == OnboardingViewModel.KeyStatus.Valid) {
                VButton("Build my library", onNext, icon = Icons.AutoMirrored.Rounded.ArrowForward, modifier = Modifier.fillMaxWidth())
            } else {
                VButton(
                    "Verify key", { vm.checkKey(key) },
                    enabled = key.isNotBlank(),
                    loading = status == OnboardingViewModel.KeyStatus.Checking,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
    ) {
        StepHeader("Step 3 · Artwork", "Add posters & details", "Veltoret uses The Movie Database (TMDB) for posters, cast and episode guides. A free key takes about a minute.")
        NumberedLine(1, "Create a free account at themoviedb.org", 4)
        NumberedLine(2, "Open Settings → API and request a key (choose “Personal”)", 5)
        NumberedLine(3, "Copy the API Key or the Read Access Token and paste it below", 6)
        Row(
            Modifier
                .padding(top = 4.dp, bottom = 16.dp)
                .clip(RoundedCornerShape(8.dp))
                .clickable { uri.openUri("https://www.themoviedb.org/settings/api") }
                .padding(vertical = 6.dp)
                .entrance(7),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Open TMDB API settings", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
            Spacer(Modifier.width(6.dp))
            Icon(Icons.AutoMirrored.Rounded.OpenInNew, null, tint = VColors.Amber, modifier = Modifier.size(16.dp))
        }
        VTextField(
            value = key,
            onValueChange = { key = it; vm.resetKeyStatus() },
            label = "API key or Read Access Token",
            leadingIcon = Icons.Rounded.Key,
            visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            trailing = {
                IconButton(onClick = { visible = !visible }) {
                    Icon(if (visible) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, "Show key", tint = VColors.TextMuted)
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .entrance(8),
        )
        AnimatedVisibility(status is OnboardingViewModel.KeyStatus.Valid || status is OnboardingViewModel.KeyStatus.Invalid) {
            val s = status
            Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (s is OnboardingViewModel.KeyStatus.Valid) Icons.Rounded.CheckCircle else Icons.Rounded.ErrorOutline, null,
                    tint = if (s is OnboardingViewModel.KeyStatus.Valid) VColors.Success else VColors.Danger,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    if (s is OnboardingViewModel.KeyStatus.Invalid) s.message else "Key verified — you're all set",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (s is OnboardingViewModel.KeyStatus.Valid) VColors.Success else VColors.Danger,
                )
            }
        }
        Spacer(Modifier.height(16.dp))
        TmdbAttribution()
    }
}

@Composable
private fun NumberedLine(n: Int, text: String, index: Int) {
    Row(
        Modifier
            .padding(vertical = 5.dp)
            .entrance(index),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(26.dp)
                .clip(CircleShape)
                .background(VColors.AmberDim),
            contentAlignment = Alignment.Center,
        ) { Text("$n", style = MaterialTheme.typography.labelMedium, color = VColors.AmberSoft) }
        Spacer(Modifier.width(12.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium)
    }
}

// ---------------------------------------------------------------------------------------------

@Composable
private fun ColumnScope.ScanStep(vm: OnboardingViewModel, onDone: () -> Unit) {
    val scan by vm.scan.collectAsStateWithLifecycle()
    val finished = !scan.running && scan.lastFinishedAt > 0
    val found by animateIntAsState(scan.filesFound, tween(600), label = "found")
    val matched by animateIntAsState(scan.matched, tween(600), label = "matched")

    StepLayout(
        illustration = { ScanIllustration(finished, it.widthIn(max = 560.dp)) },
        wideScale = 1f,
        bottom = {
            VButton(
                if (finished) "Start watching" else "Continue in background",
                onDone,
                icon = if (finished) Icons.Rounded.PlayCircle else null,
                style = if (finished) ButtonStyle.Primary else ButtonStyle.Secondary,
                modifier = Modifier.fillMaxWidth(),
            )
        },
    ) {
        StepHeader(
            "Step 4 · Library",
            if (finished) "Your library is ready" else "Building your library",
            when {
                finished && scan.error != null -> "Finished with a problem: ${scan.error}"
                finished -> "Everything is organized. Enjoy the show."
                else -> "This only takes a while the first time. You can start browsing whenever you like."
            },
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.entrance(4)) {
            StatTile("Videos found", found.toString(), Modifier.weight(1f))
            StatTile("Matched", if (scan.toMatch > 0) "$matched / ${scan.toMatch}" else matched.toString(), Modifier.weight(1f))
        }
        if (!finished) {
            Spacer(Modifier.height(18.dp))
            Text(
                if (scan.phase.startsWith("Matching")) "Matching titles with TMDB…" else "Reading your Drive…",
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextMuted,
            )
            Spacer(Modifier.height(8.dp))
            VProgress(if (scan.toMatch > 0) scan.matched.toFloat() / scan.toMatch else 0.05f, height = 4.dp)
        }
    }
}

@Composable
private fun StatTile(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .clip(RoundedCornerShape(16.dp))
            .background(VColors.Surface)
            .border(1.dp, VColors.Outline, RoundedCornerShape(16.dp))
            .padding(16.dp)
    ) {
        Text(value, style = MaterialTheme.typography.headlineMedium, color = VColors.Text)
        Text(label, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
    }
}
