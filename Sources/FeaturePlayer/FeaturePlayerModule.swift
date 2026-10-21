import AppKit
import Foundation
import VeltoretKit

/// FeaturePlayer module entry points (called by the app target).
public enum FeaturePlayerModule {
    /// Sets `AppServices.playback` (Play buttons everywhere open the player window through it).
    public static func initialize() {
        AppServices.playback = VeltoretPlaybackLauncher()
        // Subtitle copies left over by a previous run (crash, force quit).
        let dir = AppPaths.temp.appendingPathComponent("subtitles", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    public static func start() {}

    /// Saves the open video's progress and closes the player.
    public static func shutdown() {
        MainActor.assumeIsolated {
            PlayerWindowController.current?.controller.saveProgress(sync: true)
            PlayerWindowController.current?.close()
        }
    }
}
