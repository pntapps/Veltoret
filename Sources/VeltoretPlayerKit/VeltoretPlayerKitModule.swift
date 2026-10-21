import Foundation
import VeltoretKit

extension AppServices {
    /// Player memory (track choices per video, languages per show, aspect mode) at `AppPaths.playerPrefs`.
    public static var playerPrefs: PlayerPrefsStore! {
        get { PlayerKitServices.playerPrefs }
        set { PlayerKitServices.playerPrefs = newValue }
    }
    /// Loopback HTTP server the player streams Drive / SMB files through.
    public static var mediaStream: MediaStreamServer { MediaStreamServer.shared }
}

enum PlayerKitServices {
    nonisolated(unsafe) static var playerPrefs: PlayerPrefsStore!
}

/// VeltoretPlayerKit module entry points (called by the app target).
public enum VeltoretPlayerKitModule {
    public static func initialize() {
        AppServices.playerPrefs = PlayerPrefsStore.shared
    }

    /// The stream server starts lazily on the first `MediaStreamServer.shared.url(…)`.
    public static func start() {}

    public static func shutdown() {
        MediaStreamServer.shared.stop()
    }
}
