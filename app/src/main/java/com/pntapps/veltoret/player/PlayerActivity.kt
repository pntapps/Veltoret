package com.pntapps.veltoret.player

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import com.pntapps.veltoret.ui.theme.VeltoretTheme
import com.pntapps.veltoret.ui.util.container
import kotlinx.coroutines.launch

class PlayerActivity : ComponentActivity() {

    private val viewModel: PlayerViewModel by viewModels {
        viewModelFactory { initializer { PlayerViewModel(container, argsFrom(intent)) } }
    }

    private var session: MediaSession? = null
    private var attached: ExoPlayer? = null
    private val inPip = mutableStateOf(false)

    /** null = follow the video's shape; otherwise the user's explicit choice from the Rotate button. */
    private var orientationChoice: Int? = null

    private val playerListener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            applyOrientation()
            updatePipParams()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) = updatePipParams()
    }

    private val pipReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val player = viewModel.player
            when (intent.getIntExtra(EXTRA_PIP_ACTION, 0)) {
                PIP_PLAY_PAUSE -> if (player.isPlaying) player.pause() else player.play()
                PIP_REWIND -> viewModel.seekBy(-10_000)
                PIP_FORWARD -> viewModel.seekBy(10_000)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
        ContextCompat.registerReceiver(this, pipReceiver, IntentFilter(ACTION_PIP), ContextCompat.RECEIVER_NOT_EXPORTED)

        // The player can be rebuilt (decoder switch): keep the media session and listeners on the live one.
        lifecycleScope.launch {
            viewModel.playerFlow.collect { player ->
                attached?.removeListener(playerListener)
                player.addListener(playerListener)
                attached = player
                val current = session
                if (current == null) session = MediaSession.Builder(this@PlayerActivity, player).build()
                else current.player = player
                applyOrientation()
                updatePipParams()
            }
        }

        setContent {
            VeltoretTheme {
                PlayerScreen(
                    viewModel = viewModel,
                    inPip = inPip.value,
                    onExit = { finish() },
                    onEnterPip = { enterPip() },
                    onRotate = { rotate() },
                )
            }
        }
    }

    /** Sheets and dialogs are separate windows that bring the system bars back; hide them again. */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            WindowCompat.getInsetsController(window, window.decorView).hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    /** singleTask: a new "play" request (e.g. while in picture-in-picture) arrives here. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        orientationChoice = null
        viewModel.open(argsFrom(intent))
    }

    // ---- Orientation ---------------------------------------------------------------------------

    private fun applyOrientation() {
        val size = viewModel.player.videoSize
        val portraitVideo = size.width > 0 && size.height > size.width
        requestedOrientation = orientationChoice ?: if (portraitVideo) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
    }

    private fun rotate() {
        val landscapeNow = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        orientationChoice = if (landscapeNow) ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        applyOrientation()
    }

    // ---- Picture in picture --------------------------------------------------------------------

    private fun pipParams(): PictureInPictureParams {
        val player = viewModel.player
        val size = player.videoSize
        val ratio = if (size.width > 0 && size.height > 0) Rational(size.width, size.height).coerceRatio() else Rational(16, 9)
        return PictureInPictureParams.Builder()
            .setAspectRatio(ratio)
            .setActions(
                listOf(
                    remoteAction(android.R.drawable.ic_media_rew, "Back 10 seconds", PIP_REWIND),
                    if (player.isPlaying) remoteAction(android.R.drawable.ic_media_pause, "Pause", PIP_PLAY_PAUSE)
                    else remoteAction(android.R.drawable.ic_media_play, "Play", PIP_PLAY_PAUSE),
                    remoteAction(android.R.drawable.ic_media_ff, "Forward 10 seconds", PIP_FORWARD),
                )
            )
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    setAutoEnterEnabled(player.isPlaying)
                    setSeamlessResizeEnabled(true)
                }
            }
            .build()
    }

    private fun remoteAction(icon: Int, title: String, action: Int): RemoteAction {
        val intent = Intent(ACTION_PIP).setPackage(packageName).putExtra(EXTRA_PIP_ACTION, action)
        val pending = PendingIntent.getBroadcast(this, action, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return RemoteAction(Icon.createWithResource(this, icon), title, title, pending)
    }

    /** Android limits PiP aspect ratios to between 1:2.39 and 2.39:1. */
    private fun Rational.coerceRatio(): Rational {
        val value = toFloat()
        return when {
            value > 2.39f -> Rational(239, 100)
            value < 1 / 2.39f -> Rational(100, 239)
            else -> this
        }
    }

    private fun updatePipParams() {
        runCatching { setPictureInPictureParams(pipParams()) }
    }

    private fun enterPip() {
        runCatching { enterPictureInPictureMode(pipParams()) }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && viewModel.player.isPlaying) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip.value = isInPictureInPictureMode
    }

    // ---- Keyboard (tablets with keyboards, Chromebooks) ----------------------------------------

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val player = viewModel.player
        when (keyCode) {
            KeyEvent.KEYCODE_SPACE, KeyEvent.KEYCODE_K -> if (player.isPlaying) player.pause() else player.play()
            KeyEvent.KEYCODE_J, KeyEvent.KEYCODE_DPAD_LEFT -> viewModel.seekBy(-10_000)
            KeyEvent.KEYCODE_L, KeyEvent.KEYCODE_DPAD_RIGHT -> viewModel.seekBy(10_000)
            KeyEvent.KEYCODE_M -> player.volume = if (player.volume > 0f) 0f else 1f
            KeyEvent.KEYCODE_N -> viewModel.playNext()
            KeyEvent.KEYCODE_P -> viewModel.playPrevious()
            else -> return super.onKeyDown(keyCode, event)
        }
        return true
    }

    override fun onStop() {
        super.onStop()
        // Leaving picture-in-picture via its close button stops the activity: pause instead of playing on.
        if (!isInPictureInPictureMode) viewModel.player.pause()
        viewModel.saveProgress()
    }

    override fun onDestroy() {
        attached?.removeListener(playerListener)
        runCatching { unregisterReceiver(pipReceiver) }
        session?.release()
        session = null
        super.onDestroy()
    }

    companion object {
        private const val EXTRA_FILE_ID = "file_id"
        private const val EXTRA_ACCOUNT = "account"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_FROM_START = "from_start"
        private const val ACTION_PIP = "com.pntapps.veltoret.PIP_CONTROL"
        private const val EXTRA_PIP_ACTION = "pip_action"
        private const val PIP_PLAY_PAUSE = 1
        private const val PIP_REWIND = 2
        private const val PIP_FORWARD = 3

        private fun argsFrom(intent: Intent) = PlayerArgs(
            fileId = intent.getStringExtra(EXTRA_FILE_ID).orEmpty(),
            accountEmail = intent.getStringExtra(EXTRA_ACCOUNT),
            title = intent.getStringExtra(EXTRA_TITLE),
            fromStart = intent.getBooleanExtra(EXTRA_FROM_START, false),
        )

        fun intent(context: Context, fileId: String, accountEmail: String?, title: String?, fromStart: Boolean) =
            Intent(context, PlayerActivity::class.java)
                .putExtra(EXTRA_FILE_ID, fileId)
                .putExtra(EXTRA_ACCOUNT, accountEmail)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_FROM_START, fromStart)
    }
}

/** Opens the full-screen player. Library files only need [fileId]; Files-tab items pass the account too. */
fun Context.playFile(fileId: String, accountEmail: String? = null, title: String? = null, fromStart: Boolean = false) {
    startActivity(PlayerActivity.intent(this, fileId, accountEmail, title, fromStart))
}
