package com.pntapps.veltoret

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade
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
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory(callFactory = { container.baseHttp })) }
            .crossfade(220)
            .build()
}
