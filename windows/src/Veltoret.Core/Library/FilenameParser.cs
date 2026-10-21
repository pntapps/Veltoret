using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Veltoret.Core.Library;

/// <summary>
/// Turns release-style file and folder names ("The.Matrix.1999.1080p.BluRay.x264.mkv",
/// "Show Name - S02E05 - Title.mkv", "[Group] Show - 05 [1080p].mkv") into searchable guesses.
///
/// Port of the Android app's FilenameParser. Keep both in step: the corpus tests (FilenameParserCorpusTests)
/// are the same lines as the Android ones. Non-ASCII characters are written as \uhhhh.
/// </summary>
public static class FilenameParser
{
    public static readonly HashSet<string> VideoExtensions = new(StringComparer.Ordinal)
    {
        "mkv", "mp4", "m4v", "avi", "mov", "wmv", "flv", "webm", "ts", "m2ts", "mts",
        "mpg", "mpeg", "3gp", "ogv", "vob", "divx", "rmvb", "asf", "f4v", "mxf",
    };

    public static readonly HashSet<string> SubtitleExtensions = new(StringComparer.Ordinal)
    {
        "srt", "vtt", "ass", "ssa", "ttml", "dfxp",
    };

    public sealed record MovieGuess(string Title, int? Year);

    public sealed record EpisodeGuess(string ShowTitle, int? ShowYear, int Season, int Episode, int? EpisodeEnd);

    /// <summary>
    /// A title to look up on TMDB. The first candidate is the parser's best guess; later ones are fallbacks.
    /// <see cref="ExactOnly"/> marks guesses made by trimming words off a name, which only count on an exact title match.
    /// </summary>
    public sealed record TitleCandidate(string Title, int? Year, bool ExactOnly = false);

    public static string Extension(string name)
    {
        var i = name.LastIndexOf('.');
        return i < 0 ? "" : name[(i + 1)..].ToLowerInvariant();
    }

    public static string BaseName(string name)
    {
        var i = name.LastIndexOf('.');
        return i < 0 ? name : name[..i];
    }

    public static bool IsVideo(string name, string mimeType = "") =>
        VideoExtensions.Contains(Extension(name)) || (mimeType.StartsWith("video/") && Extension(name) != "");

    public static bool IsSubtitle(string name) => SubtitleExtensions.Contains(Extension(name));

    /// <summary>Archives Veltoret can unpack into Drive (see ExtractService).</summary>
    public static bool IsArchive(string name) => Extension(name) == "zip";

    private const string Langs = "hindi|english|tamil|telugu|malayalam|kannada|bengali|marathi|punjabi|gujarati|urdu|" +
        "korean|japanese|spanish|french|german|italian|russian|chinese|mandarin|cantonese|arabic|turkish|portuguese|thai|indonesian";

    /// <summary>Words that describe a release's audio or subtitles, never its title ("(Hindi Dubbed)").</summary>
    private static readonly HashSet<string> LanguageWords = new(
        Langs.Split('|').Concat(new[]
        {
            "dubbed", "dual", "audio", "multi", "org", "original", "subbed", "subs", "sub", "esub", "esubs", "msub", "msubs", "hc",
        }));

    private const RegexOptions O = RegexOptions.CultureInvariant;

    private static Regex R(string pattern) => new(pattern, O);

    private static readonly Regex Year = R(@"(?<![0-9])(19[0-9]{2}|20[0-3][0-9])(?![0-9])");
    private static readonly Regex YearExact = R(@"^(19[0-9]{2}|20[0-3][0-9])$");
    private static readonly Regex ParenYear = R(@"\((19[0-9]{2}|20[0-3][0-9])\)");
    private static readonly Regex Paren = R(@"\(([^()]*)\)");
    private static readonly Regex Bracketed = R(@"\[[^\]]*\]|\{[^\}]*\}|【[^】]*】");

