package com.pntapps.veltoret.player.cast

import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.MediaTrack
import com.google.android.gms.cast.TextTrackStyle
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.images.WebImage
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.BuildConfig
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.ui.util.isTv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.DatagramSocket
import java.net.InetAddress

/** One subtitle for the Chromecast, already converted to WebVTT. */
data class CastSubtitle(val id: String, val label: String, val language: String?, val vtt: String)

/** What to cast: a library file (or a Files-tab file) with what the TV shows about it. */
data class CastMedia(
    val fileId: String,
    val file: MediaFileEntity?,
    /** What the player's data sources read: a content/smb URI, or DriveMedia's URI. */
    val uri: Uri,
    val title: String,
    val subtitle: String?,
    val posterUrl: String?,
    val backdropUrl: String?,
    val isEpisode: Boolean,
    val subtitles: List<CastSubtitle> = emptyList(),
    val activeSubtitle: String? = null,
    /** Set when the audio is a format Chromecasts usually can't decode (DTS, TrueHD). */
    val audioWarning: String? = null,
)

data class CastState(
    /** Cast is possible here (phone or tablet with Play services; never on TV). */
    val available: Boolean = false,
    val connected: Boolean = false,
    val deviceName: String? = null,
    val media: CastMedia? = null,
    val playing: Boolean = false,
    val buffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    /** The video played to the end on the TV. */
    val finished: Boolean = false,
    val error: String? = null,
    val activeSubtitle: String? = null,
)

/**
 * Chromecast through Google Cast's Default Media Receiver: no receiver app or server of our own. Videos
 * stream from [CastServer] on the phone. Watch progress is saved like local playback, so casting and the
 * phone resume each other. Cast's own media notification gives lock-screen and notification controls.
 */
@OptIn(UnstableApi::class)
class CastController(private val context: Context, private val container: AppContainer) {

    private val _state = MutableStateFlow(CastState())
    val state: StateFlow<CastState> = _state.asStateFlow()

    private var castContext: CastContext? = null
    private val server by lazy { CastServer(container.mediaDataSources()) }
    private var session: CastSession? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastSavedAt = 0L

