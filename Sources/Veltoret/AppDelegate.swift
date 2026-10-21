import AppKit
import SwiftUI
import VeltoretKit
import VeltoretPlayerKit
import VeltoretDrive
import VeltoretSmb
import VeltoretCast
import VeltoretPlans
import VeltoretUI
import FeatureLibrary
import FeaturePlayer
import FeatureFiles
import FeatureNetwork
import FeatureSettings

/// Creates every service (AppServices), the main window and the menus (Windows: App.xaml.cs + MainWindow).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var pendingOpenFiles: [URL] = []
    private var started = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            try AppServices.initFoundation()
        } catch {
            Log.error(error, "Opening the library database")
            let alert = NSAlert()
            alert.messageText = "Veltoret can't open its library"
            alert.informativeText = "\(error.localizedDescription)\n\nThe database is in ~/Library/Application Support/Veltoret."
            alert.runModal()
            exit(1)
        }
        // Order matters: foundation → Core → file sources → player → plans → cast → UI → features.
        CoreModule.initialize()
        VeltoretDriveModule.initialize()
        VeltoretSmbModule.initialize()
        VeltoretPlayerKitModule.initialize()
        VeltoretPlansModule.initialize()
        VeltoretCastModule.initialize()
        VeltoretUIModule.initialize()
        FeatureLibraryModule.initialize()
        FeaturePlayerModule.initialize()
        FeatureFilesModule.initialize()
        FeatureNetworkModule.initialize()
        FeatureSettingsModule.initialize()
        AppWiring.connectModules()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened at login (SMAppService) → stay in the menu bar, like Windows' "--background".
        if !(LoginItem.launchedAtLogin && AppServices.settings.current.onboardingComplete) {
            showMainWindow()
        }
        startServices()
        if !pendingOpenFiles.isEmpty { openFiles(pendingOpenFiles); pendingOpenFiles = [] }
    }

    private func startServices() {
        guard !started else { return }
        started = true
        CoreModule.start()
        VeltoretDriveModule.start()
        VeltoretSmbModule.start()
        VeltoretPlayerKitModule.start()
        VeltoretPlansModule.start()
        VeltoretCastModule.start()
        VeltoretUIModule.start()
        FeatureLibraryModule.start()
        FeaturePlayerModule.start()
        FeatureFilesModule.start()
        FeatureNetworkModule.start()
        FeatureSettingsModule.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FeaturePlayerModule.shutdown()
        FeatureNetworkModule.shutdown()
        FeatureSettingsModule.shutdown()
        VeltoretCastModule.shutdown()
        VeltoretSmbModule.shutdown()
        VeltoretDriveModule.shutdown()
        VeltoretPlayerKitModule.shutdown()
        VeltoretPlansModule.shutdown()
        CoreModule.shutdown()
    }

    /// With "Keep running in the menu bar" the app stays alive when its last window closes, so reminders,
    /// new-episode alerts and scans keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppServices.settings.current.runInBackground
    }

    /// Dock icon click with no visible window → show the main window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Videos opened from Finder ("Open With → Veltoret" or dropped on the Dock icon) play directly.
    func application(_ application: NSApplication, open urls: [URL]) {
        if started { openFiles(urls) } else { pendingOpenFiles.append(contentsOf: urls) }
    }

    private func openFiles(_ urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL }) else { return }
        VeltoretPlaybackLauncher.openLocalFile(url)
    }

    // MARK: Main window

    func showMainWindow() {
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Veltoret"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: MainShell())
            w.setFrameAutosaveName("VeltoretMainWindow")
            if !w.setFrameUsingName("VeltoretMainWindow") { w.center() }
            w.tabbingMode = .disallowed
            mainWindow = w
        }
        ShellCommands.showMainWindow()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
