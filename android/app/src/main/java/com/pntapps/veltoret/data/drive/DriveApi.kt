package com.pntapps.veltoret.data.drive

import com.pntapps.veltoret.data.auth.GoogleAuthManager
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.Response
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query
import retrofit2.http.Tag

const val DRIVE_FILE_FIELDS =
    "id,name,mimeType,size,modifiedTime,parents,fileExtension," +
        "videoMediaMetadata(width,height,durationMillis)," +
        "capabilities(canRename,canTrash,canDelete,canAddChildren)"
const val DRIVE_LIST_FIELDS = "nextPageToken,files($DRIVE_FILE_FIELDS)"

interface DriveApi {
    @GET("drive/v3/files")
    suspend fun list(
        @Tag account: DriveAccount,
        @Query("q") query: String,
        @Query("pageToken") pageToken: String? = null,
        @Query("orderBy") orderBy: String? = "folder,name_natural",
        @Query("fields") fields: String = DRIVE_LIST_FIELDS,
        @Query("pageSize") pageSize: Int = 1000,
        @Query("supportsAllDrives") supportsAllDrives: Boolean = true,
        @Query("includeItemsFromAllDrives") includeAllDrives: Boolean = true,
    ): DriveFileList

    @GET("drive/v3/files/{id}")
    suspend fun get(
        @Tag account: DriveAccount,
        @Path("id") id: String,
        @Query("fields") fields: String = DRIVE_FILE_FIELDS,
        @Query("supportsAllDrives") supportsAllDrives: Boolean = true,
    ): DriveFile

    @GET("drive/v3/about")
    suspend fun about(
        @Tag account: DriveAccount,
        @Query("fields") fields: String = "user(displayName,emailAddress,photoLink),storageQuota(limit,usage)",
    ): DriveAbout

    @PATCH("drive/v3/files/{id}")
    suspend fun update(
        @Tag account: DriveAccount,
        @Path("id") id: String,
        @Body body: DriveFileUpdate,
        @Query("addParents") addParents: String? = null,
        @Query("removeParents") removeParents: String? = null,
        @Query("fields") fields: String = DRIVE_FILE_FIELDS,
        @Query("supportsAllDrives") supportsAllDrives: Boolean = true,
    ): DriveFile

    @POST("drive/v3/files")
    suspend fun create(
        @Tag account: DriveAccount,
        @Body body: DriveFileCreate,
        @Query("fields") fields: String = DRIVE_FILE_FIELDS,
        @Query("supportsAllDrives") supportsAllDrives: Boolean = true,
    ): DriveFile

    @DELETE("drive/v3/files/{id}")
    suspend fun delete(
        @Tag account: DriveAccount,
        @Path("id") id: String,
        @Query("supportsAllDrives") supportsAllDrives: Boolean = true,
    ): retrofit2.Response<Unit>
}

/** Adds the right account's bearer token to tagged Drive calls and retries once on 401. */
class DriveAuthInterceptor(private val auth: GoogleAuthManager) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val account = request.tag(DriveAccount::class.java) ?: return chain.proceed(request)
        val token = runBlocking { auth.accessToken(account.email) }
        val response = chain.proceed(request.newBuilder().header("Authorization", "Bearer $token").build())
        if (response.code != 401) return response
        response.close()
        val fresh = runBlocking {
            auth.invalidate(account.email)
            auth.accessToken(account.email)
        }
        return chain.proceed(request.newBuilder().header("Authorization", "Bearer $fresh").build())
    }
}
