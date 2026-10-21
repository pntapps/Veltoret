import AppKit
import SwiftUI
import VeltoretKit
import FeaturePlayer
import FeatureNetwork
import FeatureSettings

/// Player ↔ cast bridge, the menu bar item's Pause/Resume, and the Playback menu.
@MainActor
extension AppWiring {
    static func connectPlayerAndFiles() {
        PlayerHooks.castButton = { CastPlayerBridge.makeCastButton() }
        CastPlayerBridge.attach(
            pause: { PlayerWindowController.current?.pauseForCast() },
            resume: { ms in PlayerWindowController.current?.resumeAfterCast(positionMs: ms) },
            currentVideo: {
                guard let p = PlayerWindowController.current else { return nil }
                return CastPlayerVideo(fileId: p.fileId, account: p.account, file: p.currentFile, title: p.videoTitle,
                                       subtitle: p.videoSubtitle, positionMs: Int64(p.positionSeconds * 1000))
            })
        MenuBarController.nowPlaying = {
            guard let p = PlayerWindowController.current else { return nil }
            return (title: p.videoTitle, isPlaying: p.isPlaying, toggle: { PlayerCommands.togglePlayPause() })
        }
    }

    static func extendMenuForPlayer(_ main: NSMenu) {
        let item = NSMenuItem(title: "Playback", action: nil, keyEquivalent: "")
        let menu = PlayerCommands.makeMenu()
        menu.title = "Playback"
        item.submenu = menu
        // Before Window and Help.
        main.insertItem(item, at: max(0, main.items.count - 2))
    }
}
