package com.pntapps.veltoret.data.smb

import android.webkit.MimeTypeMap
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.mserref.NtStatus
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.protocol.transport.TransportException
import com.hierynomus.security.bc.BCSecurityProvider
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.common.SMBRuntimeException
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File
import com.pntapps.veltoret.data.drive.DriveCapabilities
import com.pntapps.veltoret.data.drive.DriveFile
import com.rapid7.client.dcerpc.mssrvs.ServerService
import com.rapid7.client.dcerpc.transport.SMBTransportFactories
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.time.Instant
import java.util.EnumSet
import java.util.concurrent.TimeUnit

/** A network share problem, worded for people (wrong password, server off, folder gone…). */
class SmbException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * File access on SMB servers (Windows sharing, Samba on routers and NAS boxes) through smbj, SMB 2 and 3.
 * One signed-in session per server is kept and reused; a dropped connection is reopened once per call.
 * Folders and files come back as [DriveFile]s so the rest of the app can treat every source alike.
 */
class SmbStorage(private val servers: SmbServerStore) {

    private val client = SMBClient(
        SmbConfig.builder()
            // Android's built-in crypto lacks MD4 and friends that NTLM sign-in needs.
            .withSecurityProvider(BCSecurityProvider())
            .withMultiProtocolNegotiate(true)
            // How long one request may wait for its answer. No socket read timeout (soTimeout): the player
            // stops reading for a minute or more once its buffer is full, and a read timeout on the idle
            // connection kills smbj's packet reader while the connection still reports itself connected,
            // so the next request waited for an answer that never came.
            .withTimeout(20, TimeUnit.SECONDS)
            .build()
    )
    private val sessions = HashMap<String, Session>()
    /** Hosts whose connection failed outside [withSession] (a player read); their next call reconnects. */
    private val broken: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()
    /** Open shares by "host/share"; they belong to the host's current session. */
    private val shares = HashMap<String, DiskShare>()
    private val mutex = Mutex()

    /**
     * Signs in to [server] with [password] without saving anything, and lists its shares. Used by
     * "Add network server" to check the details before they're stored.
     */
    suspend fun test(server: SmbServer, password: String): List<String> = io {
        val session = open(server, password)
        try {
            shareNames(session)
        } finally {
            runCatching { session.connection.close() }
        }
    }

