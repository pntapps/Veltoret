import Foundation
import VeltoretKit

/// What the user picked for one video, restored the next time it opens. Tracks are identified by their position
/// among tracks of the same type plus their language, which stays stable for a given file.
public struct TrackMemory: Hashable, Sendable {
    public static let subOff = "off"
    public static let subEmbedded = "embedded"
    public static let subExternal = "external"

    public var audioIndex: Int?
    public var audioLanguage: String?
    /// `subOff`, `subEmbedded` or `subExternal`; nil = never chosen.
    public var subtitleMode: String?
    public var subtitleIndex: Int?
    public var subtitleLanguage: String?
    /// External subtitles: "drive:<id>" (any library source), "file:<path>" or "side:<id>".
    public var externalSource: String?
    public var externalName: String?
    public var subtitleOffsetMs: Int64

    public init(audioIndex: Int? = nil, audioLanguage: String? = nil, subtitleMode: String? = nil,
                subtitleIndex: Int? = nil, subtitleLanguage: String? = nil, externalSource: String? = nil,
                externalName: String? = nil, subtitleOffsetMs: Int64 = 0) {
        self.audioIndex = audioIndex; self.audioLanguage = audioLanguage; self.subtitleMode = subtitleMode
        self.subtitleIndex = subtitleIndex; self.subtitleLanguage = subtitleLanguage
        self.externalSource = externalSource; self.externalName = externalName; self.subtitleOffsetMs = subtitleOffsetMs
    }

    /// C#'s `with { … }`: a changed copy.
    public func with(_ change: (inout TrackMemory) -> Void) -> TrackMemory {
        var copy = self
        change(&copy)
        return copy
    }

    private static let sep: Character = "\u{1F}" // unit separator; never appears in names or paths

    /// Android's SharedPreferences format: 8 fields joined with U+001F, empty = nil.
    public func encode() -> String {
        let fields: [String?] = [
            audioIndex.map(String.init), audioLanguage, subtitleMode, subtitleIndex.map(String.init), subtitleLanguage,
            externalSource, externalName?.replacingOccurrences(of: String(Self.sep), with: " "), String(subtitleOffsetMs),
        ]
        return fields.map { $0 ?? "" }.joined(separator: String(Self.sep))
    }

    public static func decode(_ raw: String) -> TrackMemory {
        let f = raw.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        func at(_ i: Int) -> String? { i < f.count && !f[i].isEmpty ? f[i] : nil }
        return TrackMemory(
            audioIndex: at(0).flatMap { Int($0) }, audioLanguage: at(1), subtitleMode: at(2),
            subtitleIndex: at(3).flatMap { Int($0) }, subtitleLanguage: at(4), externalSource: at(5),
            externalName: at(6), subtitleOffsetMs: at(7).flatMap { Int64($0) } ?? 0)
    }
}

/// Small player memory (Android: PlayerPrefs, SharedPreferences "player"): per-video track choices
/// ("video:{fileId}"), per-show audio ("audio:{showId}") and subtitle ("sub:{showId}", "off") languages, and the
/// last aspect mode ("resize"). Stored as a JSON object of the same keys and string values.
open class PlayerPrefsStore: @unchecked Sendable {
    public static let off = "off"

    /// The app's instance, at `AppPaths.playerPrefs` (created on first use).
    public static var shared: PlayerPrefsStore {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let s = sharedInstance, s.path == AppPaths.playerPrefs { return s }
        let s = PlayerPrefsStore(url: AppPaths.playerPrefs)
        sharedInstance = s
        return s
    }
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedInstance: PlayerPrefsStore?

    public let path: URL
    private let lock = NSLock()
    private var values: [String: String]

    public init(url: URL) {
        path = url
        values = Self.load(url)
    }

    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }

    private func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    private func put(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            try data.write(to: path, options: .atomic)
        } catch {
            Log.error("player prefs: \(error)")
        }
    }

    // ---- Per video ----------------------------------------------------------------------------

    public func trackMemory(_ videoKey: String) -> TrackMemory? {
        get("video:" + videoKey).map(TrackMemory.decode)
    }

    public func updateTrackMemory(_ videoKey: String, _ change: (TrackMemory) -> TrackMemory) {
        let m = change(trackMemory(videoKey) ?? TrackMemory())
        put("video:" + videoKey, m.encode())
    }

    // ---- Per show -----------------------------------------------------------------------------

    public func audioLanguage(_ showId: Int?) -> String? {
        guard let showId else { return nil }
        return get("audio:\(showId)")
    }

    public func setAudioLanguage(_ showId: Int?, _ language: String?) {
        guard let showId, let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        put("audio:\(showId)", language)
    }

    /// nil = no preference, `off` = subtitles off, otherwise a language code.
    public func subtitleLanguage(_ showId: Int?) -> String? {
        guard let showId else { return nil }
        return get("sub:\(showId)")
    }

    public func setSubtitleLanguage(_ showId: Int?, _ language: String?) {
        guard let showId else { return }
        put("sub:\(showId)", language ?? Self.off)
    }

    /// "Fit", "Fill" or "Stretch" (default Fit).
    public var resizeMode: String {
        get {
            let v = get("resize")
            return v == "Fill" || v == "Stretch" ? v! : "Fit"
        }
        set { put("resize", newValue) }
    }
}
