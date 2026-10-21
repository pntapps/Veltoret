import AppKit
import SwiftUI
import VeltoretCast
import VeltoretKit
import VeltoretPlayerKit
import VeltoretUI

/// What the player shows, for casting (the Windows bridge read these from `PlayerWindow`).
public struct CastPlayerVideo: Sendable {
    /// The file id the player plays ("" when nothing is open).
    public var fileId: String
    /// The source account: a Google email, "device" or "smb://host".
    public var account: String?
    /// The library file, when the video is one (else a Files-screen item).
    public var file: MediaFileEntity?
    public var title: String
    public var subtitle: String?
    /// The player's current position.
    public var positionMs: Int64

    public init(fileId: String, account: String?, file: MediaFileEntity?, title: String, subtitle: String? = nil, positionMs: Int64) {
        self.fileId = fileId; self.account = account; self.file = file; self.title = title; self.subtitle = subtitle
        self.positionMs = positionMs
    }
}

/// Hands the open video to the TV and back (Android PlayerViewModel's cast collector, Windows CastPlayerBridge):
/// connecting casts what the player shows (it pauses); a video opened while connected goes to the TV too;
/// disconnecting brings it back to the player, paused at the TV's position. The player needs no cast code: the app
/// target wires it with closures, since FeatureNetwork doesn't depend on FeaturePlayer:
///
/// ```swift
/// PlayerHooks.castButton = { CastPlayerBridge.makeCastButton() }
/// CastPlayerBridge.attach(
///     pause: { PlayerWindowController.current?.pauseForCast() },
///     resume: { ms in PlayerWindowController.current?.resumeAfterCast(positionMs: ms) },
///     currentVideo: { PlayerWindowController.current.map { CastPlayerVideo(fileId: $0.fileId, …) } })
/// ```
@MainActor
public enum CastPlayerBridge {
    private static var pause: (@MainActor () -> Void)?
    private static var resume: (@MainActor (Int64) -> Void)?
    private static var currentVideo: (@MainActor () -> CastPlayerVideo?)?
    private static var describe: (@MainActor () async -> CastMedia?)?

    private static var started = false
    private static var wasConnected = false
    /// The file id the player handed to the TV (Windows `_castFrom`); nil when the TV plays something cast elsewhere.
    private static var castFromFileId: String?
    private static var seenFileId: String?
    private static var audioChosen = Set<String>()
    private static var timer: Timer?
    private static var busy = false
    private static let bag = MainBag()

    /// The cast button for the player's top bar (`PlayerHooks.castButton`): the on-image variant.
    public static func makeCastButton() -> AnyView { AnyView(CastButton(onImage: true)) }

    /// Connects the bridge to the player.
    /// - Parameters:
    ///   - pause: the player's `pauseForCast()` (saves progress, pauses, stops saving while casting).
    ///   - resume: the player's `resumeAfterCast(positionMs:)` (seeks there and stays paused).
    ///   - currentVideo: what the open player shows, nil when no player is open.
    ///   - describe: optional, the player's own CastMedia (its real selected MKV audio track, loaded external
    ///     subtitles converted with `CastSubtitles.toVtt`, sync); without it the library description is used.
    public static func attach(pause: @escaping @MainActor () -> Void,
                              resume: @escaping @MainActor (_ positionMs: Int64) -> Void,
                              currentVideo: @escaping @MainActor () -> CastPlayerVideo?,
                              describe: (@MainActor () async -> CastMedia?)? = nil) {
        self.pause = pause
        self.resume = resume
        self.currentVideo = currentVideo
        self.describe = describe
        start()
    }

    /// Starts following the cast state (idempotent; `FeatureNetworkModule.start()` calls it).
    public static func start() {
        guard !started, let cast = AppServices.cast else { return }
        started = true
        wasConnected = cast.state.connected
        bag.on(cast.stateChanged) { _ in onState(AppServices.cast.state) }
    }

    /// The open player's title (the remote's fallback while the TV hasn't reported one).
    static var currentTitle: String? {
        guard let t = currentVideo?()?.title, !t.isEmpty else { return nil }
        return t
    }

    private static func onState(_ s: CastState) {
        if s.connected && !wasConnected {
            wasConnected = true
            seenFileId = nil
            startTimer()
            Task { await castCurrentPlayer(ask: true) }
        } else if !s.connected && wasConnected {
            wasConnected = false
            stopTimer()
            resumeLocally(s)
        }
    }

