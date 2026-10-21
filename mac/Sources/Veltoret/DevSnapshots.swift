import AppKit
import VeltoretKit
import VeltoretUI

/// Developer aid (no effect in normal use): with `VELTORET_SNAPSHOT_DIR` set, the app renders its main window to PNG
/// files there — first as launched, then one per route in `VELTORET_SNAPSHOT_ROUTES` (comma-separated:
/// home, movies, shows, search, files, settings, fixmatch, onboarding) — and quits. Drawing its own window needs no
/// Screen Recording permission, so layouts can be checked from a terminal. `VELTORET_DATA_DIR` (read in
/// AppDelegate) points the app at a throwaway data folder.
@MainActor
enum DevSnapshots {
    static func runIfRequested(window: @escaping () -> NSWindow?) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["VELTORET_SNAPSHOT_DIR"] else { return }
        let routes = (env["VELTORET_SNAPSHOT_ROUTES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let delay = Double(env["VELTORET_SNAPSHOT_DELAY"] ?? "") ?? 2.5
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(delay))
            capture(window(), to: "\(dir)/00-launch.png")
            for (i, name) in routes.enumerated() {
                if let route = route(for: name) {
                    AppServices.navigate(route)
                    try? await Task.sleep(for: .seconds(delay))
                    capture(window(), to: String(format: "%@/%02d-%@.png", dir, i + 1, name))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func route(for name: String) -> Route? {
        switch name {
        case "home": return .home
        case "movies": return .movies()
        case "shows": return .shows()
        case "search": return .search()
        case "files": return .files()
        case "settings": return .settings
        case "fixmatch": return .fixMatch()
        case "archives": return .archives
        case "onboarding": return .onboarding
        default:
            if name.hasPrefix("movie:"), let id = Int(name.dropFirst(6)) { return .movieDetail(movieId: id) }
            if name.hasPrefix("show:"), let id = Int(name.dropFirst(5)) { return .showDetail(showId: id) }
            return nil
        }
    }

    private static func capture(_ window: NSWindow?, to path: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
