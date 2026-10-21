package com.pntapps.veltoret.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Router
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import com.pntapps.veltoret.ui.util.container
import com.pntapps.veltoret.data.pairing.PhoneSubmission
import com.pntapps.veltoret.data.pairing.PhoneSetupServer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.data.smb.SmbServer
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.files.Crumb
import com.pntapps.veltoret.ui.settings.AddServerViewModel
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.rememberLocalNetworkAccess

/**
 * "Add network server" for the remote: servers found on the network on the left (OK picks one), the
 * address and sign-in on the right. Same [AddServerViewModel] as phones; on success [onAdded] gets the
 * server and the folders a typed address pointed into, to open the folder picker there.
 */
@Composable
fun TvAddServerScreen(onDismiss: () -> Unit, onAdded: (SmbServer, List<Crumb>) -> Unit) {
    val vm = appViewModel("tv-add-server") { AddServerViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    var address by remember { mutableStateOf("") }
    var guest by remember { mutableStateOf(false) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    val withNetworkAccess = rememberLocalNetworkAccess { vm.showError(it) }
    fun connect() = withNetworkAccess { vm.connect(address, guest, username, password) }
    var usePhone by remember { mutableStateOf(false) }

    val scanButton = remember { FocusRequester() }
    val firstServer = remember { FocusRequester() }
    val usernameField = remember { FocusRequester() }
    val connectButton = remember { FocusRequester() }
    val phoneButton = remember { FocusRequester() }

    LaunchedEffect(Unit) {
        vm.reset()
        withNetworkAccess { vm.scan() }
        scanButton.focusSoon()
    }
    // Servers arrive a moment later; the first one takes focus so OK picks it straight away.
    var focusedFirst by remember { mutableStateOf(false) }
    LaunchedEffect(state.found.isNotEmpty()) {
        if (state.found.isNotEmpty() && !focusedFirst) {
            focusedFirst = true
            firstServer.focusSoon()
        }
    }
    LaunchedEffect(state.added) {
        state.added?.let { (server, crumbs) ->
            vm.consumeAdded()
            onAdded(server, crumbs)
        }
    }
    ReturnFocusWhenClosed()

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler(onBack = onDismiss)
        Box(
            Modifier
                .fillMaxSize()
                .background(VColors.Background)
                .padding(horizontal = TvDimens.Edge + 16.dp, vertical = TvDimens.Top + 8.dp)
        ) {
            Column(Modifier.fillMaxSize()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Add network server", style = MaterialTheme.typography.headlineMedium, color = VColors.Text)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "Shared folders on a router with a USB drive, a NAS or a computer on this network.",
                            style = MaterialTheme.typography.bodyLarge,
                            color = VColors.TextMuted,
                        )
                    }
                    // Typing a password with the remote is slow: a phone can fill this in (QR code or Send to TV).
                    // At the top so it's always on screen; the form below doesn't scroll on a 1080p TV.
                    TvButton(
                        "Use your phone",
                        { withNetworkAccess { usePhone = true } },
                        icon = Icons.Rounded.PhoneAndroid,
                        focusRequester = phoneButton,
                    )
                }
                Spacer(Modifier.height(24.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                    // Left: servers found on the network.
                    Column(Modifier.width(400.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("On your network", style = MaterialTheme.typography.titleMedium, color = VColors.Text, modifier = Modifier.weight(1f))
                            if (state.scanning) CircularProgressIndicator(Modifier.size(18.dp), color = VColors.Amber, strokeWidth = 2.dp)
                        }
                        Spacer(Modifier.height(12.dp))
                        TvButton(
                            if (state.scanning) "Searching…" else "Search again",
                            { withNetworkAccess { vm.scan() } },
                            icon = Icons.Rounded.Refresh,
                            enabled = !state.scanning,
                            focusRequester = scanButton,
                            // ↑ goes to "Use your phone" rather than into the address field (which opens the keyboard).
                            modifier = Modifier.focusProperties { up = phoneButton },
                        )
                        Spacer(Modifier.height(12.dp))
                        if (state.found.isEmpty() && !state.scanning) {
                            Text(
                                "No servers found. Check that the TV is on the same network, or enter the address on the right.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = VColors.TextMuted,
                            )
                        }
                        LazyColumn(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            items(state.found, key = { it.address }) { server ->
                                TvListItem(
                                    title = server.name ?: if (server.isRouter) "Your router" else "File server",
                                    subtitle = if (server.isRouter) "${server.address} · router" else server.address,
                                    leading = if (server.isRouter) Icons.Rounded.Router else Icons.Rounded.Dns,
                                    selected = server.address == state.picked?.address,
                                    onClick = {
                                        vm.pick(server)
                                        address = server.address
                                    },
                                    focusRequester = if (server == state.found.first()) firstServer else null,
                                )
                            }
                        }
                    }
                    // Right: address and sign-in.
                    Column(Modifier.width(460.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        VTextField(
                            address, { address = it; vm.showError(null) }, "Server address",
                            Modifier.fillMaxWidth().tvTextFieldExit(),
                            placeholder = "\\\\192.168.0.10\\Movies",
                            leadingIcon = Icons.Rounded.Dns,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                        )
                        // ↓ from the chips goes to the next thing to fill in, not the nearest button (Cancel).
                        Row(
                            Modifier.focusProperties {
                                down = if (guest) connectButton else usernameField
                            },
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            TvChip("Username and password", !guest, { guest = false; vm.showError(null) })
                            TvChip("Guest", guest, { guest = true; vm.showError(null) })
                        }
                        if (!guest) {
                            VTextField(
                                username, { username = it; vm.showError(null) }, "Username",
                                Modifier.fillMaxWidth().focusRequester(usernameField).tvTextFieldExit(),
                                leadingIcon = Icons.Rounded.Person,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Next, autoCorrectEnabled = false),
                            )
                            VTextField(
                                password, { password = it; vm.showError(null) }, "Password",
                                Modifier.fillMaxWidth().tvTextFieldExit(),
                                leadingIcon = Icons.Rounded.Lock,
                                visualTransformation = PasswordVisualTransformation(),
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done, autoCorrectEnabled = false),
                                keyboardActions = KeyboardActions(onDone = { connect() }),
                            )
                            Text(
                                "The password is stored encrypted on this TV and is only sent to this server.",
                                style = MaterialTheme.typography.bodySmall,
                                color = VColors.TextFaint,
                            )
                        }
                        state.error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = VColors.Danger) }
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            // Stays enabled while connecting (the view model ignores repeats): a disabled button would drop the remote's focus.
                            TvButton(if (state.busy) "Connecting…" else "Connect", { connect() }, focusRequester = connectButton)
                            TvButton("Cancel", onDismiss)
                        }
                    }
                }
            }
        }
    }

    if (usePhone) {
        TvPhoneSetupPanel(
            found = { vm.state.value.found },
            busy = state.busy,
            error = state.error,
            onSubmit = { sent ->
                address = sent.address
                guest = sent.guest
                username = sent.username
                password = sent.password
                vm.attempt(sent.address, sent.guest, sent.username, sent.password, sent.name)
            },
            onDismiss = { usePhone = false },
        )
    }

    // Picking a server moves on to signing in (or straight to Connect for guest access).
    LaunchedEffect(state.picked) {
        if (state.picked == null) return@LaunchedEffect
        (if (guest) connectButton else usernameField).focusSoon()
    }
}

