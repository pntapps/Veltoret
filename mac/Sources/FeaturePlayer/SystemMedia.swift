import AppKit
import Foundation
import IOKit.pwr_mgt
import MediaPlayer
import VeltoretKit

/// Keeps the display awake while a video plays (Windows SetThreadExecutionState / Android FLAG_KEEP_SCREEN_ON).
@MainActor
final class DisplaySleepBlocker {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func set(_ on: Bool) {
        if on == held { return }
        if on {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Veltoret is playing a video" as CFString, &id)
            if r == kIOReturnSuccess { assertion = id; held = true }
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            held = false
        }
    }
}

/// Now Playing (Control Center, the menu bar's Now Playing, media keys, AirPods) for the player window.
@MainActor
final class NowPlaying {
    struct Actions {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seekBy: (Int64) -> Void
        var seekTo: (Int64) -> Void
    }

    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkUrl: String?
    private var artwork: MPMediaItemArtwork?
    private var lastPublished = Date.distantPast

    func attach(_ actions: Actions) {
        detachCommands()
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ body: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            let token = command.addTarget { event in
                if Thread.isMainThread { return MainActor.assumeIsolated { body(event) } }
                nonisolated(unsafe) let e = event
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = body(e) } }
                return .success
            }
            targets.append((command, token))
        }
        add(center.playCommand) { _ in actions.play(); return .success }
        add(center.pauseCommand) { _ in actions.pause(); return .success }
        add(center.togglePlayPauseCommand) { _ in actions.toggle(); return .success }
        add(center.nextTrackCommand) { _ in actions.next(); return .success }
        add(center.previousTrackCommand) { _ in actions.previous(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { _ in actions.seekBy(10_000); return .success }
        add(center.skipBackwardCommand) { _ in actions.seekBy(-10_000); return .success }
        add(center.changePlaybackPositionCommand) { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            actions.seekTo(Int64(e.positionTime * 1000))
            return .success
        }
    }

    private func detachCommands() {
        for (command, token) in targets { command.removeTarget(token) }
        targets = []
    }

    /// Publishes title, subtitle, times and rate. Cheap to call often (throttled to once a second unless forced).
    func update(title: String, subtitle: String?, durationMs: Int64, positionMs: Int64, playing: Bool, speed: Float,
                artworkUrl: String?, force: Bool = false) {
        if !force && Date().timeIntervalSince(lastPublished) < 1 { return }
        lastPublished = Date()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(max(0, positionMs)) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(speed) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let subtitle, !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        if durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000 }
        if artworkUrl != self.artworkUrl {
            self.artworkUrl = artworkUrl
            artwork = nil
            if let artworkUrl { loadArtwork(artworkUrl) }
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }

    private func loadArtwork(_ url: String) {
        Task { @MainActor [weak self] in
            guard let file = await AppServices.images?.file(for: url), let image = NSImage(contentsOf: file) else { return }
            guard let self, self.artworkUrl == url else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.lastPublished = .distantPast
        }
    }

    func clear() {
        detachCommands()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        artworkUrl = nil
        artwork = nil
    }
}
