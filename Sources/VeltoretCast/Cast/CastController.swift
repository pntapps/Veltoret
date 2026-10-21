import Foundation
import VeltoretKit

/// Where casting saves and reads watch progress (the core WatchRepository; see `VeltoretCastModule`).
public protocol CastProgressStore: AnyObject, Sendable {
    /// WatchRepository.savePosition(file, fallbackFileId, positionMs, durationMs).
    func savePosition(file: MediaFileEntity?, fallbackFileId: String, positionMs: Int64, durationMs: Int64) async throws
    /// The saved state for what `file` is (WatchKeys.forFile).
    func saved(for file: MediaFileEntity) async throws -> WatchStateEntity?
}

/// Chromecast (Default Media Receiver, videos streamed from `CastServer` on this Mac) and "Play on TV" (Veltoret on
/// a TV plays the title itself, its own copy or this Mac's vlink:// stream) behind one state, as on Android. Watch
/// progress is saved like local playback, so casting and the Mac resume each other.
public final class CastController: @unchecked Sendable {
    public let server: CastServer
    public let tvLink: TvLinkClient
    public let media: CastMediaFactory
    private let open: CastServer.Opener
    private let progress: CastProgressStore
    private let autoPlayNext: () -> Bool
    private let awake = KeepAwake()
    private let lock = NSLock()
    private let bag = SubscriptionBag()

    private var _state = CastState()
    private var client: ChromecastClient?
    private var device: CastDevice?
    private var mediaSessionId: Int64?
    private var loadedSessionId: Int64?
    private var sessionTask: Task<Void, Never>?
    private var linkTask: Task<Void, Never>?
    private var lastSavedAt: Date = .distantPast
    private var finishHandledFor: String?
    private var loadGeneration = 0
    private var served = false

    private var chromecasts: [String: CastDevice] = [:]
    private var tvs: [String: CastDevice] = [:]
    private var discoveryRefs = 0
    private var discoveryTasks: [Task<Void, Never>] = []

    /// Fired on any thread; UI code hops to the main actor.
    public let stateChanged = Event<CastState>()
    public let devicesChanged = Event<Void>()
    /// The receiver never fetched the video after LOAD: most likely the macOS firewall (or a VPN / guest network)
    /// keeps the TV from reaching this Mac.
    public let receiverUnreachable = Event<Void>()

    public init(open: @escaping CastServer.Opener, tvLink: TvLinkClient, progress: CastProgressStore, media: CastMediaFactory,
                autoPlayNext: @escaping () -> Bool) {
        self.open = open
        server = CastServer(open: open)
        self.tvLink = tvLink
        self.progress = progress
        self.media = media
        self.autoPlayNext = autoPlayNext
        server.requestReceived.subscribe { [weak self] in self?.setServed(true) }.store(in: bag)
        tvLink.store.changed.subscribe { [weak self] in self?.refreshPairing() }.store(in: bag)
    }

    public var state: CastState { lock.lock(); defer { lock.unlock() }; return _state }

    private func setServed(_ v: Bool) { lock.withLock { served = v } }
    private var wasServed: Bool { lock.lock(); defer { lock.unlock() }; return served }

    private func update(_ edit: (inout CastState) -> Void) {
        lock.lock()
        var next = _state
        edit(&next)
        _state = next
        lock.unlock()
        stateChanged.fire(next)
    }

    private static func idle(_ it: inout CastState) {
        var n = CastState()
        n.available = it.available; n.positionMs = it.positionMs; n.durationMs = it.durationMs; n.media = it.media
        it = n
    }

    // =============================================================================================
    // Discovery
    // =============================================================================================

    /// Veltoret TVs first, then Chromecasts.
    public var devices: [CastDevice] {
        lock.lock(); defer { lock.unlock() }
        let byName: (CastDevice, CastDevice) -> Bool = { $0.name.lowercased() < $1.name.lowercased() }
        return tvs.values.sorted(by: byName) + chromecasts.values.sorted(by: byName)
    }

