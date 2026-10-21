package com.pntapps.veltoret.ui.settings

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Router
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.LaunchedEffect
import com.pntapps.veltoret.data.smb.FoundServer
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import kotlinx.coroutines.launch
import com.pntapps.veltoret.ui.util.container
import com.pntapps.veltoret.data.pairing.SetupReply
import com.pntapps.veltoret.data.pairing.PhoneSubmission
import com.pntapps.veltoret.data.pairing.FoundTv
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.pntapps.veltoret.data.smb.SmbServer
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.SelectChip
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.files.Crumb
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel
import com.pntapps.veltoret.ui.util.rememberLocalNetworkAccess
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * "Add network server": an address (typed or pasted, e.g. \\192.168.0.10\Movies), then a username and
 * password or guest access. The details are checked by signing in before anything is saved; on success
 * [onAdded] gets the server and the folders the address pointed into (to open the browser there).
 */
@Composable
fun AddServerDialog(onDismiss: () -> Unit, onAdded: (SmbServer, List<Crumb>) -> Unit) {
    val vm = appViewModel("add-server") { AddServerViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    var address by remember { mutableStateOf("") }
    var guest by remember { mutableStateOf(false) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    val busy = state.busy
    val withNetworkAccess = rememberLocalNetworkAccess { vm.showError(it) }
    fun connect() = vm.connect(address, guest, username, password)

    // Look as soon as the screen opens; most people don't know their server's address.
    LaunchedEffect(Unit) {
        vm.reset()
        withNetworkAccess { vm.scan() }
    }
    LaunchedEffect(state.added) {
        state.added?.let { (server, crumbs) ->
            vm.consumeAdded()
            onAdded(server, crumbs)
        }
    }

    Dialog(onDismissRequest = { if (!busy) onDismiss() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .imePadding()
        ) {
            ScreenHeader("Add network server", subtitle = "Shared folders on a router, NAS or computer") {
                VIconButton(Icons.Rounded.Close, "Close", onDismiss)
            }
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp)
                    .widthIn(max = 640.dp)
                    .align(Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    "Pick a server found on your Wi-Fi, or enter the address you'd use in Windows File Explorer. " +
                        "You can paste the full path to your movies folder, or just the server's address and pick the folder next.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = VColors.TextMuted,
                )
                FoundServers(
                    state.found, state.scanning, state.picked?.address,
                    onPick = { server -> vm.pick(server); address = server.address },
                    onScan = { withNetworkAccess { vm.scan() } },
                )
                VTextField(
                    address, { address = it; vm.showError(null) }, "Server address",
                    Modifier.fillMaxWidth(),
                    placeholder = "\\\\192.168.0.10\\Movies",
                    leadingIcon = Icons.Rounded.Dns,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SelectChip("Username and password", !guest, { guest = false; vm.showError(null) })
                    SelectChip("Guest", guest, { guest = true; vm.showError(null) })
                }
                if (!guest) {
                    VTextField(
                        username, { username = it; vm.showError(null) }, "Username",
                        Modifier.fillMaxWidth(),
                        leadingIcon = Icons.Rounded.Person,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Next, autoCorrectEnabled = false),
                    )
                    VTextField(
                        password, { password = it; vm.showError(null) }, "Password",
                        Modifier.fillMaxWidth(),
                        leadingIcon = Icons.Rounded.Lock,
                        visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done, autoCorrectEnabled = false),
                        keyboardActions = KeyboardActions(onDone = { if (!busy) withNetworkAccess { connect() } }),
                        trailing = {
                            IconButton({ showPassword = !showPassword }) {
                                Icon(
                                    if (showPassword) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                                    if (showPassword) "Hide password" else "Show password",
                                    tint = VColors.TextMuted,
                                )
                            }
                        },
                    )
                    Text(
                        "The password is stored encrypted on this device and is only sent to this server.",
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextFaint,
                    )
                }
                state.error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = VColors.Danger) }
                VButton(
                    if (busy) "Connecting…" else "Connect",
                    { withNetworkAccess { connect() } },
                    Modifier.fillMaxWidth(),
                    loading = busy,
                    enabled = !busy,
                )
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

/**
 * "Send to TV": hands this saved server, password included, to a TV showing "Use your phone", so nobody has
 * to type it with a remote. Finds the TVs on the network; the 6-digit code shown on the TV protects it.
 */
