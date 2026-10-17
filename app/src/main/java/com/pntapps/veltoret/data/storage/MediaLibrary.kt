package com.pntapps.veltoret.data.storage

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.storage.StorageManager
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import com.pntapps.veltoret.data.drive.DriveCapabilities
import com.pntapps.veltoret.data.drive.DriveFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant

/**
 * Videos on devices without the system folder picker, mainly Google TV / Android TV. Android indexes
 * every video on internal storage and plugged-in USB drives in MediaStore; this presents that index
 * as folders (by file path) so users still pick which folders are Movies and which are TV Shows.
 *
 * Folder ids look like `ms:/storage/emulated/0/Movies`; file ids are MediaStore content URIs, which
 * the player opens like any other content URI. Files here are read-only: the media library doesn't
 * let apps rename, move or delete other apps' files without a system prompt per file.
 */
class MediaLibrary(private val context: Context) {

    /** TVs ship a stub instead of the real folder picker; phones and tablets have the real one. */
    val folderPickerAvailable: Boolean by lazy {
        val pkg = context.packageManager
            .resolveActivity(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PackageManager.MATCH_DEFAULT_ONLY)
            ?.activityInfo?.packageName
        pkg != null && !pkg.contains("frameworkpackagestubs")
    }

    val permission: String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Manifest.permission.READ_MEDIA_VIDEO
        else Manifest.permission.READ_EXTERNAL_STORAGE

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /** One folder per storage volume that has videos: the TV itself and each USB drive. */
    suspend fun roots(): List<DriveFile> = withContext(Dispatchers.IO) {
        if (!hasPermission()) return@withContext emptyList()
        videos().map { storageRoot(it.path) }.distinct().filterNotNull().map { root ->
            folder(root, volumeLabel(root), parent = null)
        }.sortedBy { if (it.name == INTERNAL_LABEL) "" else it.name }
    }

    /** Sub-folders and videos directly inside [folderId]. */
    suspend fun listChildren(folderId: String): List<DriveFile> = withContext(Dispatchers.IO) {
        val dir = folderId.removePrefix(PREFIX).trimEnd('/')
        val prefix = "$dir/"
        val result = mutableListOf<DriveFile>()
        val subfolders = sortedSetOf<String>()
        for (v in videos(underDir = dir)) {
            if (!v.path.startsWith(prefix)) continue
            val rest = v.path.removePrefix(prefix)
            val slash = rest.indexOf('/')
            if (slash >= 0) subfolders += rest.substring(0, slash)
            else result += DriveFile(
                id = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, v.id).toString(),
                name = v.name,
                mimeType = v.mime ?: "video/*",
                size = v.size.toString(),
                modifiedTime = v.modifiedSec.takeIf { it > 0 }?.let { Instant.ofEpochSecond(it).toString() },
                parents = listOf(folderId),
                capabilities = ReadOnly,
            )
        }
        subfolders.map { folder("$dir/$it", it, parent = folderId) } + result
    }

    private class Video(val id: Long, val path: String, val name: String, val size: Long, val modifiedSec: Long, val mime: String?)

    @Suppress("DEPRECATION") // DATA is the only column that gives folder structure on every API level.
    private fun videos(underDir: String? = null): List<Video> {
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_MODIFIED,
            MediaStore.Video.Media.MIME_TYPE,
        )
        val (selection, args) = if (underDir != null) {
            "${MediaStore.Video.Media.DATA} LIKE ? ESCAPE '\\'" to arrayOf(escapeLike("$underDir/") + "%")
        } else null to null
        return context.contentResolver.query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, projection, selection, args, null)?.use { c ->
            buildList {
                while (c.moveToNext()) {
                    val path = c.getString(1) ?: continue
                    add(Video(c.getLong(0), path, c.getString(2) ?: File(path).name, c.getLong(3), c.getLong(4), c.getString(5)))
                }
            }
        } ?: emptyList()
    }

    private fun folder(path: String, name: String, parent: String?) = DriveFile(
        id = PREFIX + path,
        name = name,
        mimeType = DriveFile.FOLDER_MIME,
        parents = listOfNotNull(parent),
        capabilities = ReadOnly,
    )

    /** "/storage/emulated/0/Movies/x.mkv" → "/storage/emulated/0"; "/storage/1A2B-3C4D/x.mkv" → "/storage/1A2B-3C4D". */
    private fun storageRoot(path: String): String? =
        Regex("""^(/storage/emulated/\d+|/storage/[^/]+|/mnt/media_rw/[^/]+)""").find(path)?.value

    private fun volumeLabel(root: String): String {
        if (root.startsWith("/storage/emulated/")) return INTERNAL_LABEL
        val sm = context.getSystemService(StorageManager::class.java)
        return runCatching { sm.getStorageVolume(File(root))?.getDescription(context) }.getOrNull()
            ?.takeIf { it.isNotBlank() } ?: "USB drive"
    }

    private fun escapeLike(s: String) = s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    companion object {
        const val PREFIX = "ms:"
        const val INTERNAL_LABEL = "TV storage"
        fun isMediaLibraryId(id: String) = id.startsWith(PREFIX) || id.startsWith("content://media/")

        private val ReadOnly = DriveCapabilities(canRename = false, canTrash = false, canDelete = false, canAddChildren = false)
    }
}
