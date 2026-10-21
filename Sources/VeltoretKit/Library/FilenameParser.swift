import Foundation

/// Turns release-style file and folder names ("The.Matrix.1999.1080p.BluRay.x264.mkv",
/// "Show Name - S02E05 - Title.mkv", "[Group] Show - 05 [1080p].mkv") into searchable guesses.
///
/// Line-by-line port of the Windows/Android FilenameParser. Keep them in step: the corpus tests
/// (FilenameParserCorpusTests) are the same lines. All indices are UTF-16 offsets (as in .NET and NSRegularExpression).
public enum FilenameParser {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "wmv", "flv", "webm", "ts", "m2ts", "mts",
        "mpg", "mpeg", "3gp", "ogv", "vob", "divx", "rmvb", "asf", "f4v", "mxf",
    ]

    public static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "ttml", "dfxp"]

    public struct MovieGuess: Hashable, Sendable {
        public var title: String
        public var year: Int?
        public init(title: String, year: Int?) { self.title = title; self.year = year }
    }

    public struct EpisodeGuess: Hashable, Sendable {
        public var showTitle: String
        public var showYear: Int?
        public var season: Int
        public var episode: Int
        public var episodeEnd: Int?
        public init(showTitle: String, showYear: Int?, season: Int, episode: Int, episodeEnd: Int?) {
            self.showTitle = showTitle; self.showYear = showYear; self.season = season; self.episode = episode
            self.episodeEnd = episodeEnd
        }
    }

    /// A title to look up on TMDB. The first candidate is the parser's best guess; later ones are fallbacks.
    /// `exactOnly` marks guesses made by trimming words off a name, which only count on an exact title match.
    public struct TitleCandidate: Hashable, Sendable {
        public var title: String
        public var year: Int?
        public var exactOnly: Bool
        public init(title: String, year: Int?, exactOnly: Bool = false) {
            self.title = title; self.year = year; self.exactOnly = exactOnly
        }
    }

    // MARK: - String helpers (UTF-16 semantics, like .NET)

    private static let posix = Locale(identifier: "en_US_POSIX")
    static func lower(_ s: String) -> String { s.lowercased(with: posix) }
    private static func len(_ s: String) -> Int { (s as NSString).length }
    private static func prefix(_ s: String, _ n: Int) -> String { (s as NSString).substring(to: n) }
    private static func suffix(_ s: String, from n: Int) -> String { (s as NSString).substring(from: n) }
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    public static func `extension`(_ name: String) -> String {
        let r = (name as NSString).range(of: ".", options: .backwards)
        return r.location == NSNotFound ? "" : lower(suffix(name, from: r.location + 1))
    }

    public static func baseName(_ name: String) -> String {
        let r = (name as NSString).range(of: ".", options: .backwards)
        return r.location == NSNotFound ? name : prefix(name, r.location)
    }

    public static func isVideo(_ name: String, mimeType: String = "") -> Bool {
        videoExtensions.contains(`extension`(name)) || (mimeType.hasPrefix("video/") && `extension`(name) != "")
    }

    public static func isSubtitle(_ name: String) -> Bool { subtitleExtensions.contains(`extension`(name)) }

    /// Archives Veltoret can unpack into Drive (see the extract service).
    public static func isArchive(_ name: String) -> Bool { `extension`(name) == "zip" }

    // MARK: - Regex wrapper

    final class Rx: @unchecked Sendable {
        let re: NSRegularExpression
        init(_ pattern: String) {
            do { re = try NSRegularExpression(pattern: pattern) } catch { fatalError("Bad regex \(pattern): \(error)") }
        }
        private func all(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
        func match(_ s: String) -> M? { re.firstMatch(in: s, range: all(s)).map { M($0, s) } }
        func matches(_ s: String) -> [M] { re.matches(in: s, range: all(s)).map { M($0, s) } }
        func isMatch(_ s: String) -> Bool { re.firstMatch(in: s, range: all(s)) != nil }
        func replace(_ s: String, _ with: String) -> String {
            re.stringByReplacingMatches(in: s, range: all(s), withTemplate: NSRegularExpression.escapedTemplate(for: with))
        }
        func replace(_ s: String, _ evaluator: (M) -> String) -> String {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in matches(s) {
                out += ns.substring(with: NSRange(location: last, length: m.index - last))
                out += evaluator(m)
                last = m.index + m.length
            }
            out += ns.substring(from: last)
            return out
        }
    }

    struct M {
        let r: NSTextCheckingResult
        let s: String
        init(_ r: NSTextCheckingResult, _ s: String) { self.r = r; self.s = s }
        var index: Int { r.range.location }
        var length: Int { r.range.length }
        var value: String { (s as NSString).substring(with: r.range) }
        func success(_ i: Int) -> Bool { i < r.numberOfRanges && r.range(at: i).location != NSNotFound }
        func group(_ i: Int) -> String { success(i) ? (s as NSString).substring(with: r.range(at: i)) : "" }
    }

    private static func R(_ p: String) -> Rx { Rx(p) }

    // MARK: - Patterns

    private static let langs = "hindi|english|tamil|telugu|malayalam|kannada|bengali|marathi|punjabi|gujarati|urdu|" +
        "korean|japanese|spanish|french|german|italian|russian|chinese|mandarin|cantonese|arabic|turkish|portuguese|thai|indonesian"

    /// Words that describe a release's audio or subtitles, never its title ("(Hindi Dubbed)").
    private static let languageWords: Set<String> = Set(langs.split(separator: "|").map(String.init) + [
        "dubbed", "dual", "audio", "multi", "org", "original", "subbed", "subs", "sub", "esub", "esubs", "msub", "msubs", "hc",
    ])

    private static let year = R(#"(?<![0-9])(19[0-9]{2}|20[0-3][0-9])(?![0-9])"#)
    private static let yearExact = R(#"^(19[0-9]{2}|20[0-3][0-9])$"#)
    private static let parenYear = R(#"\((19[0-9]{2}|20[0-3][0-9])\)"#)
    private static let paren = R(#"\(([^()]*)\)"#)
    private static let bracketed = R(#"\[[^\]]*\]|\{[^\}]*\}|【[^】]*】"#)

    // Release sites glued to names: "www.Site.com - Movie (2020)", "Movie.2020.1080p.SiteName.army". Only
    // lowercase endings count, so dotted titles ("The.Office.US", "The.Fault.in.Our.Stars") are left alone.
    private static let siteTld = "com|net|org|cc|io|ws|xyz|lol|army|ai|ag|mx|sx|nz|pw|biz|info|site|club|vip|bz|li|im|ms|" +
        "tw|ru|cx|vc|gs|nl|lat|ink|pics|bid|cam|mov|to|in|me|co|tv|so|la|is|at"
    private static let siteTldEnd = "com|net|org|cc|io|ws|xyz|lol|army|ai|ag|mx|sx|nz|pw|biz|info|site|club|vip|bz|li|im|ms|" +
        "tw|ru|cx|vc|gs|nl|lat|ink|pics|bid|cam|mov"

    private static let sitePrefix = R(
        #"^\s*(?:www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*?\.(?:"# + siteTld + #")(?:\.[a-z]{2})?(?![A-Za-z0-9])[\s._\-:|]*"# +
        #"|[A-Za-z0-9-]{3,}\.(?:"# + siteTld + #")(?:\.[a-z]{2})?\s+[-|:]\s+)"#)

    private static let siteSuffix = R(#"[\s._-]+(?:www\.)?[A-Za-z0-9-]{3,}\.(?:"# + siteTldEnd + #")(?:\.[a-z]{2})?$"#)

    private static let junk = R(
        "(?i)(?<![a-z0-9])(?:" + [
            // Resolution and dynamic range
            "2160p", "1440p", "1080p", "1080i", "720p", "576p", "480p", "360p", "4k", "8k", "uhd", "fhd",
            #"hdr10\+?"#, "hdr10plus", "hdr", "sdr", "dolby ?vision", "dovi",
            // Source
            "blu-?ray", "bdrip", "brrip", "bdremux", "bd25", "bd50", "remux", "web-?dl", "web-?rip", "hdtv", "pdtv", "sdtv",
            "hdrip", "dvdrip", "dvdscr", "dvd5", "dvd9", "hdts", "hdcam", "camrip", "hdtc", "pre-?dvd", "telesync", "vhsrip",
            // Video codec
            "x ?26[45]", "h ?26[45]", "hevc", "avc", "av1", "vp9", "xvid", "divx", "10 ?bit", "8 ?bit", "12 ?bit", "hi10p",
            // Audio
            "aac[0-9]?", "e?ac-?3", "ddp?[0-9]", #"dd\+"#, "dts(?:-?hd)?(?:-?ma)?", "truehd", "atmos", "flac", "opus", "lpcm",
            // Edition and release flags
            "proper", "repack", "rerip", "extended", "unrated", "uncut", "uncensored", "directors? cut", "imax", "remastered",
            "limited", "internal", "hfr", "60fps",
            // Streaming services
            "amzn", "dsnp", "hmax", "atvp", "nf", "hulu", "zee5", "sonyliv", "jiocinema", "hotstar", "pcok", "pmtp",
            // Audio languages and subtitles
            "dual audio", "multi audio", "org audio", "hindi dubbed", "dubbed", "esubs?", "msubs?", "hc-?esubs?",
            "multi ?subs?", "subbed",
            "(?:" + langs + ")(?: ?[-+&] ?| )(?:" + langs + ")",
        ].joined(separator: "|") + ")(?![a-z0-9])")

    /// Season markers left in show names ("Below.S01.480p", "Show S01-S03", "Show Season 2", "Show Complete Series").
    private static let seasonTag = R(
        #"(?i)(?<![a-z0-9])(?:s([0-9]{1,2})(?: ?(?:-|to) ?s?[0-9]{1,2})?|seasons? ?([0-9]{1,2})(?: ?(?:-|to) ?[0-9]{1,2})?|complete(?: series| seasons?)?)(?![a-z0-9])"#)

    // Episode numbering, tried in this order.
    private static let sxe = R(
        #"(?i)(?<![a-z0-9])s([0-9]{1,2})[ ._-]?(?:e|ep) ?([0-9]{1,4})(?:(?:-|-?e|-?ep) ?([0-9]{1,4}))?(?![0-9])"#)
    private static let nxn = R(#"(?i)(?<![0-9])([0-9]{1,2})x([0-9]{2,3})(?![0-9])"#)
    private static let wordy = R(#"(?i)(?<![a-z])season[ ._-]?([0-9]{1,2})[ ._,-]*(?:episode|ep|e)[ ._-]?([0-9]{1,4})(?![0-9])"#)
    private static let date = R(#"(?<![0-9])((?:19|20)[0-9]{2})[ .-](0[1-9]|1[0-2])[ .-](0[1-9]|[12][0-9]|3[01])(?![0-9])"#)
    private static let cjkEpisode = R(#"第 ?([0-9]{1,4}) ?[話话集]"#)
    private static let dashNumber = R(#"(?i)(?<![0-9]) - ([0-9]{1,4})(?:v[0-9])?(?![0-9a-z])"#)
    private static let epOnly = R(#"(?i)(?<![a-z0-9])(?:episode|epi|eps|ep|e|part|pt|chapter|ch)\.? ?([0-9]{1,4})(?![0-9])"#)
    private static let bareNumber = R(#"(?i)(?<= )([0-9]{1,4})(?:v[0-9])?(?![0-9a-z])"#)
    private static let leadingNumber = R(#"(?i)^([0-9]{1,3})(?![0-9a-z])"#)

    // Folders between the library root and the file.
    private static let seasonWords = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    ]
    private static let seasonFolder = R(
        #"(?i)^(?:season|series|staffel|temporada|saison|stagione|seizoen|sezon|s)[ ._-]?([0-9]{1,2})(?![0-9])"#)
    private static let seasonWordFolder = R(#"(?i)^season ([a-z]+)(?![a-z])"#)
    private static let specialsFolder = R(#"(?i)^(?:specials?|extras?|season 0+)$"#)
    private static let noiseFolder = R(
        #"(?i)^(?:(?:"# + langs + #") )?(?:tv|tv shows?|shows|series|web ?series|tv series|movies|films|anime|cartoons|k-?dramas|"# +
        #"dramas|documentar(?:y|ies)|videos|downloads?|new folder(?: [0-9]+)?|completed?|episodes?|media|dubbed|"# +
        langs + #"|(?:disc|disk|cd|dvd|part|vol|volume) ?[0-9]*|[0-9]+)$"#)
    private static let genericNames: Set<String> = [
        "movie", "video", "film", "sample", "trailer", "cd1", "cd2", "part1", "part2", "disc1", "disc2",
    ]

    private static let wordSeparator = R(#"(?<=[\p{L}\p{N}])[.+](?=[\p{L}\p{N}])"#)
    private static let spaces = R(#"\s+"#)
    private static let parens = R(#"[()]"#)
    private static let nonLetters = R(#"[^\p{L}]+"#)
    private static let tidyChars: Set<Character> = [" ", "-", ".", ",", ":", "[", "]", "_", "|", "+", "&"]

    // MARK: - Cleaning

    /// Strips extension (for files), bracketed group tags, release-site names, and separators.
    public static func clean(_ raw: String, isFile: Bool = true) -> String {
        var s = isFile ? baseName(raw) : raw
        s = bracketed.replace(s, " ")
        s = sitePrefix.replace(s, "")
        s = siteSuffix.replace(s, "")
        s = s.replacingOccurrences(of: "_", with: " ")
        // Dots and pluses between words are separators ("The.Matrix" -> "The Matrix", "Mr.Robot" -> "Mr Robot").
        s = wordSeparator.replace(s, " ")
        s = spaces.replace(s, " ")
        return trim(s)
    }

    private static func trimChars(_ s: String) -> String {
        var scalars = Array(s)
        while let f = scalars.first, tidyChars.contains(f) { scalars.removeFirst() }
        while let l = scalars.last, tidyChars.contains(l) { scalars.removeLast() }
        return String(scalars)
    }

    private static func tidyTitle(_ s: String) -> String { trimChars(spaces.replace(parens.replace(s, " "), " ")) }

    /// "(Hindi Dubbed)", "(Dual Audio)": parentheses that only describe the audio.
    private static func dropLanguageParens(_ s: String) -> String {
        paren.replace(s) { m in
            let words = nonLetters.replace(lower(m.group(1)), " ").split(separator: " ").map(String.init).filter { !$0.isEmpty }
            return !words.isEmpty && words.allSatisfy { languageWords.contains($0) } ? " " : m.value
        }
    }

    /// Splits a cleaned string into a title and an optional release year.
    private static func titleAndYear(_ raw: String) -> MovieGuess {
        let cleaned = trim(spaces.replace(dropLanguageParens(raw), " "))
        let junkMatch = junk.match(cleaned)
        let junkAt: Int? = (junkMatch != nil && junkMatch!.index > 0) ? junkMatch!.index : nil
        // A year in parentheses is the release year; otherwise the last year before the release tags.
        let yearMatch = parenYear.matches(cleaned).last(where: { $0.index > 0 })
            ?? year.matches(cleaned).last(where: { $0.index > 0 && (junkAt == nil || $0.index < junkAt!) })
            ?? year.matches(cleaned).last(where: { $0.index > 0 })
        if let y = yearMatch {
            let cut = min(y.index, junkAt ?? Int.max)
            let title = tidyTitle(prefix(cleaned, cut))
            if !title.isEmpty { return MovieGuess(title: title, year: Int(y.group(1))) }
        }
        return MovieGuess(title: tidyTitle(junkAt != nil ? prefix(cleaned, junkAt!) : cleaned), year: nil)
    }

    /// Like `titleAndYear`, but also cuts season and episode markers off a show name ("Below S01" -> "Below").
    private static func showTitleAndYear(_ cleaned: String) -> MovieGuess {
        var guess = titleAndYear(cleaned)
        let cuts = [seasonTag.match(guess.title), sxe.match(guess.title), nxn.match(guess.title)]
            .compactMap { $0 }.filter { $0.index > 0 }.map { $0.index }
        guard let minCut = cuts.min() else { return guess }
        guess.title = tidyTitle(prefix(guess.title, minCut))
        return guess
    }

    /// The season named in a show folder ("Below.S01.480p" -> 1), for files that only carry an episode number.
    private static func seasonFromTag(_ cleaned: String) -> Int? {
        guard let m = seasonTag.match(cleaned), m.index > 0 else { return nil }
        let digits = !m.group(1).isEmpty ? m.group(1) : m.group(2)
        return Int(digits)
    }

    /// "Season 2", "S02", "Staffel 2", "Season Two" -> 2; "Specials" -> 0; anything else -> nil.
    private static func seasonOfFolder(_ cleaned: String) -> Int? {
        if specialsFolder.isMatch(cleaned) { return 0 }
        if let m = seasonFolder.match(cleaned) { return Int(m.group(1)) }
        guard let w = seasonWordFolder.match(cleaned) else { return nil }
        guard let index = seasonWords.firstIndex(of: lower(w.group(1))) else { return nil }
        return index + 1
    }

    /// Folders that say nothing about the title: categories ("English Shows"), quality ("1080p x264"), discs.
    private static func isNoiseFolder(_ cleaned: String) -> Bool {
        if cleaned.isEmpty || noiseFolder.isMatch(cleaned) { return true }
        if let j = junk.match(cleaned) { return j.index == 0 }
        return false
    }

    /// Cleaned folder names that can name a title, nearest to the file first.
    private static func titleFolders(_ folders: [String]) -> [String] {
        let list = folders.map { clean($0, isFile: false) }
            .filter { seasonOfFolder($0) == nil && !isNoiseFolder($0) }
        return list.reversed()
    }

    private static func isAllDigitsOrSpaces(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0 == " " || CharacterSet.decimalDigits.contains($0) }
    }

    public static func parseMovie(_ fileName: String, folders: [String] = []) -> MovieGuess {
        let fromFile = titleAndYear(clean(fileName))
        let parentFolder = titleFolders(folders).first
        let parent = parentFolder.map { titleAndYear($0) }
        let generic = len(fromFile.title) < 2 ||
            genericNames.contains(lower(fromFile.title)) ||
            isAllDigitsOrSpaces(fromFile.title)
        guard let parent, !parent.title.isEmpty else { return fromFile }
        if generic { return parent }
        if fromFile.year == nil && parent.year != nil { return parent }
        return fromFile
    }

    private struct EpisodeNumbers {
        var season: Int?
        var episode: Int
        var episodeEnd: Int?
        /// Where the show title ends in the cleaned file name; 0 when the name starts with the number.
        var titleEnd: Int
        /// A bare three-digit number in a scene-style name ("Show.Name.105") that may mean season 1, episode 5.
        var compact = false
    }

    private static func isYear(_ digits: String) -> Bool { len(digits) == 4 && yearExact.isMatch(digits) }

    private static func episodeNumbers(_ cleaned: String, _ fileName: String) -> EpisodeNumbers? {
        if let m = sxe.match(cleaned) {
            let episode = Int(m.group(2))!
            var end: Int? = nil
            if m.success(3), let e = Int(m.group(3)), e > episode, e - episode < 50 { end = e }
            return EpisodeNumbers(season: Int(m.group(1)), episode: episode, episodeEnd: end, titleEnd: m.index)
        }
        if let m = nxn.match(cleaned) {
            return EpisodeNumbers(season: Int(m.group(1)), episode: Int(m.group(2))!, episodeEnd: nil, titleEnd: m.index)
        }
        if let m = wordy.match(cleaned) {
            return EpisodeNumbers(season: Int(m.group(1)), episode: Int(m.group(2))!, episodeEnd: nil, titleEnd: m.index)
        }
        // Daily shows: "Show.2024.03.15" is season 2024, episode 315.
        if let m = date.match(cleaned), m.index > 0 {
            return EpisodeNumbers(season: Int(m.group(1)), episode: Int(m.group(2))! * 100 + Int(m.group(3))!,
                                  episodeEnd: nil, titleEnd: m.index)
        }
        if let m = cjkEpisode.match(cleaned) {
            return EpisodeNumbers(season: nil, episode: Int(m.group(1))!, episodeEnd: nil, titleEnd: m.index)
        }
        if let m = dashNumber.matches(cleaned).first(where: { !isYear($0.group(1)) }) {
            return EpisodeNumbers(season: nil, episode: Int(m.group(1))!, episodeEnd: nil, titleEnd: m.index)
        }
        if let m = epOnly.matches(cleaned).first(where: { !isYear($0.group(1)) }) {
            return EpisodeNumbers(season: nil, episode: Int(m.group(1))!, episodeEnd: nil, titleEnd: m.index)
        }
        // A number after the title, followed by nothing or by release tags: "[Group] Show 05 (1080p)".
        if let m = bareNumber.matches(cleaned).first(where: { x in
            let rest = trim(suffix(cleaned, from: x.index + x.length))
            if x.index <= 0 || isYear(x.group(1)) { return false }
            if rest.isEmpty || rest.hasPrefix("(") || rest.hasPrefix("-") { return true }
            if let j = junk.match(rest) { return j.index == 0 }
            return false
        }) {
            let digits = m.group(1)
            let compact = len(digits) == 3 && !baseName(fileName).contains(" ") && Int(suffix(digits, from: 1))! > 0
            return EpisodeNumbers(season: nil, episode: Int(digits)!, episodeEnd: nil, titleEnd: m.index, compact: compact)
        }
        if let m = leadingNumber.match(cleaned) {
            return EpisodeNumbers(season: nil, episode: Int(m.group(1))!, episodeEnd: nil, titleEnd: 0)
        }
        return nil
    }

    /// True when one name contains the other ("The Office US" / "Office"), ignoring case and punctuation.
    private static func overlaps(_ a: String, _ b: String) -> Bool {
        let x = normalizeForCompare(a)
        let y = normalizeForCompare(b)
        return !x.isEmpty && !y.isEmpty && ((x as NSString).contains(y) || (y as NSString).contains(x))
    }

    /// `folders` are the folder names between the TV library root and the file. The show name comes from the
    /// nearest folder that names something ("Breaking Bad (2008)", "Below.S01.480p"), skipping season folders,
    /// category folders ("English Shows") and quality folders ("480p x264"); otherwise from the file name.
    public static func parseEpisode(_ fileName: String, folders: [String] = []) -> EpisodeGuess? {
        let cleaned = clean(fileName)
        guard let numbers = episodeNumbers(cleaned, fileName) else { return nil }
        let cleanedFolders = folders.map { clean($0, isFile: false) }
        var season = numbers.season
        if season == nil {
            var i = cleanedFolders.count - 1
            while i >= 0 && season == nil { season = seasonOfFolder(cleanedFolders[i]); i -= 1 }
        }
        let showFolder = titleFolders(folders).first
        if season == nil, let showFolder { season = seasonFromTag(showFolder) }
        var episode = numbers.episode
        if numbers.compact && season == nil {
            season = episode / 100
            episode %= 100
        }

        var fromFolder = showFolder.map { showTitleAndYear($0) }
        if let f = fromFolder, f.title.isEmpty { fromFolder = nil }
        let fromFile = numbers.titleEnd > 0 ? showTitleAndYear(prefix(cleaned, numbers.titleEnd)) : nil
        var show: MovieGuess?
        if let ff = fromFolder {
            if ff.year == nil, let file = fromFile, file.year != nil, overlaps(ff.title, file.title) {
                show = MovieGuess(title: ff.title, year: file.year)
            } else {
                show = ff
            }
        } else {
            show = fromFile
        }
        guard let show, !show.title.isEmpty else { return nil }
        return EpisodeGuess(showTitle: show.title, showYear: show.year, season: season ?? 1, episode: episode,
                            episodeEnd: numbers.episodeEnd)
    }

    /// Titles to try on TMDB for a movie file, best guess first.
    public static func movieCandidates(_ fileName: String, folders: [String] = []) -> [TitleCandidate] {
        let primary = parseMovie(fileName, folders: folders)
        let fromFile = titleAndYear(clean(fileName))
        let parents = titleFolders(folders).map { titleAndYear($0) }
        return candidates([primary, fromFile] + parents)
    }

    /// Titles to try on TMDB for an episode file's show, best guess first.
    public static func showCandidates(_ fileName: String, folders: [String] = []) -> [TitleCandidate] {
        guard let primary = parseEpisode(fileName, folders: folders) else { return [] }
        let cleaned = clean(fileName)
        let numbers = episodeNumbers(cleaned, fileName)
        let fromFile = (numbers != nil && numbers!.titleEnd > 0) ? showTitleAndYear(prefix(cleaned, numbers!.titleEnd)) : nil
        var guesses = [MovieGuess(title: primary.showTitle, year: primary.showYear)]
        if let fromFile { guesses.append(fromFile) }
        guesses += titleFolders(folders).map { showTitleAndYear($0) }
        return candidates(guesses)
    }

    private struct CandidateKey: Hashable { let title: String; let year: Int? }

    /// The guesses themselves, then trimmed versions for leftovers the parser couldn't recognise: the part
    /// before " - " ("Title - Subtitle"), and the title without its last one or two words ("Movie Name Hindi").
    /// Trimmed versions must keep two words or a year, so a clip can't shrink into a common one-word title.
    private static func candidates(_ guesses: [MovieGuess]) -> [TitleCandidate] {
        var keys = Set<CandidateKey>()
        var output: [TitleCandidate] = []
        func add(_ title: String, _ year: Int?, _ exactOnly: Bool) {
            let key = CandidateKey(title: normalizeForCompare(title), year: year)
            if len(key.title) >= 2 && keys.insert(key).inserted {
                output.append(TitleCandidate(title: title, year: year, exactOnly: exactOnly))
            }
        }
        let real = guesses.filter { !trim($0.title).isEmpty }
        for g in real { add(g.title, g.year, false) }
        for g in real {
            let beforeDash = trim(g.title.components(separatedBy: " - ")[0])
            if beforeDash != g.title { add(beforeDash, g.year, true) }
            let words = g.title.components(separatedBy: " ").filter { !$0.isEmpty }
            for drop in 1...2 {
                let keep = words.count - drop
                if keep >= 2 || (keep >= 1 && g.year != nil) { add(words.prefix(keep).joined(separator: " "), g.year, true) }
            }
        }
        return output
    }

    private static let combiningAccents = R(#"[̀-ͯ]+"#)
    private static let apostrophes = R(#"['`‘’ʼ]"#)
    private static let notWordish = R(#"[^\p{L}\p{M}\p{N} ]"#)

    public static func normalizeForCompare(_ s: String) -> String {
        // Drop Latin accents ("Amélie" -> "amelie") but keep every script's letters and vowel signs (Hindi, Japanese...).
        let unaccented = combiningAccents.replace(s.decomposedStringWithCanonicalMapping, "")
        var t = lower(unaccented.precomposedStringWithCanonicalMapping)
        // Apostrophes join words ("Don't" == "Dont", "Stine's" == "Stines"); file names usually drop them.
        t = apostrophes.replace(t, "")
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = notWordish.replace(t, " ")
        t = trim(spaces.replace(t, " "))
        return t.hasPrefix("the ") ? suffix(t, from: 4) : t
    }

    private static let fourK = R(#"(?<![a-z0-9])(4k|uhd)(?![a-z0-9])"#)
    private static let dolbyVision = R(#"dolby ?vision|(?<![a-z])dv(?![a-z])|dovi"#)
    private static let hevc = R(#"hevc|x265|h ?\.?265"#)
    private static let ddPlus = R(#"ddp|eac3|e-ac-3|dd\+"#)
    private static let sevenOne = R(#"7[ .]1"#)
    private static let fiveOne = R(#"5[ .]1"#)

    /// Quality hints for badges, read from the file name ("2160p", "HEVC", "DTS"...).
    public static func qualityTags(_ fileName: String, height: Int) -> [String] {
        let n = lower(fileName)
        var tags: [String] = []
        if height >= 2000 || n.contains("2160p") || fourK.isMatch(n) { tags.append("4K") }
        else if height >= 1000 || n.contains("1080p") { tags.append("1080p") }
        else if height >= 700 || n.contains("720p") { tags.append("720p") }
        else if height >= 1 && height <= 699 { tags.append("SD") }
        if dolbyVision.isMatch(n) { tags.append("Dolby Vision") }
        else if n.contains("hdr") { tags.append("HDR") }
        if hevc.isMatch(n) { tags.append("HEVC") }
        if n.contains("atmos") { tags.append("Atmos") }
        else if n.contains("truehd") { tags.append("TrueHD") }
        else if n.contains("dts") { tags.append("DTS") }
        else if ddPlus.isMatch(n) { tags.append("DD+") }
        if sevenOne.isMatch(n) { tags.append("7.1") }
        else if fiveOne.isMatch(n) { tags.append("5.1") }
        if n.contains("remux") { tags.append("Remux") }
        return tags
    }
}
