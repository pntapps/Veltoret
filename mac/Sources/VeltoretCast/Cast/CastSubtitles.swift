import Foundation

/// Subtitles for the TV (Android CastSubtitles): Chromecasts read WebVTT, so sidecar SRT / ASS / SSA / VTT files are
/// parsed into cues and converted, shifted by the player's subtitle sync.
public enum CastSubtitles {
    /// One cue: start and end in microseconds, and its text (lines separated by "\n").
    public struct Line: Hashable, Sendable {
        public var startUs: Int64
        public var endUs: Int64
        public var text: String
        public init(startUs: Int64, endUs: Int64, text: String) { self.startUs = startUs; self.endUs = endUs; self.text = text }
    }

    /// WebVTT for `lines`, shifted by `offsetUs`; cues ending before 0 are dropped.
    public static func toVtt(_ lines: [Line], offsetUs: Int64 = 0) -> String {
        var sb = "WEBVTT\n\n"
        for line in lines {
            let start = line.startUs + offsetUs
            let end = line.endUs + offsetUs
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-->", with: "->")
            if end <= 0 || text.isEmpty { continue }
            sb += time(max(0, start)) + " --> " + time(end) + "\n"
            // A blank line would end the cue early.
            sb += splitLines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n") + "\n\n"
        }
        return sb
    }

    /// "01:02:03.045"
    public static func time(_ us: Int64) -> String {
        let ms = us / 1000
        return String(format: "%02lld:%02lld:%02lld.%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Kotlin's String.lines(): splits on CRLF, LF and CR (on scalars, since "\r\n" is one Swift Character).
    static func splitLines(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        var it = Array(text.unicodeScalars)[...]
        while let s = it.popFirst() {
            if s == "\r" {
                if it.first == "\n" { _ = it.popFirst() }
                out.append(String(current)); current = .init()
            } else if s == "\n" {
                out.append(String(current)); current = .init()
            } else {
                current.append(s)
            }
        }
        out.append(String(current))
        return out
    }

    // ---- Parsing sidecar files ------------------------------------------------------------------------

    /// Cues of a subtitle file by its extension (srt, ass, ssa, vtt); others are tried as SRT.
    public static func parse(_ input: String, fileName: String) -> [Line] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var text = input
        if text.unicodeScalars.first == "\u{FEFF}" { text = String(text.unicodeScalars.dropFirst()) }
        switch ext {
        case "ass", "ssa": return parseAss(text)
        default: return parseSrtOrVtt(text)
        }
    }

    /// Decodes subtitle bytes: UTF-8 (with or without BOM), UTF-16 with BOM, else Latin-1.
    public static func decode(_ bytes: Data) -> String {
        let b = [UInt8](bytes.prefix(2))
        if b.count == 2 && b[0] == 0xFF && b[1] == 0xFE { return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if b.count == 2 && b[0] == 0xFE && b[1] == 0xFF { return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private static let timing = try! NSRegularExpression(
        pattern: "^\\s*((?:[0-9]+:)?[0-9]{1,2}:[0-9]{1,2}[,.][0-9]{1,3})\\s*-->\\s*((?:[0-9]+:)?[0-9]{1,2}:[0-9]{1,2}[,.][0-9]{1,3})")
    private static let tags = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let assOverrides = try! NSRegularExpression(pattern: "\\{[^}]*\\}")

    private static func replace(_ re: NSRegularExpression, _ s: String, _ with: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: with))
    }

    private static func parseSrtOrVtt(_ text: String) -> [Line] {
        let lines = splitLines(text)
        var cues: [Line] = []
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let l = lines[i]
            guard let m = timing.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                  let r1 = Range(m.range(at: 1), in: l), let r2 = Range(m.range(at: 2), in: l) else { continue }
            let start = clock(String(l[r1]))
            let end = clock(String(l[r2]))
            var body: [String] = []
            var j = i + 1
            while j < lines.count && !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                let lj = lines[j]
                if timing.firstMatch(in: lj, range: NSRange(lj.startIndex..., in: lj)) != nil { j -= 1; break }
                body.append(replace(tags, lj, "").trimmingCharacters(in: .whitespaces))
                j += 1
            }
            i = max(i, j)
            if let start, let end { cues.append(Line(startUs: start, endUs: end, text: body.joined(separator: "\n"))) }
        }
        return stableSorted(cues)
    }

