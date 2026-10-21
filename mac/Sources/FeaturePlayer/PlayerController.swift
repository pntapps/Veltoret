import AppKit
import Foundation
import VLCKit
import VeltoretKit
import VeltoretPlayerKit

/// Receives VLCKit's delegate callbacks (any thread) and hands the state to the controller on the main actor.
final class VlcEvents: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
    var onState: ((VLCMediaPlayerState) -> Void)?

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        onState?(player.state)
    }
}

/// Keeps libVLC's recent error-level log lines (PlayerErrors reads them; libVLC's error event has no reason).
final class VlcErrorLog: NSObject, VLCLogging, @unchecked Sendable {
    var level: VLCLogLevel = .error
    private let lock = NSLock()
    private var lines: [String] = []

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        guard level == .error else { return }
        let module = context?.module ?? ""
        lock.lock()
        lines.append(module.isEmpty ? message : "\(module): \(message)")
        if lines.count > 12 { lines.removeFirst() }
        lock.unlock()
    }

    var recent: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func clear() { lock.lock(); lines.removeAll(); lock.unlock() }
}

/// A restartable one-shot main-thread timer (WPF DispatcherTimer used as a one-shot).
@MainActor
final class OneShot {
    private var timer: Timer?
    private let interval: TimeInterval
    private let action: @MainActor () -> Void