    private static func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { watchPlayer() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// A video opened in the player while connected goes to the TV.
    private static func watchPlayer() {
        guard let v = currentVideo?(), !v.fileId.isEmpty else { return }
        if v.fileId == seenFileId { return }
        guard let st = AppServices.cast?.state, st.connected, !st.connecting else { return }
        seenFileId = v.fileId
        if st.media?.fileId == v.fileId && castFromFileId == v.fileId { return }
        Task { await castCurrentPlayer(ask: true) }
    }

    /// Sends the open video to the TV at the player's position; the player pauses.
    public static func castCurrentPlayer(ask: Bool) async {
        guard let v = currentVideo?(), !v.fileId.isEmpty, !busy, let cast = AppServices.cast else { return }
        busy = true
        defer { busy = false }
        pause?()
        let fileId = v.fileId
        seenFileId = fileId
        let startMs = v.positionMs
        guard var media = await describeVideo(v) else { return }
        guard currentVideo?()?.fileId == fileId else { return }
        // Veltoret on a TV plays every track itself; only a Chromecast needs the audio chosen first.
        if ask && cast.state.link == nil && media.audioOptions.count > 1 && !audioChosen.contains(fileId) {
            let track = await CastAudioDialog.ask(deviceName: cast.state.deviceName, options: media.audioOptions, current: media.audioTrack)
            audioChosen.insert(fileId)
            if let track, track != media.audioTrack {
                let codec = media.audioOptions.first { $0.track == track }?.codec
                media.audioTrack = track
                media.audioWarning = CastFormats.audioWarning(codec, media.name)
            }
        }
        guard cast.state.connected else { return }
        castFromFileId = fileId
        await cast.load(media, startMs: startMs)
    }

    /// Casts a library file without the player (e.g. from a page): the TV starts at `startMs`.
    public static func castFile(_ file: MediaFileEntity, startMs: Int64) async {
        guard let cast = AppServices.cast else { return }
        let media = await cast.media.forFile(file)
        castFromFileId = nil
        await cast.load(media, startMs: startMs)
    }

    private static func describeVideo(_ v: CastPlayerVideo) async -> CastMedia? {
        if let describe, let media = await describe() { return media }
        guard let factory = AppServices.cast?.media else { return nil }
        var media: CastMedia
        if let file = v.file {
            media = await factory.forFile(file)
        } else if let account = v.account {
            let name = v.title.isEmpty ? (v.fileId as NSString).lastPathComponent : v.title
            media = await factory.forItem(account: account, fileId: v.fileId, name: name)
        } else {
            return nil
        }
        if media.file == nil && !v.title.trimmingCharacters(in: .whitespaces).isEmpty {
            media.title = v.title
            media.subtitle = v.subtitle ?? media.subtitle
        }
        return media
    }

    /// The cast ended: the player takes over, paused at the TV's position.
    private static func resumeLocally(_ s: CastState) {
        let from = castFromFileId
        castFromFileId = nil
        guard from != nil, let v = currentVideo?(), !v.fileId.isEmpty else { return }
        if s.media == nil || s.media?.fileId == v.fileId {
            resume?(s.media != nil ? s.positionMs : 0)
        } else {
            // The TV moved on to another episode: open that one here (its progress was saved while casting).
            resume?(0)
            if let next = s.media?.file, let playback = AppServices.playback {
                Task { await playback.playFile(next, startOver: false) }
            }
        }
    }
}

/// The library's "cast instead of playing here" helper (`LibraryHooks.castIfConnected`).
@MainActor
public enum CastLauncher {
    /// When a TV is connected, sends `file` there (from its saved position, as Play would) and returns true;
    /// otherwise returns false so the caller plays it on this Mac.
    public static func castIfConnected(_ file: MediaFileEntity) async -> Bool {
        guard let cast = AppServices.cast else { return false }
        let s = cast.state
        guard s.connected, !s.connecting else { return false }
        var startMs: Int64 = 0
        if let saved = try? AppServices.watch?.get(WatchKeys.forFile(file)) {
            startMs = PlayerMath.resumeAt(false, saved.positionMs, saved.watched)
        }
        await CastPlayerBridge.castFile(file, startMs: startMs)
        return true
    }
}
