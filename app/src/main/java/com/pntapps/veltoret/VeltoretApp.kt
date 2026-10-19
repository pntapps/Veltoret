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
import com.pntapps.veltoret.data.plans.UpcomingWorker
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.map
import com.pntapps.veltoret.data.tvlink.TvLinkService
import com.pntapps.veltoret.ui.util.isTv

class VeltoretApp : Application(), SingletonImageLoader.Factory {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        container.appScope.launch {
            container.accountRepository.ensureServerAccounts()
            if (container.settings.settings.first().onboardingComplete) {
                SyncWorker.schedulePeriodic(this@VeltoretApp)
                UpcomingWorker.schedule(this@VeltoretApp)
            }
            // Alarms don't survive the app being force-stopped either: set reminders again on every start.
            container.plans.restore(this@VeltoretApp, container)
        }
        // TV: keep the "Play on TV" listener running so a phone can open Veltoret here.
        if (isTv()) {
            container.tvLinkHost.init(this)
            container.appScope.launch {
                container.settings.settings.map { it.playFromPhone }.distinctUntilChanged().collect { TvLinkService.start(this@VeltoretApp, it) }
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
