import AppKit
import Foundation
import VeltoretKit

/// The UI module: design system, navigation, shell, dialogs, toasts. See `Sources/VeltoretUI/README.md`.
public enum VeltoretUIModule {
    nonisolated(unsafe) private static var subs: [Subscription] = []

    /// Registers the fonts, routes `AppServices.toast` / `AppServices.navigate` to the shell, and attaches the theme
    /// to settings. Call after the foundation and before the feature modules (they register pages here).
    @MainActor
    public static func initialize() {
        Fonts.register()
        ThemeState.shared.attach()
        AppServices.toast = { message in Toast.show(message) }
        AppServices.navigate = { route in
            ShellCommands.showMainWindow()
            Navigator.shared.navigate(route)
        }
    }

    /// Binds the shell's offline label and scan indicator to Connectivity and the library scanner (call after Core
    /// started). Safe when those services are missing.
    @MainActor
    public static func start() {
        ThemeState.shared.attach()
        subs.removeAll()
        if let c = AppServices.connectivity {
            ShellStatus.shared.isOffline = !c.isOnline
            subs.append(c.onlineChanged.subscribe { online in
                Task { @MainActor in ShellStatus.shared.isOffline = !online }
            })
        }
        if let scanner = AppServices.scanner {
            apply(scanner.state)
            subs.append(scanner.stateChanged.subscribe { state in
                Task { @MainActor in apply(state) }
            })
        }
    }

    public static func shutdown() { subs.removeAll() }

    /// "Matching" while matching, else "Syncing {filesFound}" (Android ScanChip text).
    @MainActor
    private static func apply(_ s: ScanState) {
        let status = ShellStatus.shared
        if s.running {
            status.scanText = s.phase.hasPrefix("Matching") ? "Matching" : "Syncing \(s.filesFound)"
            status.scanProgress = s.progress.map { Double($0) }
        } else {
            status.scanText = nil
            status.scanProgress = nil
        }
    }
}

extension ArtworkLoader {
    /// Remote images go through the core image cache (download once, offline-friendly).
    static func defaultResolve(_ url: String) async -> URL? {
        guard let images = AppServices.images else { return nil }
        return await images.file(for: url)
    }
}