    /** The server's shares, or the folders and files inside [folderId]. */
    suspend fun list(folderId: String): List<DriveFile> {
        val path = SmbPath.parse(folderId)
        return if (path.share == null) {
            withSession(path.host) { session -> shareNames(session).map { folder(path.child(it)) } }
        } else {
            withShare(path) { share ->
                share.list(path.sharePath)
                    .filter { info ->
                        val name = info.fileName
                        name != "." && name != ".." &&
                            info.fileAttributes and (FileAttributes.FILE_ATTRIBUTE_HIDDEN.value or FileAttributes.FILE_ATTRIBUTE_SYSTEM.value) == 0L
                    }
                    .map { info ->
                        val child = path.child(info.fileName)
                        if (info.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L) folder(child, path.id)
                        else DriveFile(
                            id = child.id,
                            name = info.fileName,
                            mimeType = mimeFor(info.fileName),
                            size = info.endOfFile.toString(),
                            modifiedTime = info.lastWriteTime?.toEpochMillis()?.takeIf { it > 0 }?.let { Instant.ofEpochMilli(it).toString() },
                            parents = listOf(path.id),
                            capabilities = CAPABILITIES,
                        )
                    }
                    .sortedWith(compareBy<DriveFile> { !it.isFolder }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
            }
        }
    }

    /** Opens a file for reading from the start (subtitles and other small files). */
    suspend fun <T> read(fileId: String, block: suspend (InputStream) -> T): T {
        val path = SmbPath.parse(fileId)
        val file = withShare(path) { share -> openForReading(share, path) }
        return try {
            file.inputStream.use { block(it) }
        } finally {
            runCatching { file.close() }
        }
    }

    /** Opens a video for the player: random-access reads from any position. Close it when done. */
    suspend fun openReader(fileId: String): SmbReader {
        val path = SmbPath.parse(fileId)
        return withShare(path) { share ->
            val file = openForReading(share, path)
            try {
                SmbReader(file, file.fileInformation.standardInformation.endOfFile) { e -> if (isDropped(e)) broken += path.host }
            } catch (e: Exception) {
                runCatching { file.close() }
                throw e
            }
        }
    }

    /** Returns the new id (it's the path, so it changes). */
    suspend fun rename(id: String, newName: String): String {
        val path = SmbPath.parse(id)
        require(path.segments.isNotEmpty()) { "Shared folders can't be renamed from here" }
        val target = path.parent!!.child(newName)
        withShare(path) { share -> moveEntry(share, path, target) }
        return target.id
    }

    /** Moves within the same shared folder (SMB can't move between shares in one step). */
    suspend fun move(id: String, toFolder: String): String {
        val path = SmbPath.parse(id)
        val folder = SmbPath.parse(toFolder)
        if (folder.host != path.host || folder.share != path.share) throw SmbException("Files can only be moved within the same shared folder")
        val target = folder.child(path.name)
        withShare(path) { share -> moveEntry(share, path, target) }
        return target.id
    }

    /** Deletes permanently (network shares have no trash); folders with everything in them. */
    suspend fun delete(id: String) {
        val path = SmbPath.parse(id)
        require(path.segments.isNotEmpty()) { "Shared folders can't be deleted from here" }
        withShare(path) { share ->
            if (share.folderExists(path.sharePath)) share.rmdir(path.sharePath, true) else share.rm(path.sharePath)
        }
    }

    suspend fun createFolder(parentId: String, name: String) {
        val path = SmbPath.parse(parentId).child(name)
        withShare(path) { share -> share.mkdir(path.sharePath) }
    }

    /** Forgets the open session, e.g. after the server was removed or its password changed. */
    suspend fun disconnect(account: String) = mutex.withLock {
        val host = SmbPath.parse(account).host
        synchronized(shares) { shares.keys.removeAll { it.startsWith("$host/") } }
        sessions.remove(host)?.let { runCatching { it.connection.close() } }
    }

    // ---------------------------------------------------------------------------------------------

    private fun openForReading(share: DiskShare, path: SmbPath): File = share.openFile(
        path.sharePath,
        EnumSet.of(AccessMask.GENERIC_READ),
        null,
        EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ, SMB2ShareAccess.FILE_SHARE_WRITE, SMB2ShareAccess.FILE_SHARE_DELETE),
        SMB2CreateDisposition.FILE_OPEN,
        null,
    )

