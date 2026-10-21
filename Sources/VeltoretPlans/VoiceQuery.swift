import Foundation
import VeltoretKit

/// Turns what someone said ("play Below season 1 episode 2 on Veltoret") into a library title (Android:
/// data/library/VoiceQuery.kt; VoiceQueryTest). Matching ignores case, accents, punctuation and a leading "the"
/// (FilenameParser.NormalizeForCompare), because speech never says "Spider-Man" with its hyphen.
public enum VoiceQuery {
    public struct Parsed: Hashable, Sendable {
        public var title: String
        public var season: Int?
        public var episode: Int?
        public var year: Int?
        public init(_ title: String, season: Int? = nil, episode: Int? = nil, year: Int? = nil) {
            self.title = title; self.season = season; self.episode = episode; self.year = year
        }
    }

    /// A movie or show in the library.
    public struct Candidate: Hashable, Sendable {
        public var id: Int
        public var isShow: Bool
        public var title: String
        public var year: Int?
        public init(id: Int, isShow: Bool, title: String, year: Int?) {
            self.id = id; self.isShow = isShow; self.title = title; self.year = year
        }
    }

    private static func rx(_ p: String, _ ci: Bool = true) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: ci ? [.caseInsensitive] : [])
    }

    private static let seasonEpisode = rx(#"\bseason\s+([0-9]{1,2})\s*,?\s*(?:episode|ep)\s+([0-9]{1,3})\b"#)
    private static let code = rx(#"\bs([0-9]{1,2})\s*e([0-9]{1,3})\b"#)
    private static let episodeOnly = rx(#"\b(?:episode|ep)\s+([0-9]{1,3})\b"#)
    private static let yearRx = rx(#"\b(19[0-9][0-9]|20[0-9][0-9])\b"#, false)
    private static let leading = rx(#"^\s*(?:play|watch|start|resume|search(?:\s+for)?|find|open)\s+"#)
    private static let trailing = rx(#"\s+(?:on|in|with|using)\s+veltoret\s*$"#)
    private static let spaces = rx(#"\s+"#, false)

    private static let minScore = 40

    private static func replace(_ r: NSRegularExpression, _ s: String, _ with: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: with)
    }

    private static func firstMatch(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        (s as NSString).substring(with: m.range(at: i))
    }

    private static func remove(_ range: NSRange, from s: String) -> String {
        (s as NSString).replacingCharacters(in: range, with: "")
    }

    public static func parse(_ raw: String) -> Parsed {
        var text = replace(leading, replace(trailing, raw.trimmingCharacters(in: .whitespacesAndNewlines), ""), "")
        var season: Int?, episode: Int?
        if let m = firstMatch(seasonEpisode, text) ?? firstMatch(code, text) {
            season = Int(group(m, 1, text))
            episode = Int(group(m, 2, text))
            text = remove(m.range, from: text)
        } else if let e = firstMatch(episodeOnly, text) {
            season = 1
            episode = Int(group(e, 1, text))
            text = remove(e.range, from: text)
        }
        // A year narrows the match ("Dune 2021"), but a title that is only a year ("1917") stays a title.
        var year: Int?
        if let ym = firstMatch(yearRx, text) {
            let without = remove(ym.range, from: text)
            if !without.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                year = Int(group(ym, 0, text))
                text = without
            }
        }
        return Parsed(replace(spaces, text, " ").trimmingCharacters(in: .whitespacesAndNewlines),
                      season: season, episode: episode, year: year)
    }

    /// The title `parsed` most likely means, or nil when nothing is close enough to play.
    public static func best(_ parsed: Parsed, _ candidates: [Candidate]) -> Candidate? {
        let wanted = normalizeForCompare(parsed.title)
        if wanted.isEmpty { return nil }
        let pool = parsed.episode != nil ? candidates.filter(\.isShow) : candidates
        var best: Candidate?
        var bestScore = 0
        for c in pool {
            let s = score(wanted, parsed.year, c)
            if s < minScore { continue }
            // Ties: a movie (people say "play X" for films more often), then the shorter title; full ties keep the first.
            if best == nil || compare(s, c, bestScore, best!) > 0 {
                best = c
                bestScore = s
            }
        }
        return best
    }

    private static func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : a > b ? 1 : 0 }

    private static func compare(_ s1: Int, _ c1: Candidate, _ s2: Int, _ c2: Candidate) -> Int {
        if s1 != s2 { return cmp(s1, s2) }
        if c1.isShow != c2.isShow { return c1.isShow ? -1 : 1 }
        return cmp(-c1.title.utf16.count, -c2.title.utf16.count)
    }

    private static func score(_ wanted: String, _ year: Int?, _ c: Candidate) -> Int {
        let title = normalizeForCompare(c.title)
        if title.isEmpty { return 0 }
        var b: Int
        if title == wanted { b = 100 }
        else if title.hasPrefix(wanted + " ") || wanted.hasPrefix(title + " ") { b = 80 }
        else if title.contains(wanted) && wanted.utf16.count >= 4 { b = 65 }
        else {
            // Most of the spoken words appear in the title ("wrecking crew" for "The Wrecking Crew").
            let words = Set(wanted.split(separator: " ").map(String.init).filter { $0.utf16.count > 1 })
            let have = Set(title.split(separator: " ").map(String.init))
            if words.isEmpty { b = 0 } else {
                let s = 50 * words.filter(have.contains).count / words.count
                b = s >= 35 ? s : 0
            }
        }
        let yearBonus: Int
        if let year, let cy = c.year { yearBonus = year == cy ? 10 : -20 } else { yearBonus = 0 }
        return b + yearBonus
    }

    /// FilenameParser.normalizeForCompare: lowercase, no Latin accents, punctuation as spaces, no leading "the".
    static func normalizeForCompare(_ s: String) -> String { FilenameParser.normalizeForCompare(s) }
}
