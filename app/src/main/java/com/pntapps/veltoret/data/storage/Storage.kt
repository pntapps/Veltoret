package com.pntapps.veltoret.data.storage

import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.drive.DriveRepository
import com.pntapps.veltoret.data.smb.SmbPath
import com.pntapps.veltoret.data.smb.SmbServerStore
import com.pntapps.veltoret.data.smb.SmbStorage
import java.io.InputStream

/**
 * One front door for every file source. [account] is a Google account email, [LocalStorage.ACCOUNT] for
 * folders on this device, or "smb://host" for a network share server ([SmbPath.isSmb]).
 */
class Storage(
    private val drive: DriveRepository,
    val local: LocalStorage,
    val smb: SmbStorage,
    private val smbServers: SmbServerStore,
) {

    fun isLocal(account: String?) = LocalStorage.isLocal(account)
    fun isSmb(account: String?) = SmbPath.isSmb(account)

    fun rootId(account: String) = when {
        isLocal(account) -> LocalStorage.ROOT
        isSmb(account) -> account
        else -> DriveRepository.ROOT
    }

    fun rootName(account: String) = when {
        isLocal(account) -> LocalStorage.DISPLAY_NAME
        isSmb(account) -> smbServers.server(account)?.name ?: SmbPath.parse(account).host
        else -> "My Drive"
    }

    suspend fun list(account: String, folderId: String, orderBy: String = "folder,name_natural"): List<DriveFile> = when {
        isSmb(account) -> smb.list(folderId)
        !isLocal(account) -> drive.listChildren(account, folderId, orderBy)
        folderId == LocalStorage.ROOT -> local.roots()
        else -> local.listChildren(folderId)
    }

    /** Drive searches the whole account; on the device and network shares we filter the folder being shown. */
    suspend fun search(account: String, query: String, currentFolder: String): List<DriveFile> =
        if (isLocal(account) || isSmb(account)) list(account, currentFolder).filter { it.name.contains(query, ignoreCase = true) }
        else drive.search(account, query)

    /** Returns the item's id afterwards (it can change for device files). */
    suspend fun rename(account: String, id: String, newName: String): String = when {
        isSmb(account) -> smb.rename(id, newName)
        isLocal(account) -> local.rename(id, newName)
        else -> drive.rename(account, id, newName).id
    }

    /** Drive: to trash (recoverable). Device and network servers: deleted permanently. */
    suspend fun remove(account: String, id: String) {
        when {
            isSmb(account) -> smb.delete(id)
            isLocal(account) -> local.delete(id)
            else -> drive.trash(account, id)
        }
    }

    suspend fun move(account: String, id: String, fromParent: String?, toParent: String) {
        when {
            isSmb(account) -> smb.move(id, toParent)
            isLocal(account) -> local.move(id, fromParent ?: error("Unknown source folder"), toParent)
            else -> drive.move(account, id, fromParent, toParent)
        }
    }

    suspend fun createFolder(account: String, parentId: String, name: String) {
        when {
            isSmb(account) -> smb.createFolder(parentId, name)
            isLocal(account) -> local.createFolder(parentId, name)
            else -> drive.createFolder(account, parentId, name)
        }
    }

    /** Reads a whole (small) file, e.g. a subtitle. */
    suspend fun <T> read(account: String, id: String, block: suspend (InputStream) -> T): T = when {
        isSmb(account) -> smb.read(id, block)
        isLocal(account) -> kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { local.open(id).use { block(it) } }
        else -> drive.download(account, id) { input, _ -> block(input) }
    }
}
