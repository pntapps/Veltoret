package com.pntapps.veltoret.player

import android.media.audiofx.LoudnessEnhancer
import android.net.Uri
import androidx.annotation.OptIn
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.text.Cue
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlaybackException
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.BuildConfig
import com.pntapps.veltoret.data.auth.AuthRequiredException
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.library.WatchKeys
import com.pntapps.veltoret.data.settings.AppSettings
import com.pntapps.veltoret.data.tmdb.TmdbImages
import com.pntapps.veltoret.ui.util.Format
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

data class PlayerArgs(val fileId: String, val accountEmail: String?, val title: String?, val fromStart: Boolean)

data class ExternalSubInfo(val id: String, val label: String, val language: String?)

data class EpisodeItem(
    val fileId: String,
    val accountEmail: String,
    val season: Int,
    val episode: Int,
    val name: String,
    val stillUrl: String?,
    val watched: Boolean,
    val current: Boolean,
)

/** [endsAtMs] for a countdown; [endOfEpisode] to stop when the current video finishes. */
data class SleepTimer(val endsAtMs: Long?, val endOfEpisode: Boolean)

data class DecoderStats(val video: String? = null, val audio: String? = null, val droppedFrames: Int = 0)

data class PlayerUi(
    val title: String = "",
    val subtitle: String? = null,
    val fileName: String = "",
    val fileSize: Long = 0,
    val isEpisode: Boolean = false,
    val showId: Int? = null,
    val next: MediaFileEntity? = null,
    val nextLabel: String? = null,
    val previous: MediaFileEntity? = null,
    val error: String? = null,
    val finished: Boolean = false,
    val settings: AppSettings = AppSettings(),
    val resumedFrom: Long? = null,
    val externalSubs: List<ExternalSubInfo> = emptyList(),
    val selectedExternal: String? = null,
    val subtitleOffsetMs: Long = 0,
    val softwareDecoding: Boolean = false,
    val sleep: SleepTimer? = null,
    val autoPlayCancelled: Boolean = false,
    val introSkipped: Boolean = false,
    /** Short one-off notice for the HUD ("Switched to software decoding"). */
    val notice: String? = null,
    val boost: Float = 0f,
    /** Shown when loading is slow ("Loading from MyNAS…"); null for files on this device. */
    val loadingFrom: String? = null,
)

enum class ResizeMode(val label: String) { Fit("Fit"), Fill("Fill"), Stretch("Stretch") }

@OptIn(UnstableApi::class)
class PlayerViewModel(private val container: AppContainer, args: PlayerArgs) : ViewModel() {

    private val library = container.libraryRepository
    private val watch = container.watchRepository
    val prefs = PlayerPrefs(container.appContext)

    private val _ui = MutableStateFlow(PlayerUi())
    val ui: StateFlow<PlayerUi> = _ui.asStateFlow()

    private val _decoders = MutableStateFlow(DecoderStats())
    val decoders: StateFlow<DecoderStats> = _decoders.asStateFlow()

    private val _player: MutableStateFlow<ExoPlayer>
    /** The player can be rebuilt (decoder switch), so observe this rather than holding on to one instance. */
    val playerFlow: StateFlow<ExoPlayer> get() = _player
    val player: ExoPlayer get() = _player.value

