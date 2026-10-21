import AppKit
import VeltoretKit
import VeltoretPlayerKit

/// What the app's Playback menu (and anything else) can ask of the open player. Every call is a no-op when no
/// player is open. Single-key shortcuts (Space, ←/→, M, F…) are handled by the player window itself; the menu only
/// uses ⌘ shortcuts, enabled while the player window is key, so typing in the main window is never taken over.
@MainActor
public enum PlayerCommands {
    private static var c: PlayerController? { PlayerWindowController.current?.controller }

    public static var isPlayerOpen: Bool { PlayerWindowController.current != nil }
    /// The player window is the key window (menu items with player-only shortcuts are enabled then).
    public static var isPlayerKey: Bool { PlayerWindowController.current?.window?.isKeyWindow == true }
    public static var isPlaying: Bool { c?.playWhenReady == true }
    public static var hasNextEpisode: Bool { c?.next != nil }
    public static var hasPreviousEpisode: Bool { c?.previous != nil }
    public static var isLocked: Bool { c?.locked == true }
    public static var isMiniPlayer: Bool { c?.isMini == true }
    public static var isMuted: Bool { c?.player.audio?.isMuted == true }

    public static func togglePlayPause() { c?.togglePlay() }
    public static func play() { c?.play() }
    public static func pause() { c?.pause() }
    public static func skipForward() { guard let c else { return }; c.seekWithRipple(true, c.settings.seekSeconds) }
    public static func skipBackward() { guard let c else { return }; c.seekWithRipple(false, c.settings.seekSeconds) }
    public static func startOver() { c?.startOver() }
    public static func skipIntro() { c?.skipIntro() }
    public static func nextEpisode() { c?.playNext() }
    public static func previousEpisode() { c?.playPrevious() }
    public static func volumeUp() { c?.changeVolume(5) }
    public static func volumeDown() { c?.changeVolume(-5) }
    public static func toggleMute() { c?.toggleMute() }
    public static func speedUp() {
        guard let c else { return }
        c.setSpeed(PlayerMath.stepSpeed(c.speed, 1))
        c.showHud(PlayerFormat.speedOption(c.speed), "speedometer")
    }
    public static func speedDown() {
        guard let c else { return }
        c.setSpeed(PlayerMath.stepSpeed(c.speed, -1))
        c.showHud(PlayerFormat.speedOption(c.speed), "speedometer")
    }
    public static func normalSpeed() { c?.setSpeed(1) }
    public static func cycleAudio() { c?.cycleAudio() }
    public static func cycleSubtitles() { c?.cycleSubtitles() }
    public static func subtitlesOff() { c?.disableSubtitles() }
    public static func subtitleEarlier() { c?.nudgeSync(-100) }
    public static func subtitleLater() { c?.nudgeSync(100) }
    public static func cycleAspect() { guard let c else { return }; c.cycleAspect(); c.showHud(c.resize, "aspectratio") }
    public static func toggleFullScreen() { PlayerWindowController.current?.toggleFullscreen() }
    public static func toggleMiniPlayer() { PlayerWindowController.current?.toggleMini() }
    public static func toggleLock() { guard let c else { return }; if c.locked { c.unlock() } else { c.lock() } }
    public static func showVideoInfo() { showPanel(.info) }
    public static func showAudio() { showPanel(.audio) }
    public static func showSubtitles() { showPanel(.subtitles) }
    public static func showEpisodes() { guard let c, c.isEpisode else { return }; showPanel(.episodes) }
    public static func showSleepTimer() { showPanel(.sleep) }
    public static func closePlayer() { PlayerWindowController.current?.close() }
    public static func bringPlayerToFront() { PlayerWindowController.current?.bringToFront() }

    private static func showPanel(_ kind: PanelKind) {
        guard let wc = PlayerWindowController.current else { return }
        if wc.controller.isMini { wc.exitMini() }
        wc.controller.openPanel(kind)
        wc.controller.showControls()
    }

