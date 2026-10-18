package com.pntapps.veltoret.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Cloud
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.PlayCircle
import androidx.compose.material.icons.rounded.SettingsRemote
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.BuildConfig
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.demo.DemoLibrary
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.ui.accounts.rememberAccountConnector
import com.pntapps.veltoret.ui.components.Wordmark
import com.pntapps.veltoret.ui.onboarding.OnboardingStep
import com.pntapps.veltoret.ui.onboarding.OnboardingViewModel
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel

private typealias Step = OnboardingStep

/** First-run setup for TVs: five short steps, everything reachable with the remote. */
@Composable
fun TvOnboarding(startStep: OnboardingStep = Step.Welcome) {
    val vm = appViewModel("tv-onboarding") { OnboardingViewModel(it) }
    var step by rememberSaveable { mutableStateOf(startStep) }
    BackHandler(enabled = step != Step.Welcome && step != Step.Scan) { step = Step.entries[step.ordinal - 1] }

    Box(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        AnimatedContent(step, transitionSpec = { fadeIn(tween(260)) togetherWith fadeOut(tween(180)) }, label = "tvStep") { s ->
            when (s) {
                Step.Welcome -> WelcomeStep(vm) { step = Step.Accounts }
                Step.Accounts -> SourcesStep(vm) { step = Step.Folders }
                Step.Folders -> FoldersStep(vm) { step = Step.Tmdb }
                Step.Tmdb -> TmdbStep(vm) { step = Step.Scan }
                Step.Scan -> ScanStep(vm)
            }
        }
    }
}

/** Two columns: a big statement on the left, the step's controls on the right. */
@Composable
private fun StepFrame(
    eyebrow: String,
    title: String,
    body: String,
    icon: ImageVector,
    content: @Composable ColumnScope.() -> Unit,
) {
    Row(
        Modifier
            .fillMaxSize()
            .padding(horizontal = TvDimens.Edge + 24.dp, vertical = TvDimens.Top + 20.dp),
    ) {
        Column(Modifier.weight(0.9f).fillMaxHeight(), verticalArrangement = Arrangement.Center) {
            Box(
                Modifier
                    .size(72.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(VColors.AmberDim),
                contentAlignment = Alignment.Center,
            ) { Icon(icon, null, tint = VColors.Amber, modifier = Modifier.size(38.dp)) }
            Spacer(Modifier.height(24.dp))
            Text(eyebrow.uppercase(), style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
            Spacer(Modifier.height(8.dp))
            Text(title, style = MaterialTheme.typography.displaySmall, color = VColors.Text)
            Spacer(Modifier.height(12.dp))
            Text(body, style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted)
        }
        Spacer(Modifier.width(56.dp))
        Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.Center, content = content)
    }
}

@Composable
private fun WelcomeStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    val start = remember { FocusRequester() }
    val demo by vm.demoProgress.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { start.focusSoon() }
    Row(
        Modifier
            .fillMaxSize()
            .padding(horizontal = TvDimens.Edge + 24.dp, vertical = TvDimens.Top + 20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Wordmark(large = true)
            Spacer(Modifier.height(14.dp))
            Text("Your movies and shows,\nas a private cinema.", style = MaterialTheme.typography.headlineMedium, color = VColors.Text)
            Spacer(Modifier.height(32.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                TvButton("Get started", onNext, icon = Icons.AutoMirrored.Rounded.ArrowForward, focusRequester = start)
                if (BuildConfig.DEBUG) {
                    TvButton(
                        demo?.let { "Loading demo… ${(it * 100).toInt()}%" } ?: "Explore a demo library",
                        { vm.loadDemo() },
                        enabled = demo == null,
                    )
                }
            }
        }
        Column(Modifier.weight(0.9f), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Feature(Icons.Rounded.AutoAwesome, "Organized for you", "Posters, cast and episode guides added automatically.")
            Feature(Icons.Rounded.PlayCircle, "Plays everything", "MKV, MP4 and more, with any audio track or subtitle.")
            Feature(Icons.Rounded.SettingsRemote, "Made for the remote", "Every screen works with the arrows and OK.")
        }
    }
}

@Composable
private fun Feature(icon: ImageVector, title: String, body: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .size(52.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(VColors.Surface),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, null, tint = VColors.Amber, modifier = Modifier.size(26.dp)) }
        Spacer(Modifier.width(18.dp))
        Column {
            Text(title, style = MaterialTheme.typography.titleMedium, color = VColors.Text)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
        }
    }
}