    // Release sites glued to names: "www.Site.com - Movie (2020)", "Movie.2020.1080p.SiteName.army". Only
    // lowercase endings count, so dotted titles ("The.Office.US", "The.Fault.in.Our.Stars") are left alone.
    private const string SiteTld = "com|net|org|cc|io|ws|xyz|lol|army|ai|ag|mx|sx|nz|pw|biz|info|site|club|vip|bz|li|im|ms|" +
        "tw|ru|cx|vc|gs|nl|lat|ink|pics|bid|cam|mov|to|in|me|co|tv|so|la|is|at";
    private const string SiteTldEnd = "com|net|org|cc|io|ws|xyz|lol|army|ai|ag|mx|sx|nz|pw|biz|info|site|club|vip|bz|li|im|ms|" +
        "tw|ru|cx|vc|gs|nl|lat|ink|pics|bid|cam|mov";

    private static readonly Regex SitePrefix = R(
        @"^\s*(?:www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*?\.(?:" + SiteTld + @")(?:\.[a-z]{2})?(?![A-Za-z0-9])[\s._\-:|]*" +
        @"|[A-Za-z0-9-]{3,}\.(?:" + SiteTld + @")(?:\.[a-z]{2})?\s+[-|:]\s+)");

    private static readonly Regex SiteSuffix = R(@"[\s._-]+(?:www\.)?[A-Za-z0-9-]{3,}\.(?:" + SiteTldEnd + @")(?:\.[a-z]{2})?$");

    private static readonly Regex Junk = R(
        "(?i)(?<![a-z0-9])(?:" + string.Join("|", new[]
        {
            // Resolution and dynamic range
            "2160p", "1440p", "1080p", "1080i", "720p", "576p", "480p", "360p", "4k", "8k", "uhd", "fhd",
            @"hdr10\+?", "hdr10plus", "hdr", "sdr", "dolby ?vision", "dovi",
            // Source
            "blu-?ray", "bdrip", "brrip", "bdremux", "bd25", "bd50", "remux", "web-?dl", "web-?rip", "hdtv", "pdtv", "sdtv",
            "hdrip", "dvdrip", "dvdscr", "dvd5", "dvd9", "hdts", "hdcam", "camrip", "hdtc", "pre-?dvd", "telesync", "vhsrip",
            // Video codec
            "x ?26[45]", "h ?26[45]", "hevc", "avc", "av1", "vp9", "xvid", "divx", "10 ?bit", "8 ?bit", "12 ?bit", "hi10p",
            // Audio
            "aac[0-9]?", "e?ac-?3", "ddp?[0-9]", @"dd\+", "dts(?:-?hd)?(?:-?ma)?", "truehd", "atmos", "flac", "opus", "lpcm",
            // Edition and release flags
            "proper", "repack", "rerip", "extended", "unrated", "uncut", "uncensored", "directors? cut", "imax", "remastered",
            "limited", "internal", "hfr", "60fps",
            // Streaming services
            "amzn", "dsnp", "hmax", "atvp", "nf", "hulu", "zee5", "sonyliv", "jiocinema", "hotstar", "pcok", "pmtp",
            // Audio languages and subtitles
            "dual audio", "multi audio", "org audio", "hindi dubbed", "dubbed", "esubs?", "msubs?", "hc-?esubs?",
            "multi ?subs?", "subbed",
            "(?:" + Langs + ")(?: ?[-+&] ?| )(?:" + Langs + ")",
        }) + ")(?![a-z0-9])");

    /// <summary>Season markers left in show names ("Below.S01.480p", "Show S01-S03", "Show Season 2", "Show Complete Series").</summary>
    private static readonly Regex SeasonTag = R(
        @"(?i)(?<![a-z0-9])(?:s([0-9]{1,2})(?: ?(?:-|to) ?s?[0-9]{1,2})?|seasons? ?([0-9]{1,2})(?: ?(?:-|to) ?[0-9]{1,2})?|complete(?: series| seasons?)?)(?![a-z0-9])");