    /// A ready-made "Playback" menu wired to these commands (the app adds it to the menu bar).
    public static func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Playback")
        let t = MenuTarget.shared
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                  tag: Int = 0) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            i.target = t
            i.tag = tag
            menu.addItem(i)
        }
        let arrowRight = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let arrowLeft = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let arrowUp = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let arrowDown = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        item("Play/Pause", #selector(MenuTarget.playPause))
        item("Skip Forward", #selector(MenuTarget.forward), arrowRight)
        item("Skip Back", #selector(MenuTarget.back), arrowLeft)
        item("Start Over", #selector(MenuTarget.startOver))
        item("Skip Intro", #selector(MenuTarget.skipIntro))
        menu.addItem(.separator())
        item("Next Episode", #selector(MenuTarget.next), arrowRight, [.command, .shift])
        item("Previous Episode", #selector(MenuTarget.previous), arrowLeft, [.command, .shift])
        item("Episodes…", #selector(MenuTarget.episodes))
        menu.addItem(.separator())
        item("Volume Up", #selector(MenuTarget.volumeUp), arrowUp)
        item("Volume Down", #selector(MenuTarget.volumeDown), arrowDown)
        item("Mute", #selector(MenuTarget.mute))
        menu.addItem(.separator())
        item("Faster", #selector(MenuTarget.faster))
        item("Slower", #selector(MenuTarget.slower))
        item("Normal Speed", #selector(MenuTarget.normal))
        menu.addItem(.separator())
        item("Audio…", #selector(MenuTarget.audio))
        item("Next Audio Track", #selector(MenuTarget.cycleAudio))
        item("Subtitles…", #selector(MenuTarget.subtitles))
        item("Next Subtitle", #selector(MenuTarget.cycleSubtitles))
        item("Subtitles Off", #selector(MenuTarget.subtitlesOff))
        item("Subtitles Earlier", #selector(MenuTarget.subEarlier))
        item("Subtitles Later", #selector(MenuTarget.subLater))
        menu.addItem(.separator())
        item("Picture Size: Fit / Fill / Stretch", #selector(MenuTarget.aspect))
        item("Mini Player", #selector(MenuTarget.mini), "m", [.command, .option])
        item("Lock Controls", #selector(MenuTarget.lock), "l")
        item("Sleep Timer…", #selector(MenuTarget.sleep))
        item("Video Info", #selector(MenuTarget.info), "i", [.command, .option])
        menu.addItem(.separator())
        item("Close Player", #selector(MenuTarget.closePlayer))
        return menu
    }
}

/// Menu target: validates items (player-only shortcuts need the player window to be key).
@MainActor
final class MenuTarget: NSObject, NSMenuItemValidation {
    static let shared = MenuTarget()

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard PlayerCommands.isPlayerOpen else { return false }
        let needsKey = !menuItem.keyEquivalent.isEmpty
        if needsKey && !PlayerCommands.isPlayerKey { return false }
        switch menuItem.action {
        case #selector(playPause)?:
            menuItem.title = PlayerCommands.isPlaying ? "Pause" : "Play"
        case #selector(next)?: return PlayerCommands.hasNextEpisode
        case #selector(previous)?: return PlayerCommands.hasPreviousEpisode
        case #selector(mute)?: menuItem.state = PlayerCommands.isMuted ? .on : .off
        case #selector(lock)?: menuItem.title = PlayerCommands.isLocked ? "Unlock Controls" : "Lock Controls"
        case #selector(mini)?: menuItem.state = PlayerCommands.isMiniPlayer ? .on : .off
        case #selector(episodes)?, #selector(skipIntro)?:
            return PlayerWindowController.current?.controller.isEpisode == true
        default: break
        }
        return true
    }

    @objc func playPause() { PlayerCommands.togglePlayPause() }
    @objc func forward() { PlayerCommands.skipForward() }
    @objc func back() { PlayerCommands.skipBackward() }
    @objc func startOver() { PlayerCommands.startOver() }
    @objc func skipIntro() { PlayerCommands.skipIntro() }
    @objc func next() { PlayerCommands.nextEpisode() }
    @objc func previous() { PlayerCommands.previousEpisode() }
    @objc func episodes() { PlayerCommands.showEpisodes() }
    @objc func volumeUp() { PlayerCommands.volumeUp() }
    @objc func volumeDown() { PlayerCommands.volumeDown() }
    @objc func mute() { PlayerCommands.toggleMute() }
    @objc func faster() { PlayerCommands.speedUp() }
    @objc func slower() { PlayerCommands.speedDown() }
    @objc func normal() { PlayerCommands.normalSpeed() }
    @objc func audio() { PlayerCommands.showAudio() }
    @objc func cycleAudio() { PlayerCommands.cycleAudio() }
    @objc func subtitles() { PlayerCommands.showSubtitles() }
    @objc func cycleSubtitles() { PlayerCommands.cycleSubtitles() }
    @objc func subtitlesOff() { PlayerCommands.subtitlesOff() }
    @objc func subEarlier() { PlayerCommands.subtitleEarlier() }
    @objc func subLater() { PlayerCommands.subtitleLater() }
    @objc func aspect() { PlayerCommands.cycleAspect() }
    @objc func mini() { PlayerCommands.toggleMiniPlayer() }
    @objc func lock() { PlayerCommands.toggleLock() }
    @objc func sleep() { PlayerCommands.showSleepTimer() }
    @objc func info() { PlayerCommands.showVideoInfo() }
    @objc func closePlayer() { PlayerCommands.closePlayer() }
}