/** Large option card used for the two sources. */
@Composable
private fun SourceCard(icon: ImageVector, title: String, body: String, done: Boolean, onClick: () -> Unit, requester: FocusRequester? = null) {
    TvSurface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = VColors.Surface,
        focusedColor = VColors.SurfaceHigh,
        focusedScale = 1.03f,
        focusRequester = requester,
    ) {
        Row(Modifier.padding(22.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = VColors.Amber, modifier = Modifier.size(34.dp))
            Spacer(Modifier.width(20.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleLarge, color = VColors.Text)
                Text(body, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
            }
            if (done) Icon(Icons.Rounded.CheckCircle, "Connected", tint = VColors.Amber, modifier = Modifier.size(28.dp))
        }
    }
}

@Composable
private fun SourcesStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    val accounts = vm.accounts.collectAsStateWithLifecycle().value.filter { it.email != DemoLibrary.EMAIL }
    var error by remember { mutableStateOf<String?>(null) }
    val connector = rememberAccountConnector(onConnected = { error = null }, onError = { error = "${it.title}. ${it.message}" })
    val drive = remember { FocusRequester() }
    val google = accounts.filterNot { LocalStorage.isLocal(it.email) || SmbPath.isSmb(it.email) }
    val hasDevice = accounts.any { LocalStorage.isLocal(it.email) }
    val device = rememberTvDeviceSource(onReady = {}, onPicked = {}, onDenied = { error = "Allow access to videos to use this TV's storage and USB drives." })
    LaunchedEffect(Unit) { drive.focusSoon() }

    StepFrame(
        "Step 1 of 4", "Where are your videos?",
        "Connect the Google Drive that holds them, use videos on this TV and its USB drives, or both.",
        Icons.Rounded.Cloud,
    ) {
        SourceCard(
            Icons.Rounded.Cloud,
            if (google.isEmpty()) "Google Drive" else "Add another Google account",
            google.joinToString { it.email }.ifBlank { if (connector.busy()) "Connecting…" else "Sign in with the account that holds your videos" },
            done = google.isNotEmpty(),
            onClick = { error = null; connector.connect() },
            requester = drive,
        )
        Spacer(Modifier.height(14.dp))
        SourceCard(
            Icons.Rounded.Tv, "This TV",
            if (hasDevice) "Videos on this TV and USB drives" else "Internal storage and USB drives",
            done = hasDevice,
            onClick = { error = null; vm.useDevice(); device.open() },
        )
        error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = VColors.Danger, modifier = Modifier.padding(top = 14.dp)) }
        Spacer(Modifier.height(24.dp))
        TvButton("Continue", onNext, icon = Icons.AutoMirrored.Rounded.ArrowForward, enabled = accounts.isNotEmpty())
    }
}

@Composable
private fun FoldersStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    val accounts = vm.accounts.collectAsStateWithLifecycle().value.filter { it.email != DemoLibrary.EMAIL }
    val folders = vm.folders.collectAsStateWithLifecycle().value.filter { it.accountEmail != DemoLibrary.EMAIL }
    var pickFor by remember { mutableStateOf<String?>(null) }
    var typeFor by remember { mutableStateOf<DriveFile?>(null) }
    val first = remember { FocusRequester() }
    val device = rememberTvDeviceSource(onReady = { pickFor = LocalStorage.ACCOUNT }, onPicked = { typeFor = it }, onDenied = {})
    LaunchedEffect(Unit) { first.focusSoon() }

    StepFrame(
        "Step 2 of 4", "Choose your folders",
        "Tell Veltoret where your movies and TV shows live. You can add more folders any time in Settings.",
        Icons.Rounded.CreateNewFolder,
    ) {
        LazyColumn(Modifier.height(300.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            accounts.forEachIndexed { i, acc ->
                val local = LocalStorage.isLocal(acc.email)
                items(folders.filter { it.accountEmail == acc.email }, key = { "f${it.id}" }) { f ->
                    TvListItem(
                        f.name, { vm.removeFolder(f) },
                        subtitle = "${if (local) "This TV" else if (SmbPath.isSmb(acc.email)) acc.displayName else acc.email} · OK to remove",
                        leading = if (f.type == LibraryType.MOVIES) Icons.Rounded.Movie else Icons.Rounded.LiveTv,
                        trailing = if (f.type == LibraryType.MOVIES) "Movies" else "TV",
                    )
                }
                item("add-${acc.email}") {
                    TvListItem(
                        title = if (local) "Add a folder from this TV" else "Add a Drive folder",
                        subtitle = if (local) null else acc.email,
                        leading = Icons.Rounded.CreateNewFolder,
                        onClick = { if (local) device.open() else pickFor = acc.email },
                        focusRequester = if (i == 0) first else null,
                    )
                }
            }
        }
        Spacer(Modifier.height(20.dp))
        TvButton("Continue", onNext, icon = Icons.AutoMirrored.Rounded.ArrowForward, enabled = folders.isNotEmpty())
    }

    pickFor?.let { email ->
        TvFolderPicker(email, onDismiss = { pickFor = null }) { crumb, type ->
            vm.addFolder(email, crumb.id, crumb.name, type)
            pickFor = null
        }
    }
    typeFor?.let { folder ->
        TvChoiceDialog(
            "What's in \"${folder.name}\"?", listOf(LibraryType.MOVIES, LibraryType.SHOWS),
            { if (it == LibraryType.MOVIES) "Movies" else "TV Shows" }, null,
            onDismiss = { typeFor = null },
            onSelect = { vm.addFolder(LocalStorage.ACCOUNT, folder.id, folder.name, it); typeFor = null },
        )
    }
}