    /// Starts looking for TVs (reference-counted; each picker calls start and stop).
    public func startDiscovery() {
        lock.lock()
        discoveryRefs += 1
        if discoveryRefs > 1 { lock.unlock(); return }
        chromecasts.removeAll()
        tvs.removeAll()
        let a = Task.detached { [weak self] in guard let self else { return }; await self.discoverChromecasts() }
        let b = Task.detached { [weak self] in guard let self else { return }; await self.discoverTvs() }
        discoveryTasks = [a, b]
        lock.unlock()
        devicesChanged.fire()
    }

    public func stopDiscovery() {
        lock.lock(); defer { lock.unlock() }
        if discoveryRefs == 0 { return }
        discoveryRefs -= 1
        if discoveryRefs > 0 { return }
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks = []
    }

    private func discoverChromecasts() async {
        while !Task.isCancelled {
            for await s in Bonjour.browse("_googlecast._tcp", window: 10) {
                if Task.isCancelled { break }
                guard let host = s.host else { continue }
                let id = (s.txtValue("id") ?? "").isEmpty ? s.instance : s.txtValue("id")!
                let name = (s.txtValue("fn") ?? "").isEmpty ? s.instance : s.txtValue("fn")!
                let device = CastDevice(id: id, name: name, kind: .chromecast, host: host, port: s.port, model: s.txtValue("md"))
                lock.withLock { chromecasts[id] = device }
                devicesChanged.fire()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func discoverTvs() async {
        while !Task.isCancelled {
            for await tv in tvLink.find(window: 10) {
                if Task.isCancelled { break }
                lock.withLock {
                    tvs[tv.id] = CastDevice(id: tv.id, name: tv.name, kind: .veltoret, host: tv.host, port: tv.port, paired: tv.paired)
                }
                devicesChanged.fire()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Updates "paired" on the found TVs after pairing or forgetting.
    public func refreshPairing() {
        lock.lock()
        for (id, d) in tvs {
            var n = d
            n.paired = tvLink.store.secret(id) != nil
            tvs[id] = n
        }
        lock.unlock()
        devicesChanged.fire()
    }

    // =============================================================================================
    // Connecting
    // =============================================================================================

    /// Connects to a Chromecast or a paired Veltoret TV. Connection errors land in `CastState.error`; an unpaired
    /// Veltoret TV throws `LinkError` (code "unpaired").
    public func connect(_ device: CastDevice) async throws {
        if device.kind == .veltoret {
            if tvLink.store.secret(device.id) == nil { throw LinkError("Pair this Mac with \(device.name) first", code: "unpaired") }
            var tv = device.asLinkTv()
            tv.paired = true
            await connectLink(tv)
            return
        }
        if state.link != nil { await disconnectLink(stopTv: true) }
        if currentClient != nil { await disconnectChromecast(stopApp: true) }
        update { Self.idle(&$0); $0.connecting = true; $0.deviceName = device.name }
        let client: ChromecastClient
        do {
            client = try await ChromecastClient.connect(host: device.host, port: device.port)
            do { try await client.launch() } catch { await client.dispose(); throw error }
        } catch {
            update { Self.idle(&$0); $0.error = "Couldn't connect to \(device.name)" }
            return
        }
        lock.withLock {
            self.client = client
            self.device = device
            mediaSessionId = nil
            loadedSessionId = nil
        }
        client.onMediaStatus = { [weak self] in self?.onMediaStatus($0) }
        client.onReceiverStatus = { [weak self] in self?.onReceiverStatus($0) }
        client.onClosed = { [weak self, weak client] in
            guard let self, let client else { return }
            Task.detached { await self.onChromecastDropped(client) }
        }
        update { $0.connecting = false; $0.connected = true; $0.deviceName = device.name; $0.error = nil }
        Task.detached { try? await client.receiverGetStatus() }
        let poll = Task.detached { [weak self] in guard let self else { return }; await self.pollChromecast(client) }
        lock.withLock { sessionTask = poll }
    }

    private var currentClient: ChromecastClient? { lock.lock(); defer { lock.unlock() }; return client }

    /// Stops casting (and the video on the TV). Returns the TV's last position, for the local player.
    @discardableResult
    public func disconnect() async -> Int64 {
        if state.link != nil { await disconnectLink(stopTv: true) }
        else if currentClient != nil { await disconnectChromecast(stopApp: true) }
        return state.positionMs
    }

    private func disconnectChromecast(stopApp: Bool) async {
        let c: ChromecastClient? = lock.withLock {
            let c = client
            client = nil
            device = nil
            mediaSessionId = nil
            loadedSessionId = nil
            sessionTask?.cancel()
            sessionTask = nil
            return c
        }
        guard let c else { return }
        saveProgress()
        c.onMediaStatus = nil
        c.onReceiverStatus = nil
        if stopApp { await c.stopApp() }
        await c.dispose()
        server.stop()
        awake.release()
        update { Self.idle(&$0) }
    }

    private func onChromecastDropped(_ c: ChromecastClient) async {
        guard currentClient === c else { return }
        await disconnectChromecast(stopApp: false)
    }

    // =============================================================================================
    // "Play on TV" (Veltoret on the TV)
    // =============================================================================================

    private func connectLink(_ tv: LinkTv) async {
        if currentClient != nil { await disconnectChromecast(stopApp: true) }
        update { Self.idle(&$0); $0.connected = true; $0.deviceName = tv.name; $0.link = tv }
        let task = Task.detached { [weak self] in guard let self else { return }; await self.pollLink(tv) }
        lock.withLock {
            linkTask?.cancel()
            linkTask = task
        }
    }

    private func disconnectLink(stopTv: Bool) async {
        let link: LinkTv? = lock.withLock {
            guard let tv = _state.link else { return nil }
            linkTask?.cancel()
            linkTask = nil
            return tv
        }
        guard let tv = link else { return }
        saveProgress()
        if stopTv { try? await tvLink.command(tv, LinkCommand(type: LinkCommand.stop)) }
        server.stop()
        awake.release()
        update { Self.idle(&$0) }
    }

    private func loadLink(_ tv: LinkTv, _ media: CastMedia, startMs: Int64) async {
        lock.withLock { finishHandledFor = nil }
        update {
            $0.media = media; $0.finished = false; $0.error = nil; $0.positionMs = startMs; $0.buffering = true
            $0.playing = false; $0.linkSource = nil; $0.durationMs = media.durationMs > 0 ? media.durationMs : 0
        }
        Task.detached { [weak self] in guard let self else { return }; await self.updateHasNext(media) }
        do {
            // The TV plays its own copy when it has one; this Mac's stream is the fallback.
            try server.start(CastServer.addressFacing(tv.host))
            let stream = TvLinkProtocol.streamUrl(try server.media("v\(CastFormats.javaHash(media.fileId))", account: media.account,
                                                                   fileId: media.fileId, mime: CastFormats.mimeFor(media.name),
                                                                   length: media.sizeBytes))
            let f = media.file
            let request = LinkPlay(title: media.title, subtitle: media.subtitle, fileId: media.fileId,
                                   accountEmail: f?.accountEmail ?? media.account, fileName: f?.name ?? media.fileName,
                                   movieId: f?.movieId, showId: f?.showId, season: f?.season, episode: f?.episode,
                                   streamUrl: stream, startMs: startMs, audioLanguage: media.audioLanguage,
                                   subtitleLanguage: media.subtitleLanguage)
            let source = try await tvLink.play(tv, request)
            if source == LinkStatus.sourcePhone { awake.acquire() }
            update { $0.linkSource = source }
        } catch {
            let message = (error as? LinkError)?.message ?? ""
            update { $0.error = message.isEmpty ? "Couldn't play on \(tv.name)" : message; $0.buffering = false }
        }
    }

    private func linkCommand(_ command: LinkCommand) async {
        guard let tv = state.link else { return }
        do { try await tvLink.command(tv, command) }
        catch { update { $0.error = (error as? LinkError)?.message ?? "\(error)" } }
    }

    public func selectLinkAudio(_ id: String) {
        update { $0.linkAudioSelected = id }
        Task.detached { [weak self] in guard let self else { return }; await self.linkCommand(LinkCommand(type: LinkCommand.audio, track: id)) }
    }

    /// A subtitle id from LinkStatus, or nil for off.
    public func selectLinkSubtitle(_ id: String?) {
        update { $0.linkSubtitleSelected = id }
        Task.detached { [weak self] in guard let self else { return }; await self.linkCommand(LinkCommand(type: LinkCommand.subtitle, track: id)) }
    }

    /// Follows the TV once a second: position, play state, its real audio and subtitle tracks.
    private func pollLink(_ tv: LinkTv) async {
        var wasActive = false
        var failures = 0
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            let status: LinkStatus
            do {
                status = try await tvLink.status(tv)
            } catch {
                if Task.isCancelled { return }
                failures += 1
                let le = error as? LinkError
                if failures >= 6 { update { $0.error = (le?.message.isEmpty == false) ? le!.message : "Lost touch with \(tv.name)" } }
                // Forgotten after a 401: nothing more to do here.
                if le?.code == "unpaired" { await disconnectLink(stopTv: false); return }
                continue
            }
            if Task.isCancelled { return }
            failures = 0
            if !status.active {
                // The player was closed on the TV (Back): the Mac takes over where it stopped.
                if wasActive && !status.ended { await disconnectLink(stopTv: false); return }
                if status.ended {
                    update { $0.playing = false; $0.buffering = false; $0.finished = true }
                    await onFinished()
                }
                continue
            }
            wasActive = true
            let wasPlaying = state.playing
            update {
                $0.playing = status.playing
                $0.buffering = status.buffering
                $0.positionMs = status.positionMs
                if status.durationMs > 0 { $0.durationMs = status.durationMs }
                $0.finished = status.ended
                $0.error = status.error
                if !status.source.isEmpty { $0.linkSource = status.source }
                $0.linkAudio = status.audio
                $0.linkAudioSelected = status.audioSelected
                $0.linkSubtitles = status.subtitles
                $0.linkSubtitleSelected = status.subtitleSelected
            }
            if status.ended { await onFinished() }
            else if wasPlaying && !status.playing { saveProgress() }
            else if status.playing && sinceLastSave > 10 { saveProgress() }
        }
    }

    private var sinceLastSave: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastSavedAt) }

    // =============================================================================================
    // Media
    // =============================================================================================

    /// Sends `media` to the TV, starting at `startMs`.
    public func load(_ media: CastMedia, startMs: Int64) async {
        if let tv = state.link { await loadLink(tv, media, startMs: startMs); return }
        let current: (ChromecastClient, CastDevice, Int)? = lock.withLock {
            guard let client, let device else { return nil }
            loadGeneration += 1
            finishHandledFor = nil
            return (client, device, loadGeneration)
        }
        guard let (client, device, generation) = current else { return }
        do {
            try server.start(CastServer.addressFacing(device.host))
            var patches: [Int64: UInt8]?
            if let keep = media.audioTrack, media.audioOptions.count > 1 {
                let source = try await open(media.account, media.fileId)
                defer { source.close() }
                patches = CastAudio.hideAllBut(await CastAudio.audioTracks(CastAudio.reader(source)), keep: keep)
            }
            let mime = CastFormats.mimeFor(media.name)
            // Each audio choice gets its own URL so the receiver doesn't reuse a cached stream.
            let video = try server.media("v\(CastFormats.javaHash(media.fileId))a\(media.audioTrack ?? 0)", account: media.account,
                                         fileId: media.fileId, mime: mime, length: media.sizeBytes, patches: patches)
            var subtitles: [CastLoadRequest.SubtitleTrack] = []
            for (i, sub) in media.subtitles.enumerated() {
                subtitles.append(.init(name: sub.label, url: try server.text("s\(i)-\(CastFormats.javaHash(sub.id))", sub.vtt),
                                       language: sub.language))
            }
            let active: Int? = media.activeSubtitle.flatMap { a in media.subtitles.firstIndex { $0.id == a } }

            awake.acquire()
            setServed(false)
            update {
                $0.media = media; $0.finished = false; $0.error = nil; $0.positionMs = startMs; $0.buffering = true
                $0.activeSubtitle = active != nil ? media.activeSubtitle : nil
                $0.durationMs = media.durationMs > 0 ? media.durationMs : 0
            }
            Task.detached { [weak self] in guard let self else { return }; await self.updateHasNext(media) }
            Task.detached { [weak self] in guard let self else { return }; await self.watchReachability(generation) }
            let reply = try await client.load { id, session in
                CastLoadRequest.build(requestId: id, sessionId: session, videoUrl: video, contentType: mime, media: media,
                                      startMs: startMs, subtitles: subtitles, activeSubtitleIndex: active)
            }
            // Statuses of the media this LOAD replaced are ignored from now on.
            lock.withLock {
                if generation == loadGeneration, let loaded = Self.sessionIdOf(reply) { loadedSessionId = loaded }
            }
        } catch let e as CastLoadError {
            if isGeneration(generation) { update { $0.error = e.description; $0.buffering = false } }
            if !wasServed { receiverUnreachable.fire() }
        } catch {
            if isGeneration(generation) { update { $0.error = "Couldn't start casting: \(error.localizedDescription)"; $0.buffering = false } }
        }
    }

    private func isGeneration(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return g == loadGeneration }

    /// If the receiver hasn't fetched anything 20 s after LOAD, this Mac is probably unreachable (firewall).
    private func watchReachability(_ generation: Int) async {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        if !isGeneration(generation) || wasServed { return }
        let st = state
        if st.connected && st.link == nil && !st.playing { receiverUnreachable.fire() }
    }

    private func updateHasNext(_ media: CastMedia) async {
        let next = self.media.nextEpisode(media.file)
        update { if $0.media?.fileId == media.fileId { $0.hasNext = next != nil } }
    }

    public func play() {
        if state.link != nil { Task.detached { [weak self] in guard let self else { return }; await self.linkCommand(LinkCommand(type: LinkCommand.play)) }; return }
        mediaCommand("PLAY")
    }

    public func pause() {
        if state.link != nil { Task.detached { [weak self] in guard let self else { return }; await self.linkCommand(LinkCommand(type: LinkCommand.pause)) }; return }
        mediaCommand("PAUSE")
    }

    public func togglePlay() { if state.playing { pause() } else { play() } }

    public func seek(to positionMs: Int64) {
        let ms = max(0, positionMs)
        if state.link != nil { Task.detached { [weak self] in guard let self else { return }; await self.linkCommand(LinkCommand(type: LinkCommand.seek, positionMs: ms)) } }
        else { mediaCommand("SEEK", ["currentTime": Double(ms) / 1000.0]) }
        update { $0.positionMs = ms }
    }

    public func seek(by deltaMs: Int64) { seek(to: state.positionMs + deltaMs) }

    /// Shows subtitle `id` on the Chromecast, or none.
    public func selectSubtitle(_ id: String?) {
        guard let media = state.media else { return }
        let index = media.subtitles.firstIndex { $0.id == id } ?? -1
        mediaCommand("EDIT_TRACKS_INFO", ["activeTrackIds": index >= 0 ? [index + 1] : [Int]()])
        update { $0.activeSubtitle = index >= 0 ? id : nil }
    }

    /// Switches the audio on the Chromecast: the video reloads at the same spot with only that track audible.
    public func switchAudio(_ track: Int64) async {
        let st = state
        guard var media = st.media, st.link == nil, media.audioTrack != track else { return }
        let codec = media.audioOptions.first { $0.track == track }?.codec
        media.audioTrack = track
        media.audioWarning = CastFormats.audioWarning(codec, media.name)
        media.activeSubtitle = st.activeSubtitle
        await load(media, startMs: st.positionMs)
    }

    /// Chromecast volume, 0...1.
    public func setVolume(_ level: Double) {
        guard let c = currentClient else { return }
        update { $0.volume = min(max(level, 0), 1); $0.muted = false }
        Task.detached { try? await c.setVolume(level) }
    }

    public func setMuted(_ muted: Bool) {
        guard let c = currentClient else { return }
        update { $0.muted = muted }
        Task.detached { try? await c.setMuted(muted) }
    }

    /// Plays the next episode on the TV (the remote's "Next episode", and auto-play at the end).
    public func playNext() async {
        guard let next = media.nextEpisode(state.media?.file) else { return }
        let nextMedia = await media.forFile(next)
        var start: Int64 = 0
        if let saved = try? await progress.saved(for: next), !saved.watched, saved.positionMs > 0 { start = saved.positionMs }
        await load(nextMedia, startMs: start)
    }

    private func onFinished() async {
        guard let media = state.media else { return }
        let first: Bool = lock.withLock {
            if finishHandledFor == media.fileId { return false }
            finishHandledFor = media.fileId
            return true
        }
        if !first { return }
        saveProgress(ended: true)
        if !autoPlayNext() { return }
        await playNext()
    }

    private func mediaCommand(_ type: String, _ extra: CastJSON? = nil) {
        let (c, session) = lock.withLock { (client, mediaSessionId) }
        guard let c, let session else { return }
        Task.detached { try? await c.mediaCommand(type, mediaSessionId: session, extra: extra) }
    }

    private func pollChromecast(_ c: ChromecastClient) async {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            let hasSession = lock.withLock { mediaSessionId != nil && client === c }
            if !hasSession { continue }
            try? await c.mediaGetStatus()
        }
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    static func sessionIdOf(_ payload: CastJSON) -> Int64? {
        guard let list = payload["status"] as? [CastJSON], let first = list.first,
              let id = (first["mediaSessionId"] as? NSNumber) else { return nil }
        return id.int64Value
    }

    private func onReceiverStatus(_ payload: CastJSON) {
        guard let s = payload["status"] as? CastJSON, let v = s["volume"] as? CastJSON else { return }
        let level = Self.number(v["level"])
        let muted = (v["muted"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        update { if let level { $0.volume = level }; if let muted { $0.muted = muted } }
    }

    private func onMediaStatus(_ payload: CastJSON) {
        guard let list = payload["status"] as? [CastJSON], let s = list.first else { return }
        if let id = (s["mediaSessionId"] as? NSNumber)?.int64Value {
            lock.lock()
            if let loaded = loadedSessionId, id < loaded { lock.unlock(); return } // the video before the current one
            mediaSessionId = id
            lock.unlock()
        }
        let playerState = s["playerState"] as? String ?? "IDLE"
        let idleReason = s["idleReason"] as? String
        let position = Self.number(s["currentTime"]).map { Int64($0 * 1000) }
        let duration = Self.number((s["media"] as? CastJSON)?["duration"]).map { Int64($0 * 1000) }
        let idle = playerState == "IDLE"
        let finished = idle && idleReason == "FINISHED"
        let failed = idle && idleReason == "ERROR"
        let wasPlaying = state.playing
        let playing = playerState == "PLAYING"
        update {
            $0.playing = playing
            $0.buffering = playerState == "BUFFERING" || playerState == "LOADING"
            if !idle, let p = position { $0.positionMs = p }
            if let d = duration, d > 0 { $0.durationMs = d }
            $0.finished = finished || ($0.finished && idle)
            if failed { $0.error = "The TV couldn't play this video. Its format may not be supported by Chromecast." }
        }
        if finished { Task.detached { [weak self] in guard let self else { return }; await self.onFinished() } }
        else if wasPlaying && !playing { saveProgress() }
        else if playing && sinceLastSave > 10 { saveProgress() }
    }

    /// Watch progress, shared with local playback (resume works both ways).
    public func saveProgress(ended: Bool = false) {
        let st = state
        guard let media = st.media else { return }
        let duration = st.durationMs > 0 ? st.durationMs : (media.file?.durationMs ?? 0)
        if duration <= 0 { return }
        let position = ended ? duration : st.positionMs
        if position <= 0 { return }
        lock.withLock { lastSavedAt = Date() }
        let store = progress
        Task.detached {
            try? await store.savePosition(file: media.file, fallbackFileId: media.fileId, positionMs: position, durationMs: duration)
        }
    }

    /// App exit: stop the TV and the server.
    public func shutdown() {
        let done = DispatchSemaphore(value: 0)
        Task.detached { [weak self] in _ = await self?.disconnect(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
        server.stop()
        awake.release()
        lock.lock()
        discoveryRefs = 0
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks = []
        lock.unlock()
    }
}