/**
 * "Use your phone": a QR code that opens a form in any phone's browser (option one), and a 6-digit code for
 * "Send to TV" in Veltoret on a phone or tablet (option two). Both come in through [PhoneSetupServer],
 * which runs only while this panel is open. What a phone sends fills in the screen behind and connects.
 */
@Composable
private fun TvPhoneSetupPanel(
    found: () -> List<com.pntapps.veltoret.data.smb.FoundServer>,
    busy: Boolean,
    error: String?,
    onSubmit: suspend (PhoneSubmission) -> String?,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val container = context.container
    val latestSubmit by rememberUpdatedState(onSubmit)
    val server = remember {
        PhoneSetupServer(context.applicationContext, container.json, found) { latestSubmit(it) }
    }
    DisposableEffect(server) {
        runCatching { server.start() }
        onDispose { server.stop() }
    }
    val url by server.url.collectAsStateWithLifecycle()
    val code by server.code.collectAsStateWithLifecycle()
    val close = remember { FocusRequester() }
    LaunchedEffect(Unit) { close.focusSoon() }
    ReturnFocusWhenClosed()

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler(onBack = onDismiss)
        Box(
            Modifier
                .fillMaxSize()
                .background(VColors.Background)
                .padding(horizontal = TvDimens.Edge + 16.dp, vertical = TvDimens.Top + 8.dp)
        ) {
            Column(Modifier.fillMaxSize()) {
                // Close and the status sit at the top: everything has to fit a 1080p screen without scrolling.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Use your phone", style = MaterialTheme.typography.headlineMedium, color = VColors.Text)
                        Spacer(Modifier.height(6.dp))
                        when {
                            busy -> Text("Connecting with the details from your phone…", style = MaterialTheme.typography.bodyLarge, color = VColors.AmberSoft)
                            error != null -> Text(error, style = MaterialTheme.typography.bodyLarge, color = VColors.Danger)
                            else -> Text(
                                "Waiting for your phone. It needs to be on the same Wi-Fi as this TV.",
                                style = MaterialTheme.typography.bodyLarge,
                                color = VColors.TextMuted,
                            )
                        }
                    }
                    TvButton("Close", onDismiss, focusRequester = close)
                }
                Spacer(Modifier.height(28.dp))
                if (url == null) {
                    Text(
                        "This TV isn't on Wi-Fi or Ethernet, so a phone can't reach it.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = VColors.Danger,
                    )
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(64.dp)) {
                        Column(Modifier.width(420.dp)) {
                            Text("Any phone", style = MaterialTheme.typography.titleLarge, color = VColors.Amber)
                            Spacer(Modifier.height(8.dp))
                            Text(
                                "Scan with the phone's camera, then fill in the server on the page that opens.",
                                style = MaterialTheme.typography.bodyLarge,
                                color = VColors.Text,
                            )
                            Spacer(Modifier.height(18.dp))
                            QrCode(url!!, Modifier.size(220.dp))
                            Spacer(Modifier.height(12.dp))
                            Text(url!!, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
                        }
                        Column(Modifier.width(420.dp)) {
                            Text("Veltoret on your phone or tablet", style = MaterialTheme.typography.titleLarge, color = VColors.Amber)
                            Spacer(Modifier.height(8.dp))
                            Text(
                                "Open Settings, choose your network server, tap Send to TV, pick this TV and enter:",
                                style = MaterialTheme.typography.bodyLarge,
                                color = VColors.Text,
                            )
                            Spacer(Modifier.height(18.dp))
                            Text(
                                code.chunked(3).joinToString(" "),
                                style = MaterialTheme.typography.displayMedium,
                                color = VColors.Text,
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                "Sent encrypted. The code changes after a wrong try.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = VColors.TextMuted,
                            )
                        }
                    }
                }
            }
        }
    }
}

/** A QR code drawn as flat squares (dark on white, so phone cameras read it reliably). */
@Composable
private fun QrCode(text: String, modifier: Modifier = Modifier) {
    val matrix = remember(text) {
        com.google.zxing.qrcode.QRCodeWriter().encode(
            text, com.google.zxing.BarcodeFormat.QR_CODE, 0, 0,
            mapOf(com.google.zxing.EncodeHintType.MARGIN to 2),
        )
    }
    androidx.compose.foundation.Canvas(modifier.background(androidx.compose.ui.graphics.Color.White)) {
        val cell = size.minDimension / matrix.width
        for (y in 0 until matrix.height) for (x in 0 until matrix.width) {
            if (matrix.get(x, y)) {
                drawRect(
                    androidx.compose.ui.graphics.Color.Black,
                    topLeft = androidx.compose.ui.geometry.Offset(x * cell, y * cell),
                    size = androidx.compose.ui.geometry.Size(cell + 0.5f, cell + 0.5f),
                )
            }
        }
    }
}