    /** Sets Cast up on the main thread; returns false where it isn't available (TV, no Play services). */
    fun init(): Boolean {
        castContext?.let { return true }
        if (context.isTv()) return false
        if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) != ConnectionResult.SUCCESS) return false
        val cast = runCatching { CastContext.getSharedInstance(context) }.getOrNull() ?: return false
        castContext = cast
        cast.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
        cast.sessionManager.currentCastSession?.takeIf { it.isConnected }?.let(::onConnected)
        _state.update { it.copy(available = true) }
        return true
    }

    /** What the device picker searches for (Cast devices that can run the Default Media Receiver). */
    fun routeSelector() = castContext?.mergedSelector

    // ---------------------------------------------------------------------------------------------
    // Sessions
    // ---------------------------------------------------------------------------------------------

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) = onConnected(session)
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) = onConnected(session)
        override fun onSessionEnded(session: CastSession, error: Int) = onDisconnected()
        override fun onSessionSuspended(session: CastSession, reason: Int) = onDisconnected()
        override fun onSessionStartFailed(session: CastSession, error: Int) {
            _state.update { it.copy(error = "Couldn't connect to ${session.castDevice?.friendlyName ?: "the TV"}") }
        }
        override fun onSessionResumeFailed(session: CastSession, error: Int) = onDisconnected()
        override fun onSessionStarting(session: CastSession) = Unit
        override fun onSessionEnding(session: CastSession) = saveProgress()
        override fun onSessionResuming(session: CastSession, sessionId: String) = Unit
    }

    private fun onConnected(s: CastSession) {
        session = s
        s.remoteMediaClient?.let { client ->
            client.registerCallback(mediaCallback)
            client.addProgressListener(progressListener, 1_000)
        }
        _state.update { it.copy(connected = true, deviceName = s.castDevice?.friendlyName, error = null) }
    }

    private fun onDisconnected() {
        saveProgress()
        session?.remoteMediaClient?.let { client ->
            client.unregisterCallback(mediaCallback)
            client.removeProgressListener(progressListener)
        }
        session = null
        server.stop()
        releaseLocks()
        _state.update { CastState(available = it.available, positionMs = it.positionMs, media = it.media) }
    }

    /** Stops casting (and the video on the TV). */
    fun disconnect() {
        castContext?.sessionManager?.endCurrentSession(true)
    }

    // ---------------------------------------------------------------------------------------------
    // Media
    // ---------------------------------------------------------------------------------------------

    /** Sends [media] to the TV, starting at [startMs]. */
    fun load(media: CastMedia, startMs: Long) {
        if (BuildConfig.DEBUG) Log.d("VeltoretCast", "load ${media.title} at $startMs session=${session != null} client=${session?.remoteMediaClient != null}")
        val s = session ?: return
        val client = s.remoteMediaClient ?: return
        // Cast's own calls must happen on the main thread; only the server and network work go to IO.
        val device = s.castDevice?.inetAddress
        container.appScope.launch(Dispatchers.Main) {
            try {
                val urls = withContext(Dispatchers.IO) {
                    server.start(phoneAddressFacing(device ?: error("The TV's address is unknown")))
                    val video = server.media("v${media.fileId.hashCode().toUInt()}", media.uri, mimeFor(media), media.file?.sizeBytes)
                    video to media.subtitles.mapIndexed { i, sub -> sub to server.text("s$i-${sub.id.hashCode().toUInt()}", sub.vtt) }
                }
                val tracks = urls.second.mapIndexed { i, (sub, url) ->
                    MediaTrack.Builder(i + 1L, MediaTrack.TYPE_TEXT)
                        .setName(sub.label)
                        .setSubtype(MediaTrack.SUBTYPE_SUBTITLES)
                        .setContentId(url)
                        .setContentType("text/vtt")
                        .apply { sub.language?.let { setLanguage(it) } }
                        .build()
                }
                val metadata = MediaMetadata(if (media.isEpisode) MediaMetadata.MEDIA_TYPE_TV_SHOW else MediaMetadata.MEDIA_TYPE_MOVIE).apply {
                    putString(MediaMetadata.KEY_TITLE, media.title)
                    media.subtitle?.let { putString(MediaMetadata.KEY_SUBTITLE, it) }
                    // The receiver's idle and pause screens use these.
                    media.posterUrl?.let { addImage(WebImage(Uri.parse(it))) }
                    media.backdropUrl?.let { addImage(WebImage(Uri.parse(it))) }
                }
                val info = MediaInfo.Builder(urls.first)
                    .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
                    .setContentType(mimeFor(media))
                    .setMetadata(metadata)
                    .setMediaTracks(tracks)
                    .setTextTrackStyle(TextTrackStyle().apply {
                        backgroundColor = 0x99000000.toInt()
                        foregroundColor = 0xFFFFFFFF.toInt()
                        edgeType = TextTrackStyle.EDGE_TYPE_DROP_SHADOW
                        fontScale = 1.0f
                    })
                    .build()
                val active = media.subtitles.indexOfFirst { it.id == media.activeSubtitle }.takeIf { it >= 0 }
                val request = MediaLoadRequestData.Builder()
                    .setMediaInfo(info)
                    .setAutoplay(true)
                    .setCurrentTime(startMs)
                    .apply { if (active != null) setActiveTrackIds(longArrayOf(active + 1L)) }
                    .build()
                if (BuildConfig.DEBUG) Log.d("VeltoretCast", "serving ${urls.first} (${mimeFor(media)}), ${tracks.size} subtitle tracks")
                acquireLocks()
                _state.update {
                    it.copy(media = media, finished = false, error = null, positionMs = startMs, buffering = true, activeSubtitle = media.activeSubtitle)
                }
                client.load(request).setResultCallback { result ->
                    if (BuildConfig.DEBUG) Log.d("VeltoretCast", "load result ${result.status}")
                    if (!result.status.isSuccess) {
                        _state.update { st -> st.copy(error = "The TV couldn't play this video (${result.status.statusCode})", buffering = false) }
                    }
                }
            } catch (e: Exception) {
                if (BuildConfig.DEBUG) Log.w("VeltoretCast", "load failed", e)
                _state.update { it.copy(error = "Couldn't start casting: ${e.message}") }
            }
        }
    }

    fun play() { session?.remoteMediaClient?.play() }
    fun pause() { session?.remoteMediaClient?.pause() }

    fun seekTo(ms: Long) {
        session?.remoteMediaClient?.seek(MediaSeekOptions.Builder().setPosition(ms.coerceAtLeast(0)).build())
        _state.update { it.copy(positionMs = ms.coerceAtLeast(0)) }
    }

    fun seekBy(deltaMs: Long) = seekTo(_state.value.positionMs + deltaMs)

    /** Shows subtitle [id] on the TV, or none. */
    fun selectSubtitle(id: String?) {
        val media = _state.value.media ?: return
        val index = media.subtitles.indexOfFirst { it.id == id }
        session?.remoteMediaClient?.setActiveMediaTracks(if (index >= 0) longArrayOf(index + 1L) else longArrayOf())
        _state.update { it.copy(activeSubtitle = id.takeIf { index >= 0 }) }
    }

    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = refresh()
    }

    private val progressListener = RemoteMediaClient.ProgressListener { progress, duration ->
        _state.update { it.copy(positionMs = progress, durationMs = duration.coerceAtLeast(it.durationMs)) }
        val now = System.currentTimeMillis()
        if (_state.value.playing && now - lastSavedAt > 10_000) saveProgress()
    }

    private fun refresh() {
        val client = session?.remoteMediaClient ?: return
        val status = client.mediaStatus
        val playerState = status?.playerState ?: MediaStatus.PLAYER_STATE_IDLE
        val finished = playerState == MediaStatus.PLAYER_STATE_IDLE && status?.idleReason == MediaStatus.IDLE_REASON_FINISHED
        val failed = playerState == MediaStatus.PLAYER_STATE_IDLE && status?.idleReason == MediaStatus.IDLE_REASON_ERROR
        val wasPlaying = _state.value.playing
        _state.update {
            it.copy(
                playing = playerState == MediaStatus.PLAYER_STATE_PLAYING,
                buffering = playerState == MediaStatus.PLAYER_STATE_BUFFERING || playerState == MediaStatus.PLAYER_STATE_LOADING,
                durationMs = client.streamDuration.takeIf { d -> d > 0 } ?: it.durationMs,
                finished = finished || (it.finished && playerState == MediaStatus.PLAYER_STATE_IDLE),
                error = if (failed) "The TV couldn't play this video. Its format may not be supported by Chromecast." else it.error,
            )
        }
        if (finished) saveProgress(ended = true)
        else if (wasPlaying && playerState != MediaStatus.PLAYER_STATE_PLAYING) saveProgress()
    }

    /** Watch progress, shared with local playback (resume works both ways). */
    fun saveProgress(ended: Boolean = false) {
        val st = _state.value
        val media = st.media ?: return
        val duration = st.durationMs.takeIf { it > 0 } ?: media.file?.durationMs?.takeIf { it > 0 } ?: return
        val position = if (ended) duration else st.positionMs
        if (position <= 0) return
        lastSavedAt = System.currentTimeMillis()
        container.appScope.launch { container.watchRepository.savePosition(media.file, media.fileId, position, duration) }
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /** The phone's address on the network the Chromecast is on (a UDP "connect" picks the right interface). */
    private fun phoneAddressFacing(device: InetAddress): InetAddress {
        return DatagramSocket().use { socket ->
            socket.connect(device, 8009)
            socket.localAddress
        }
    }

    /** While casting the phone serves the video: keep Wi-Fi awake and the CPU running with the screen off. */
    private fun acquireLocks() {
        if (wifiLock == null) {
            val wifi = context.getSystemService(WifiManager::class.java)
            @Suppress("DEPRECATION")
            wifiLock = wifi?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Veltoret:cast")?.apply { setReferenceCounted(false); acquire() }
        }
        if (wakeLock == null) {
            val power = context.getSystemService(PowerManager::class.java)
            wakeLock = power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Veltoret:cast")?.apply { setReferenceCounted(false); acquire(6 * 60 * 60 * 1000L) }
        }
    }

    private fun releaseLocks() {
        runCatching { wifiLock?.release() }
        runCatching { wakeLock?.release() }
        wifiLock = null
        wakeLock = null
    }

    companion object {
        /** The MIME type Chromecasts expect for the file's container. */
        fun mimeFor(media: CastMedia): String {
            val name = media.file?.name ?: media.title
            return when (name.substringAfterLast('.', "").lowercase()) {
                "mp4", "m4v", "mov" -> "video/mp4"
                "webm" -> "video/webm"
                "ts", "m2ts" -> "video/mp2t"
                "avi" -> "video/x-msvideo"
                else -> "video/x-matroska"
            }
        }
    }
}
