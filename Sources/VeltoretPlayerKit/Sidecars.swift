import Foundation
import VeltoretKit

/// A subtitle file next to the video whose name starts with the video's ("Movie.en.srt").
public struct SidecarMatch<T> {
    public let file: T
    public let name: String
    public let language: String?
    public init(file: T, name: String, language: String?) { self.file = file; self.name = name; self.language = language }
}

extension SidecarMatch: Sendable where T: Sendable {}

public enum Sidecars {
    /// Subtitle extensions (FilenameParser.SubtitleExtensions).
    public static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "ttml", "dfxp"]

    // FilenameParser.BaseName / Extension / IsSubtitle (kept here so the player kit doesn't depend on core's parser).
    static func baseName(_ name: String) -> String {
        guard let i = name.lastIndex(of: ".") else { return name }
        return String(name[..<i])
    }

    static func ext(_ name: String) -> String {
        guard let i = name.lastIndex(of: ".") else { return "" }
        return name[name.index(after: i)...].lowercased()
    }

    public static func isSubtitle(_ name: String) -> Bool { subtitleExtensions.contains(ext(name)) }

    /// Subtitle files beside `videoName`: names starting with the video's base name, with the language taken from
    /// the part after it when that is a 2–3 letter code ("Movie.en.srt" → "en"; "Movie.forced.en.srt" → none).
    public static func match<T>(_ videoName: String, _ files: [T], name: (T) -> String) -> [SidecarMatch<T>] {
        let base = baseName(videoName).lowercased()
        var result: [SidecarMatch<T>] = []
        for f in files {
            let n = name(f)
            if !isSubtitle(n) { continue }
            if !n.lowercased().hasPrefix(base) { continue }
            let subBase = baseName(n)
            var tail = subBase.count >= base.count ? String(subBase.dropFirst(base.count)) : ""
            let trimSet: Set<Character> = [".", " ", "_", "-"]
            while let c = tail.first, trimSet.contains(c) { tail.removeFirst() }
            while let c = tail.last, trimSet.contains(c) { tail.removeLast() }
            let first = (tail.firstIndex(of: ".").map { String(tail[..<$0]) } ?? tail).lowercased()
            let lang = (2...3).contains(first.count) && first.allSatisfy(\.isLetter) ? first : nil
            result.append(SidecarMatch(file: f, name: n, language: lang))
        }
        return result
    }
}

/// Next / previous episode files (Android LibraryRepository.nextEpisodeFile / previousEpisodeFile).
public enum EpisodeNav {
    private static func isAfter(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 > b.0 || (a.0 == b.0 && a.1 > b.1) }

    private static func candidates(_ showFiles: [MediaFileEntity], _ online: Bool) -> [MediaFileEntity] {
        showFiles.filter { ($0.season ?? 0) > 0 && $0.episode != nil && (online || Accounts.isLocal($0.accountEmail)) }
    }

    /// Stable sort by keys, ties keep input order (C# OrderBy).
    private static func ordered(_ files: [MediaFileEntity], _ less: (MediaFileEntity, MediaFileEntity) -> Bool?) -> [MediaFileEntity] {
        files.enumerated().sorted { a, b in less(a.element, b.element) ?? (a.offset < b.offset) }.map(\.element)
    }

    /// The episode file after `file`, preferring the same account. Specials are skipped.
    public static func next(_ file: MediaFileEntity, _ showFiles: [MediaFileEntity], online: Bool) -> MediaFileEntity? {
        guard file.showId != nil, let season = file.season, let last = file.episodeEnd ?? file.episode else { return nil }
        let list = candidates(showFiles, online).filter { isAfter(($0.season!, $0.episode!), (season, last)) }
        return ordered(list) { a, b in
            if a.season! != b.season! { return a.season! < b.season! }
            if a.episode! != b.episode! { return a.episode! < b.episode! }
            let ra = a.accountEmail == file.accountEmail ? 0 : 1, rb = b.accountEmail == file.accountEmail ? 0 : 1
            return ra != rb ? ra < rb : nil
        }.first
    }

    public static func previous(_ file: MediaFileEntity, _ showFiles: [MediaFileEntity], online: Bool) -> MediaFileEntity? {
        guard file.showId != nil, let season = file.season, let episode = file.episode else { return nil }
        let list = candidates(showFiles, online).filter { isAfter((season, episode), ($0.season!, $0.episodeEnd ?? $0.episode!)) }
        return ordered(list) { a, b in
            if a.season! != b.season! { return a.season! > b.season! }
            if a.episode! != b.episode! { return a.episode! > b.episode! }
            let ra = a.accountEmail == file.accountEmail ? 0 : 1, rb = b.accountEmail == file.accountEmail ? 0 : 1
            return ra != rb ? ra < rb : nil
        }.first
    }

    /// In-player episode list: one file per (season, episode), specials last.
    public static func episodeList(_ showFiles: [MediaFileEntity]) -> [MediaFileEntity] {
        var seen = Set<[Int]>()
        let unique = showFiles.filter { f in
            guard let s = f.season, let e = f.episode else { return false }
            return seen.insert([s, e]).inserted
        }
        return ordered(unique) { a, b in
            let sa = a.season == 0 ? Int.max : a.season!, sb = b.season == 0 ? Int.max : b.season!
            if sa != sb { return sa < sb }
            return a.episode! != b.episode! ? a.episode! < b.episode! : nil
        }
    }
}
