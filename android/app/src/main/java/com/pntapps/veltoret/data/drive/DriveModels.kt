package com.pntapps.veltoret.data.drive

import kotlinx.serialization.Serializable

/** Retrofit request tag telling [DriveAuthInterceptor] which Google account to authorize as. */
data class DriveAccount(val email: String)

@Serializable
data class DriveFileList(
    val nextPageToken: String? = null,
    val files: List<DriveFile> = emptyList(),
)

@Serializable
data class DriveFile(
    val id: String,
    val name: String = "",
    val mimeType: String = "",
    // Drive sends int64 values as JSON strings.
    val size: String? = null,
    val modifiedTime: String? = null,
    val parents: List<String> = emptyList(),
    val videoMediaMetadata: DriveVideoMetadata? = null,
    val fileExtension: String? = null,
    val capabilities: DriveCapabilities? = null,
) {
    val isFolder: Boolean get() = mimeType == FOLDER_MIME
    val sizeBytes: Long get() = size?.toLongOrNull() ?: 0L

    companion object {
        const val FOLDER_MIME = "application/vnd.google-apps.folder"
    }
}

@Serializable
data class DriveVideoMetadata(
    val width: Int? = null,
    val height: Int? = null,
    val durationMillis: String? = null,
)

@Serializable
data class DriveCapabilities(
    val canRename: Boolean = true,
    val canTrash: Boolean = true,
    val canDelete: Boolean = false,
    val canAddChildren: Boolean = true,
)

@Serializable
data class DriveAbout(
    val user: DriveUser? = null,
    val storageQuota: DriveQuota? = null,
)

@Serializable
data class DriveUser(
    val displayName: String? = null,
    val emailAddress: String? = null,
    val photoLink: String? = null,
)

@Serializable
data class DriveQuota(
    val limit: String? = null,
    val usage: String? = null,
)

@Serializable
data class DriveFileUpdate(
    val name: String? = null,
    val trashed: Boolean? = null,
)

@Serializable
data class DriveFileCreate(
    val name: String,
    val mimeType: String,
    val parents: List<String>,
)