    // Episode numbering, tried in this order.
    private static readonly Regex Sxe = R(
        @"(?i)(?<![a-z0-9])s([0-9]{1,2})[ ._-]?(?:e|ep) ?([0-9]{1,4})(?:(?:-|-?e|-?ep) ?([0-9]{1,4}))?(?![0-9])");
    private static readonly Regex Nxn = R(@"(?i)(?<![0-9])([0-9]{1,2})x([0-9]{2,3})(?![0-9])");
    private static readonly Regex Wordy = R(@"(?i)(?<![a-z])season[ ._-]?([0-9]{1,2})[ ._,-]*(?:episode|ep|e)[ ._-]?([0-9]{1,4})(?![0-9])");
    private static readonly Regex Date = R(@"(?<![0-9])((?:19|20)[0-9]{2})[ .-](0[1-9]|1[0-2])[ .-](0[1-9]|[12][0-9]|3[01])(?![0-9])");
    private static readonly Regex CjkEpisode = R(@"第 ?([0-9]{1,4}) ?[話话集]");
    private static readonly Regex DashNumber = R(@"(?i)(?<![0-9]) - ([0-9]{1,4})(?:v[0-9])?(?![0-9a-z])");
    private static readonly Regex EpOnly = R(@"(?i)(?<![a-z0-9])(?:episode|epi|eps|ep|e|part|pt|chapter|ch)\.? ?([0-9]{1,4})(?![0-9])");
    private static readonly Regex BareNumber = R(@"(?i)(?<= )([0-9]{1,4})(?:v[0-9])?(?![0-9a-z])");
    private static readonly Regex LeadingNumber = R(@"(?i)^([0-9]{1,3})(?![0-9a-z])");

    // Folders between the library root and the file.
    private static readonly string[] SeasonWords =
    {
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    };
    private static readonly Regex SeasonFolder = R(
        @"(?i)^(?:season|series|staffel|temporada|saison|stagione|seizoen|sezon|s)[ ._-]?([0-9]{1,2})(?![0-9])");
    private static readonly Regex SeasonWordFolder = R(@"(?i)^season ([a-z]+)(?![a-z])");
    private static readonly Regex SpecialsFolder = R(@"(?i)^(?:specials?|extras?|season 0+)$");
    private static readonly Regex NoiseFolder = R(
        @"(?i)^(?:(?:" + Langs + @") )?(?:tv|tv shows?|shows|series|web ?series|tv series|movies|films|anime|cartoons|k-?dramas|" +
        @"dramas|documentar(?:y|ies)|videos|downloads?|new folder(?: [0-9]+)?|completed?|episodes?|media|dubbed|" +
        Langs + @"|(?:disc|disk|cd|dvd|part|vol|volume) ?[0-9]*|[0-9]+)$");
    private static readonly HashSet<string> GenericNames = new()
    {
        "movie", "video", "film", "sample", "trailer", "cd1", "cd2", "part1", "part2", "disc1", "disc2",
    };

    private static readonly Regex WordSeparator = R(@"(?<=[\p{L}\p{N}])[.+](?=[\p{L}\p{N}])");
    private static readonly Regex Spaces = R(@"\s+");
    private static readonly Regex Parens = R(@"[()]");
    private static readonly Regex NonLetters = R(@"[^\p{L}]+");
    private static readonly char[] TidyChars = { ' ', '-', '.', ',', ':', '[', ']', '_', '|', '+', '&' };

    /// <summary>Strips extension (for files), bracketed group tags, release-site names, and separators.</summary>
    public static string Clean(string raw, bool isFile = true)
    {
        var s = isFile ? BaseName(raw) : raw;
        s = Bracketed.Replace(s, " ");
        s = SitePrefix.Replace(s, "");
        s = SiteSuffix.Replace(s, "");
        s = s.Replace('_', ' ');
        // Dots and pluses between words are separators ("The.Matrix" -> "The Matrix", "Mr.Robot" -> "Mr Robot").
        s = WordSeparator.Replace(s, " ");
        s = Spaces.Replace(s, " ");
        return s.Trim();
    }

    private static string TidyTitle(string s) => Spaces.Replace(Parens.Replace(s, " "), " ").Trim(TidyChars);

