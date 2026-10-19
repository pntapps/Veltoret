package com.pntapps.veltoret.data.tvlink

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.MainActivity
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.pairing.PairingCrypto
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.player.LinkArgs
import com.pntapps.veltoret.player.PlayerActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/** The TV's open player, as the phone sees it. Called on the main thread. */
interface LinkPlayer {
    fun linkStatus(): LinkStatus
    fun linkCommand(command: LinkCommand)
}

/** The TV shows this while a phone pairs. */
data class PairingPrompt(val phoneName: String, val code: String)

/**
 * The TV's half of "Play on TV": decides what to play for a phone's request (the same file, else the
 * TV's own copy of the title, else the phone's stream), opens the player, and passes the phone's
 * remote controls to it. TvLinkServer handles the network side.
 */
class TvLinkHost(private val context: Context, private val container: AppContainer) {

    private val _pairing = MutableStateFlow<PairingPrompt?>(null)
    val pairing: StateFlow<PairingPrompt?> = _pairing.asStateFlow()

    @Volatile private var player: LinkPlayer? = null
    /** The linked video played to the end and its player closed. */
    @Volatile private var ended = false
    @Volatile private var startedActivities = 0
    /** A request that waits for Veltoret to be opened (newer Android won't let it open itself). */
    @Volatile private var pending: Intent? = null

    fun init(app: Application) {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) { startedActivities++ }
            override fun onActivityStopped(activity: Activity) { startedActivities = (startedActivities - 1).coerceAtLeast(0) }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    fun attach(p: LinkPlayer) { player = p; ended = false }

    fun detach(p: LinkPlayer, finished: Boolean) {
        if (player === p) { player = null; ended = finished }
    }

    /**
     * Veltoret may open itself: always on Android 9 and older; on newer Android only while it's on
     * screen or with "Display over other apps".
     */
    fun canOpen(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || startedActivities > 0 || Settings.canDrawOverlays(context)

    /** Opening Veltoret plays what a phone asked for meanwhile. Called by MainActivity on TV. */
    fun takePending(): Intent? = pending.also { pending = null }

    // ---- Pairing --------------------------------------------------------------------------------

    /** Shows a new code for [phoneName]; false when Veltoret can't come to the front to show it. */
    fun startPairing(phoneName: String): Boolean {
        _pairing.value = PairingPrompt(phoneName, PairingCrypto.newCode())
        if (!canOpen()) return false
        if (startedActivities == 0) {
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
        }
        return true
    }

    fun pairingCode(): String? = _pairing.value?.code

    /** A wrong code: a new one, so guessing can't work. */
    fun newPairingCode() {
        _pairing.value = _pairing.value?.copy(code = PairingCrypto.newCode())
    }

    fun endPairing() { _pairing.value = null }

    // ---- Playback -------------------------------------------------------------------------------

    suspend fun play(request: LinkPlay): LinkReply {
        val file = withContext(Dispatchers.IO) { resolve(request) }
        val fromPhone = file == null
        if (fromPhone && request.streamUrl == null) return LinkReply(false, "The TV doesn't have this video")
        val link = LinkArgs(
            startMs = request.startMs,
            audioLanguage = request.audioLanguage,
            subtitleLanguage = request.subtitleLanguage,
            fromPhone = fromPhone,
            subtitle = request.subtitle,
        )
        val intent = PlayerActivity.intent(
            context,
            fileId = file?.driveId ?: request.streamUrl!!,
            accountEmail = file?.accountEmail ?: TvLink.STREAM_ACCOUNT,
            title = request.title,
            fromStart = false,
            link = link,
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ended = false
        if (!canOpen()) {
            pending = intent
            return LinkReply(false, "Open Veltoret on the TV to start it", code = "open_app")
        }
        withContext(Dispatchers.Main) { context.startActivity(intent) }
        return LinkReply(true, if (fromPhone) LinkStatus.SOURCE_PHONE else LinkStatus.SOURCE_TV)
    }

    /** The same file if this TV's library has it, else its own copy of the movie or episode. */
    private suspend fun resolve(r: LinkPlay): MediaFileEntity? {
        val online = container.connectivity.isOnline
        container.libraryRepository.file(r.fileId)
            ?.takeIf { online || LocalStorage.isLocal(it.accountEmail) }
            ?.let { return it }
        return when {
            r.movieId != null -> container.playback.movieFile(r.movieId)
            r.showId != null && r.season != null && r.episode != null -> container.playback.episodeFile(r.showId, r.season, r.episode)
            else -> null
        }
    }

    suspend fun status(): LinkStatus = withContext(Dispatchers.Main) {
        player?.linkStatus() ?: LinkStatus(active = false, ended = ended)
    }

    suspend fun command(command: LinkCommand): LinkReply = withContext(Dispatchers.Main) {
        val p = player ?: return@withContext LinkReply(false, "Nothing is playing on the TV")
        p.linkCommand(command)
        LinkReply(true)
    }
}
