import Foundation

/// Human-readable names for languages, codecs, channels and resolutions, used by the track lists and the info panel
/// (Android: player/MediaFormats.kt and PlayerViewModel.languageName; Windows: Veltoret.Core.Player.MediaFormats).
/// Codecs arrive as libVLC FourCCs.
public enum MediaFormats {
    // ---- Languages ------------------------------------------------------------------------------

    /// ISO 639-2/B (bibliographic) codes that differ from the terminology codes Foundation knows.
    private static let bibliographic: [String: String] = [
        "fre": "fr", "ger": "de", "chi": "zh", "cze": "cs", "dut": "nl", "gre": "el",
        "per": "fa", "rum": "ro", "slo": "sk", "alb": "sq", "arm": "hy", "baq": "eu",
        "bur": "my", "geo": "ka", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms",
        "tib": "bo", "wel": "cy",
    ]

    private static let english = Locale(identifier: "en_US_POSIX")
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    private static func primary(_ code: String) -> String {
        let lower = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// The canonical code Foundation knows for a language code ("en", "eng", "fre", "pt-BR" → "en", "en", "fr", "pt";
    /// "tlh" → "tlh"), or nil when unknown.
    private static func canonical(_ code: String) -> String? {
        let key = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        var result: String?
        var p = primary(key)
        if let two = bibliographic[p] { p = two }
        if !p.isEmpty, p != "und" {
            let lc = Locale.LanguageCode(p)
            if lc.isISOLanguage {
                let lang = Locale.Language(identifier: p)
                if let two = lang.languageCode?.identifier(.alpha2) { result = two }
                else if let three = lang.languageCode?.identifier(.alpha3) { result = three }
                else { result = p }
            } else if let three = Locale.Language(identifier: p).languageCode?.identifier(.alpha3) {
                // Deprecated codes ("iw" → "heb" → "he").
                result = Locale.Language(identifier: three).languageCode?.identifier(.alpha2) ?? three
            }
        }
        cacheLock.lock(); cache[key] = result; cacheLock.unlock()
        return result
    }

    /// A language code made comparable: "eng" / "en-US" / "EN" → "en". "und", nil or blank → nil. Unknown codes
    /// are lowercased as they are. Persisted and compared languages always go through this.
    public static func normalizeLanguage(_ code: String?) -> String? {
        guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "und" { return nil }
        if let c = canonical(trimmed), c.count == 2 { return c }
        return primary(trimmed)
    }

    /// "en" → "English"; unknown codes uppercased ("XX"); nil/blank/"und" → nil.
    public static func languageName(_ code: String?) -> String? {
        guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, code != "und" else { return nil }
        var name: String?
        if let c = canonical(code) { name = english.localizedString(forLanguageCode: c) }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty, name != code, !name.hasPrefix("Unknown") {
            return name
        }
        return code.uppercased()
    }

    // ---- Labels -----------------------------------------------------------------------------------

    // Release sites rotate domains (.at, .town, .army, .zone…), so any "name.tld" with a lowercase ending
    // counts, not a fixed list. Real labels capitalise ("Dub.Intl", "DTS-HD.MA") and codecs are short ("H.264").
    private static let junkLabel = try! NSRegularExpression(
        pattern: #"(?i:www\.|https?://|@)|\b[A-Za-z0-9-]{3,}\.[a-z]{2,10}\b"#)

    /// A track's own label, unless it's a release group's web address or similar noise.
    public static func cleanLabel(_ label: String?) -> String? {
        guard let t = label?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let range = NSRange(t.startIndex..., in: t)
        return junkLabel.firstMatch(in: t, range: range) == nil ? t : nil
    }

    /// Display names for a list of tracks: language first ("English"), the track's own label only if it's
    /// meaningful, and a number when several tracks would otherwise look identical ("Hindi 2").
    public static func trackTitles(_ tracks: [(language: String?, label: String?)], fallback: String,
                                   language: ((String?) -> String?)? = nil) -> [String] {
        let lang = language ?? { languageName($0) }
        let names = tracks.enumerated().map { i, t in lang(t.language) ?? cleanLabel(t.label) ?? "\(fallback) \(i + 1)" }
        var totals: [String: Int] = [:]
        for n in names { totals[n, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return names.map { name in
            if totals[name, default: 0] <= 1 { return name }
            let n = seen[name, default: 0] + 1
            seen[name] = n
            return "\(name) \(n)"
        }
    }

    // ---- Codecs (libVLC FourCCs) ---------------------------------------------------------------

    /// libVLC's codec value (VLC_FOURCC: first character in the lowest byte) as its four characters.
    public static func fourCC(_ codec: UInt32) -> String {
        if codec == 0 { return "" }
        var s = ""
        for i in 0..<4 {
            s.unicodeScalars.append(Unicode.Scalar(UInt8((codec >> (8 * UInt32(i))) & 0xFF)))
        }
        return s
    }

    public static func audioCodec(_ fourcc: String?) -> String? {
        guard let f = fourcc?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty else { return nil }
        switch f {
        case "mp4a", "aac": return "AAC"
        case "a52", "ac-3", "ac3": return "Dolby Digital"
        case "eac3": return "Dolby Digital+"
        case "ac-4", "ac4": return "Dolby AC-4"
        case "mlp", "trhd": return "Dolby TrueHD"
        case "dts": return "DTS"
        case "dtsh": return "DTS-HD"
        case "dtse": return "DTS Express"
        case "opus", "Opus": return "Opus"
        case "flac": return "FLAC"
        case "vorb": return "Vorbis"
        case "mpga", "mp3", "mp2a", "mpg3": return "MP3"
        case "alac": return "ALAC"
        case "araw", "lpcm", "u8", "s8", "s16l", "s16b", "s24l", "s24b", "s32l", "s32b", "f32l", "f32b",
             "fl32", "f64l", "fl64", "pcm": return "PCM"
        default: return f.uppercased()
        }
    }

    public static func videoCodec(_ fourcc: String?) -> String? {
        guard let f = fourcc?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty else { return nil }
        switch f {
        case "h264", "H264", "avc1", "x264": return "H.264"
        case "hevc", "hvc1", "hev1", "h265": return "HEVC"
        case "dvh1", "dvhe", "dva1", "dvav": return "Dolby Vision"
        case "VP80", "vp80", "VP8": return "VP8"
        case "VP90", "vp90", "VP9": return "VP9"
        case "av01", "AV01": return "AV1"
        case "mp4v", "DIVX", "XVID", "FMP4": return "MPEG-4 Part 2"
        case "mp2v", "mpgv": return "MPEG-2"
        case "WVC1", "VC-1", "vc1": return "VC-1"
        case "h263", "H263": return "H.263"
        default: return f.uppercased()
        }
    }

    /// Subtitle format name, or nil when unknown.
    public static func subtitleFormat(_ fourcc: String?) -> String? {
        switch fourcc?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ssa": return "ASS"
        case "subt": return "SRT"
        case "wvtt": return "WebVTT"
        case "ttml": return "TTML"
        case "pgss", "pgs": return "PGS"
        case "spu": return "VobSub"
        case "dvbs": return "DVB"
        case "tx3g": return "Timed text"
        default: return nil
        }
    }

    public static func channels(_ count: Int) -> String? {
        switch count {
        case ...0: return nil
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count) ch"
        }
    }

    /// "1920×1080 · 1080p"; nil when unknown.
    public static func resolution(_ width: Int, _ height: Int) -> String? {
        if width <= 0 || height <= 0 { return nil }
        let label = height >= 2000 || width >= 3800 ? "4K"
            : height >= 1400 ? "1440p"
            : height >= 1000 || width >= 1900 ? "1080p"
            : height >= 700 ? "720p"
            : "SD"
        return "\(width)×\(height) · \(label)"
    }

    public static func bitrate(_ bps: Int64) -> String? {
        if bps <= 0 { return nil }
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", locale: english, Double(Float(bps) / 1_000_000)) }
        return "\(bps / 1000) kbps"
    }

    /// Java's "%.3g fps": three significant digits ("24.0 fps", "120 fps").
    public static func frameRate(_ fps: Double) -> String? {
        if fps <= 0 || fps.isNaN || fps.isInfinite { return nil }
        var exponent = Int(floor(log10(fps)))
        let scale = pow(10, Double(exponent - 2))
        let rounded = (fps / scale).rounded(.toNearestOrAwayFromZero) * scale
        exponent = Int(floor(log10(rounded)))
        let decimals = max(0, 2 - exponent)
        return String(format: "%.\(decimals)f", locale: english, rounded) + " fps"
    }

    /// "48.0 kHz" (Kotlin prints a Double with at least one decimal).
    public static func sampleRate(_ hz: Int) -> String? {
        if hz <= 0 { return nil }
        var s = String(format: "%.4f", locale: english, Double(hz) / 1000.0)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s + " kHz"
    }
}