@Composable
private fun TmdbStep(vm: OnboardingViewModel, onNext: () -> Unit) {
    val status by vm.keyStatus.collectAsStateWithLifecycle()
    var entering by remember { mutableStateOf(false) }
    val primary = remember { FocusRequester() }
    val ready = vm.hasBundledKey || status == OnboardingViewModel.KeyStatus.Valid
    LaunchedEffect(ready) { primary.focusSoon() }

    StepFrame(
        "Step 3 of 4",
        if (ready) "Posters & details are ready" else "Add posters & details",
        if (vm.hasBundledKey) "This copy of Veltoret comes with a TMDB key, so artwork, cast and episode guides work without any setup."
        else "Veltoret uses The Movie Database (TMDB). Get a free key at themoviedb.org → Settings → API, then enter it here.",
        Icons.Rounded.Key,
    ) {
        if (ready) {
            TvButton("Build my library", onNext, icon = Icons.AutoMirrored.Rounded.ArrowForward, focusRequester = primary)
        } else {
            TvButton(
                if (status == OnboardingViewModel.KeyStatus.Checking) "Checking…" else "Enter TMDB key",
                { entering = true }, icon = Icons.Rounded.Key, focusRequester = primary,
            )
            (status as? OnboardingViewModel.KeyStatus.Invalid)?.let {
                Text(it.message, style = MaterialTheme.typography.bodyMedium, color = VColors.Danger, modifier = Modifier.padding(top = 14.dp))
            }
        }
        Spacer(Modifier.height(18.dp))
        Text("This product uses the TMDB API but is not endorsed or certified by TMDB.", style = MaterialTheme.typography.bodySmall, color = VColors.TextFaint)
    }
    if (entering) {
        TvTextDialog(
            title = "TMDB key", label = "API key or Read Access Token", initial = "", confirm = "Verify", secret = true,
            onDismiss = { entering = false }, onConfirm = { vm.checkKey(it) },
        )
    }
}

@Composable
private fun ReadyLine(icon: ImageVector, text: String) {
    Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = VColors.Amber, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(14.dp))
        Text(text, style = MaterialTheme.typography.titleSmall, color = VColors.Text)
    }
}

@Composable
private fun ScanStep(vm: OnboardingViewModel) {
    val scan by vm.scan.collectAsStateWithLifecycle()
    val done = remember { FocusRequester() }
    val startedAt = remember { System.currentTimeMillis() }
    LaunchedEffect(Unit) { vm.startScan(); done.focusSoon() }
    val finished = !scan.running && scan.lastFinishedAt >= startedAt

    StepFrame(
        "Step 4 of 4",
        if (finished) "Your library is ready" else "Building your library",
        if (finished) "Found ${scan.filesFound} videos. New files are picked up automatically."
        else "Finding your videos and matching them with TMDB. You can start watching while this finishes.",
        Icons.Rounded.AutoAwesome,
    ) {
        // One card holds the status and the only action, so the focused button reads as part of the step
        // instead of floating on its own.
        Column(
            Modifier
                .width(440.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(VColors.Surface)
                .border(1.dp, VColors.Outline, RoundedCornerShape(24.dp))
                .padding(28.dp),
        ) {
            if (finished) {
                ReadyLine(Icons.Rounded.CheckCircle, "${scan.filesFound} video${if (scan.filesFound == 1) "" else "s"} in your library")
                ReadyLine(Icons.Rounded.Movie, "Movies and shows are waiting on Home")
                ReadyLine(Icons.Rounded.CreateNewFolder, "Add or change folders any time in Settings")
            } else {
                Text("${scan.phase.ifBlank { "Starting" }}… ${scan.filesFound} files", style = MaterialTheme.typography.titleMedium, color = VColors.Text)
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(Modifier.fillMaxWidth(), color = VColors.Amber, trackColor = VColors.Outline)
            }
            Spacer(Modifier.height(24.dp))
            TvButton(
                if (finished) "Start watching" else "Continue in background", { vm.finish() },
                icon = Icons.AutoMirrored.Rounded.ArrowForward, focusRequester = done, modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
