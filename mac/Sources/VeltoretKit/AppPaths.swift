import Foundation

/// Where Veltoret keeps its data: ~/Library/Application Support/Veltoret (caches in ~/Library/Caches/Veltoret).
public enum AppPaths {
    nonisolated(unsafe) public static var root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Veltoret", isDirectory: true)
    }()

    public static var database: URL { root.appendingPathComponent("veltoret.db") }
    public static var settings: URL { root.appendingPathComponent("settings.json") }
    /// Poster and backdrop cache, so the library looks right offline. Kept in Application Support (not Caches)
    /// because macOS may purge Caches and the library must work offline.
    public static var imageCache: URL { root.appendingPathComponent("images", isDirectory: true) }
    /// Per-video track choices and per-show languages (player).
    public static var playerPrefs: URL { root.appendingPathComponent("player-prefs.json") }
    /// Background jobs (uploads, ZIP extraction).
    public static var transfers: URL { root.appendingPathComponent("transfers.json") }
    /// Non-secret JSON stores (server lists, paired TVs). Passwords and tokens live in the Keychain (SecretStore).
    public static var stores: URL { root.appendingPathComponent("stores", isDirectory: true) }
    public static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// Scratch files (subtitle copies…); cleared by macOS eventually.
    public static var temp: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Veltoret", isDirectory: true) }

    /// Creates the directory (and parents) if needed and returns it.
    @discardableResult
    public static func ensure(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
