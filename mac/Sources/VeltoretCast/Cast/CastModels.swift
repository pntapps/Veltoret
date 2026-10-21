import Foundation
import VeltoretKit

/// An audio track the TV can play instead of the file's default one (`CastAudio`).
/// `track` is the MKV TrackNumber; `codec` is the codec name ("DTS", "E-AC3"…) for the DTS / TrueHD warning.
public struct CastAudioOption: Hashable, Sendable {
    public var track: Int64
    public var label: String
    public var detail: String
    public var codec: String?
    public init(track: Int64, label: String, detail: String, codec: String? = nil) {
        self.track = track; self.label = label; self.detail = detail; self.codec = codec
    }
}

/// One subtitle for the Chromecast, already converted to WebVTT.
public struct CastSubtitle: Hashable, Sendable {
    public var id: String
    public var label: String
    public var language: String?
    public var vtt: String
    public init(id: String, label: String, language: String?, vtt: String) {
        self.id = id; self.label = label; self.language = language; self.vtt = vtt
    }
}

/// What to cast: a library file (or a Files-screen file) with what the TV shows about it.
public struct CastMedia: Hashable, Sendable {
    public var fileId: String = ""
    /// The source account: a Google email, "device" or "smb://host" (Storage.openRead).
    public var account: String = ""
    public var file: MediaFileEntity?
    /// The file name (MIME type by extension); defaults to `file.name`.
    public var fileName: String?
    public var title: String = ""
    public var subtitle: String?
    public var posterUrl: String?
    public var backdropUrl: String?
    public var isEpisode = false
    public var subtitles: [CastSubtitle] = []
    public var activeSubtitle: String?
    /// Set when the audio is a format Chromecasts usually can't decode (DTS, TrueHD).
    public var audioWarning: String?
    /// The MKV track number of the audio to play; the other audio tracks are hidden from the TV.
    public var audioTrack: Int64?
    /// Audio tracks to choose from (MKV with several); empty when the TV gets the file as it is.
    public var audioOptions: [CastAudioOption] = []
    /// "Play on TV": this Mac's audio language and subtitle choice (a language or `LinkPlay.subtitlesOff`).
    public var audioLanguage: String?
    public var subtitleLanguage: String?
    /// File size when known (library files), else probed on first request.
    public var sizeBytes: Int64?
    public var durationMs: Int64 = 0

    public init(fileId: String = "", account: String = "", file: MediaFileEntity? = nil, fileName: String? = nil,
                title: String = "", subtitle: String? = nil, posterUrl: String? = nil, backdropUrl: String? = nil,
                isEpisode: Bool = false, subtitles: [CastSubtitle] = [], activeSubtitle: String? = nil,
                audioWarning: String? = nil, audioTrack: Int64? = nil, audioOptions: [CastAudioOption] = [],
                audioLanguage: String? = nil, subtitleLanguage: String? = nil, sizeBytes: Int64? = nil, durationMs: Int64 = 0) {
        self.fileId = fileId; self.account = account; self.file = file; self.fileName = fileName; self.title = title
        self.subtitle = subtitle; self.posterUrl = posterUrl; self.backdropUrl = backdropUrl; self.isEpisode = isEpisode
        self.subtitles = subtitles; self.activeSubtitle = activeSubtitle; self.audioWarning = audioWarning
        self.audioTrack = audioTrack; self.audioOptions = audioOptions; self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage; self.sizeBytes = sizeBytes; self.durationMs = durationMs
    }

    public var name: String { fileName ?? file?.name ?? title }
}

public enum CastDeviceKind: String, Hashable, Sendable { case chromecast, veltoret }

/// A TV in the device picker: a Chromecast or Veltoret on a TV ("Play on TV").
public struct CastDevice: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: CastDeviceKind
    public var host: String
    public var port: Int
    public var model: String?
    public var paired: Bool

    public init(id: String, name: String, kind: CastDeviceKind, host: String, port: Int, model: String? = nil, paired: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port; self.model = model; self.paired = paired
    }

    public var detail: String {
        kind == .veltoret
            ? (paired ? "Veltoret · all audio tracks and subtitles" : "Veltoret · pair once with a code")
            : "Chromecast"
    }

    public func asLinkTv() -> LinkTv { LinkTv(id: id, name: name, host: host, port: port, paired: paired) }
}

public struct CastState: Hashable, Sendable {
    public var available = true
    /// Connecting to a Chromecast (TLS + launching the receiver).
    public var connecting = false
    public var connected = false
    public var deviceName: String?
    public var media: CastMedia?
    public var playing = false
    public var buffering = false
    public var positionMs: Int64 = 0
    public var durationMs: Int64 = 0
    /// The video played to the end on the TV.
    public var finished = false
    public var error: String?
    public var activeSubtitle: String?
    /// Chromecast volume 0...1 (nil when unknown or a Veltoret TV).
    public var volume: Double?
    public var muted = false
    /// Connected to Veltoret on a TV ("Play on TV") rather than a Chromecast.
    public var link: LinkTv?
    /// "Play on TV": `LinkStatus.sourceTv` (its own copy) or `sourcePhone` (streaming from this Mac).
    public var linkSource: String?
    public var linkAudio: [LinkTrack] = []
    public var linkAudioSelected: String?
    public var linkSubtitles: [LinkTrack] = []
    public var linkSubtitleSelected: String?
    /// The show has an episode after the one on the TV.
    public var hasNext = false

    public init() {}
}

public enum CastFormats {
    /// The MIME type Chromecasts expect for the file's container (by file name extension).
    public static func mimeFor(_ name: String) -> String {
        let ext: String
        if let dot = name.lastIndex(of: ".") { ext = String(name[name.index(after: dot)...]).lowercased() } else { ext = "" }
        switch ext {
        case "mp4", "m4v", "mov": return "video/mp4"
        case "webm": return "video/webm"
        case "ts", "m2ts": return "video/mp2t"
        case "avi": return "video/x-msvideo"
        default: return "video/x-matroska"
        }
    }

    private static let trueHdName = try! NSRegularExpression(pattern: "\\bTRUEHD\\b")
    private static let dtsName = try! NSRegularExpression(pattern: "\\bDTS")

    /// Chromecasts usually can't play DTS or TrueHD. Checks the selected audio's `codec`, or the file name when the
    /// tracks aren't known yet (codec nil).
    public static func audioWarning(_ codec: String?, _ fileName: String?) -> String? {
        var kind: String?
        if let codec {
            let c = codec.uppercased()
            kind = c.contains("DTS") ? "DTS"
                : (c.contains("TRUEHD") || c.contains("TRUE HD") || c.contains("MLP") || c.contains("TRHD")) ? "Dolby TrueHD"
                : nil
        } else {
            let name = (fileName ?? "").uppercased()
            let r = NSRange(name.startIndex..., in: name)
            kind = trueHdName.firstMatch(in: name, range: r) != nil ? "Dolby TrueHD"
                : dtsName.firstMatch(in: name, range: r) != nil ? "DTS" : nil
        }
        guard let kind else { return nil }
        return "This video's audio is \(kind), which most Chromecasts can't play, so there may be no sound. Another version of it may work."
    }

    /// Java's String.hashCode() as an unsigned decimal (Android: `hashCode().toUInt()`).
    public static func javaHash(_ s: String) -> UInt32 {
        var h: Int32 = 0
        for unit in s.utf16 { h = h &* 31 &+ Int32(unit) }
        return UInt32(bitPattern: h)
    }
}