    private var fileId = args.fileId
    private var email: String? = args.accountEmail
    private var file: MediaFileEntity? = null
    private var titleHint = args.title
    private val externals = LinkedHashMap<String, ExternalSubtitle>()
    private var autoSubtitlePending: String? = null
    /** Choices saved for the current video, applied once its tracks are known. */
    private var restore: TrackMemory? = null
    private var triedSoftwareFallback = false
    private var enhancer: LoudnessEnhancer? = null
    private var sleepJob: Job? = null
    private var loadJob: Job? = null

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_ENDED) onEnded()
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (!isPlaying) saveProgress()
        }

        override fun onTracksChanged(tracks: Tracks) {
            if (BuildConfig.DEBUG) logTracks(tracks)
            applyRestore(tracks)
            applyPendingSubtitleChoice(tracks)
        }

        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            enhancer?.release()
            enhancer = null
            if (_ui.value.boost > 0f) setBoost(_ui.value.boost)
        }

        override fun onPlayerError(error: PlaybackException) {
            if (isDecoderError(error) && !_ui.value.softwareDecoding && !triedSoftwareFallback) {
                // The phone's hardware decoder can't handle this file: retry with FFmpeg in software.
                triedSoftwareFallback = true
                setSoftwareDecoding(true, notice = "Switched to software decoding")
            } else {
                _ui.update { it.copy(error = describe(error)) }
            }
        }
    }

    private val analytics = object : AnalyticsListener {
        override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
            _decoders.update { it.copy(video = decoderName) }
        }

        override fun onAudioDecoderInitialized(eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
            _decoders.update { it.copy(audio = decoderName) }
        }

        override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
            _decoders.update { it.copy(droppedFrames = it.droppedFrames + droppedFrames) }
        }
    }

    init {
        val settings = runBlocking { container.settings.current() }
        _ui.update { it.copy(settings = settings) }
        _player = MutableStateFlow(createPlayer(preferSoftware = false))
        open(args)
        viewModelScope.launch {
            while (isActive) {
                delay(10_000)
                if (player.isPlaying) saveProgress()
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Player construction
    // ---------------------------------------------------------------------------------------------

    private fun createPlayer(preferSoftware: Boolean): ExoPlayer {
        val context = container.appContext
        val renderers = DefaultRenderersFactory(context)
            // The bundled FFmpeg build adds audio the platform often lacks (DTS, DTS-HD, TrueHD, AC3,
            // E-AC3, FLAC, ALAC). Video always goes through Android's MediaCodec decoders.
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)
            // "Software decoding" = try Android's built-in software decoders before the hardware ones.
            .apply { if (preferSoftware) setMediaCodecSelector(softwareFirst) }
        val http = OkHttpDataSource.Factory(container.mediaHttp).setUserAgent("Veltoret")
        val drive = ResolvingDataSource.Factory(http, DriveMedia.Resolver(container.auth))
        // Network share files ("smb://…") are read with smbj; everything else that isn't on the device is Drive.
        val upstream = SchemeRoutingDataSource.Factory(SmbDataSource.Factory(container.smbStorage), drive)
        val dataSource = DefaultDataSource.Factory(context, upstream)
            .apply { if (com.pntapps.veltoret.BuildConfig.DEBUG) setTransferListener(DebugTransferLog) }
        // Note: never enable "constant bitrate seeking always" — Drive URLs carry no file extension, and
        // that flag lets the MP3/ADTS sniffers claim MKV files (no tracks, invented duration).
        val extractors = VeltoretExtractorsFactory(DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true))
        val mediaSources = DefaultMediaSourceFactory(BufferedDataSource.Factory(dataSource), extractors)
            // Drive streams over mobile networks hiccup; retry harder before giving up.
            .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(8))
        // Larger buffer than default for high-bitrate remuxes; still capped by memory (byte target).
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(30_000, 90_000, 1_500, 3_000)
            .build()
        return ExoPlayer.Builder(context, renderers)
            .setMediaSourceFactory(mediaSources)
            .setLoadControl(loadControl)
            .setTrackSelector(DefaultTrackSelector(context))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setSeekBackIncrementMs(_ui.value.settings.seekSeconds * 1000L)
            .setSeekForwardIncrementMs(_ui.value.settings.seekSeconds * 1000L)
            .build()
            .also {
                it.addListener(listener)
                it.addAnalyticsListener(analytics)
            }
    }

    /** Rebuilds the player with or without FFmpeg-first decoding, keeping position and choices. */
    fun setSoftwareDecoding(enabled: Boolean, notice: String? = null) {
        val old = player
        val position = old.currentPosition
        val playWhenReady = old.playWhenReady
        val params = old.trackSelectionParameters
        val speed = old.playbackParameters
        old.removeListener(listener)
        old.removeAnalyticsListener(analytics)
        old.release()
        enhancer?.release()
        enhancer = null

        val fresh = createPlayer(preferSoftware = enabled)
        fresh.trackSelectionParameters = params
        fresh.playbackParameters = speed
        _decoders.value = DecoderStats()
        _ui.update { it.copy(softwareDecoding = enabled, error = null, notice = notice ?: it.notice) }
        _player.value = fresh
        if (email != null) {
            fresh.setMediaItem(buildItem(), position)
            fresh.prepare()
            fresh.playWhenReady = playWhenReady || notice != null
        }
        if (_ui.value.boost > 0f) setBoost(_ui.value.boost)
    }

    private val softwareFirst = MediaCodecSelector { mimeType, secure, tunneling ->
        MediaCodecUtil.getDecoderInfos(mimeType, secure, tunneling).sortedBy { if (it.softwareOnly) 0 else 1 }
    }

    /** Debug builds: one line per track with support level and selection, for diagnosing playback reports. */
    private fun logTracks(tracks: Tracks) {
        tracks.groups.forEach { g ->
            for (i in 0 until g.length) {
                val f = g.getTrackFormat(i)
                android.util.Log.d(
                    "VeltoretPlayer",
                    "type=${g.type} mime=${f.sampleMimeType} codecs=${f.codecs} lang=${f.language} " +
                        "support=${androidx.media3.common.C.getFormatSupportString(g.getTrackSupport(i))} selected=${g.isTrackSelected(i)}",
                )
            }
        }
    }

    private fun isDecoderError(e: PlaybackException) = e.errorCode in setOf(
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
    )

    // ---------------------------------------------------------------------------------------------
    // Loading
    // ---------------------------------------------------------------------------------------------

    /** Opens a video; also used when the activity receives a new intent (e.g. from picture-in-picture). */
    fun open(args: PlayerArgs) {
        if (_ui.value.title.isNotEmpty()) saveProgress()
        titleHint = args.title
        loadJob?.cancel()
        loadJob = viewModelScope.launch { load(args.fileId, args.accountEmail, args.fromStart) }
    }

    private suspend fun load(requestedId: String, emailHint: String?, fromStart: Boolean) {
        var found = library.file(requestedId)
        // Offline, a Drive file can't stream, but the same movie or episode may be stored on this device.
        if (found != null && !container.connectivity.isOnline) library.deviceCopy(found)?.let { found = it }
        val entity = found
        val id = entity?.driveId ?: requestedId
        fileId = id
        file = entity
        email = entity?.accountEmail ?: emailHint
        externals.clear()
        restore = prefs.trackMemory(id)
        triedSoftwareFallback = false
        _decoders.update { it.copy(droppedFrames = 0) }
        val account = email
        if (account == null) {
            _ui.update { it.copy(error = "This file isn't linked to a Google account") }
            return
        }

        var title = titleHint ?: entity?.name ?: "Video"
        var subtitle: String? = null
        if (entity?.movieId != null) {
            library.movieEntity(entity.movieId)?.let { m ->
                title = m.title
                subtitle = listOfNotNull(m.year?.toString(), Format.runtime(m.runtimeMin)).joinToString(" · ")
            }
        } else if (entity?.showId != null) {
            library.showEntity(entity.showId)?.let { s -> title = s.name }
            val ep = if (entity.season != null && entity.episode != null) library.episode(entity.showId, entity.season, entity.episode) else null
            subtitle = listOfNotNull(Format.episodeCode(entity.season, entity.episode).ifBlank { null }, ep?.name).joinToString("  ·  ")
        }
        titleHint = null

        val next = entity?.let { library.nextEpisodeFile(it) }
        val previous = entity?.let { library.previousEpisodeFile(it) }
        val resumeAt = if (fromStart) 0L else {
            val key = entity?.let(WatchKeys::forFile) ?: WatchKeys.file(id)
            watch.get(key)?.takeIf { !it.watched && it.positionMs > 10_000 }?.positionMs ?: 0L
        }
        _ui.update {
            it.copy(
                title = title,
                subtitle = subtitle,
                fileName = entity?.name ?: title,
                fileSize = entity?.sizeBytes ?: 0,
                isEpisode = entity?.showId != null,
                showId = entity?.showId,
                next = next,
                nextLabel = next?.let { n -> episodeLabel(n) },
                previous = previous,
                error = null,
                finished = false,
                resumedFrom = resumeAt.takeIf { r -> r > 0 },
                externalSubs = emptyList(),
                selectedExternal = null,
                subtitleOffsetMs = restore?.subtitleOffsetMs ?: 0,
                autoPlayCancelled = false,
                introSkipped = false,
                loadingFrom = when {
                    container.storage.isLocal(account) -> null
                    container.storage.isSmb(account) -> container.storage.rootName(account)
                    else -> "Google Drive"
                },
            )
        }

        applyLanguagePreferences(entity?.showId)
        player.setMediaItem(buildItem(), resumeAt)
        player.prepare()
        player.playWhenReady = true

        // Subtitle files sitting next to the video with the same base name (Movie.srt, Movie.en.srt …).
        if (entity != null) loadSidecarSubtitles(entity)
    }

    private suspend fun episodeLabel(n: MediaFileEntity): String {
        val ep = n.showId?.let { sid -> if (n.season != null && n.episode != null) library.episode(sid, n.season, n.episode) else null }
        return listOfNotNull(Format.episodeCode(n.season, n.episode), ep?.name).joinToString("  ·  ")
    }

    private fun buildItem(): MediaItem = MediaItem.Builder()
        // Device files play straight from storage, network share files by their smb:// id; Drive files stream through DriveMedia.
        .setUri(if (container.storage.isLocal(email) || container.storage.isSmb(email)) Uri.parse(fileId) else DriveMedia.uri(fileId, email!!))
        .setMediaId(fileId)
        .setMediaMetadata(MediaMetadata.Builder().setTitle(_ui.value.title).setSubtitle(_ui.value.subtitle).build())
        .build()

    /** Starts each video with the show's remembered languages, falling back to the global settings. */
    private fun applyLanguagePreferences(showId: Int?) {
        val settings = _ui.value.settings
        val memory = restore
        val audio = memory?.audioLanguage ?: prefs.audioLanguage(showId) ?: settings.preferredAudioLanguage
        val sub = when (memory?.subtitleMode) {
            TrackMemory.SUB_OFF, TrackMemory.SUB_EXTERNAL -> PlayerPrefs.OFF
            TrackMemory.SUB_EMBEDDED -> memory.subtitleLanguage ?: PlayerPrefs.OFF
            else -> prefs.subtitleLanguage(showId) ?: settings.preferredSubtitleLanguage.ifBlank { PlayerPrefs.OFF }
        }
        autoSubtitlePending = sub.takeIf { it != PlayerPrefs.OFF && memory?.subtitleMode == null }
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .clearOverrides()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            .setPreferredAudioLanguage(audio)
            .setPreferredTextLanguage(sub.takeIf { it != PlayerPrefs.OFF })
            // "Off" means off: ignore the file's "default" flag, but still show forced subtitles
            // (signs and foreign-language lines).
            .setIgnoredTextSelectionFlags(if (sub == PlayerPrefs.OFF) C.SELECTION_FLAG_DEFAULT else 0)
            .build()
    }

    /**
     * Re-applies the exact tracks saved for this video once the player knows them. Runs once per
     * video; tracks are matched by position within their type, falling back to language.
     */
    private fun applyRestore(tracks: Tracks) {
        val memory = restore ?: return
        if (tracks.groups.isEmpty()) return
        restore = null
        var params = player.trackSelectionParameters.buildUpon()
        var changed = false
        pick(tracks, C.TRACK_TYPE_AUDIO, memory.audioIndex, memory.audioLanguage)?.let { (g, i) ->
            if (!g.isTrackSelected(i)) {
                params = params.setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i))
                changed = true
            }
        }
        when (memory.subtitleMode) {
            TrackMemory.SUB_OFF -> {
                params = params.clearOverridesOfType(C.TRACK_TYPE_TEXT).setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                changed = true
            }
            TrackMemory.SUB_EMBEDDED -> pick(tracks, C.TRACK_TYPE_TEXT, memory.subtitleIndex, memory.subtitleLanguage)?.let { (g, i) ->
                params = params.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i))
                changed = true
            }
            TrackMemory.SUB_EXTERNAL -> memory.externalSource?.let { source ->
                viewModelScope.launch { restoreExternal(source, memory.externalName ?: "Subtitles") }
            }
        }
        if (changed) player.trackSelectionParameters = params.build()
    }

    /** The track at [ordinal] among tracks of [type] if its language still matches, else the first with [language]. */
    private fun pick(tracks: Tracks, type: Int, ordinal: Int?, language: String?): Pair<Tracks.Group, Int>? {
        val all = tracks.groups.filter { it.type == type }.flatMap { g -> (0 until g.length).map { g to it } }
        val byOrdinal = ordinal?.let { all.getOrNull(it) }
            ?.takeIf { (g, i) -> language == null || g.getTrackFormat(i).language == language }
        return byOrdinal ?: language?.let { lang -> all.firstOrNull { (g, i) -> g.getTrackFormat(i).language == lang } }
    }

    private fun ordinalOf(group: Tracks.Group, index: Int): Int {
        var n = 0
        for (g in player.currentTracks.groups) {
            if (g.type != group.type) continue
            if (g == group) return n + index
            n += g.length
        }
        return index
    }

    /** Reloads a previously added subtitle file ("drive:…", "device:…" or a sidecar "side:…"). */
    private suspend fun restoreExternal(source: String, name: String) {
        externals[source]?.let { selectExternal(source, remember = false); return }
        val account = email ?: return
        runCatching {
            val bytes = when {
                source.startsWith("drive:") || source.startsWith("side:") ->
                    container.storage.read(account, source.substringAfter(':')) { it.readLimited() }
                source.startsWith("device:") -> withContext(Dispatchers.IO) {
                    container.appContext.contentResolver.openInputStream(Uri.parse(source.substringAfter(':')))?.use { it.readLimited() }
                }
                else -> null
            } ?: return
            val cues = withContext(Dispatchers.Default) { SubtitleEngine.parse(bytes, name) }
            if (cues.isNotEmpty()) {
                externals[source] = ExternalSubtitle(source, name, null, cues)
                _ui.update { it.copy(externalSubs = externals.values.map { s -> ExternalSubInfo(s.id, s.label, s.language) }) }
                selectExternal(source, remember = false)
            }
        }
    }

    /** If the preferred subtitle language isn't embedded but a sidecar file has it, use the file. */
    private fun applyPendingSubtitleChoice(tracks: Tracks) {
        val wanted = autoSubtitlePending ?: return
        if (tracks.groups.isEmpty()) return
        val embeddedSelected = tracks.groups.any { it.type == C.TRACK_TYPE_TEXT && it.isSelected }
        if (embeddedSelected) {
            autoSubtitlePending = null
            return
        }
        externals.values.firstOrNull { it.language == wanted }?.let {
            autoSubtitlePending = null
            selectExternal(it.id, remember = false)
        }
    }

    private suspend fun loadSidecarSubtitles(entity: MediaFileEntity) {
        val base = FilenameParser.baseName(entity.name).lowercase()
        val sidecars = runCatching { library.subtitlesBeside(entity) }.getOrDefault(emptyList())
            .filter { it.name.lowercase().startsWith(base) }
        for (sub in sidecars) {
            val tail = FilenameParser.baseName(sub.name).drop(base.length).trim('.', ' ', '_', '-')
            val lang = tail.substringBefore('.').lowercase().takeIf { it.length in 2..3 && it.all(Char::isLetter) }
            runCatching {
                val bytes = container.storage.read(sub.accountEmail, sub.driveId) { it.readLimited() }
                val cues = withContext(Dispatchers.Default) { SubtitleEngine.parse(bytes, sub.name) }
                addExternal(ExternalSubtitle("side:${sub.driveId}", lang?.let { languageName(it) } ?: sub.name, lang, cues), select = false)
            }
        }
        applyPendingSubtitleChoice(player.currentTracks)
    }

    // ---------------------------------------------------------------------------------------------
    // Progress, episodes, sleep timer
    // ---------------------------------------------------------------------------------------------

    fun saveProgress() {
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: file?.durationMs ?: return
        val position = player.currentPosition
        val f = file
        val id = fileId
        container.appScope.launch { watch.savePosition(f, id, position, duration) }
    }

    private fun onEnded() {
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: file?.durationMs ?: 0L
        val f = file
        val id = fileId
        container.appScope.launch { watch.savePosition(f, id, duration, duration) }
        val sleep = _ui.value.sleep
        if (sleep?.endOfEpisode == true) {
            _ui.update { it.copy(sleep = null, notice = "Sleep timer: stopped") }
            return
        }
        val next = _ui.value.next
        if (next != null && _ui.value.settings.autoPlayNext && !_ui.value.autoPlayCancelled) playNext()
        else _ui.update { it.copy(finished = true) }
    }

    fun playNext() {
        val next = _ui.value.next ?: return
        open(PlayerArgs(next.driveId, next.accountEmail, null, fromStart = false))
    }

    fun playPrevious() {
        val previous = _ui.value.previous ?: return
        open(PlayerArgs(previous.driveId, previous.accountEmail, null, fromStart = false))
    }

    fun playEpisode(item: EpisodeItem) = open(PlayerArgs(item.fileId, item.accountEmail, null, fromStart = item.watched))

    fun cancelAutoPlay() = _ui.update { it.copy(autoPlayCancelled = true) }

    fun startOver() {
        player.seekTo(0)
        _ui.update { it.copy(resumedFrom = null) }
    }

    fun dismissResume() = _ui.update { it.copy(resumedFrom = null) }

    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    fun skipForward(seconds: Int) {
        val target = player.currentPosition + seconds * 1000L
        player.seekTo(if (player.duration > 0) minOf(target, player.duration - 1000) else target)
    }

    fun seekBy(deltaMs: Long) {
        val target = (player.currentPosition + deltaMs).coerceAtLeast(0)
        player.seekTo(if (player.duration > 0) minOf(target, player.duration - 500) else target)
    }

    fun skipIntro() {
        skipForward(_ui.value.settings.skipSeconds)
        _ui.update { it.copy(introSkipped = true) }
    }

    suspend fun episodeList(): List<EpisodeItem> {
        val showId = _ui.value.showId ?: return emptyList()
        val files = library.showFilesOnce(showId).filter { it.season != null && it.episode != null }
            .distinctBy { it.season to it.episode }
        val meta = library.episodesOnce(showId).associateBy { it.seasonNumber to it.episodeNumber }
        val states = watch.observeForShow(showId).first().associateBy { it.key }
        return files.sortedWith(compareBy({ if (it.season == 0) Int.MAX_VALUE else it.season }, { it.episode })).map { f ->
            val m = meta[f.season!! to f.episode!!]
            EpisodeItem(
                fileId = f.driveId,
                accountEmail = f.accountEmail,
                season = f.season,
                episode = f.episode,
                name = m?.name?.takeIf { it.isNotBlank() } ?: "Episode ${f.episode}",
                stillUrl = TmdbImages.still(m?.stillPath),
                watched = states[WatchKeys.episode(showId, f.season, f.episode)]?.watched == true,
                current = f.driveId == fileId,
            )
        }
    }

    fun setSleepTimer(minutes: Int?) {
        sleepJob?.cancel()
        if (minutes == null) {
            _ui.update { it.copy(sleep = null) }
            return
        }
        val endsAt = System.currentTimeMillis() + minutes * 60_000L
        _ui.update { it.copy(sleep = SleepTimer(endsAt, endOfEpisode = false)) }
        sleepJob = viewModelScope.launch {
            delay(minutes * 60_000L)
            player.pause()
            _ui.update { it.copy(sleep = null, notice = "Sleep timer: paused") }
        }
    }

    fun setSleepAtEndOfEpisode() {
        sleepJob?.cancel()
        _ui.update { it.copy(sleep = SleepTimer(null, endOfEpisode = true)) }
    }

    // ---------------------------------------------------------------------------------------------
    // Tracks & subtitles
    // ---------------------------------------------------------------------------------------------

    fun selectTrack(group: Tracks.Group, index: Int) {
        if (group.type == C.TRACK_TYPE_TEXT) _ui.update { it.copy(selectedExternal = null) }
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(group.type, false)
            .setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, index))
            .build()
        val language = group.getTrackFormat(index).language?.takeIf { it != "und" }
        val ordinal = ordinalOf(group, index)
        when (group.type) {
            C.TRACK_TYPE_AUDIO -> {
                prefs.setAudioLanguage(_ui.value.showId, language)
                prefs.updateTrackMemory(fileId) { it.copy(audioIndex = ordinal, audioLanguage = language) }
            }
            C.TRACK_TYPE_TEXT -> {
                if (language != null) prefs.setSubtitleLanguage(_ui.value.showId, language)
                prefs.updateTrackMemory(fileId) {
                    it.copy(subtitleMode = TrackMemory.SUB_EMBEDDED, subtitleIndex = ordinal, subtitleLanguage = language, externalSource = null, externalName = null)
                }
            }
        }
    }

    fun disableSubtitles() {
        autoSubtitlePending = null
        _ui.update { it.copy(selectedExternal = null) }
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .build()
        prefs.setSubtitleLanguage(_ui.value.showId, null)
        prefs.updateTrackMemory(fileId) { it.copy(subtitleMode = TrackMemory.SUB_OFF, externalSource = null, externalName = null) }
    }

    fun selectExternal(id: String, remember: Boolean = true) {
        val sub = externals[id] ?: return
        // Hand subtitle drawing to our own engine; the player's text renderer stays off.
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
            .build()
        _ui.update { it.copy(selectedExternal = id) }
        if (remember) {
            if (sub.language != null) prefs.setSubtitleLanguage(_ui.value.showId, sub.language)
            prefs.updateTrackMemory(fileId) {
                it.copy(subtitleMode = TrackMemory.SUB_EXTERNAL, externalSource = id, externalName = sub.label, subtitleIndex = null)
            }
        }
    }

    fun adjustSubtitleOffset(deltaMs: Long) = setSubtitleOffset(_ui.value.subtitleOffsetMs + deltaMs)
    fun resetSubtitleOffset() = setSubtitleOffset(0)

    private fun setSubtitleOffset(ms: Long) {
        _ui.update { it.copy(subtitleOffsetMs = ms) }
        prefs.updateTrackMemory(fileId) { it.copy(subtitleOffsetMs = ms) }
    }

    /** Cues for the selected external subtitle at [positionMs], or null when the player draws subtitles. */
    fun externalCues(positionMs: Long): List<Cue>? {
        val id = _ui.value.selectedExternal ?: return null
        val sub = externals[id] ?: return null
        return SubtitleEngine.activeAt(sub, positionMs * 1000, _ui.value.subtitleOffsetMs * 1000)
    }

    private fun addExternal(sub: ExternalSubtitle, select: Boolean) {
        externals[sub.id] = sub
        _ui.update { it.copy(externalSubs = externals.values.map { s -> ExternalSubInfo(s.id, s.label, s.language) }) }
        if (select) selectExternal(sub.id)
    }

    /** Adds a subtitle file from the device. Returns an error message, or null on success. */
    suspend fun addDeviceSubtitle(uri: Uri, name: String): String? = try {
        val bytes = withContext(Dispatchers.IO) {
            runCatching {
                container.appContext.contentResolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            container.appContext.contentResolver.openInputStream(uri)?.use { it.readLimited() } ?: error("Couldn't open the file")
        }
        val cues = withContext(Dispatchers.Default) { SubtitleEngine.parse(bytes, name) }
        if (cues.isEmpty()) "No subtitles found in $name"
        else {
            addExternal(ExternalSubtitle("device:$uri", name, null, cues), select = true)
            null
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        e.message ?: "Couldn't read $name"
    }

    suspend fun addDriveSubtitle(sub: DriveFile): String? = try {
        val account = email ?: error("No account")
        val bytes = container.storage.read(account, sub.id) { it.readLimited() }
        val cues = withContext(Dispatchers.Default) { SubtitleEngine.parse(bytes, sub.name) }
        if (cues.isEmpty()) "No subtitles found in ${sub.name}"
        else {
            addExternal(ExternalSubtitle("drive:${sub.id}", sub.name, null, cues), select = true)
            null
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        e.message ?: "Couldn't read ${sub.name}"
    }

    /** Subtitle files in the same Drive folder as the video. */
    suspend fun driveSubtitleCandidates(): List<DriveFile> {
        val account = email ?: return emptyList()
        val parent: String = file?.parentId
            ?: (if (container.storage.isLocal(account)) null
            else if (container.storage.isSmb(account)) com.pntapps.veltoret.data.smb.SmbPath.parse(fileId).parent?.id
            else runCatching { container.driveRepository.get(account, fileId).parents.firstOrNull() }.getOrNull())
            ?: return emptyList()
        return container.storage.list(account, parent).filter { FilenameParser.isSubtitle(it.name) }
    }

    private fun java.io.InputStream.readLimited(): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
            require(out.size() <= SubtitleEngine.MAX_BYTES) { "That file is too large to be a subtitle" }
        }
        return out.toByteArray()
    }

    // ---------------------------------------------------------------------------------------------
    // Volume boost
    // ---------------------------------------------------------------------------------------------

    /** [amount] 0..1 maps to up to +10 dB on top of the system's maximum volume. */
    fun setBoost(amount: Float) {
        val value = amount.coerceIn(0f, 1f)
        _ui.update { it.copy(boost = value) }
        val gainMb = (value * 1000).toInt()
        if (gainMb <= 0) {
            enhancer?.enabled = false
            return
        }
        val e = enhancer ?: runCatching { LoudnessEnhancer(player.audioSessionId) }.getOrNull()?.also { enhancer = it } ?: return
        runCatching {
            e.setTargetGain(gainMb)
            e.enabled = true
        }
    }

    // ---------------------------------------------------------------------------------------------

    fun retry() {
        _ui.update { it.copy(error = null) }
        if (player.currentMediaItem == null) {
            open(PlayerArgs(fileId, email, null, fromStart = false))
        } else {
            player.prepare()
            player.play()
        }
    }

    private fun describe(error: PlaybackException): String {
        var cause: Throwable? = error
        while (cause != null) {
            if (cause is AuthRequiredException) return "Your Google account needs to be reconnected in Settings."
            if (cause is com.pntapps.veltoret.data.smb.SmbException) return cause.message ?: "Couldn't read this file from the server."
            cause = cause.cause
        }
        val message = error.cause?.message.orEmpty()
        if (container.storage.isSmb(email) && !container.connectivity.isOnline) {
            return "You're offline. This video is on a network server, so this device needs to be on the same network."
        }
        // IO problems (codes 2xxx) with a network share; decoder and format errors fall through to the usual messages.
        if (container.storage.isSmb(email) && error.errorCode in 2000..2999) {
            return "Couldn't read this video from the network server. Check that it's on and that you're on the same Wi-Fi."
        }
        if (!container.storage.isLocal(email) && !container.connectivity.isOnline) {
            return "You're offline. This video is on Google Drive, so it needs an internet connection. " +
                "Videos on this device still play."
        }
        if (container.storage.isLocal(email) && error.errorCode in setOf(
                PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND,
                PlaybackException.ERROR_CODE_IO_NO_PERMISSION,
                PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
            )
        ) {
            return "This file isn't available on this device. If it's on an SD card or USB drive, make sure it's connected."
        }
        return when {
            "403" in message -> "Google Drive refused the stream (403). The file may have hit its daily download limit — try again later."
            "404" in message -> "This file is no longer in Google Drive."
            error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED ||
                error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> "Network problem. Check your connection and retry."
            error.errorCode == PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED ->
                "This file's container format isn't supported (for example WMV/ASF or RealMedia)."
            isDecoderError(error) -> decoderProblem(error)
            else -> error.errorCodeName.replace("ERROR_CODE_", "").replace('_', ' ').lowercase().replaceFirstChar { it.uppercase() }
        }
    }

    /** Explains which format the device couldn't decode, so people know what to do about it. */
    private fun decoderProblem(error: PlaybackException): String {
        val format = (error as? ExoPlaybackException)?.rendererFormat
        val codecs = format?.codecs.orEmpty()
        val mime = format?.sampleMimeType
        return when {
            mime == null -> "This device can't decode this file's format."
            codecs.startsWith("hvc1.2") || codecs.startsWith("hev1.2") ->
                "This video is 10-bit HEVC (H.265 Main 10), and this device has no decoder for it. " +
                    "An 8-bit H.264 or HEVC version of the file will play."
            mime == MimeTypes.VIDEO_DOLBY_VISION ->
                "This video is Dolby Vision, which this device can't decode."
            MimeTypes.isVideo(mime) -> {
                val size = if (format.width > 0) " at ${format.width}×${format.height}" else ""
                "This device can't decode ${MediaFormats.videoCodec(mime)} video$size."
            }
            MimeTypes.isAudio(mime) -> "This device can't decode the ${MediaFormats.audioCodec(mime)} audio track. Try another audio track."
            else -> "This device can't decode this file's format."
        }
    }

    override fun onCleared() {
        saveProgress()
        sleepJob?.cancel()
        enhancer?.release()
        player.removeListener(listener)
        player.release()
    }

    companion object {
        fun languageName(code: String?): String? {
            if (code.isNullOrBlank() || code == "und") return null
            return java.util.Locale.forLanguageTag(code).getDisplayLanguage(java.util.Locale.US).takeIf { it.isNotBlank() && it != code }
                ?: code.uppercase()
        }
    }
}