    /// <summary>"(Hindi Dubbed)", "(Dual Audio)": parentheses that only describe the audio.</summary>
    private static string DropLanguageParens(string s) => Paren.Replace(s, m =>
    {
        var words = NonLetters.Split(m.Groups[1].Value.ToLowerInvariant()).Where(w => w.Length > 0).ToList();
        return words.Count > 0 && words.All(LanguageWords.Contains) ? " " : m.Value;
    });

    /// <summary>Splits a cleaned string into a title and an optional release year.</summary>
    private static MovieGuess TitleAndYear(string raw)
    {
        var cleaned = Spaces.Replace(DropLanguageParens(raw), " ").Trim();
        var junkMatch = Junk.Match(cleaned);
        int? junk = junkMatch.Success && junkMatch.Index > 0 ? junkMatch.Index : null;
        // A year in parentheses is the release year; otherwise the last year before the release tags.
        var year = ParenYear.Matches(cleaned).LastOrDefault(m => m.Index > 0)
            ?? Year.Matches(cleaned).LastOrDefault(m => m.Index > 0 && (junk == null || m.Index < junk))
            ?? Year.Matches(cleaned).LastOrDefault(m => m.Index > 0);
        if (year != null)
        {
            var cut = Math.Min(year.Index, junk ?? int.MaxValue);
            var title = TidyTitle(cleaned[..cut]);
            if (title.Length > 0) return new MovieGuess(title, int.Parse(year.Groups[1].Value));
        }
        return new MovieGuess(TidyTitle(junk != null ? cleaned[..junk.Value] : cleaned), null);
    }

    /// <summary>Like <see cref="TitleAndYear"/>, but also cuts season and episode markers off a show name ("Below S01" -> "Below").</summary>
    private static MovieGuess ShowTitleAndYear(string cleaned)
    {
        var guess = TitleAndYear(cleaned);
        var cuts = new[] { SeasonTag.Match(guess.Title), Sxe.Match(guess.Title), Nxn.Match(guess.Title) }
            .Where(m => m.Success && m.Index > 0).Select(m => m.Index).ToList();
        if (cuts.Count == 0) return guess;
        return guess with { Title = TidyTitle(guess.Title[..cuts.Min()]) };
    }

    /// <summary>The season named in a show folder ("Below.S01.480p" -> 1), for files that only carry an episode number.</summary>
    private static int? SeasonFromTag(string cleaned)
    {
        var m = SeasonTag.Match(cleaned);
        if (!m.Success || m.Index <= 0) return null;
        var digits = m.Groups[1].Value.Length > 0 ? m.Groups[1].Value : m.Groups[2].Value;
        return int.TryParse(digits, out var n) ? n : null;
    }

    /// <summary>"Season 2", "S02", "Staffel 2", "Season Two" -> 2; "Specials" -> 0; anything else -> null.</summary>
    private static int? SeasonOfFolder(string cleaned)
    {
        if (SpecialsFolder.IsMatch(cleaned)) return 0;
        var m = SeasonFolder.Match(cleaned);
        if (m.Success) return int.Parse(m.Groups[1].Value);
        var w = SeasonWordFolder.Match(cleaned);
        if (!w.Success) return null;
        var index = Array.IndexOf(SeasonWords, w.Groups[1].Value.ToLowerInvariant());
        return index >= 0 ? index + 1 : null;
    }

    /// <summary>Folders that say nothing about the title: categories ("English Shows"), quality ("1080p x264"), discs.</summary>
    private static bool IsNoiseFolder(string cleaned)
    {
        if (cleaned.Length == 0 || NoiseFolder.IsMatch(cleaned)) return true;
        var j = Junk.Match(cleaned);
        return j.Success && j.Index == 0;
    }

    /// <summary>Cleaned folder names that can name a title, nearest to the file first.</summary>
    private static List<string> TitleFolders(IReadOnlyList<string> folders)
    {
        var list = folders.Select(f => Clean(f, isFile: false))
            .Where(f => SeasonOfFolder(f) == null && !IsNoiseFolder(f))
            .ToList();
        list.Reverse();
        return list;
    }

