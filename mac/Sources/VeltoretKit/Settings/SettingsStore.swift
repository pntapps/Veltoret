import Foundation

/// Same settings as the Android app's AppSettings (DataStore) and the Windows app, with the same defaults.
/// Decoding tolerates missing keys (older files), so add new settings with a default here.
public struct AppSettings: Codable, Equatable, Sendable {
    public var onboardingComplete = false
    /// Key the user typed in (TMDB v3 API key or v4 read access token).
    public var tmdbKeyOverride = ""
    public var oledBlack = false
    public var autoPlayNext = true
    public var skipSeconds = 85
    public var seekSeconds = 10
    public var preferredAudioLanguage = "en"
    /// Empty = subtitles off by default.
    public var preferredSubtitleLanguage = ""
    public var subtitleScale: Float = 1
    public var subtitleBackground = false
    /// Mac: play HDR videos in HDR (EDR) on displays that support it.
    public var autoHdr = true
    public var lastScanAt: Int64 = 0
    /// Notify on the day a show on the Watchlist airs a new episode.
    public var newEpisodeAlerts = true
    /// Mac: keep running in the menu bar when the last window closes, so reminders and scans keep working.
    public var runInBackground = true
    /// Mac: open at login (SMAppService), in the background.
    public var startAtLogin = false
    /// Mac: show the Veltoret item in the menu bar.
    public var showMenuBarItem = true
    /// Episodes TMDB alerted about already ("yyyy-MM-dd|showId:season:episode").
    public var alertedEpisodes: [String] = []

    public init() {}

    /// The key to use: the user's, else one bundled at build time (never in public builds).
    public var tmdbKey: String {
        let typed = tmdbKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? BundledKeys.tmdb : typed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaultValue
        onboardingComplete = (try? c.decodeIfPresent(Bool.self, forKey: .onboardingComplete)) ?? d.onboardingComplete
        tmdbKeyOverride = (try? c.decodeIfPresent(String.self, forKey: .tmdbKeyOverride)) ?? d.tmdbKeyOverride
        oledBlack = (try? c.decodeIfPresent(Bool.self, forKey: .oledBlack)) ?? d.oledBlack
        autoPlayNext = (try? c.decodeIfPresent(Bool.self, forKey: .autoPlayNext)) ?? d.autoPlayNext
        skipSeconds = (try? c.decodeIfPresent(Int.self, forKey: .skipSeconds)) ?? d.skipSeconds
        seekSeconds = (try? c.decodeIfPresent(Int.self, forKey: .seekSeconds)) ?? d.seekSeconds
        preferredAudioLanguage = (try? c.decodeIfPresent(String.self, forKey: .preferredAudioLanguage)) ?? d.preferredAudioLanguage
        preferredSubtitleLanguage = (try? c.decodeIfPresent(String.self, forKey: .preferredSubtitleLanguage)) ?? d.preferredSubtitleLanguage
        subtitleScale = (try? c.decodeIfPresent(Float.self, forKey: .subtitleScale)) ?? d.subtitleScale
        subtitleBackground = (try? c.decodeIfPresent(Bool.self, forKey: .subtitleBackground)) ?? d.subtitleBackground
        autoHdr = (try? c.decodeIfPresent(Bool.self, forKey: .autoHdr)) ?? d.autoHdr
        lastScanAt = (try? c.decodeIfPresent(Int64.self, forKey: .lastScanAt)) ?? d.lastScanAt
        newEpisodeAlerts = (try? c.decodeIfPresent(Bool.self, forKey: .newEpisodeAlerts)) ?? d.newEpisodeAlerts
        runInBackground = (try? c.decodeIfPresent(Bool.self, forKey: .runInBackground)) ?? d.runInBackground
        startAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .startAtLogin)) ?? d.startAtLogin
        showMenuBarItem = (try? c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem)) ?? d.showMenuBarItem
        alertedEpisodes = (try? c.decodeIfPresent([String].self, forKey: .alertedEpisodes)) ?? d.alertedEpisodes
    }

    public static let defaultValue = AppSettings()
}

/// A developer's TMDB key from the VELTORET_TMDB_KEY environment variable (the Android app's local.properties key).
/// Never commit a key: public builds have none and users enter their own.
public enum BundledKeys {
    public static var tmdb: String {
        ProcessInfo.processInfo.environment["VELTORET_TMDB_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Settings saved as JSON in ~/Library/Application Support/Veltoret/settings.json.
public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var _current: AppSettings

    /// Fires after every update with the new settings (on the updating thread).
    public let changed = Event<AppSettings>()

    public init(url: URL) {
        self.url = url
        _current = Self.load(url)
    }

    public var current: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return _current
    }

    /// Applies `edit` and saves: `settings.update { $0.autoPlayNext = false }`.
    public func update(_ edit: (inout AppSettings) -> Void) {
        lock.lock()
        var next = _current
        edit(&next)
        _current = next
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(next).write(to: url, options: .atomic)
        } catch {
            Log.error(error, "Saving settings")
        }
        lock.unlock()
        changed.fire(next)
    }

    private static func load(_ url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }
}
