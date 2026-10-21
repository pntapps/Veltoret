import AppKit
import SwiftUI
import VeltoretKit
import VeltoretUI
import FeatureLibrary
import FeatureNetwork
import FeatureSettings
import FeatureFiles

/// Connects feature modules that can't import each other: the library's hooks, the menu bar item and
/// notifications ↔ the main window, and (in AppWiring+Player) the player ↔ cast bridge and Files.
@MainActor
enum AppWiring {
    static func connectModules() {
        // Library screens → other modules' dialogs and buttons.
        LibraryHooks.connectGoogle = { await ConnectGoogle.run() }
        LibraryHooks.voiceSearch = { await VoiceSearch.listen() }
        LibraryHooks.addNetworkServer = { await AddServerDialog.show() }
        LibraryHooks.reminderDialog = { type, id, season, episode, title, airDate in
            await ReminderDialog.show(type: type, id: id, season: season, episode: episode, title: title, airDate: airDate)
        }
        LibraryHooks.castButton = { AnyView(CastButton()) }
        LibraryHooks.castIfConnected = { file in await CastLauncher.castIfConnected(file) }

        // Notifications and the menu bar item reopen the main window even after it was closed.
        let show: @MainActor () -> Void = { (NSApp.delegate as? AppDelegate)?.showMainWindow() }
        OpenRequests.showMainWindow = show
        MenuBarController.openMainWindow = show

        connectPlayerAndFiles()
    }

    static func extendMenu(_ main: NSMenu) {
        extendMenuForPlayer(main)
    }
}