/** Debug builds: logs where each read starts, how long it took to open and how much it read. */
private object DebugTransferLog : androidx.media3.datasource.TransferListener {
    private val started = java.util.concurrent.ConcurrentHashMap<androidx.media3.datasource.DataSource, Long>()
    private val bytes = java.util.concurrent.ConcurrentHashMap<androidx.media3.datasource.DataSource, Long>()
    override fun onTransferInitializing(source: androidx.media3.datasource.DataSource, dataSpec: androidx.media3.datasource.DataSpec, isNetwork: Boolean) {
        started[source] = android.os.SystemClock.elapsedRealtime()
        android.util.Log.d("VeltoretIO", "init pos=${dataSpec.position}")
    }
    override fun onTransferStart(source: androidx.media3.datasource.DataSource, dataSpec: androidx.media3.datasource.DataSpec, isNetwork: Boolean) {
        bytes[source] = 0
        android.util.Log.d("VeltoretIO", "open pos=${dataSpec.position} took=${android.os.SystemClock.elapsedRealtime() - (started[source] ?: 0)}ms")
    }
    override fun onBytesTransferred(source: androidx.media3.datasource.DataSource, dataSpec: androidx.media3.datasource.DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
        bytes.merge(source, bytesTransferred.toLong(), Long::plus)
    }
    override fun onTransferEnd(source: androidx.media3.datasource.DataSource, dataSpec: androidx.media3.datasource.DataSpec, isNetwork: Boolean) {
        android.util.Log.d("VeltoretIO", "end pos=${dataSpec.position} read=${bytes[source]} total=${android.os.SystemClock.elapsedRealtime() - (started[source] ?: 0)}ms")
    }
}
