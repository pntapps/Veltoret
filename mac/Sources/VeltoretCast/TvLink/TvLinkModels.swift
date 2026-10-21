import Foundation

// "Play on TV" messages (WIRE). Names are the Kotlin names; defaults are the Kotlin defaults, because the TV leaves
// out every field equal to its default.

/// GET /hello: who the TV is, and its pairing key.
public struct LinkHello: Decodable, Hashable, Sendable, LinkEncodable {
    public var id = ""
    public var name = ""
    public var version = 0
    public var tvKey = ""
    public var salt = ""
    enum CodingKeys: String, CodingKey { case id, name, version, tvKey, salt }
    public init(id: String = "", name: String = "", version: Int = 0, tvKey: String = "", salt: String = "") {
        self.id = id; self.name = name; self.version = version; self.tvKey = tvKey; self.salt = salt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, ""); name = c.value(.name, ""); version = c.value(.version, 0)
        tvKey = c.value(.tvKey, ""); salt = c.value(.salt, "")
    }
    public var linkFields: [(String, Any?)] { [("id", id), ("name", name), ("version", version), ("tvKey", tvKey), ("salt", salt)] }
}

/// POST /pair/start.
public struct LinkPairStart: Hashable, Sendable, LinkEncodable {
    public var phoneId = ""
    public var phoneName = ""
    public init(phoneId: String = "", phoneName: String = "") { self.phoneId = phoneId; self.phoneName = phoneName }
    public var linkFields: [(String, Any?)] { [("phoneId", phoneId), ("phoneName", phoneName)] }
}

/// Sealed with the code into POST /pair.
public struct LinkPairSecret: Decodable, Hashable, Sendable, LinkEncodable {
    public var phoneId = ""
    public var phoneName = ""
    public var secret = ""
    enum CodingKeys: String, CodingKey { case phoneId, phoneName, secret }
    public init(phoneId: String = "", phoneName: String = "", secret: String = "") {
        self.phoneId = phoneId; self.phoneName = phoneName; self.secret = secret
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phoneId = c.value(.phoneId, ""); phoneName = c.value(.phoneName, ""); secret = c.value(.secret, "")
    }
    public var linkFields: [(String, Any?)] { [("phoneId", phoneId), ("phoneName", phoneName), ("secret", secret)] }
}

public struct LinkReply: Decodable, Hashable, Sendable {
    public var ok = false
    public var message = ""
    public var code: String?
    enum CodingKeys: String, CodingKey { case ok, message, code }
    public init(ok: Bool = false, message: String = "", code: String? = nil) { self.ok = ok; self.message = message; self.code = code }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.value(.ok, false); message = c.value(.message, ""); code = c.optional(.code)
    }
}

/// POST /play: what to play. The TV prefers its own copy and falls back to `streamUrl`.
public struct LinkPlay: Hashable, Sendable, LinkEncodable {
    public static let subtitlesOff = "off"

    public var title = ""
    public var subtitle: String?
    public var fileId = ""
    public var accountEmail = ""
    public var fileName: String?
    public var movieId: Int?
    public var showId: Int?
    public var season: Int?
    public var episode: Int?
    /// "vlink://ip:port/token/id".
    public var streamUrl: String?
    public var startMs: Int64 = 0
    public var audioLanguage: String?
    /// A language code, `subtitlesOff`, or nil to keep the TV's usual choice.
    public var subtitleLanguage: String?

    public init(title: String = "", subtitle: String? = nil, fileId: String = "", accountEmail: String = "", fileName: String? = nil,
                movieId: Int? = nil, showId: Int? = nil, season: Int? = nil, episode: Int? = nil, streamUrl: String? = nil,
                startMs: Int64 = 0, audioLanguage: String? = nil, subtitleLanguage: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.fileId = fileId; self.accountEmail = accountEmail
        self.fileName = fileName; self.movieId = movieId; self.showId = showId; self.season = season; self.episode = episode
        self.streamUrl = streamUrl; self.startMs = startMs; self.audioLanguage = audioLanguage; self.subtitleLanguage = subtitleLanguage
    }

    public var linkFields: [(String, Any?)] {
        [("title", title), ("subtitle", subtitle), ("fileId", fileId), ("accountEmail", accountEmail), ("fileName", fileName),
         ("movieId", movieId), ("showId", showId), ("season", season), ("episode", episode), ("streamUrl", streamUrl),
         ("startMs", startMs), ("audioLanguage", audioLanguage), ("subtitleLanguage", subtitleLanguage)]
    }
}

/// POST /command.
public struct LinkCommand: Hashable, Sendable, LinkEncodable {
    public static let play = "play"
    public static let pause = "pause"
    public static let seek = "seek"
    public static let stop = "stop"
    public static let audio = "audio"
    /// `track` nil turns subtitles off.
    public static let subtitle = "subtitle"

    public var type = ""
    public var positionMs: Int64?
    public var track: String?
    public init(type: String, positionMs: Int64? = nil, track: String? = nil) { self.type = type; self.positionMs = positionMs; self.track = track }
    public var linkFields: [(String, Any?)] { [("type", type), ("positionMs", positionMs), ("track", track)] }
}

public struct LinkTrack: Decodable, Hashable, Sendable {
    public var id = ""
    public var label = ""
    public var detail = ""
    enum CodingKeys: String, CodingKey { case id, label, detail }
    public init(id: String = "", label: String = "", detail: String = "") { self.id = id; self.label = label; self.detail = detail }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, ""); label = c.value(.label, ""); detail = c.value(.detail, "")
    }
}

/// POST /status: what the TV is playing now. The idle TV answers `{}`.
public struct LinkStatus: Decodable, Hashable, Sendable {
    public static let sourceTv = "tv"
    public static let sourcePhone = "phone"

    public var active = false
    public var title = ""
    public var source = ""
    public var playing = false
    public var buffering = false
    public var positionMs: Int64 = 0
    public var durationMs: Int64 = 0
    public var ended = false
    public var error: String?
    public var audio: [LinkTrack] = []
    public var audioSelected: String?
    public var subtitles: [LinkTrack] = []
    public var subtitleSelected: String?

    enum CodingKeys: String, CodingKey {
        case active, title, source, playing, buffering, positionMs, durationMs, ended, error, audio, audioSelected, subtitles, subtitleSelected
    }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = c.value(.active, false); title = c.value(.title, ""); source = c.value(.source, "")
        playing = c.value(.playing, false); buffering = c.value(.buffering, false)
        positionMs = c.value(.positionMs, 0); durationMs = c.value(.durationMs, 0); ended = c.value(.ended, false)
        error = c.optional(.error); audio = c.value(.audio, []); audioSelected = c.optional(.audioSelected)
        subtitles = c.value(.subtitles, []); subtitleSelected = c.optional(.subtitleSelected)
    }
}

/// A TV running Veltoret's "Play on TV" listener. `paired`: this Mac has its secret.
public struct LinkTv: Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var paired: Bool
    public init(id: String, name: String, host: String, port: Int, paired: Bool) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.paired = paired
    }
}

/// A paired TV as stored.
public struct LinkPeer: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// A request the TV refused (or couldn't be reached), with the sentence to show and its code.
public struct LinkError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public let code: String?
    public init(_ message: String, code: String? = nil) { self.message = message; self.code = code }
    public var description: String { message }
    public var errorDescription: String? { message }
}
