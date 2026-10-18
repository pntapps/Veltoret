package com.pntapps.veltoret.ui.settings

import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Router
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.core.content.ContextCompat
import com.pntapps.veltoret.data.smb.FoundServer
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.FolderOpen
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.pntapps.veltoret.ui.util.container
import com.pntapps.veltoret.data.smb.SmbException
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.data.smb.SmbServer
import com.pntapps.veltoret.data.smb.SmbStorage
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.Panel
import com.pntapps.veltoret.ui.components.ScreenHeader
import com.pntapps.veltoret.ui.components.SelectChip
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.files.Crumb
import com.pntapps.veltoret.ui.theme.VColors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * "Add network server": an address (typed or pasted, e.g. \\192.168.0.10\Movies), then a username and
 * password or guest access. The details are checked by signing in before anything is saved; on success
 * [onAdded] gets the server and the folders the address pointed into (to open the browser there).
 */
@Composable
fun AddServerDialog(onDismiss: () -> Unit, onAdded: (SmbServer, List<Crumb>) -> Unit) {
    val container = LocalContext.current.container
    val scope = rememberCoroutineScope()
    var address by remember { mutableStateOf("") }
    var guest by remember { mutableStateOf(false) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPassword by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Servers found on the network; [picked] remembers the chosen one's name for the saved server.
    var found by remember { mutableStateOf<List<FoundServer>>(emptyList()) }
    var scanning by remember { mutableStateOf(false) }
    var scanRound by remember { mutableIntStateOf(0) }
    var picked by remember { mutableStateOf<FoundServer?>(null) }
    val withNetworkAccess = rememberLocalNetworkAccess { error = it }

    LaunchedEffect(scanRound) {
        if (scanRound == 0) return@LaunchedEffect
        scanning = true
        found = emptyList()
        container.smbDiscovery.discover().collect { server ->
            // The sweep and the announcements can both find a server; keep one row, with the best name.
            val existing = found.firstOrNull { it.address == server.address }
            found = if (existing == null) (found + server).sortedWith(compareBy({ !it.isRouter }, { it.name == null }, { it.address }))
            else found.map { if (it.address == server.address) it.copy(name = it.name ?: server.name, isRouter = it.isRouter || server.isRouter) else it }
        }
        scanning = false
    }
    // Look as soon as the screen opens; most people don't know their server's address.
    LaunchedEffect(Unit) { withNetworkAccess { scanRound++ } }

    fun connect() {
        val path = SmbPath.fromUserInput(address)
        if (path == null) {
            error = "Enter the server's address, like 192.168.0.10 or \\\\192.168.0.10\\Movies"
            return
        }
        if (!guest && username.isBlank()) {
            error = "Enter the username, or choose Guest if the server has no password"
            return
        }
        // "WORKGROUP\user" signs in to a Windows domain or workgroup.
        val (domain, user) = username.trim().let { if ('\\' in it) it.substringBefore('\\') to it.substringAfter('\\') else "" to it }
        val name = picked?.takeIf { it.address.equals(path.host, ignoreCase = true) }?.name ?: path.host
        val server = SmbServer(host = path.host, username = if (guest) "" else user, domain = if (guest) "" else domain, name = name)
        val secret = if (guest) "" else password
        busy = true
        error = null
        scope.launch {
            try {
                val shares = container.smbStorage.test(server, secret)
                // Match the typed share to the server's spelling ("movies" → "Movies").
                val share = path.share?.let { typed ->
                    shares.firstOrNull { it.equals(typed, ignoreCase = true) }
                        ?: throw SmbException(
                            "There's no shared folder called \"$typed\" on ${server.host}." +
                                if (shares.isEmpty()) "" else " It shares: ${shares.joinToString(", ")}"
                        )
                }
                container.smbStorage.disconnect(server.account)
                container.smbServers.save(server, secret)
                var crumbPath = SmbPath(server.host, null, emptyList())
                val crumbs = buildList {
                    if (share != null) {
                        crumbPath = crumbPath.child(share)
                        add(Crumb(crumbPath.id, share))
                        path.segments.forEach { segment ->
                            crumbPath = crumbPath.child(segment)
                            add(Crumb(crumbPath.id, segment))
                        }
                    }
                }
                onAdded(server, crumbs)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val message = (e as? SmbException)?.message ?: SmbStorage.describe(e)
                error = if (guest && message == SmbStorage.WRONG_LOGIN) "This server doesn't allow guests. Sign in with its username and password." else message
            } finally {
                busy = false
            }
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
                    found, scanning, picked?.address,
                    onPick = { server -> picked = server; address = server.address; error = null },
                    onScan = { withNetworkAccess { scanRound++ } },
                )
                VTextField(
                    address, { address = it; error = null }, "Server address",
                    Modifier.fillMaxWidth(),
                    placeholder = "\\\\192.168.0.10\\Movies",
                    leadingIcon = Icons.Rounded.Dns,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SelectChip("Username and password", !guest, { guest = false; error = null })
                    SelectChip("Guest", guest, { guest = true; error = null })
                }
                if (!guest) {
                    VTextField(
                        username, { username = it; error = null }, "Username",
                        Modifier.fillMaxWidth(),
                        leadingIcon = Icons.Rounded.Person,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Next, autoCorrectEnabled = false),
                    )
                    VTextField(
                        password, { password = it; error = null }, "Password",
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
                error?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = VColors.Danger) }
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

/**
 * Runs an action that talks to the local network, first asking for Android 17's "local network"
 * permission (ACCESS_LOCAL_NETWORK, in Nearby devices) when needed. Earlier versions don't need it.
 * [onDenied] gets a sentence to show when the user says no.
 */
@Composable
fun rememberLocalNetworkAccess(onDenied: (String) -> Unit): (() -> Unit) -> Unit {
    val context = LocalContext.current
    val denied by rememberUpdatedState(onDenied)
    var pending by remember { mutableStateOf<(() -> Unit)?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val action = pending
        pending = null
        if (granted) action?.invoke()
        else denied("Veltoret needs the \"Nearby devices\" permission to reach servers on your network. You can allow it in Android's app settings.")
    }
    return remember {
        { action ->
            if (Build.VERSION.SDK_INT < LOCAL_NETWORK_SDK ||
                ContextCompat.checkSelfPermission(context, LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED
            ) {
                action()
            } else {
                pending = action
                launcher.launch(LOCAL_NETWORK_PERMISSION)
            }
        }
    }
}

// Android 17 (API 37) enforces local network access for apps targeting it.
private const val LOCAL_NETWORK_SDK = 37
private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