    private static func stableSorted(_ cues: [Line]) -> [Line] {
        cues.enumerated().sorted { a, b in a.element.startUs != b.element.startUs ? a.element.startUs < b.element.startUs : a.offset < b.offset }
            .map { $0.element }
    }

    /// "01:02:03,045", "02:03.045" or "1:02:03.04" in microseconds.
    static func clock(_ text: String) -> Int64? {
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var h: Int64 = 0
        let m: Int64
        let secPart: String
        if parts.count == 3 {
            guard let hh = Int64(parts[0]), let mm = Int64(parts[1]) else { return nil }
            h = hh; m = mm; secPart = parts[2]
        } else if parts.count == 2 {
            guard let mm = Int64(parts[0]) else { return nil }
            m = mm; secPart = parts[1]
        } else { return nil }
        let pieces = secPart.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let s = Int64(pieces[0]) else { return nil }
        var frac: Int64 = 0
        if pieces.count > 1 {
            // ".5" = 500 ms, ".04" = 40 ms (centiseconds in ASS), ".045" = 45 ms.
            let f = String((pieces[1] + "000").prefix(3))
            guard let v = Int64(f) else { return nil }
            frac = v
        }
        return ((h * 3600 + m * 60 + s) * 1000 + frac) * 1000
    }

    private static func parseAss(_ text: String) -> [Line] {
        var cues: [Line] = []
        var format: [String]?
        var inEvents = false
        for raw in splitLines(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            if !inEvents { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst("Format:".count).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            if !line.lowercased().hasPrefix("dialogue:") { continue }
            let fmt = format ?? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            let fields = line.dropFirst("Dialogue:".count).split(separator: ",", maxSplits: fmt.count - 1, omittingEmptySubsequences: false).map(String.init)
            if fields.count < fmt.count { continue }
            guard let startAt = fmt.firstIndex(of: "start"), let endAt = fmt.firstIndex(of: "end"),
                  let textAt = fmt.firstIndex(of: "text") else { continue }
            guard let start = clock(fields[startAt].trimmingCharacters(in: .whitespaces)),
                  let end = clock(fields[endAt].trimmingCharacters(in: .whitespaces)) else { continue }
            let body = replace(assOverrides, fields[textAt], "")
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
            cues.append(Line(startUs: start, endUs: end, text: body))
        }
        return stableSorted(cues)
    }

    /// "Movie.en.srt" → "en"; nil when the name has no language part.
    public static func languageFromName(_ fileName: String) -> String? {
        let stem = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let dot = stem.lastIndex(of: ".") else { return nil }
        var tag = String(stem[stem.index(after: dot)...]).lowercased()
        if ["forced", "sdh", "cc", "hi"].contains(tag) {
            let rest = stem[..<dot]
            guard let d2 = rest.lastIndex(of: ".") else { return nil }
            tag = String(rest[rest.index(after: d2)...]).lowercased()
        }
        return (tag.count == 2 || tag.count == 3) && tag.allSatisfy({ $0 >= "a" && $0 <= "z" }) ? tag : nil
    }
}

/// Language codes ("en", "eng", "fre", "pt-BR") to English names, and to two-letter codes.
public enum LanguageNames {
    /// Matroska uses ISO 639-2/B ("fre", "ger"); Foundation knows the /T codes.
    private static let bibliographic: [String: String] = [
        "fre": "fra", "ger": "deu", "dut": "nld", "chi": "zho", "cze": "ces", "gre": "ell", "per": "fas", "rum": "ron",
        "slo": "slk", "ice": "isl", "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "geo": "kat", "mac": "mkd",
        "mao": "mri", "may": "msa", "tib": "bod", "wel": "cym",
    ]

    private static func normalized(_ code: String) -> String? {
        let c = code.trimmingCharacters(in: .whitespaces)
        if c.isEmpty { return nil }
        return bibliographic[c.lowercased()] ?? c
    }

    private static func alpha2(_ code: String) -> String? {
        guard let c = normalized(code) else { return nil }
        let lc = Locale.Language(identifier: c).languageCode
        guard let lc, lc.isISOLanguage, lc.identifier != "und" else { return nil }
        return lc.identifier(.alpha2) ?? lc.identifier
    }

    public static func name(_ code: String) -> String {
        guard let c = normalized(code), alpha2(code) != nil,
              let n = Locale(identifier: "en_US").localizedString(forLanguageCode: c) else { return code }
        return n
    }

    public static func toTwoLetter(_ code: String?) -> String? {
        guard let code, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return alpha2(code) ?? code
    }
}