@Composable
fun SendToTvDialog(account: String, onDismiss: () -> Unit) {
    val container = LocalContext.current.container
    val scope = rememberCoroutineScope()
    val server = remember(account) { container.smbServers.server(account) }
    var tvs by remember { mutableStateOf<List<FoundTv>>(emptyList()) }
    var chosen by remember { mutableStateOf<FoundTv?>(null) }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<SetupReply?>(null) }
    var searching by remember { mutableStateOf(true) }
    val withNetworkAccess = rememberLocalNetworkAccess { result = SetupReply(false, it) }

    LaunchedEffect(Unit) {
        withNetworkAccess {
            scope.launch {
                // One entry per TV: a newer answer from the same TV replaces the older one.
                container.sendToTv.find().collect { tv ->
                    tvs = tvs.filterNot { it.host == tv.host } + tv
                    if (chosen?.host == tv.host) chosen = tv
                }
            }
            scope.launch { kotlinx.coroutines.delay(8_000); searching = false }
        }
    }

    fun send() {
        val tv = chosen ?: return
        val s = server ?: return
        val password = container.smbServers.password(account)
        if (password == null) {
            result = SetupReply(false, "This device can't read the saved password any more. Remove the server and add it again.")
            return
        }
        busy = true
        result = null
        scope.launch {
            result = container.sendToTv.send(
                tv, code,
                PhoneSubmission(
                    address = s.host,
                    guest = s.guest,
                    username = if (s.domain.isBlank()) s.username else "${s.domain}\\${s.username}",
                    password = password,
                    name = s.name,
                ),
            )
            busy = false
            // A wrong code makes the TV show a new one: clear the field for it.
            if (result?.ok == false && result?.message?.startsWith("That code") == true) code = ""
        }
    }

    Dialog(onDismissRequest = { if (!busy) onDismiss() }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .imePadding()
        ) {
            ScreenHeader("Send to TV", subtitle = server?.name ?: "") {
                VIconButton(Icons.Rounded.Close, "Close", onDismiss)
            }
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 20.dp)
                    .widthIn(max = 640.dp)
                    .align(Alignment.CenterHorizontally),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Text(
                    "On the TV, open Veltoret's Settings → Add network server → Use your phone. It shows a code; " +
                        "pick the TV here and enter it. The server and its password are sent encrypted.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = VColors.TextMuted,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("TVs on your network", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                    if (searching && tvs.isEmpty()) CircularProgressIndicator(Modifier.size(16.dp), color = VColors.Amber, strokeWidth = 2.dp)
                }
                if (tvs.isEmpty() && !searching) {
                    Text(
                        "No TV found. Check the TV is showing \"Use your phone\" and that both are on the same Wi-Fi.",
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextMuted,
                    )
                }
                tvs.forEach { tv ->
                    val selected = tv == chosen
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(if (selected) VColors.AmberDim else VColors.Surface)
                            .border(1.dp, if (selected) VColors.Amber else VColors.Outline, RoundedCornerShape(12.dp))
                            .clickable { chosen = tv; result = null }
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Rounded.Tv, null, tint = VColors.AmberSoft)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(tv.name, style = MaterialTheme.typography.bodyLarge)
                            Text(tv.host, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
                        }
                        if (selected) Icon(Icons.Rounded.CheckCircle, "Selected", tint = VColors.Amber)
                    }
                }
                if (chosen != null) {
                    VTextField(
                        code, { text -> code = text.filter(Char::isDigit).take(6); result = null }, "Code on the TV",
                        Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { if (code.length == 6 && !busy) send() }),
                    )
                }
                result?.let { Text(it.message, style = MaterialTheme.typography.bodyMedium, color = if (it.ok) VColors.Amber else VColors.Danger) }
                if (result?.ok == true) {
                    VButton("Done", onDismiss, Modifier.fillMaxWidth())
                } else {
                    VButton(
                        if (busy) "Sending…" else "Send",
                        { send() },
                        Modifier.fillMaxWidth(),
                        loading = busy,
                        enabled = !busy && chosen != null && code.length == 6,
                    )
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

/** "On your network": servers found by [com.pntapps.veltoret.data.smb.SmbDiscovery], tap one to use it. */
@Composable
private fun FoundServers(found: List<FoundServer>, scanning: Boolean, selected: String?, onPick: (FoundServer) -> Unit, onScan: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("On your network", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            if (scanning) {
                CircularProgressIndicator(Modifier.size(16.dp), color = VColors.Amber, strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
                Text("Searching…", style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
            } else {
                TextButton(onScan) {
                    Icon(Icons.Rounded.Refresh, null, tint = VColors.Amber, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Scan again", color = VColors.Amber)
                }
            }
        }
        if (found.isEmpty() && !scanning) {
            Text(
                "No servers found. Check that this device is on the same Wi-Fi as the server, or type its address below.",
                style = MaterialTheme.typography.bodySmall,
                color = VColors.TextMuted,
            )
        }
        found.forEach { server ->
            val isSelected = server.address == selected
            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (isSelected) VColors.AmberDim else VColors.Surface)
                    .border(1.dp, if (isSelected) VColors.Amber else VColors.Outline, RoundedCornerShape(12.dp))
                    .clickable { onPick(server) }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(if (server.isRouter) Icons.Rounded.Router else Icons.Rounded.Dns, null, tint = VColors.AmberSoft)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(server.name ?: if (server.isRouter) "Your router" else "File server", style = MaterialTheme.typography.bodyLarge)
                    Text(
                        if (server.isRouter) "${server.address} · router" else server.address,
                        style = MaterialTheme.typography.bodySmall,
                        color = VColors.TextMuted,
                    )
                }
                if (isSelected) Icon(Icons.Rounded.CheckCircle, "Selected", tint = VColors.Amber)
            }
        }
    }
}