    public static MovieGuess ParseMovie(string fileName, IReadOnlyList<string>? folders = null)
    {
        folders ??= Array.Empty<string>();
        var fromFile = TitleAndYear(Clean(fileName));
        var parentFolder = TitleFolders(folders).FirstOrDefault();
        var parent = parentFolder != null ? TitleAndYear(parentFolder) : null;
        var generic = fromFile.Title.Length < 2 ||
            GenericNames.Contains(fromFile.Title.ToLowerInvariant()) ||
            fromFile.Title.All(c => char.IsDigit(c) || c == ' ');
        if (parent == null || parent.Title.Length == 0) return fromFile;
        if (generic) return parent;
        if (fromFile.Year == null && parent.Year != null) return parent;
        return fromFile;
    }

    private sealed record EpisodeNumbers(
        int? Season,
        int Episode,
        int? EpisodeEnd,
        /* Where the show title ends in the cleaned file name; 0 when the name starts with the number. */
        int TitleEnd,
        /* A bare three-digit number in a scene-style name ("Show.Name.105") that may mean season 1, episode 5. */
        bool Compact = false);

    private static bool IsYear(string digits) => digits.Length == 4 && YearExact.IsMatch(digits);

    private static EpisodeNumbers? GetEpisodeNumbers(string cleaned, string fileName)
    {
        var m = Sxe.Match(cleaned);
        if (m.Success)
        {
            var episode = int.Parse(m.Groups[2].Value);
            int? end = m.Groups[3].Success && int.TryParse(m.Groups[3].Value, out var e) && e > episode && e - episode < 50 ? e : null;
            return new EpisodeNumbers(int.Parse(m.Groups[1].Value), episode, end, m.Index);
        }
        m = Nxn.Match(cleaned);
        if (m.Success) return new EpisodeNumbers(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), null, m.Index);
        m = Wordy.Match(cleaned);
        if (m.Success) return new EpisodeNumbers(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), null, m.Index);
        // Daily shows: "Show.2024.03.15" is season 2024, episode 315.
        m = Date.Match(cleaned);
        if (m.Success && m.Index > 0)
            return new EpisodeNumbers(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value) * 100 + int.Parse(m.Groups[3].Value), null, m.Index);
        m = CjkEpisode.Match(cleaned);
        if (m.Success) return new EpisodeNumbers(null, int.Parse(m.Groups[1].Value), null, m.Index);
        m = DashNumber.Matches(cleaned).FirstOrDefault(x => !IsYear(x.Groups[1].Value));
        if (m != null) return new EpisodeNumbers(null, int.Parse(m.Groups[1].Value), null, m.Index);
        m = EpOnly.Matches(cleaned).FirstOrDefault(x => !IsYear(x.Groups[1].Value));
        if (m != null) return new EpisodeNumbers(null, int.Parse(m.Groups[1].Value), null, m.Index);
        // A number after the title, followed by nothing or by release tags: "[Group] Show 05 (1080p)".
        m = BareNumber.Matches(cleaned).FirstOrDefault(x =>
        {
            var rest = cleaned[(x.Index + x.Length)..].Trim();
            if (x.Index <= 0 || IsYear(x.Groups[1].Value)) return false;
            if (rest.Length == 0 || rest.StartsWith('(') || rest.StartsWith('-')) return true;
            var j = Junk.Match(rest);
            return j.Success && j.Index == 0;
        });
        if (m != null)
        {
            var digits = m.Groups[1].Value;
            var compact = digits.Length == 3 && !BaseName(fileName).Contains(' ') && int.Parse(digits[1..]) > 0;
            return new EpisodeNumbers(null, int.Parse(digits), null, m.Index, compact);
        }
        m = LeadingNumber.Match(cleaned);
        if (m.Success) return new EpisodeNumbers(null, int.Parse(m.Groups[1].Value), null, 0);
        return null;
    }

    /// <summary>True when one name contains the other ("The Office US" / "Office"), ignoring case and punctuation.</summary>
    private static bool Overlaps(string a, string b)
    {
        var x = NormalizeForCompare(a);
        var y = NormalizeForCompare(b);
        return x.Length > 0 && y.Length > 0 && (x.Contains(y) || y.Contains(x));
    }

    /// <summary>
    /// <paramref name="folders"/> are the folder names between the TV library root and the file. The show name comes from the
    /// nearest folder that names something ("Breaking Bad (2008)", "Below.S01.480p"), skipping season folders,
    /// category folders ("English Shows") and quality folders ("480p x264"); otherwise from the file name.
    /// </summary>
    public static EpisodeGuess? ParseEpisode(string fileName, IReadOnlyList<string>? folders = null)
    {
        folders ??= Array.Empty<string>();
        var cleaned = Clean(fileName);
        var numbers = GetEpisodeNumbers(cleaned, fileName);
        if (numbers == null) return null;
        var cleanedFolders = folders.Select(f => Clean(f, isFile: false)).ToList();
        var season = numbers.Season;
        if (season == null)
        {
            for (var i = cleanedFolders.Count - 1; i >= 0 && season == null; i--) season = SeasonOfFolder(cleanedFolders[i]);
        }
        var showFolder = TitleFolders(folders).FirstOrDefault();
        if (season == null && showFolder != null) season = SeasonFromTag(showFolder);
        var episode = numbers.Episode;
        if (numbers.Compact && season == null)
        {
            season = episode / 100;
            episode %= 100;
        }

        var fromFolder = showFolder != null ? ShowTitleAndYear(showFolder) : null;
        if (fromFolder != null && fromFolder.Title.Length == 0) fromFolder = null;
        var fromFile = numbers.TitleEnd > 0 ? ShowTitleAndYear(cleaned[..numbers.TitleEnd]) : null;
        MovieGuess? show;
        if (fromFolder == null) show = fromFile;
        else if (fromFolder.Year == null && fromFile?.Year != null && Overlaps(fromFolder.Title, fromFile.Title))
            show = fromFolder with { Year = fromFile.Year };
        else show = fromFolder;
        if (show == null || show.Title.Length == 0) return null;
        return new EpisodeGuess(show.Title, show.Year, season ?? 1, episode, numbers.EpisodeEnd);
    }

    /// <summary>Titles to try on TMDB for a movie file, best guess first.</summary>
    public static List<TitleCandidate> MovieCandidates(string fileName, IReadOnlyList<string>? folders = null)
    {
        folders ??= Array.Empty<string>();
        var primary = ParseMovie(fileName, folders);
        var fromFile = TitleAndYear(Clean(fileName));
        var parents = TitleFolders(folders).Select(TitleAndYear);
        return Candidates(new[] { primary, fromFile }.Concat(parents).ToList());
    }

    /// <summary>Titles to try on TMDB for an episode file's show, best guess first.</summary>
    public static List<TitleCandidate> ShowCandidates(string fileName, IReadOnlyList<string>? folders = null)
    {
        folders ??= Array.Empty<string>();
        var primary = ParseEpisode(fileName, folders);
        if (primary == null) return new List<TitleCandidate>();
        var cleaned = Clean(fileName);
        var numbers = GetEpisodeNumbers(cleaned, fileName);
        var fromFile = numbers != null && numbers.TitleEnd > 0 ? ShowTitleAndYear(cleaned[..numbers.TitleEnd]) : null;
        var guesses = new List<MovieGuess> { new(primary.ShowTitle, primary.ShowYear) };
        if (fromFile != null) guesses.Add(fromFile);
        guesses.AddRange(TitleFolders(folders).Select(ShowTitleAndYear));
        return Candidates(guesses);
    }

    /// <summary>
    /// The guesses themselves, then trimmed versions for leftovers the parser couldn't recognise: the part
    /// before " - " ("Title - Subtitle"), and the title without its last one or two words ("Movie Name Hindi").
    /// Trimmed versions must keep two words or a year, so a clip can't shrink into a common one-word title.
    /// </summary>
    private static List<TitleCandidate> Candidates(List<MovieGuess> guesses)
    {
        var keys = new HashSet<(string, int?)>();
        var output = new List<TitleCandidate>();
        void Add(string title, int? year, bool exactOnly)
        {
            var key = (NormalizeForCompare(title), year);
            if (key.Item1.Length >= 2 && keys.Add(key)) output.Add(new TitleCandidate(title, year, exactOnly));
        }
        var real = guesses.Where(g => !string.IsNullOrWhiteSpace(g.Title)).ToList();
        foreach (var g in real) Add(g.Title, g.Year, false);
        foreach (var g in real)
        {
            var beforeDash = g.Title.Split(" - ")[0].Trim();
            if (beforeDash != g.Title) Add(beforeDash, g.Year, true);
            var words = g.Title.Split(' ').Where(w => w.Length > 0).ToList();
            for (var drop = 1; drop <= 2; drop++)
            {
                var keep = words.Count - drop;
                if (keep >= 2 || (keep >= 1 && g.Year != null)) Add(string.Join(" ", words.Take(keep)), g.Year, true);
            }
        }
        return output;
    }

    private static readonly Regex CombiningAccents = R(@"[̀-ͯ]+");
    private static readonly Regex Apostrophes = R(@"['`‘’ʼ]");
    private static readonly Regex NotWordish = R(@"[^\p{L}\p{M}\p{N} ]");

    public static string NormalizeForCompare(string s)
    {
        // Drop Latin accents ("Amélie" -> "amelie") but keep every script's letters and vowel signs (Hindi, Japanese...).
        var unaccented = CombiningAccents.Replace(s.Normalize(NormalizationForm.FormD), "");
        var t = unaccented.Normalize(NormalizationForm.FormC).ToLowerInvariant();
        // Apostrophes join words ("Don't" == "Dont", "Stine's" == "Stines"); file names usually drop them.
        t = Apostrophes.Replace(t, "");
        t = t.Replace("&", " and ");
        t = NotWordish.Replace(t, " ");
        t = Spaces.Replace(t, " ").Trim();
        return t.StartsWith("the ") ? t[4..] : t;
    }

    private static readonly Regex FourK = R(@"(?<![a-z0-9])(4k|uhd)(?![a-z0-9])");
    private static readonly Regex DolbyVision = R(@"dolby ?vision|(?<![a-z])dv(?![a-z])|dovi");
    private static readonly Regex Hevc = R(@"hevc|x265|h ?\.?265");
    private static readonly Regex DdPlus = R(@"ddp|eac3|e-ac-3|dd\+");
    private static readonly Regex SevenOne = R(@"7[ .]1");
    private static readonly Regex FiveOne = R(@"5[ .]1");

    /// <summary>Quality hints for badges, read from the file name ("2160p", "HEVC", "DTS"...).</summary>
    public static List<string> QualityTags(string fileName, int height)
    {
        var n = fileName.ToLowerInvariant();
        var tags = new List<string>();
        if (height >= 2000 || n.Contains("2160p") || FourK.IsMatch(n)) tags.Add("4K");
        else if (height >= 1000 || n.Contains("1080p")) tags.Add("1080p");
        else if (height >= 700 || n.Contains("720p")) tags.Add("720p");
        else if (height is >= 1 and <= 699) tags.Add("SD");
        if (DolbyVision.IsMatch(n)) tags.Add("Dolby Vision");
        else if (n.Contains("hdr")) tags.Add("HDR");
        if (Hevc.IsMatch(n)) tags.Add("HEVC");
        if (n.Contains("atmos")) tags.Add("Atmos");
        else if (n.Contains("truehd")) tags.Add("TrueHD");
        else if (n.Contains("dts")) tags.Add("DTS");
        else if (DdPlus.IsMatch(n)) tags.Add("DD+");
        if (SevenOne.IsMatch(n)) tags.Add("7.1");
        else if (FiveOne.IsMatch(n)) tags.Add("5.1");
        if (n.Contains("remux")) tags.Add("Remux");
        return tags;
    }
}
