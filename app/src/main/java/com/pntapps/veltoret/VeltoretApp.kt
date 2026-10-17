package com.pntapps.veltoret

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.disk.DiskCache
import coil3.request.crossfade
import okio.Path.Companion.toOkioPath
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import com.pntapps.veltoret.data.library.SyncWorker
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class VeltoretApp : Application(), SingletonImageLoader.Factory {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        container.appScope.launch {
            if (container.settings.settings.first().onboardingComplete) {
                SyncWorker.schedulePeriodic(this@VeltoretApp)
            }
        }
        // Coming back online: catch up on Drive folders and TMDB matches that were skipped while offline.
        container.appScope.launch {
            container.connectivity.online
                .drop(1)
                .distinctUntilChanged()
                .filter { it }
                .collect {
                    if (container.settings.settings.first().onboardingComplete) SyncWorker.runNow(this@VeltoretApp)
                }
        }
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { container.baseHttp })) }
            .crossfade(220)
            // Artwork is what makes the library usable offline, so keep a generous fixed-size cache.
            .diskCache {
                DiskCache.Builder()
                    .directory(context.cacheDir.resolve("image_cache").toOkioPath())
                    .maxSizeBytes(512L * 1024 * 1024)
                    .build()
            }
            .build()
}