    init(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    var isRunning: Bool { timer != nil }

    func start(_ after: TimeInterval? = nil) {
        stop()
        let t = Timer(timeInterval: after ?? interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.action()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The player's state and logic (Android PlayerViewModel + Windows PlayerWindow/.Playback): one VLC player that keeps
/// playing episode after episode. The window (`PlayerWindowController`) hosts its video view and the SwiftUI chrome,
/// which reads this object; `changed()` re-renders the chrome (the clock calls it every 100 ms).
@MainActor
final class PlayerController: ObservableObject {
    // ---- VLC ----------------------------------------------------------------------------------------
    let videoView: VLCVideoView
    let player: VLCMediaPlayer
    private let events = VlcEvents()
    let errorLog = VlcErrorLog()
    private(set) var media: VLCMedia?
    weak var host: PlayerWindowController?

    var settings: AppSettings
    private var settingsSub: Subscription?
    let prefs: PlayerPrefsStore
    let videoChanged = Event<Void>()

    // ---- The current video ----------------------------------------------------------------------------
    private(set) var fileId = ""
    private(set) var account: String?
    private(set) var file: MediaFileEntity?
    private var titleHint: String?
    private(set) var title = ""
    private(set) var subtitle: String?
    private(set) var next: MediaFileEntity?
    private(set) var previous: MediaFileEntity?
    private(set) var nextLabel: String?
    private(set) var loadingFrom: String?
    private(set) var artworkUrl: String?
    var isEpisode: Bool { file?.showId != nil }
    var showId: Int? { file?.showId }

    /// Choices saved for this video, applied once its tracks are known.
    var restore: TrackMemory?
    var tracksApplied = false
    private var playingSince: Date?
    /// The subtitle language wanted when no per-video memory exists (a sidecar may provide it).
    var autoSubtitlePending: String?
    var wantedAudio: String?
    var wantedSubtitle: String?
    private(set) var resumedFrom: Int64?
    private var resumeShownAt = Date.distantPast
    private(set) var error: String?
    private(set) var ended = false
    var autoPlayCancelled = false
    private(set) var introSkipped = false
    private var triedSoftwareFallback = false
    private(set) var software = false
    private(set) var hdrFormat: HdrFormat = .unknown

    // ---- Playback state -------------------------------------------------------------------------------
    /// "Will play when it can": what the play/pause button shows (never derived from isPlaying).
    private(set) var playWhenReady = false
    private var buffering = false
    /// From the moment a video is asked for until libVLC has it (the spinner shows meanwhile too).
    private var opening = false
    private var loadingStarted = Date()
    private var lastTimeMove = Date.distantPast
    private(set) var speed: Float = 1
    private(set) var volume = 100
    private(set) var resize = "Fit"
    private(set) var zoom = 1.0
    var panX = 0.0
    var panY = 0.0
    private var lastPolledTime: Int64 = -1
    private(set) var streamLength: Int64 = 0
    private var stopping = 0
    private var cachedTime: Int64 = 0
    private var cachedLength: Int64 = 0
    private var appliedAspect: String?
    private var appliedCrop: String?

    // ---- Cast ---------------------------------------------------------------------------------------
    private(set) var castActive = false

    // ---- UI state -----------------------------------------------------------------------------------
    var controlsVisible = true
    var locked = false
    var scrubbing = false
    var scrubFraction = 0.0
    var isMini = false
    var miniControlsVisible = false
    var isFullscreen = false
    private(set) var hud: HudState?
    var ripple: RippleState?
    var rippleVisible = false
    var panel: PanelKind = .none
    var panelVersion = 0
    var panelContent: PanelContent?
    private(set) var closing = false

    // Sleep timer (per window session; survives episode changes)
    private(set) var sleepEndsAt: Date?
    private(set) var sleepEndOfVideo = false

    // Timers
    private var clock: Timer?
    private lazy var hideTimer = OneShot(4) { [weak self] in self?.autoHide() }
    private lazy var hudTimer = OneShot(1) { [weak self] in self?.hud = nil; self?.changed() }
    lazy var rippleTimer = OneShot(0.9) { [weak self] in self?.rippleVisible = false; self?.ripple = nil; self?.changed() }
    private lazy var sleepTimer = OneShot(60) { [weak self] in self?.onSleepTimerFired() }
    private var saveTicks = 0
    private var infoTicks = 0

    // Load
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    // Mac system integration
    let nowPlaying = NowPlaying()
    let displaySleep = DisplaySleepBlocker()

    // Subtitles (PlayerController+Tracks)
    var externals: [ExternalSub] = []
    var slaveSpuIds = Set<Int>()
    var tempFiles: [URL] = []
    var selectedExternal: String?
    var pendingSlave: ExternalSub?
    var queuedSlave: ExternalSub?
    var spuBeforeSlave = Set<Int>()
    var pendingSlaveSince = Date()
    var subtitleOffsetMs: Int64 = 0
    var subtitleBusy = false
    var subtitleError: String?
    var folderSubtitles: [StorageItem]?
    var folderLoading = false
    var episodeRows: [EpisodeRowItem]?

    // Input (PlayerController+Input)
    var keyRepeat = 0
    var holding = false
    var speedBeforeHold: Float = 1
    lazy var holdTimer = OneShot(0.45) { [weak self] in self?.startHold() }
    lazy var clickTimer = OneShot(0.26) { [weak self] in self?.toggleControls() }
    var pressOnVideo = false
    var panning = false

    init() {
        settings = AppServices.settings?.current ?? AppSettings()
        prefs = AppServices.playerPrefs ?? PlayerPrefsStore.shared
        resize = prefs.resizeMode
        videoView = VLCVideoView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        videoView.backColor = .black
        videoView.autoresizingMask = [.width, .height]
        player = VLCMediaPlayer(options: Self.vlcOptions(settings))
        player.drawable = videoView
        player.libraryInstance.loggers = [errorLog]
        events.onState = { [weak self] state in
            Task { @MainActor in self?.onVlcState(state) }
        }
        player.delegate = events
        settingsSub = AppServices.settings?.changed.subscribe { [weak self] s in
            Task { @MainActor in self?.settingsChanged(s) }
        }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
        nowPlaying.attach(NowPlaying.Actions(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlay() },
            next: { [weak self] in self?.playNext() },
            previous: { [weak self] in
                guard let self else { return }
                if self.previous != nil { self.playPrevious() } else { self.seekTo(0) }
            },
            seekBy: { [weak self] in self?.seekBy($0) },
            seekTo: { [weak self] in self?.seekTo($0) }))
    }

    /// libVLC instance options. Subtitle look: white text, black outline, optional 70 % black box, size × subtitleScale.
    static func vlcOptions(_ settings: AppSettings) -> [String] {
        let relSize = Int(min(60, max(4, (16 / max(0.3, Double(settings.subtitleScale))).rounded())))
        var options = [
            "--no-sub-autodetect-file", // sidecars are loaded by Veltoret, once
            "--no-video-title-show",
            "--no-snapshot-preview",
            "--no-mouse-events",
            "--no-keyboard-events",
            "--no-osd",
            "--freetype-color=16777215",
            "--freetype-outline-thickness=4",
            "--freetype-outline-color=0",
            "--freetype-rel-fontsize=\(relSize)",
            "--sub-margin=20",
        ]
        if settings.subtitleBackground {
            options += ["--freetype-background-opacity=179", "--freetype-background-color=0"]
        } else {
            options.append("--freetype-background-opacity=0")
        }
        return options
    }

    private func settingsChanged(_ s: AppSettings) {
        settings = s
        changed()
    }

    /// Re-renders the chrome.
    func changed() { objectWillChange.send() }

    // ---------------------------------------------------------------------------------------------
    // Times
    // ---------------------------------------------------------------------------------------------

    var durationMs: Int64 {
        if stopping > 0 || media == nil { return cachedLength }
        let v = media?.length.value?.int64Value ?? 0
        cachedLength = v > 0 ? v : 0
        return cachedLength
    }

    var positionMs: Int64 {
        if stopping > 0 || media == nil { return cachedTime }
        let v = player.time.value?.int64Value ?? 0
        cachedTime = max(0, v)
        return cachedTime
    }

    /// The position the chrome shows (the scrub position while scrubbing).
    var shownPositionMs: Int64 {
        let d = durationMs
        return scrubbing && d > 0 ? Int64(scrubFraction * Double(d)) : positionMs
    }

    private func cacheTimes() {
        _ = durationMs
        _ = positionMs
    }

    var isLoading: Bool { error == nil && !ended && (opening || (media != nil && buffering)) }

    /// 0 = just started (or not loading), 1 after 5 s, 2 after 15 s; only while it should play.
    var loadingStage: Int {
        if !isLoading || !playWhenReady { return 0 }
        let ms = Date().timeIntervalSince(loadingStarted) * 1000
        return ms >= 15_000 ? 2 : ms >= 5_000 ? 1 : 0
    }

    var loadingHint: String? { isLoading ? PlayerFormat.loadingHint(loadingStage, loadingFrom) : nil }

    var chromeShown: Bool { controlsVisible && !locked && !isMini }

    var resumeVisible: Bool {
        resumedFrom != nil && !isMini && !castActive && Date().timeIntervalSince(resumeShownAt) < 7
    }

    var upNextVisible: Bool {
        !isMini && error == nil && PlayerMath.upNextVisible(next != nil, durationMs, positionMs, autoPlayCancelled, locked,
                                                            sleepEndOfVideo)
    }

    var skipIntroVisible: Bool {
        !isMini && error == nil && !upNextVisible
            && PlayerMath.skipIntroVisible(isEpisode, introSkipped, controlsVisible, locked, positionMs)
    }

    // ---------------------------------------------------------------------------------------------
    // Periodic refresh (100 ms)
    // ---------------------------------------------------------------------------------------------

    private func tick() {
        if closing { return }
        pollPlayer()
        if playWhenReady && !ended && player.isPlaying && !castActive {
            saveTicks += 1
            if saveTicks >= 100 {
                saveTicks = 0
                saveProgress()
            }
        }
        if resumedFrom != nil && Date().timeIntervalSince(resumeShownAt) >= 7 { resumedFrom = nil }
        if panel == .info {
            infoTicks += 1
            if infoTicks % 10 == 0 { refreshPanel() }
        }
        publishNowPlaying()
        changed()
    }

    func publishNowPlaying(force: Bool = false) {
        guard !title.isEmpty else { return }
        nowPlaying.update(title: title, subtitle: subtitle, durationMs: durationMs, positionMs: positionMs,
                          playing: playWhenReady && !ended && !castActive, speed: speed, artworkUrl: artworkUrl, force: force)
    }

    /// Called every 100 ms: buffering fallback, tracks once known, slave subtitle ids.
    private func pollPlayer() {
        guard media != nil, stopping == 0 else { return }
        let time = player.time.value?.int64Value ?? -1
        // VLCKit can stay in "buffering" while it plays; time moving means it plays.
        if time > 0 && lastPolledTime >= 0 && time != lastPolledTime {
            lastTimeMove = Date()
            if playingSince == nil { playingSince = Date() }
            if buffering { buffering = false }
        }
        lastPolledTime = time
        if !tracksApplied, let since = playingSince, Date().timeIntervalSince(since) > 0.4,
           [.playing, .paused, .buffering].contains(player.state) {
            applyTracksOnce()
        }
        pollSlaves()
    }

    // ---------------------------------------------------------------------------------------------
    // VLC events
    // ---------------------------------------------------------------------------------------------

    private func onVlcState(_ state: VLCMediaPlayerState) {
        if closing || media == nil { return }
        switch state {
        case .opening:
            startLoading()
        case .buffering:
            // VLCKit 3 reports buffering (even at 100 %) while it plays: only a stall while it should play counts.
            if playWhenReady && Date().timeIntervalSince(lastTimeMove) > 0.6 { startLoading() }
        case .playing:
            onVlcPlaying()
        case .paused:
            buffering = false
            if playWhenReady && !ended {
                // Not paused by Veltoret: VLCKit 3.7 reports the end of the media as "paused" (keeping the last frame).
                let remaining = durationMs - positionMs
                if (durationMs > 0 && remaining < 3_000) || player.position > 0.995 {
                    onEnded()
                    return
                }
                if let streamError {
                    showError(describe(streamError))
                    return
                }
            }
            saveProgress()
            displaySleep.set(false)
            publishNowPlaying(force: true)
        case .ended:
            if !opening && !ended { onEnded() }
        case .error:
            if !opening { onVlcError() }
        case .esAdded:
            applyAspect()
        default:
            break
        }
        changed()
    }

    private func startLoading() {
        if !buffering { loadingStarted = Date() }
        buffering = true
    }

    private func onVlcPlaying() {
        ended = false
        if playingSince == nil { playingSince = Date() }
        if !playWhenReady {
            // Pause pressed while loading: don't start when ready.
            player.pause()
        } else {
            displaySleep.set(true)
        }
        player.audio?.volume = Int32(volume)
        if abs(player.rate - speed) > 0.001 { player.rate = speed }
        applyAspect()
        publishNowPlaying(force: true)
    }

    // ---------------------------------------------------------------------------------------------
    // Opening a video
    // ---------------------------------------------------------------------------------------------

    /// Opens a video in this window (next/previous/episode list/new request): saves the current one first.
    func open(_ args: PlayerArgs) {
        if !title.isEmpty { saveProgress() }
        titleHint = args.title
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { @MainActor [weak self] in
            await self?.load(args, generation)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { generation == loadGeneration && !closing }

    private func load(_ args: PlayerArgs, _ generation: Int) async {
        do {
            let online = AppServices.connectivity?.isOnline ?? true
            var found = try AppServices.mediaFileDao.file(args.fileId)
            // Offline, a Drive or network file can't stream, but the same title may be stored on this Mac.
            if let f = found, !online, !Accounts.isLocal(f.accountEmail) {
                var copy: MediaFileEntity?
                if let m = f.movieId { copy = try AppServices.mediaFileDao.deviceCopyOfMovie(m) }
                else if let s = f.showId, let se = f.season, let ep = f.episode {
                    copy = try AppServices.mediaFileDao.deviceCopyOfEpisode(showId: s, season: se, episode: ep)
                }
                if let copy { found = copy }
            }
            guard isCurrent(generation) else { return }

            file = found
            fileId = found?.driveId ?? args.fileId
            account = found?.accountEmail ?? args.account
            resetVideoState()
            beginOpening()
            restore = prefs.trackMemory(fileId)
            subtitleOffsetMs = restore?.subtitleOffsetMs ?? 0
            stopCurrentMedia()

            guard let account else {
                title = titleHint ?? found?.name ?? "Video"
                subtitle = nil
                host?.videoTitleChanged()
                showError(PlayerErrors.noAccount)
                videoChanged.fire(())
                return
            }

            // Title and subtitle for the top bar
            var newTitle = titleHint ?? found?.name ?? "Video"
            var newSubtitle: String?
            artworkUrl = nil
            if let movieId = found?.movieId {
                if let movie = try AppServices.catalogDao.movie(movieId) {
                    newTitle = movie.title
                    newSubtitle = [movie.year.map(String.init), PlayerFormat.runtime(movie.runtimeMin)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    artworkUrl = TmdbImages.poster(movie.posterPath)
                }
            } else if let found, let showId = found.showId {
                if let show = try AppServices.catalogDao.show(showId) {
                    newTitle = show.name
                    artworkUrl = TmdbImages.poster(show.posterPath)
                }
                newSubtitle = episodeLabel(found)
                let showFiles = try AppServices.mediaFileDao.forShow(showId)
                next = EpisodeNav.next(found, showFiles, online: online)
                previous = EpisodeNav.previous(found, showFiles, online: online)
                nextLabel = next.map(episodeLabel)
            }
            titleHint = nil
            title = newTitle
            subtitle = newSubtitle

            // Resume
            var resumeAt: Int64 = 0
            if !args.fromStart {
                let key = found.map(WatchKeys.forFile) ?? WatchKeys.file(fileId)
                let state = try AppServices.watch.get(key)
                resumeAt = PlayerMath.resumeAt(false, state?.positionMs, state?.watched == true)
            }
            if resumeAt > 0 {
                resumedFrom = resumeAt
                resumeShownAt = Date()
            }
            loadingFrom = Accounts.isLocal(account) ? nil
                : Accounts.isSmb(account) ? safeRootName(account)
                : "Google Drive"
            host?.videoTitleChanged()
            changed()
            videoChanged.fire(())
            publishNowPlaying(force: true)

            applyLanguagePreferences()
            prepareHdr()
            try await startMedia(startMs: resumeAt, audioLanguage: wantedAudio, subtitleLanguage: wantedSubtitle,
                                 generation: generation)
            guard isCurrent(generation) else { return }
            showControls()

            // Subtitle files next to the video with the same base name (Movie.srt, Movie.en.srt ...).
            await loadSidecars(generation)
        } catch is CancellationError {
        } catch {
            Log.error(error, "player load")
            if isCurrent(generation) { showError(describe(error)) }
        }
        if isCurrent(generation) {
            opening = false
            changed()
        }
    }

    func isCurrentGeneration(_ generation: Int) -> Bool { isCurrent(generation) }
    var currentGeneration: Int { loadGeneration }

    private func beginOpening() {
        opening = true
        loadingStarted = Date()
        playWhenReady = !castActive
        changed()
    }

    private func safeRootName(_ account: String) -> String {
        (try? AppServices.storage.rootName(account))
            ?? account.replacingOccurrences(of: "smb://", with: "", options: .caseInsensitive)
    }

    private func episodeLabel(_ f: MediaFileEntity) -> String {
        let code = PlayerFormat.episodeCode(f.season, f.episode)
        var name: String?
        if let s = f.showId, let se = f.season, let e = f.episode {
            name = (try? AppServices.catalogDao.episode(s, se, e))??.name
        }
        return [code, name].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "  ·  ")
    }

    private func resetVideoState() {
        error = nil
        ended = false
        next = nil
        previous = nil
        nextLabel = nil
        resumedFrom = nil
        autoPlayCancelled = false
        introSkipped = false
        triedSoftwareFallback = false
        tracksApplied = false
        playingSince = nil
        autoSubtitlePending = nil
        speed = 1
        zoom = 1
        panX = 0
        panY = 0
        lastPolledTime = -1
        lastTimeMove = .distantPast
        streamLength = 0
        appliedAspect = nil
        appliedCrop = nil
        errorLog.clear()
        episodeRows = nil
        resetExternals()
    }

    /// Starts each video with remembered languages (Android applyLanguagePreferences).
    private func applyLanguagePreferences() {
        let memory = restore
        let audio = MediaFormats.normalizeLanguage(memory?.audioLanguage ?? prefs.audioLanguage(showId)
                                                   ?? settings.preferredAudioLanguage) ?? "en"
        var sub: String
        switch memory?.subtitleMode {
        case TrackMemory.subOff?, TrackMemory.subExternal?:
            sub = PlayerPrefsStore.off
        case TrackMemory.subEmbedded?:
            sub = memory?.subtitleLanguage ?? PlayerPrefsStore.off
        default:
            let preferred = settings.preferredSubtitleLanguage.trimmingCharacters(in: .whitespaces)
            sub = prefs.subtitleLanguage(showId) ?? (preferred.isEmpty ? PlayerPrefsStore.off : preferred)
        }
        if sub != PlayerPrefsStore.off { sub = MediaFormats.normalizeLanguage(sub) ?? PlayerPrefsStore.off }
        autoSubtitlePending = sub != PlayerPrefsStore.off && memory?.subtitleMode == nil ? sub : nil
        wantedAudio = audio
        wantedSubtitle = sub
    }

    /// The video's HDR format for the chip and Video info: the name at once; a local file's header alongside.
    /// (macOS picks the display's HDR/EDR mode itself, so nothing waits for it.)
    private func prepareHdr() {
        let name = videoFileName
        hdrFormat = HdrProbe.fromFileName(name)
        guard let account, Accounts.isLocal(account) else { return }
        let id = fileId
        Task { @MainActor [weak self] in
            let format = await HdrProbe.detect(account: account, fileId: id, fileName: name)
            guard let self, self.fileId == id else { return }
            self.hdrFormat = format
            self.changed()
        }
    }

    var videoFileName: String? {
        file?.name ?? (account.map(Accounts.isLocal) == true ? (fileId as NSString).lastPathComponent : title)
    }

    private func startMedia(startMs: Int64, audioLanguage: String?, subtitleLanguage: String?, generation: Int) async throws {
        guard let account else { return }
        var options = software ? [":no-videotoolbox", ":avcodec-hw=none"] : [":avcodec-hw=any"]
        if startMs > 0 { options.append(String(format: ":start-time=%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(startMs) / 1000)) }
        if let audioLanguage, !audioLanguage.isEmpty { options.append(":audio-language=" + audioLanguage) }
        let sub = subtitleLanguage ?? PlayerPrefsStore.off
        options.append(":sub-language=" + (sub.isEmpty || sub == PlayerPrefsStore.off ? "none" : sub))

        let newMedia: VLCMedia
        let id = fileId
        if Accounts.isLocal(account) {
            options.append(":file-caching=1000")
            guard FileManager.default.fileExists(atPath: id) else { throw CocoaError(.fileReadNoSuchFile) }
            newMedia = VLCMedia(path: id)
            streamLength = file?.sizeBytes
                ?? ((try? FileManager.default.attributesOfItem(atPath: id)[.size] as? NSNumber)?.int64Value ?? 0)
        } else {
            options += [":network-caching=3000", ":file-caching=3000", ":http-reconnect"]
            let name = file?.name ?? videoFileName ?? "video"
            let url = try await MediaStreamServer.shared.url(account: account, fileId: id, name: name)
            newMedia = VLCMedia(url: url)
            streamLength = file?.sizeBytes ?? 0
        }
        guard isCurrent(generation) else { throw CancellationError() }
        for o in options { newMedia.addOption(o) }

        media = newMedia
        opening = false
        playWhenReady = !castActive
        buffering = true
        loadingStarted = Date()
        playingSince = nil
        tracksApplied = false
        ended = false
        lastPolledTime = -1
        player.media = newMedia
        player.play()
        player.rate = 1
        if playWhenReady { displaySleep.set(true) }
        changed()
    }

    /// Stops and forgets the current media.
    private func stopCurrentMedia() {
        guard media != nil else { return }
        cacheTimes()
        stopping += 1
        media = nil
        player.stop()
        stopping -= 1
    }

    /// The window closes: save, stop everything, free the player.
    func close() {
        if closing { return }
        saveProgress()
        closing = true
        clock?.invalidate()
        clock = nil
        hideTimer.stop()
        hudTimer.stop()
        rippleTimer.stop()
        sleepTimer.stop()
        holdTimer.stop()
        clickTimer.stop()
        loadTask?.cancel()
        settingsSub?.cancel()
        displaySleep.set(false)
        nowPlaying.clear()
        events.onState = nil
        player.delegate = nil
        if media != nil {
            media = nil
            player.stop()
        }
        player.drawable = nil
        cleanupTempSubtitles()
    }

    // ---------------------------------------------------------------------------------------------
    // Transport
    // ---------------------------------------------------------------------------------------------

    func play() {
        guard media != nil else { return }
        playWhenReady = true
        if [.ended, .stopped].contains(player.state) { player.play() }
        else if !player.isPlaying { player.play() }
        displaySleep.set(true)
        publishNowPlaying(force: true)
        changed()
    }

    func pause() {
        playWhenReady = false
        if media != nil && player.canPause { player.pause() }
        saveProgress()
        displaySleep.set(false)
        publishNowPlaying(force: true)
        changed()
    }

    /// The play/pause button: replay after the end, else follow playWhenReady.
    func togglePlay() {
        if ended {
            open(PlayerArgs(fileId: fileId, account: account, fromStart: true))
            return
        }
        if playWhenReady { pause() } else { play() }
    }

    func seekTo(_ ms: Int64) {
        guard media != nil else { return }
        if ended {
            open(PlayerArgs(fileId: fileId, account: account, fromStart: ms <= 0))
            return
        }
        player.time = VLCTime(number: NSNumber(value: max(0, ms)))
        cachedTime = max(0, ms)
        lastPolledTime = -1
        publishNowPlaying(force: true)
        changed()
    }

    func seekBy(_ deltaMs: Int64) { seekTo(PlayerMath.seekBy(positionMs, durationMs, deltaMs)) }

    func setSpeed(_ value: Float) {
        speed = value
        player.rate = value
        publishNowPlaying(force: true)
        changed()
    }

    func changeVolume(_ delta: Int) {
        volume = min(200, max(0, volume + delta))
        player.audio?.volume = Int32(volume)
        if player.audio?.isMuted == true && delta > 0 { player.audio?.isMuted = false }
        showHud(PlayerFormat.volume(volume), "speaker.wave.2.fill")
    }

    func toggleMute() {
        guard let audio = player.audio else { return }
        audio.isMuted.toggle()
        showHud(audio.isMuted ? "Muted" : PlayerFormat.volume(volume), audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    func startOver() {
        seekTo(0)
        resumedFrom = nil
        changed()
    }

    func skipIntro() {
        seekTo(PlayerMath.skipForward(positionMs, durationMs, settings.skipSeconds))
        introSkipped = true
        changed()
    }

    // ---------------------------------------------------------------------------------------------
    // Aspect: Fit / Fill / Stretch, zoom and pan
    // ---------------------------------------------------------------------------------------------

    func videoSize() -> (width: Int, height: Int) {
        let s = player.videoSize
        if s.width > 0 && s.height > 0 { return (Int(s.width), Int(s.height)) }
        if let v = trackInfos(VLCMediaTracksInformationTypeVideo).first {
            let w = (v[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0
            let h = (v[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0
            return (w, h)
        }
        return (0, 0)
    }

    func cycleAspect() {
        resize = resize == "Fit" ? "Fill" : resize == "Fill" ? "Stretch" : "Fit"
        prefs.resizeMode = resize
        zoom = 1
        panX = 0
        panY = 0
        applyAspect()
        changed()
    }

    var aspectChipText: String { zoom > 1.001 ? "Zoom" : resize }

    func applyAspect() {
        guard media != nil else { return }
        let bounds = videoView.bounds
        let w = max(1, bounds.width.rounded())
        let h = max(1, bounds.height.rounded())
        let (vw, vh) = videoSize()
        let aspect = resize == "Stretch" ? "\(Int(w)):\(Int(h))" : nil
        let crop = PlayerMath.cropGeometry(vw, vh, Double(w), Double(h), fill: resize == "Fill", zoom, panX, panY)
        player.scaleFactor = 0
        if aspect != appliedAspect {
            appliedAspect = aspect
            Self.setVlcString(aspect) { player.videoAspectRatio = $0 }
        }
        if crop != appliedCrop {
            appliedCrop = crop
            Self.setVlcString(crop) { player.videoCropGeometry = $0 }
        }
    }

    private static func setVlcString(_ value: String?, _ set: (UnsafeMutablePointer<CChar>?) -> Void) {
        guard let value else { set(nil); return }
        let p = strdup(value)
        set(p)
        free(p)
    }

    func setZoom(_ value: Double) {
        zoom = PlayerMath.clampZoom(value)
        if zoom <= 1 {
            panX = 0
            panY = 0
        }
        applyAspect()
        showHud(PlayerFormat.zoom(zoom), "plus.magnifyingglass")
    }

    // ---------------------------------------------------------------------------------------------
    // Episodes
    // ---------------------------------------------------------------------------------------------

    func playNext() {
        guard let n = next else { return }
        open(PlayerArgs(fileId: n.driveId, account: n.accountEmail, fromStart: false))
    }

    func playPrevious() {
        guard let p = previous else { return }
        open(PlayerArgs(fileId: p.driveId, account: p.accountEmail, fromStart: false))
    }

    // ---------------------------------------------------------------------------------------------
    // Progress and the end
    // ---------------------------------------------------------------------------------------------

    /// Saves progress (fire-and-forget, so closing the window doesn't cancel it).
    func saveProgress(sync: Bool = false) {
        guard !castActive, media != nil, stopping == 0, !fileId.isEmpty, !closing else { return }
        let length = durationMs
        let duration = length > 0 ? length : file?.durationMs ?? 0
        guard duration > 0, let raw = player.time.value?.int64Value, raw >= 0 else { return }
        if sync {
            do { try AppServices.watch.savePosition(file, fallbackFileId: fileId, positionMs: raw, durationMs: duration) }
            catch { Log.error(error, "save progress") }
        } else {
            Self.save(file, fileId, raw, duration)
        }
    }

    private static func save(_ file: MediaFileEntity?, _ id: String, _ position: Int64, _ duration: Int64) {
        DispatchQueue.global(qos: .utility).async {
            do { try AppServices.watch.savePosition(file, fallbackFileId: id, positionMs: position, durationMs: duration) }
            catch { Log.error(error, "save progress") }
        }
    }

    private func onEnded() {
        let duration = durationMs > 0 ? durationMs : file?.durationMs ?? 0
        let position = cachedTime
        // A stream that broke off (server gone, Drive refused) ends early: that's an error, not the end.
        if let account, !Accounts.isLocal(account), duration > 0, position < duration - 5_000,
           let streamError = MediaStreamServer.shared.lastError(account: account, fileId: fileId) {
            showError(describe(streamError))
            return
        }
        ended = true
        buffering = false
        playWhenReady = false
        displaySleep.set(false)
        if duration > 0 && !castActive { Self.save(file, fileId, duration, duration) }
        publishNowPlaying(force: true)
        if sleepEndOfVideo {
            sleepEndOfVideo = false
            notice("Sleep timer: stopped")
            showControls()
            return
        }
        if next != nil && settings.autoPlayNext && !autoPlayCancelled { playNext() }
        else { host?.close() }
    }

    // ---------------------------------------------------------------------------------------------
    // Errors and decoding
    // ---------------------------------------------------------------------------------------------

    private var streamError: Error? {
        guard let account, !Accounts.isLocal(account) else { return nil }
        return MediaStreamServer.shared.lastError(account: account, fileId: fileId)
    }

    private func onVlcError() {
        let log = errorLog.recent
        if streamError == nil && PlayerErrors.looksLikeDecoderError(log) && !software && !triedSoftwareFallback {
            // The hardware decoder can't handle this file: retry in software, once.
            triedSoftwareFallback = true
            setSoftwareDecoding(true, notice: "Switched to software decoding")
            return
        }
        showError(describe(streamError))
    }

    func describe(_ e: Error?) -> String {
        var video: (fourCC: String, profile: Int, width: Int, height: Int)?
        var audio: String?
        if let v = trackInfos(VLCMediaTracksInformationTypeVideo).first,
           let codec = (v[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value, codec != 0 {
            video = (MediaFormats.fourCC(codec), (v[VLCMediaTracksInformationCodecProfile] as? NSNumber)?.intValue ?? 0,
                     (v[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0,
                     (v[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0)
        }
        let currentAudio = Int(player.currentAudioTrackIndex)
        if let a = trackInfos(VLCMediaTracksInformationTypeAudio).first(where: {
            ($0[VLCMediaTracksInformationId] as? NSNumber)?.intValue == currentAudio
        }), let codec = (a[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value, codec != 0 {
            audio = MediaFormats.fourCC(codec)
        }
        return PlayerErrors.describe(e, log: errorLog.recent, account: account, fileId: fileId,
                                     online: AppServices.connectivity?.isOnline ?? true, video: video, audioFourCC: audio)
    }

    func showError(_ message: String) {
        error = message
        buffering = false
        opening = false
        playWhenReady = false
        displaySleep.set(false)
        showControls()
        changed()
    }

    func retry() {
        error = nil
        if media == nil { open(PlayerArgs(fileId: fileId, account: account, fromStart: false)) }
        else { rebuildMedia(play: true) }
    }

    /// Software decoding on/off: reloads the media keeping position, play/pause, tracks and speed.
    func setSoftwareDecoding(_ enabled: Bool, notice text: String? = nil) {
        let hadError = error != nil
        software = enabled
        error = nil
        rebuildMedia(play: playWhenReady || text != nil || hadError)
        if let text { notice(text) }
        refreshPanelIfOpen()
    }

    func rebuildMedia(play: Bool) {
        guard account != nil else { return }
        beginOpening()
        let position = positionMs
        let keptSpeed = speed
        // Keep the current track choices as this video's restore point.
        let audio = audioTracks()
        let current = audio.first { $0.id == Int(player.currentAudioTrackIndex) }
        let subs = embeddedSubtitleTracks()
        let spu = subs.first { $0.id == Int(player.currentVideoSubTitleIndex) }
        restore = TrackMemory(
            audioIndex: current?.ordinal, audioLanguage: current?.language,
            subtitleMode: selectedExternal != nil ? TrackMemory.subExternal : spu != nil ? TrackMemory.subEmbedded : TrackMemory.subOff,
            subtitleIndex: spu?.ordinal, subtitleLanguage: spu?.language,
            externalSource: selectedExternal, externalName: externals.first { $0.id == selectedExternal }?.label,
            subtitleOffsetMs: subtitleOffsetMs)
        for x in externals { x.spuId = nil }
        slaveSpuIds.removeAll()
        pendingSlave = nil
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.stopCurrentMedia()
                try await self.startMedia(startMs: position, audioLanguage: self.wantedAudio,
                                          subtitleLanguage: PlayerPrefsStore.off, generation: generation)
                self.speed = keptSpeed
                if !play { self.playWhenReady = false }
            } catch is CancellationError {
            } catch {
                Log.error(error, "player rebuild")
                if self.isCurrent(generation) { self.showError(self.describe(error)) }
            }
            if self.isCurrent(generation) {
                self.opening = false
                self.changed()
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Cast hooks
    // ---------------------------------------------------------------------------------------------

    func pauseForCast() {
        saveProgress()
        pause()
        castActive = true
        resumedFrom = nil
        publishNowPlaying(force: true)
        changed()
    }

    func resumeAfterCast(positionMs ms: Int64) {
        castActive = false
        if ms > 0 { seekTo(ms) }
        pause()
    }

    // ---------------------------------------------------------------------------------------------
    // Controls visibility
    // ---------------------------------------------------------------------------------------------

    var panelOpen: Bool { panel != .none }

    func bumpInteraction() {
        hideTimer.start()
    }

    func showControls() {
        if isMini {
            miniControlsVisible = true
            bumpInteraction()
            changed()
            return
        }
        if !controlsVisible {
            controlsVisible = true
            host?.chromeVisibilityChanged()
        }
        bumpInteraction()
        changed()
    }

    func hideControls() {
        guard controlsVisible else { return }
        controlsVisible = false
        host?.chromeVisibilityChanged()
        changed()
    }

    func toggleControls() {
        if controlsVisible { hideControls() } else { showControls() }
    }

    private func autoHide() {
        hideTimer.stop()
        if isMini {
            miniControlsVisible = false
            changed()
            return
        }
        let playing = playWhenReady && !ended
        if controlsVisible && playing && !panelOpen && !scrubbing { hideControls() }
        if !controlsVisible && playing && !panelOpen { host?.hideCursor() }
    }

    func lock() {
        locked = true
        controlsVisible = true
        host?.chromeVisibilityChanged()
        bumpInteraction()
        changed()
    }

    func unlock() {
        locked = false
        controlsVisible = true
        host?.chromeVisibilityChanged()
        bumpInteraction()
        changed()
    }

    // ---------------------------------------------------------------------------------------------
    // HUD and notices
    // ---------------------------------------------------------------------------------------------

    func showHud(_ text: String, _ icon: String, sticky: Bool = false) {
        hud = HudState(text: text, icon: icon)
        if sticky { hudTimer.stop() } else { hudTimer.start() }
        changed()
    }

    func hideHud() {
        hudTimer.stop()
        hud = nil
        changed()
    }

    /// One-off notice ("Switched to software decoding", "Sleep timer: paused").
    func notice(_ text: String) { showHud(text, "info.circle") }

    // ---------------------------------------------------------------------------------------------
    // Sleep timer
    // ---------------------------------------------------------------------------------------------

    func setSleepTimer(_ minutes: Int?) {
        sleepTimer.stop()
        sleepEndOfVideo = false
        sleepEndsAt = nil
        guard let m = minutes else { changed(); return }
        sleepEndsAt = Date().addingTimeInterval(TimeInterval(m * 60))
        sleepTimer.start(TimeInterval(m * 60))
        changed()
    }

    func setSleepAtEndOfVideo() {
        sleepTimer.stop()
        sleepEndsAt = nil
        sleepEndOfVideo = true
        changed()
    }

    private func onSleepTimerFired() {
        sleepEndsAt = nil
        pause()
        notice("Sleep timer: paused")
    }
}