    private fun moveEntry(share: DiskShare, from: SmbPath, to: SmbPath) {
        share.open(
            from.sharePath,
            EnumSet.of(AccessMask.DELETE, AccessMask.GENERIC_READ),
            null,
            EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ, SMB2ShareAccess.FILE_SHARE_WRITE, SMB2ShareAccess.FILE_SHARE_DELETE),
            SMB2CreateDisposition.FILE_OPEN,
            null,
        ).use { it.rename(to.sharePath, false) }
    }

    private fun open(server: SmbServer, password: String): Session {
        val connection = client.connect(server.host, server.port)
        return try {
            connection.authenticate(
                if (server.guest) AuthenticationContext.guest()
                else AuthenticationContext(server.username, password.toCharArray(), server.domain.ifBlank { null })
            )
        } catch (e: Exception) {
            runCatching { connection.close() }
            throw e
        }
    }

    private suspend fun session(host: String, fresh: Boolean): Session = mutex.withLock {
        val existing = sessions[host]
        val stale = broken.remove(host)
        if (!fresh && !stale && existing != null && existing.connection.isConnected) return existing
        existing?.let { runCatching { it.connection.close() } }
        synchronized(shares) { shares.keys.removeAll { it.startsWith("$host/") } }
        val account = SmbPath.account(host)
        val server = servers.server(account) ?: throw SmbException("This network server was removed from Veltoret")
        val password = servers.password(account) ?: throw SmbException("Sign in to ${server.name} again")
        open(server, password).also { sessions[host] = it }
    }

    /** Runs [block] with a signed-in session, reconnecting once if the old connection went stale. */
    private suspend fun <T> withSession(host: String, block: (Session) -> T): T = io {
        try {
            block(session(host, fresh = false))
        } catch (e: Exception) {
            if (!isDropped(e)) throw e
            block(session(host, fresh = true))
        }
    }

    private suspend fun <T> withShare(path: SmbPath, block: (DiskShare) -> T): T {
        val shareName = path.share ?: throw SmbException("Pick a shared folder on ${path.host} first")
        return withSession(path.host) { session -> block(share(session, path.host, shareName)) }
    }

    private fun share(session: Session, host: String, name: String): DiskShare = synchronized(shares) {
        val key = "$host/$name"
        shares[key]?.takeIf { it.isConnected && it.treeConnect.session == session }?.let { return it }
        val share = session.connectShare(name) as? DiskShare ?: throw SmbException("\"$name\" isn't a shared folder")
        shares[key] = share
        share
    }

    /** Disk shares people can browse: no printers, IPC$ or hidden admin shares (ending in $). */
    private fun shareNames(session: Session): List<String> {
        val transport = SMBTransportFactories.SRVSVC.getTransport(session)
        return ServerService(transport).shares1
            .filter { it.type and 0xFF == STYPE_DISKTREE && !it.netName.endsWith("$") }
            .map { it.netName }
            .sortedWith(String.CASE_INSENSITIVE_ORDER)
    }

    private fun folder(path: SmbPath, parent: String? = null) = DriveFile(
        id = path.id,
        name = path.name,
        mimeType = DriveFile.FOLDER_MIME,
        parents = listOfNotNull(parent),
        capabilities = CAPABILITIES,
    )

    private fun isDropped(e: Throwable): Boolean = when (e) {
        is SmbException -> false // our own, already-worded problems (removed server, not a shared folder…)
        is TransportException, is java.util.concurrent.TimeoutException, is java.io.IOException -> true
        is SMBApiException -> e.status == NtStatus.STATUS_NETWORK_NAME_DELETED || e.status == NtStatus.STATUS_USER_SESSION_DELETED
        is SMBRuntimeException -> e.cause?.let(::isDropped) == true
        else -> false
    }

    private suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) {
        try {
            block()
        } catch (e: SmbException) {
            throw e
        } catch (e: Exception) {
            throw SmbException(describe(e), e)
        }
    }

    companion object {
        private const val STYPE_DISKTREE = 0
        const val WRONG_LOGIN = "Wrong username or password"
        private val CAPABILITIES = DriveCapabilities(canRename = true, canTrash = true, canDelete = true, canAddChildren = true)

        fun mimeFor(name: String): String =
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
                ?: "application/octet-stream"

        /** A sentence for the user. Unknown errors keep their own message. */
        fun describe(e: Throwable): String {
            var cause: Throwable? = e
            while (cause != null) {
                when (cause) {
                    is UnknownHostException -> return "Couldn't find that server on your network. Check the address."
                    is NoRouteToHostException, is ConnectException, is SocketTimeoutException ->
                        return "Couldn't reach the server. Check that it's on and that you're on the same Wi-Fi."
                    is SMBApiException -> when (cause.status) {
                        NtStatus.STATUS_LOGON_FAILURE -> return WRONG_LOGIN
                        NtStatus.STATUS_ACCOUNT_DISABLED -> return "This user account is disabled on the server"
                        NtStatus.STATUS_PASSWORD_EXPIRED -> return "This user's password has expired on the server"
                        NtStatus.STATUS_ACCESS_DENIED -> return "This user isn't allowed to open that folder"
                        NtStatus.STATUS_BAD_NETWORK_NAME -> return "The server has no shared folder with that name"
                        NtStatus.STATUS_OBJECT_NAME_NOT_FOUND, NtStatus.STATUS_OBJECT_PATH_NOT_FOUND ->
                            return "That folder or file isn't on the server any more"
                        NtStatus.STATUS_NOT_SUPPORTED -> return "The server doesn't support this"
                        else -> Unit
                    }
                    is TransportException -> return "The connection to the server was lost"
                }
                cause = cause.cause
            }
            return e.message ?: "Something went wrong talking to the server"
        }
    }
}

/**
 * An open file on a share for random-access reads (the player's data source). Not thread-safe.
 * [onError] hears about failed reads so a dead connection is replaced when the player retries.
 */
class SmbReader(private val file: File, val size: Long, private val onError: (Throwable) -> Unit) : java.io.Closeable {
    /** Reads up to [length] bytes at [position]; returns -1 at the end of the file. */
    fun read(position: Long, buffer: ByteArray, offset: Int, length: Int): Int {
        if (position >= size) return -1
        val n = try {
            file.read(buffer, position, offset, minOf(length.toLong(), size - position).toInt())
        } catch (e: Exception) {
            onError(e)
            throw e
        }
        return if (n <= 0) -1 else n
    }

    override fun close() {
        runCatching { file.close() }
    }
}
