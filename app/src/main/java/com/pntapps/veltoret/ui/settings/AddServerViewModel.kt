package com.pntapps.veltoret.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.smb.FoundServer
import com.pntapps.veltoret.data.smb.SmbException
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.data.smb.SmbServer
import com.pntapps.veltoret.data.smb.SmbStorage
import com.pntapps.veltoret.ui.files.Crumb
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class AddServerState(
    /** Servers found on the network, routers and named ones first. */
    val found: List<FoundServer> = emptyList(),
    val scanning: Boolean = false,
    /** The found server the user chose; its name becomes the saved server's name. */
    val picked: FoundServer? = null,
    val busy: Boolean = false,
    val error: String? = null,
    /** Set once signed in and saved: the server and the folders the typed address pointed into. */
    val added: Pair<SmbServer, List<Crumb>>? = null,
)

/**
 * "Add network server" for phones, tablets and TV: finds servers on the network, checks the details by
 * signing in, then saves the server (password encrypted) and adds it as a library source. The screens
 * only hold the text fields.
 */
class AddServerViewModel(private val container: AppContainer) : ViewModel() {
    private val _state = MutableStateFlow(AddServerState())
    val state: StateFlow<AddServerState> = _state.asStateFlow()
    private var scanJob: Job? = null

    /** Starts afresh each time the screen opens (the view model outlives a closed dialog). */
    fun reset() {
        scanJob?.cancel()
        _state.value = AddServerState()
    }

    fun scan() {
        scanJob?.cancel()
        _state.update { it.copy(scanning = true, found = emptyList()) }
        scanJob = viewModelScope.launch {
            container.smbDiscovery.discover().collect { server ->
                // The sweep and the announcements can both find a server; keep one row, with the best name.
                _state.update { s ->
                    val existing = s.found.firstOrNull { it.address == server.address }
                    s.copy(
                        found = if (existing == null) (s.found + server).sortedWith(compareBy({ !it.isRouter }, { it.name == null }, { it.address }))
                        else s.found.map { if (it.address == server.address) it.copy(name = it.name ?: server.name, isRouter = it.isRouter || server.isRouter) else it },
                    )
                }
            }
            _state.update { it.copy(scanning = false) }
        }
    }

    fun pick(server: FoundServer) = _state.update { it.copy(picked = server, error = null) }

    fun showError(message: String?) = _state.update { it.copy(error = message) }

    fun consumeAdded() = _state.update { it.copy(added = null) }

    fun connect(address: String, guest: Boolean, username: String, password: String) {
        if (_state.value.busy) return
        val path = SmbPath.fromUserInput(address)
        if (path == null) {
            showError("Enter the server's address, like 192.168.0.10 or \\\\192.168.0.10\\Movies")
            return
        }
        if (!guest && username.isBlank()) {
            showError("Enter the username, or choose Guest if the server has no password")
            return
        }
        // "WORKGROUP\user" signs in to a Windows domain or workgroup.
        val (domain, user) = username.trim().let { if ('\\' in it) it.substringBefore('\\') to it.substringAfter('\\') else "" to it }
        val pickedName = _state.value.picked?.takeIf { it.address.equals(path.host, ignoreCase = true) }?.name
        var server = SmbServer(host = path.host, username = if (guest) "" else user, domain = if (guest) "" else domain, name = pickedName ?: path.host)
        val secret = if (guest) "" else password
        _state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
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
                // A typed address gets the server's own name ("MYNAS") instead of its number, like a found one.
                if (pickedName == null && path.host.all { it.isDigit() || it == '.' }) {
                    container.smbDiscovery.nameOf(path.host)?.let { server = server.copy(name = it) }
                }
                container.smbStorage.disconnect(server.account)
                container.smbServers.save(server, secret)
                container.accountRepository.addServerAccount(server)
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
                _state.update { it.copy(busy = false, added = server to crumbs) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val message = (e as? SmbException)?.message ?: SmbStorage.describe(e)
                _state.update {
                    it.copy(
                        busy = false,
                        // Servers refuse guests as a wrong login, or (Windows, whose Guest account is off) a disabled account.
                        error = if (guest && (message == SmbStorage.WRONG_LOGIN || message == SmbStorage.ACCOUNT_DISABLED))
                            "This server doesn't allow guests. Sign in with its username and password."
                        else message,
                    )
                }
            }
        }
    }
}
