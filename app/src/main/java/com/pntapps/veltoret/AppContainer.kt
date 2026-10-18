package com.pntapps.veltoret

import android.content.Context
import com.pntapps.veltoret.data.auth.GoogleAuthManager
import com.pntapps.veltoret.data.db.VeltoretDatabase
import com.pntapps.veltoret.data.drive.DriveApi
import com.pntapps.veltoret.data.drive.DriveAuthInterceptor
import com.pntapps.veltoret.data.drive.DriveRepository
import com.pntapps.veltoret.data.library.AccountRepository
import com.pntapps.veltoret.data.library.LibraryRepository
import com.pntapps.veltoret.data.library.LibraryScanner
import com.pntapps.veltoret.data.library.WatchRepository
import com.pntapps.veltoret.data.settings.SettingsRepository
import com.pntapps.veltoret.data.tmdb.TmdbApi
import com.pntapps.veltoret.data.tmdb.TmdbAuthInterceptor
import com.pntapps.veltoret.data.tmdb.TmdbRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.util.concurrent.TimeUnit

/** Manual dependency graph; one instance lives in [VeltoretApp]. */
class AppContainer(context: Context) {
    val appContext: Context = context.applicationContext

    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    val settings = SettingsRepository(appContext)
    val auth = GoogleAuthManager(appContext)
    val database = VeltoretDatabase.create(appContext)

    /** Shared base client: connection pool and cache are reused by Drive, TMDB, images and playback. */
    val baseHttp: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    val driveHttp: OkHttpClient = baseHttp.newBuilder()
        .addInterceptor(DriveAuthInterceptor(auth))
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    /** Used by the player; auth headers are added by [com.pntapps.veltoret.player.DriveMedia.Resolver]. */
    val mediaHttp: OkHttpClient = baseHttp.newBuilder()
        .readTimeout(45, TimeUnit.SECONDS)
        .build()

    private val tmdbKey = settings.settings
        .map { it.tmdbKey }
        .stateIn(appScope, SharingStarted.Eagerly, com.pntapps.veltoret.data.settings.AppSettings().tmdbKey)

    private val tmdbHttp: OkHttpClient = baseHttp.newBuilder()
        .addInterceptor(TmdbAuthInterceptor { tmdbKey.value })
        .build()

    private val contentType = "application/json".toMediaType()

    val driveApi: DriveApi = Retrofit.Builder()
        .baseUrl("https://www.googleapis.com/")
        .client(driveHttp)
        .addConverterFactory(json.asConverterFactory(contentType))
        .build()
        .create(DriveApi::class.java)

    val tmdbApi: TmdbApi = Retrofit.Builder()
        .baseUrl("https://api.themoviedb.org/3/")
        .client(tmdbHttp)
        .addConverterFactory(json.asConverterFactory(contentType))
        .build()
        .create(TmdbApi::class.java)

    val driveRepository = DriveRepository(driveApi, driveHttp, json)
    val localStorage = com.pntapps.veltoret.data.storage.LocalStorage(appContext)
    val smbServers = com.pntapps.veltoret.data.smb.SmbServerStore(appContext, json)
    val smbStorage = com.pntapps.veltoret.data.smb.SmbStorage(smbServers)
    val smbDiscovery = com.pntapps.veltoret.data.smb.SmbDiscovery(appContext)
    val storage = com.pntapps.veltoret.data.storage.Storage(driveRepository, localStorage, smbStorage, smbServers)
    val tmdbRepository = TmdbRepository(tmdbApi, database.catalogDao())
    val watchRepository = WatchRepository(database.watchDao())
    val connectivity = com.pntapps.veltoret.data.net.Connectivity(appContext)
    val libraryRepository = LibraryRepository(database.catalogDao(), database.mediaFileDao(), connectivity)
    val accountRepository = AccountRepository(
        database.accountDao(), database.mediaFileDao(), database.catalogDao(), driveRepository, localStorage, auth,
        smbServers, smbStorage,
    )
    val playback = com.pntapps.veltoret.data.library.PlaybackResolver(database.mediaFileDao(), database.watchDao(), connectivity)
    val scanner = LibraryScanner(
        database.accountDao(), database.mediaFileDao(), database.catalogDao(), storage, tmdbRepository, settings, connectivity,
    )
}
