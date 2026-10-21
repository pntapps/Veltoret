import Foundation
import VeltoretKit

/// One subtitle line (or block of lines) with a concrete start and end.
public struct SubtitleCue: Hashable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public init(startMs: Int64, endMs: Int64, text: String) { self.startMs = startMs; self.endMs = endMs; self.text = text }
}

/// A message meant for the user ("That file is too large to be a subtitle") (Windows: SubtitleException).
public struct SubtitleError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Subtitle files Veltoret loads itself (Android: SubtitleEngine). libVLC renders them (with libass for ASS), but
/// the bytes are normalised to UTF-8 first and parsed once here, to report "No subtitles found in …" and to keep
/// the same cue rules as the Android app.
public enum SubtitleEngine {
    /// Larger files are almost certainly not text subtitles.
    public static let maxBytes = 8 * 1024 * 1024

    public static let tooLarge = "That file is too large to be a subtitle"
    public static let unsupported = "This subtitle format isn't supported"

    public enum Kind: Sendable { case subRip, webVtt, ssa, ttml }

    public static func formatOf(_ fileName: String) -> Kind {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "vtt": return .webVtt
        case "ass", "ssa": return .ssa
        case "ttml", "dfxp": return .ttml
        default: return .subRip
        }
    }

    /// Reads at most `maxBytes`, failing with the user-facing message when larger.
    public static func readLimited(_ source: ByteSource) async throws -> Data {
        if source.length > Int64(maxBytes) { throw SubtitleError(tooLarge) }
        var out = Data()
        var pos: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await source.read(at: pos, count: 64 * 1024)
            if chunk.isEmpty { break }
            out.append(chunk)
            pos += Int64(chunk.count)
            if out.count > maxBytes { throw SubtitleError(tooLarge) }
        }
        return out
    }

    /// Reads a subtitle from any source (opens, reads limited, closes).
    public static func readLimited(account: String, id: String) async throws -> Data {
        let s = try await AppServices.storage.openRead(account, id: id)
        defer { s.close() }
        return try await readLimited(s)
    }

    // ---- Text encoding --------------------------------------------------------------------------

    /// Android's normalizeText: UTF-8/UTF-16 with a BOM and valid UTF-8 are kept; anything else is a legacy
    /// code page, guessed and transcoded to UTF-8.
    public static func normalizeText(_ bytes: Data) -> Data {
        if hasUtf8Bom(bytes) || hasUtf16Bom(bytes) { return bytes }
        if isStrictUtf8(bytes) { return bytes }
        return Data(decodeLegacy(bytes, guessLegacyEncoding(bytes)).utf8)
    }

    /// The file as text (BOMs honoured, legacy code pages guessed).
    public static func decodeText(_ bytes: Data) -> String {
        let n = normalizeText(bytes)
        let b = [UInt8](n.prefix(3))
        if hasUtf8Bom(n) { return String(decoding: n.dropFirst(3), as: UTF8.self) }
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE {
            return String(data: n.dropFirst(2), encoding: .utf16LittleEndian) ?? decodeUtf16Lossy(n.dropFirst(2), little: true)
        }
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF {
            return String(data: n.dropFirst(2), encoding: .utf16BigEndian) ?? decodeUtf16Lossy(n.dropFirst(2), little: false)
        }
        return String(decoding: n, as: UTF8.self)
    }

    /// UTF-8 with a BOM: what Veltoret writes to the temporary file it hands to libVLC.
    public static func toUtf8WithBom(_ bytes: Data) -> Data {
        var out = Data([0xEF, 0xBB, 0xBF])
        out.append(Data(decodeText(bytes).utf8))
        return out
    }

    private static func hasUtf8Bom(_ b: Data) -> Bool {
        b.count >= 3 && b[b.startIndex] == 0xEF && b[b.startIndex + 1] == 0xBB && b[b.startIndex + 2] == 0xBF
    }

    private static func hasUtf16Bom(_ b: Data) -> Bool {
        guard b.count >= 2 else { return false }
        let x = b[b.startIndex], y = b[b.startIndex + 1]
        return (x == 0xFF && y == 0xFE) || (x == 0xFE && y == 0xFF)
    }

    private static func isStrictUtf8(_ bytes: Data) -> Bool { String(data: bytes, encoding: .utf8) != nil }

    private static func decodeUtf16Lossy(_ d: Data, little: Bool) -> String {
        let bytes = [UInt8](d)
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            units.append(little ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// A legacy Windows code page (CFStringEncoding) as a Foundation encoding.
    public static func windowsCodePage(_ codePage: Int) -> String.Encoding {
        let cf: CFStringEncodings
        switch codePage {
        case 1250: cf = .windowsLatin2
        case 1251: cf = .windowsCyrillic
        case 1253: cf = .windowsGreek
        case 1254: cf = .windowsLatin5
        case 1255: cf = .windowsHebrew
        case 1256: cf = .windowsArabic
        case 1257: cf = .windowsBalticRim
        case 1258: cf = .windowsVietnamese
        case 874: cf = .dosThai
        default: return .windowsCP1252
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }

    /// Decodes with the encoding, replacing bytes it doesn't define (C# DecoderFallback.ReplacementFallback).
    static func decodeLegacy(_ bytes: Data, _ encoding: String.Encoding) -> String {
        if let s = String(data: bytes, encoding: encoding) { return s }
        // Some code pages leave a few bytes undefined (0x81 in 1252…): decode byte by byte, "?" for those.
        var out = ""
        out.reserveCapacity(bytes.count)
        for b in bytes {
            if b < 0x80 { out.unicodeScalars.append(Unicode.Scalar(b)); continue }
            out += String(data: Data([b]), encoding: encoding) ?? "\u{FFFD}"
        }
        return out
    }

    /// Light heuristic for legacy single-byte encodings. Western text is mostly ASCII letters with the odd accent;
    /// Cyrillic and Arabic text is mostly high bytes, told apart by their most frequent letters.
    public static func guessLegacyEncoding(_ bytes: Data) -> String.Encoding {
        var asciiLetters = 0, high = 0, cyrillic = 0, arabic = 0
        for v in bytes {
            if v < 0x80 {
                if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { asciiLetters += 1 }
                continue
            }
            high += 1
            if [0xE0, 0xE5, 0xE8, 0xED, 0xEE].contains(v) || (0xF0...0xF2).contains(v) { cyrillic += 1 }
            if [0xC7, 0xC8, 0xCA, 0xD1, 0xE1, 0xE3, 0xE4, 0xE6].contains(v) { arabic += 1 }
        }
        let nonLatin = high > 0 && Float(high) / Float(high + asciiLetters) > 0.3
        let codePage = !nonLatin ? 1252 : arabic > cyrillic ? 1256 : 1251
        return windowsCodePage(codePage)
    }

    // ---- Parsing ----------------------------------------------------------------------------------

    typealias RawCue = (start: Int64?, end: Int64?, text: String)

    /// Parses a subtitle file into cues (sorted, with concrete ends, empty ones dropped).
    public static func parse(_ bytes: Data, fileName: String) throws -> [SubtitleCue] {
        if bytes.count > maxBytes { throw SubtitleError(tooLarge) }
        let text = decodeText(bytes).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let raw: [RawCue]
        switch formatOf(fileName) {
        case .ssa: raw = parseSsa(text)
        case .ttml: raw = try parseTtml(text)
        default: raw = parseArrows(text)
        }
        return finish(raw)
    }

    private static func finish(_ raw: [RawCue]) -> [SubtitleCue] {
        let sorted = raw.enumerated().filter { $0.element.start != nil }
            .sorted { ($0.element.start!, $0.offset) < ($1.element.start!, $1.offset) }.map(\.element)
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(sorted.count)
        for (i, c) in sorted.enumerated() {
            let start = c.start!
            // Some formats leave the end open ("until the next cue").
            let end = c.end ?? (i + 1 < sorted.count ? sorted[i + 1].start! : start + 5_000)
            let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { cues.append(SubtitleCue(startMs: start, endMs: end, text: t)) }
        }
        return cues
    }

    /// Cues to show at `positionMs` after the user's sync offset (positive = later).
    public static func activeAt(_ cues: [SubtitleCue], _ positionMs: Int64, _ offsetMs: Int64) -> [SubtitleCue] {
        let t = positionMs - offsetMs
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if cues[mid].startMs <= t { lo = mid + 1 } else { hi = mid }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1, scanned = 0
        while i >= 0 && scanned < 64 {
            if t < cues[i].endMs { result.insert(cues[i], at: 0) }
            i -= 1; scanned += 1
        }
        return result
    }

    private static let timestamp = try! NSRegularExpression(
        pattern: #"(?:([0-9]+):)?([0-9]{1,2}):([0-9]{1,2})(?:[.,]([0-9]{1,3}))?"#)
    private static let tags = try! NSRegularExpression(pattern: #"<[^>]*>|\{\\[^}]*\}"#)
    private static let ttmlOffset = try! NSRegularExpression(pattern: #"^([0-9.]+)(h|m|s|ms|f|t)$"#)

    private static func removeTags(_ s: String) -> String {
        tags.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func parseClock(_ s: String) -> Int64? {
        let str = s.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        guard let m = timestamp.firstMatch(in: str as String, range: NSRange(location: 0, length: str.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : str.substring(with: r)
        }
        let h = group(1).flatMap { Int64($0) } ?? 0
        let min = Int64(group(2)!) ?? 0
        let sec = Int64(group(3)!) ?? 0
        var ms: Int64 = 0
        if let f = group(4) {
            ms = (Int64(f) ?? 0) * (f.count == 1 ? 100 : f.count == 2 ? 10 : 1)
        }
        return ((h * 60 + min) * 60 + sec) * 1000 + ms
    }

    /// SubRip and WebVTT: a "start --> end" line followed by text until a blank line.
    private static func parseArrows(_ text: String) -> [RawCue] {
        var result: [RawCue] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let arrow = line.range(of: "-->") else { i += 1; continue }
            let start = parseClock(String(line[..<arrow.lowerBound]))
            let endPart = line[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let space = endPart.firstIndex(where: { $0 == " " || $0 == "\t" })
            let end = parseClock(space.map { String(endPart[..<$0]) } ?? endPart)
            var body = ""
            var j = i + 1
            while j < lines.count && !lines[j].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if lines[j].contains("-->") { break }
                if !body.isEmpty { body += "\n" }
                body += lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                j += 1
            }
            i = j
            result.append((start, end, removeTags(body)))
        }
        return result
    }

    /// SSA/ASS: "Dialogue:" lines in [Events], fields named by the "Format:" line.
    private static func parseSsa(_ text: String) -> [RawCue] {
        var result: [RawCue] = []
        var format: [String]?
        var inEvents = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            if !inEvents { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                continue
            }
            if !line.lowercased().hasPrefix("dialogue:") { continue }
            let fmt = format ?? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            format = fmt
            let fields = line.dropFirst(9).split(separator: ",", maxSplits: fmt.count - 1, omittingEmptySubsequences: false)
                .map(String.init)
            if fields.count < fmt.count { continue }
            guard let startIdx = fmt.firstIndex(of: "start"), let textIdx = fmt.firstIndex(of: "text") else { continue }
            let endIdx = fmt.firstIndex(of: "end")
            let body = removeTags(fields[textIdx]).replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
            result.append((parseClock(fields[startIdx]), endIdx.flatMap { parseClock(fields[$0]) }, body))
        }
        return result
    }

    /// TTML/DFXP: <p begin end|dur> elements; times as clock values or offsets ("12.5s", "500ms").
    private static func parseTtml(_ text: String) throws -> [RawCue] {
        let doc: XMLDocument
        do { doc = try XMLDocument(xmlString: text, options: [.nodePreserveWhitespace]) }
        catch { throw SubtitleError(unsupported) }
        var result: [RawCue] = []
        func descendants(_ node: XMLNode, _ visit: (XMLNode) -> Void) {
            for c in node.children ?? [] { visit(c); descendants(c, visit) }
        }
        guard let root = doc.rootElement() else { return result }
        var paragraphs: [XMLElement] = []
        if root.localName == "p" { paragraphs.append(root) }
        descendants(root) { n in if let e = n as? XMLElement, e.localName == "p" { paragraphs.append(e) } }
        for p in paragraphs {
            let begin = ttmlTime(attr(p, "begin"))
            var end = ttmlTime(attr(p, "end"))
            let dur = ttmlTime(attr(p, "dur"))
            if end == nil, let begin, let dur { end = begin + dur }
            var body = ""
            descendants(p) { n in
                if n.kind == .text { body += n.stringValue ?? "" }
                else if let e = n as? XMLElement, e.localName == "br" { body += "\n" }
            }
            result.append((begin, end, body))
        }
        return result
    }

    private static func attr(_ e: XMLElement, _ name: String) -> String? {
        (e.attributes ?? []).first { ($0.localName ?? $0.name) == name }?.stringValue
    }

    private static func ttmlTime(_ value: String?) -> Int64? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = v as NSString
        if let m = ttmlOffset.firstMatch(in: v, range: NSRange(location: 0, length: ns.length)),
           let n = Double(ns.substring(with: m.range(at: 1))) {
            switch ns.substring(with: m.range(at: 2)) {
            case "h": return Int64(n * 3_600_000)
            case "m": return Int64(n * 60_000)
            case "s": return Int64(n * 1000)
            case "ms": return Int64(n)
            case "f": return Int64(n * 1000 / 30)
            default: return Int64(n / 10_000) // ticks at 10 MHz
            }
        }
        // hh:mm:ss:frames → drop the frames part
        let parts = v.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 4 { v = parts.prefix(3).joined(separator: ":") }
        return parseClock(v)
    }
}
