package com.pntapps.veltoret.data.storage

import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.drive.DriveRepository
import java.io.InputStream

/**
 * One front door for both file sources. [account] is a Google account email, or
 * [LocalStorage.ACCOUNT] for folders on this device.
 */
class Storage(private val drive: DriveRepository, val local: LocalStorage) {

    fun isLocal(account: String?) = LocalStorage.isLocal(account)

    fun rootId(account: String) = if (isLocal(account)) LocalStorage.ROOT else DriveRepository.ROOT
    fun rootName(account: String) = if (isLocal(account)) LocalStorage.DISPLAY_NAME else "My Drive"

    suspend fun list(account: String, folderId: String, orderBy: String = "folder,name_natural"): List<DriveFile> = when {
        !isLocal(account) -> drive.listChildren(account, folderId, orderBy)
        folderId == LocalStorage.ROOT -> local.roots()
        else -> local.listChildren(folderId)
    }

    /** Drive searches the whole account; on the device we filter the folder being shown. */
    suspend fun search(account: String, query: String, currentFolder: String): List<DriveFile> =
        if (isLocal(account)) list(account, currentFolder).filter { it.name.contains(query, ignoreCase = true) }
        else drive.search(account, query)

    /** Returns the item's id afterwards (it can change for device files). */
    suspend fun rename(account: String, id: String, newName: String): String =
        if (isLocal(account)) local.rename(id, newName) else drive.rename(account, id, newName).id

    /** Drive: to trash (recoverable). Device: deleted permanently. */
    suspend fun remove(account: String, id: String) {
        if (isLocal(account)) local.delete(id) else drive.trash(account, id)
    }

    suspend fun move(account: String, id: String, fromParent: String?, toParent: String) {
        if (isLocal(account)) local.move(id, fromParent ?: error("Unknown source folder"), toParent)
        else drive.move(account, id, fromParent, toParent)
    }

    suspend fun createFolder(account: String, parentId: String, name: String) {
        if (isLocal(account)) local.createFolder(parentId, name) else drive.createFolder(account, parentId, name)
    }

    /** Reads a whole (small) file, e.g. a subtitle. */
    suspend fun <T> read(account: String, id: String, block: suspend (InputStream) -> T): T =
        if (isLocal(account)) kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { local.open(id).use { block(it) } }
        else drive.download(account, id) { input, _ -> block(input) }
}
