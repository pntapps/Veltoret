package com.pntapps.veltoret.data.storage

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import com.pntapps.veltoret.data.drive.DriveCapabilities
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.ui.util.isTv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.time.Instant

/**
 * Video folders on this device — internal storage, SD cards and USB drives — reached through the
 * Storage Access Framework. The user grants each folder once with the system folder picker; no broad
 * storage permission is needed. Items are exposed as [DriveFile]s whose ids are document URIs, so the
 * rest of the app can treat both sources the same way.
 */
class LocalStorage(private val context: Context) {

    private val resolver get() = context.contentResolver

    /** The TV path: videos indexed by Android, used where the folder picker doesn't exist. */
    val media = MediaLibrary(context)

    /** Keeps access to a folder picked with ACTION_OPEN_DOCUMENT_TREE and returns it as a folder item. */
    suspend fun adopt(treeUri: Uri): DriveFile = withContext(Dispatchers.IO) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        runCatching { resolver.takePersistableUriPermission(treeUri, flags) }
            .onFailure { resolver.takePersistableUriPermission(treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        val doc = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        describe(doc) ?: throw FileNotFoundException("That folder isn't available")
    }

    /** Folders the user has granted (plus, on TVs, each storage volume), shown as the top level of "This device". */
    suspend fun roots(): List<DriveFile> = withContext(Dispatchers.IO) {
        grantedRoots() + if (media.folderPickerAvailable) emptyList() else media.roots()
    }

    private fun grantedRoots(): List<DriveFile> =
        resolver.persistedUriPermissions
            .filter { it.isReadPermission && DocumentsContract.isTreeUri(it.uri) }
            .mapNotNull { perm ->
                runCatching {
                    describe(DocumentsContract.buildDocumentUriUsingTree(perm.uri, DocumentsContract.getTreeDocumentId(perm.uri)))
                }.getOrNull()
            }
            .sortedBy { it.name.lowercase() }

    suspend fun listChildren(folderId: String): List<DriveFile> = withContext(Dispatchers.IO) {
        if (MediaLibrary.isMediaLibraryId(folderId)) return@withContext media.listChildren(folderId)
        val folder = Uri.parse(folderId)
        val tree = treeOf(folder)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(folder))
        resolver.query(children, COLUMNS, null, null, null)?.use { c ->
            buildList {
                while (c.moveToNext()) {
                    val uri = DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))
                    add(toFile(uri, c.getString(1), c.getString(2), c.getLongOrNull(3), c.getLongOrNull(4), c.getInt(5), folderId))
                }
            }
        } ?: throw FileNotFoundException("This folder isn't available. If it's on an SD card or USB drive, make sure it's connected.")
    }

    /** Renames and returns the item's new id (document URIs can change on rename). */
    suspend fun rename(id: String, newName: String): String = withContext(Dispatchers.IO) {
        readOnlyCheck(id)
        (DocumentsContract.renameDocument(resolver, Uri.parse(id), newName) ?: Uri.parse(id)).toString()
    }

    suspend fun delete(id: String) = withContext(Dispatchers.IO) {
        readOnlyCheck(id)
        if (!DocumentsContract.deleteDocument(resolver, Uri.parse(id))) throw FileNotFoundException("Couldn't delete it")
    }

    suspend fun move(id: String, fromParent: String, toParent: String): String = withContext(Dispatchers.IO) {
        readOnlyCheck(id)
        try {
            DocumentsContract.moveDocument(resolver, Uri.parse(id), Uri.parse(fromParent), Uri.parse(toParent))?.toString()
                ?: throw UnsupportedOperationException()
        } catch (e: UnsupportedOperationException) {
            throw UnsupportedOperationException("This storage doesn't support moving files between these folders")
        }
    }

    suspend fun createFolder(parentId: String, name: String): String = withContext(Dispatchers.IO) {
        readOnlyCheck(parentId)
        DocumentsContract.createDocument(resolver, Uri.parse(parentId), Document.MIME_TYPE_DIR, name)?.toString()
            ?: throw FileNotFoundException("Couldn't create the folder here")
    }

    /** Space on the volume holding [folderId] (internal storage at the top level), or null for other providers. */
    suspend fun space(folderId: String): StorageSpace? = withContext(Dispatchers.IO) {
        val dir = volumeOf(folderId) ?: return@withContext null
        runCatching {
            val stat = StatFs(dir.path)
            val name = when {
                !dir.path.startsWith("/storage/emulated/") -> media.volumeLabel(dir.path)
                context.isTv() -> MediaLibrary.INTERNAL_LABEL
                else -> "Internal storage"
            }
            StorageSpace(name, stat.totalBytes - stat.availableBytes, stat.totalBytes, stat.availableBytes)
        }.getOrNull()
    }

    /**
     * The volume's directory for a folder: internal storage, an SD card or a USB drive. Only folders from
     * Android's own storage provider ("primary:Movies", "1A2B-3C4D:Films") and the TV media library are known.
     */
    @Suppress("DEPRECATION") // getExternalStorageDirectory is only used for its path, for StatFs.
    fun volumeOf(folderId: String): File? {
        val internal = Environment.getExternalStorageDirectory()
        if (folderId == ROOT) return internal
        if (folderId.startsWith(MediaLibrary.PREFIX)) return media.storageRoot(folderId.removePrefix(MediaLibrary.PREFIX))?.let(::File)
        val uri = runCatching { Uri.parse(folderId) }.getOrNull() ?: return null
        if (uri.authority != EXTERNAL_STORAGE_AUTHORITY) return null
        val volume = runCatching { DocumentsContract.getDocumentId(uri) }.getOrNull()?.substringBefore(':') ?: return null
        if (volume == "primary" || volume == "home") return internal
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.getSystemService(StorageManager::class.java).storageVolumes
                .firstOrNull { it.uuid == volume }?.directory?.let { return it }
        }
        return File("/storage/$volume")
    }

    fun open(id: String): InputStream =
        resolver.openInputStream(Uri.parse(id)) ?: throw FileNotFoundException("This file isn't available")

    /** Gives back access to a granted folder (when it's removed from the library). */
    fun release(folderId: String) {
        val tree = runCatching { treeOf(Uri.parse(folderId)) }.getOrNull() ?: return
        resolver.persistedUriPermissions.filter { it.uri == tree }.forEach {
            runCatching {
                resolver.releasePersistableUriPermission(
                    tree,
                    (if (it.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                        (if (it.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0),
                )
            }
        }
    }

    private fun readOnlyCheck(id: String) {
        if (MediaLibrary.isMediaLibraryId(id)) {
            throw UnsupportedOperationException("Files in the TV's media library can't be changed from here")
        }
    }

    private fun describe(doc: Uri): DriveFile? =
        resolver.query(doc, COLUMNS, null, null, null)?.use { c ->
            if (!c.moveToFirst()) null
            else toFile(doc, c.getString(1), c.getString(2), c.getLongOrNull(3), c.getLongOrNull(4), c.getInt(5), null)
        }

    private fun toFile(uri: Uri, name: String?, mime: String?, size: Long?, modified: Long?, flags: Int, parent: String?) = DriveFile(
        id = uri.toString(),
        name = name ?: "Untitled",
        mimeType = if (mime == Document.MIME_TYPE_DIR) DriveFile.FOLDER_MIME else (mime ?: "application/octet-stream"),
        size = size?.toString(),
        modifiedTime = modified?.takeIf { it > 0 }?.let { Instant.ofEpochMilli(it).toString() },
        parents = listOfNotNull(parent),
        capabilities = DriveCapabilities(
            canRename = flags and Document.FLAG_SUPPORTS_RENAME != 0,
            canTrash = flags and Document.FLAG_SUPPORTS_DELETE != 0,
            canDelete = flags and Document.FLAG_SUPPORTS_DELETE != 0,
            canAddChildren = flags and Document.FLAG_DIR_SUPPORTS_CREATE != 0,
        ),
    )

    private fun treeOf(doc: Uri): Uri = DocumentsContract.buildTreeDocumentUri(doc.authority, DocumentsContract.getTreeDocumentId(doc))

    private fun android.database.Cursor.getLongOrNull(i: Int) = if (isNull(i)) null else getLong(i)

    companion object {
        /** Pseudo-account id for files on this device. */
        const val ACCOUNT = "device"
        const val DISPLAY_NAME = "This device"
        /** Top level of "This device" in the Files tab: the list of granted folders. */
        const val ROOT = "device-root"
        private const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"

        fun isLocal(account: String?) = account == ACCOUNT

        private val COLUMNS = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_FLAGS,
        )
    }
}
