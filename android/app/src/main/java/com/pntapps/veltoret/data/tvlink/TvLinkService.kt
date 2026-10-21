package com.pntapps.veltoret.data.tvlink

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.pntapps.veltoret.R
import com.pntapps.veltoret.VeltoretApp
import com.pntapps.veltoret.ui.util.isTv

/**
 * Keeps the TV's "Play on TV" listener running while Veltoret is closed, so a phone can open it
 * (TV Settings "Play from your phone", on by default). Started at boot and when the app opens; TVs
 * don't show its notification, but Android requires one for a foreground service.
 */
class TvLinkService : Service() {
    private var server: TvLinkServer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Play from your phone", NotificationManager.IMPORTANCE_MIN))
        }
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_play)
            .setContentTitle("Ready to play from your phone")
            .setSilent(true)
            .setOngoing(true)
            .build()
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        runCatching { ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type) }
            .onFailure { stopSelf(); return START_NOT_STICKY }
        if (server == null) {
            val container = (application as VeltoretApp).container
            server = TvLinkServer(this, container.json, container.tvLinkStore, container.tvLinkHost)
                .also { s -> runCatching { s.start() } }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        server?.stop()
        server = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "tv-link"
        private const val NOTIFICATION_ID = 0x71E7
        private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"

        /** Starts the listener on a TV with "Play from your phone" on; safe to call repeatedly. */
        fun start(context: Context, enabled: Boolean) {
            if (!context.isTv()) return
            if (!enabled) return stop(context)
            // Android 17 needs "Nearby devices" for any home-network traffic; TV Settings asks for it.
            if (Build.VERSION.SDK_INT >= 37 &&
                ContextCompat.checkSelfPermission(context, LOCAL_NETWORK_PERMISSION) != PackageManager.PERMISSION_GRANTED
            ) return
            runCatching { ContextCompat.startForegroundService(context, Intent(context, TvLinkService::class.java)) }
                .onFailure { if (com.pntapps.veltoret.BuildConfig.DEBUG) android.util.Log.w("VeltoretLink", "service start failed", it) }
        }

        fun stop(context: Context) {
            runCatching { context.stopService(Intent(context, TvLinkService::class.java)) }
        }
    }
}
