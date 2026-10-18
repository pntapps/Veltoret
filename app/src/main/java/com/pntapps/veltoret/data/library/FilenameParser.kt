package com.pntapps.veltoret.data.library

import java.text.Normalizer

/**
 * Turns release-style file and folder names ("The.Matrix.1999.1080p.BluRay.x264.mkv",
 * "Show Name - S02E05 - Title.mkv", "[Group] Show - 05 [1080p].mkv") into searchable guesses.
 *
 * Every pattern here runs on Android's ICU regex engine (see FilenameParserDeviceTest): escape `}`,
 * and write non-ASCII characters as `\x{hhhh}`.
 */
object FilenameParser {

    val VIDEO_EXTENSIONS = setOf(
        "mkv", "mp4", "m4v", "avi", "mov", "wmv", "flv", "webm", "ts", "m2ts", "mts",
        "mpg", "mpeg", "3gp", "ogv", "vob", "divx", "rmvb", "asf", "f4v", "mxf",
    )
    val SUBTITLE_EXTENSIONS = setOf("srt", "vtt", "ass", "ssa", "ttml", "dfxp")

    data class MovieGuess(val title: String, val year: Int?)

    data class EpisodeGuess(
        val showTitle: String,
        val showYear: Int?,
        val season: Int,
        val episode: Int,
        val episodeEnd: Int?,
    )

    /**
     * A title to look up on TMDB. The first candidate is the parser's best guess; later ones are fallbacks.
     * [exactOnly] marks guesses made by trimming words off a name, which only count on an exact title match.
     */
    data class TitleCandidate(val title: String, val year: Int?, val exactOnly: Boolean = false)

    fun extension(name: String) = name.substringAfterLast('.', "").lowercase()

    fun baseName(name: String) = if ('.' in name) name.substringBeforeLast('.') else name

    fun isVideo(name: String, mimeType: String): Boolean =
        extension(name) in VIDEO_EXTENSIONS || (mimeType.startsWith("video/") && extension(name) != "")

    fun isSubtitle(name: String) = extension(name) in SUBTITLE_EXTENSIONS

    /** Archives Veltoret can unpack into Drive (see ExtractWorker). */
    fun isArchive(name: String) = extension(name) == "zip"

    private const val LANGS = "hindi|english|tamil|telugu|malayalam|kannada|bengali|marathi|punjabi|gujarati|urdu|" +
        "korean|japanese|spanish|french|german|italian|russian|chinese|mandarin|cantonese|arabic|turkish|portuguese|thai|indonesian"

    /** Words that describe a release's audio or subtitles, never its title ("(Hindi Dubbed)"). */
    private val LANGUAGE_WORDS = LANGS.split('|').toSet() +
        setOf("dubbed", "dual", "audio", "multi", "org", "original", "subbed", "subs", "sub", "esub", "esubs", "msub", "msubs", "hc")

    private val YEAR = Regex("""(?<![0-9])(19[0-9]{2}|20[0-3][0-9])(?![0-9])""")
    private val PAREN_YEAR = Regex("""\((19[0-9]{2}|20[0-3][0-9])\)""")
    private val PAREN = Regex("""\(([^()]*)\)""")
    private val BRACKETED = Regex("""\[[^\]]*\]|\{[^\}]*\}|\x{3010}[^\x{3011}]*\x{3011}""")

    // Release sites glued to names: "www.Site.com - Movie (2020)", "Movie.2020.1080p.SiteName.army". Only
    // lowercase endings count, so dotted titles ("The.Office.US", "The.Fault.in.Our.Stars") are left alone.
    private const val SITE_TLD = "com|net|org|cc|io|ws|xyz|lol|army|ai|ag|mx|sx|nz|pw|biz|info|site|club|vip|bz|li|im|ms|" +
        "tw|ru|cx|vc|gs|nl|lat|ink|pics|bid|cam|mov|to|in|me|co|tv|so|la|is|at"
    private const val SITE_TLD_END = "com|net|org|cc|io|ws|xyz|lol|army|ai|ag|mx|sx|nz|pw|biz|info|site|club|vip|bz|li|im|ms|" +
        "tw|ru|cx|vc|gs|nl|lat|ink|pics|bid|cam|mov"
    private val SITE_PREFIX = Regex(
        """^\s*(?:www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*?\.(?:$SITE_TLD)(?:\.[a-z]{2})?(?![A-Za-z0-9])[\s._\-:|]*""" +
            """|[A-Za-z0-9-]{3,}\.(?:$SITE_TLD)(?:\.[a-z]{2})?\s+[-|:]\s+)"""
    )
    private val SITE_SUFFIX = Regex("""[\s._-]+(?:www\.)?[A-Za-z0-9-]{3,}\.(?:$SITE_TLD_END)(?:\.[a-z]{2})?$""")

    private val JUNK = Regex(
        "(?i)(?<![a-z0-9])(?:" + listOf(
            // Resolution and dynamic range
            "2160p", "1440p", "1080p", "1080i", "720p", "576p", "480p", "360p", "4k", "8k", "uhd", "fhd",
            "hdr10\\+?", "hdr10plus", "hdr", "sdr", "dolby ?vision", "dovi",
            // Source
            "blu-?ray", "bdrip", "brrip", "bdremux", "bd25", "bd50", "remux", "web-?dl", "web-?rip", "hdtv", "pdtv", "sdtv",
            "hdrip", "dvdrip", "dvdscr", "dvd5", "dvd9", "hdts", "hdcam", "camrip", "hdtc", "pre-?dvd", "telesync", "vhsrip",
            // Video codec
            "x ?26[45]", "h ?26[45]", "hevc", "avc", "av1", "vp9", "xvid", "divx", "10 ?bit", "8 ?bit", "12 ?bit", "hi10p",
            // Audio
            "aac[0-9]?", "e?ac-?3", "ddp?[0-9]", "dd\\+", "dts(?:-?hd)?(?:-?ma)?", "truehd", "atmos", "flac", "opus", "lpcm",
            // Edition and release flags
            "proper", "repack", "rerip", "extended", "unrated", "uncut", "uncensored", "directors? cut", "imax", "remastered",
            "limited", "internal", "hfr", "60fps",
            // Streaming services
            "amzn", "dsnp", "hmax", "atvp", "nf", "hulu", "zee5", "sonyliv", "jiocinema", "hotstar", "pcok", "pmtp",
            // Audio languages and subtitles
            "dual audio", "multi audio", "org audio", "hindi dubbed", "dubbed", "esubs?", "msubs?", "hc-?esubs?",
            "multi ?subs?", "subbed",
            "(?:$LANGS)(?: ?[-+&] ?| )(?:$LANGS)",
        ).joinToString("|") + ")(?![a-z0-9])"
    )

    /** Season markers left in show names ("Below.S01.480p", "Show S01-S03", "Show Season 2", "Show Complete Series"). */
    private val SEASON_TAG = Regex(
        """(?i)(?<![a-z0-9])(?:s([0-9]{1,2})(?: ?(?:-|to) ?s?[0-9]{1,2})?|seasons? ?([0-9]{1,2})(?: ?(?:-|to) ?[0-9]{1,2})?|complete(?: series| seasons?)?)(?![a-z0-9])"""
    )

    // Episode numbering, tried in this order.
    private val SXE = Regex(
        """(?i)(?<![a-z0-9])s([0-9]{1,2})[ ._-]?(?:e|ep) ?([0-9]{1,4})(?:(?:-|-?e|-?ep) ?([0-9]{1,4}))?(?![0-9])"""
    )
    private val NXN = Regex("""(?i)(?<![0-9])([0-9]{1,2})x([0-9]{2,3})(?![0-9])""")
    private val WORDY = Regex("""(?i)(?<![a-z])season[ ._-]?([0-9]{1,2})[ ._,-]*(?:episode|ep|e)[ ._-]?([0-9]{1,4})(?![0-9])""")
    private val DATE = Regex("""(?<![0-9])((?:19|20)[0-9]{2})[ .-](0[1-9]|1[0-2])[ .-](0[1-9]|[12][0-9]|3[01])(?![0-9])""")
    private val CJK_EPISODE = Regex("""\x{7B2C} ?([0-9]{1,4}) ?[\x{8A71}\x{8BDD}\x{96C6}]""")
    private val DASH_NUMBER = Regex("""(?i)(?<![0-9]) - ([0-9]{1,4})(?:v[0-9])?(?![0-9a-z])""")
    private val EP_ONLY = Regex("""(?i)(?<![a-z0-9])(?:episode|epi|eps|ep|e|part|pt|chapter|ch)\.? ?([0-9]{1,4})(?![0-9])""")
    private val BARE_NUMBER = Regex("""(?i)(?<= )([0-9]{1,4})(?:v[0-9])?(?![0-9a-z])""")
    private val LEADING_NUMBER = Regex("""(?i)^([0-9]{1,3})(?![0-9a-z])""")

    // Folders between the library root and the file.
    private val SEASON_WORDS = listOf(
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    )
    private val SEASON_FOLDER = Regex(
        """(?i)^(?:season|series|staffel|temporada|saison|stagione|seizoen|sezon|s)[ ._-]?([0-9]{1,2})(?![0-9])"""
    )
    private val SEASON_WORD_FOLDER = Regex("""(?i)^season ([a-z]+)(?![a-z])""")
    private val SPECIALS_FOLDER = Regex("""(?i)^(?:specials?|extras?|season 0+)$""")
    private val NOISE_FOLDER = Regex(
        """(?i)^(?:(?:$LANGS) )?(?:tv|tv shows?|shows|series|web ?series|tv series|movies|films|anime|cartoons|k-?dramas|""" +
            """dramas|documentar(?:y|ies)|videos|downloads?|new folder(?: [0-9]+)?|completed?|episodes?|media|dubbed|""" +
            """$LANGS|(?:disc|disk|cd|dvd|part|vol|volume) ?[0-9]*|[0-9]+)$"""
    )
    private val GENERIC_NAMES = setOf("movie", "video", "film", "sample", "trailer", "cd1", "cd2", "part1", "part2", "disc1", "disc2")

    /** Strips extension (for files), bracketed group tags, release-site names, and separators. */
    fun clean(raw: String, isFile: Boolean = true): String {
        var s = if (isFile) baseName(raw) else raw
        s = s.replace(BRACKETED, " ")
        s = s.replace(SITE_PREFIX, "").replace(SITE_SUFFIX, "")
        s = s.replace('_', ' ')
        // Dots and pluses between words are separators ("The.Matrix" -> "The Matrix", "Mr.Robot" -> "Mr Robot").
        s = s.replace(Regex("""(?<=[\p{L}\p{N}])[.+](?=[\p{L}\p{N}])"""), " ")
        s = s.replace(Regex("""\s+"""), " ")
        return s.trim()
    }

    private fun tidyTitle(s: String) = s
        .replace(Regex("""[()]"""), " ")
        .replace(Regex("""\s+"""), " ")
        .trim(' ', '-', '.', ',', ':', '[', ']', '_', '|', '+', '&')

    /** "(Hindi Dubbed)", "(Dual Audio)": parentheses that only describe the audio. */
    private fun dropLanguageParens(s: String) = s.replace(PAREN) { m ->
        val words = m.groupValues[1].lowercase().split(Regex("""[^\p{L}]+""")).filter { it.isNotEmpty() }
        if (words.isNotEmpty() && words.all { it in LANGUAGE_WORDS }) " " else m.value
    }

    /** Splits a cleaned string into a title and an optional release year. */
    private fun titleAndYear(raw: String): MovieGuess {
        val cleaned = dropLanguageParens(raw).replace(Regex("""\s+"""), " ").trim()
        val junk = JUNK.find(cleaned)?.takeIf { it.range.first > 0 }?.range?.first
        // A year in parentheses is the release year; otherwise the last year before the release tags.
        val year = PAREN_YEAR.findAll(cleaned).lastOrNull { it.range.first > 0 }
            ?: YEAR.findAll(cleaned).lastOrNull { it.range.first > 0 && (junk == null || it.range.first < junk) }
            ?: YEAR.findAll(cleaned).lastOrNull { it.range.first > 0 }
        if (year != null) {
            val cut = minOf(year.range.first, junk ?: Int.MAX_VALUE)
            val title = tidyTitle(cleaned.substring(0, cut))
            if (title.isNotEmpty()) return MovieGuess(title, year.groupValues[1].toInt())
        }
        val title = tidyTitle(if (junk != null) cleaned.substring(0, junk) else cleaned)
        return MovieGuess(title, null)
    }

    /** Like [titleAndYear], but also cuts season and episode markers off a show name ("Below S01" -> "Below"). */
    private fun showTitleAndYear(cleaned: String): MovieGuess {
        val guess = titleAndYear(cleaned)
        val cut = listOfNotNull(SEASON_TAG.find(guess.title), SXE.find(guess.title), NXN.find(guess.title))
            .map { it.range.first }.filter { it > 0 }.minOrNull() ?: return guess
        return guess.copy(title = tidyTitle(guess.title.substring(0, cut)))
    }

    /** The season named in a show folder ("Below.S01.480p" -> 1), for files that only carry an episode number. */
    private fun seasonFromTag(cleaned: String): Int? =
        SEASON_TAG.find(cleaned)?.takeIf { it.range.first > 0 }?.let { m ->
            (m.groupValues[1].ifEmpty { m.groupValues[2] }).toIntOrNull()
        }

    /** "Season 2", "S02", "Staffel 2", "Season Two" -> 2; "Specials" -> 0; anything else -> null. */
    private fun seasonOfFolder(cleaned: String): Int? = when {
        SPECIALS_FOLDER.matches(cleaned) -> 0
        else -> SEASON_FOLDER.find(cleaned)?.groupValues?.get(1)?.toInt()
            ?: SEASON_WORD_FOLDER.find(cleaned)?.groupValues?.get(1)?.lowercase()?.let { w ->
                SEASON_WORDS.indexOf(w).takeIf { it >= 0 }?.plus(1)
            }
    }

    /** Folders that say nothing about the title: categories ("English Shows"), quality ("1080p x264"), discs. */
    private fun isNoiseFolder(cleaned: String) =
        cleaned.isEmpty() || NOISE_FOLDER.matches(cleaned) || JUNK.find(cleaned)?.range?.first == 0

    /** Cleaned folder names that can name a title, nearest to the file first. */
    private fun titleFolders(folders: List<String>): List<String> =
        folders.map { clean(it, isFile = false) }
            .filter { seasonOfFolder(it) == null && !isNoiseFolder(it) }
            .asReversed()

    fun parseMovie(fileName: String, folders: List<String> = emptyList()): MovieGuess {
        val fromFile = titleAndYear(clean(fileName))
        val parent = titleFolders(folders).firstOrNull()?.let { titleAndYear(it) }
        val generic = fromFile.title.length < 2 ||
            fromFile.title.lowercase() in GENERIC_NAMES ||
            fromFile.title.all { it.isDigit() || it == ' ' }
        return when {
            parent == null || parent.title.isEmpty() -> fromFile
            generic -> parent
            fromFile.year == null && parent.year != null -> parent
            else -> fromFile
        }
    }

    private data class EpisodeNumbers(
        val season: Int?,
        val episode: Int,
        val episodeEnd: Int?,
        /** Where the show title ends in the cleaned file name; 0 when the name starts with the number. */
        val titleEnd: Int,
        /** A bare three-digit number in a scene-style name ("Show.Name.105") that may mean season 1, episode 5. */
        val compact: Boolean = false,
    )

    private fun isYear(digits: String) = digits.length == 4 && YEAR.matches(digits)

    private fun episodeNumbers(cleaned: String, fileName: String): EpisodeNumbers? {
        SXE.find(cleaned)?.let { m ->
            val episode = m.groupValues[2].toInt()
            val end = m.groupValues[3].toIntOrNull()?.takeIf { it > episode && it - episode < 50 }
            return EpisodeNumbers(m.groupValues[1].toInt(), episode, end, m.range.first)
        }
        NXN.find(cleaned)?.let { return EpisodeNumbers(it.groupValues[1].toInt(), it.groupValues[2].toInt(), null, it.range.first) }
        WORDY.find(cleaned)?.let { return EpisodeNumbers(it.groupValues[1].toInt(), it.groupValues[2].toInt(), null, it.range.first) }
        // Daily shows: "Show.2024.03.15" is season 2024, episode 315.
        DATE.find(cleaned)?.takeIf { it.range.first > 0 }?.let { m ->
            return EpisodeNumbers(m.groupValues[1].toInt(), m.groupValues[2].toInt() * 100 + m.groupValues[3].toInt(), null, m.range.first)
        }
        CJK_EPISODE.find(cleaned)?.let { return EpisodeNumbers(null, it.groupValues[1].toInt(), null, it.range.first) }
        DASH_NUMBER.findAll(cleaned).firstOrNull { !isYear(it.groupValues[1]) }?.let {
            return EpisodeNumbers(null, it.groupValues[1].toInt(), null, it.range.first)
        }
        EP_ONLY.findAll(cleaned).firstOrNull { !isYear(it.groupValues[1]) }?.let {
            return EpisodeNumbers(null, it.groupValues[1].toInt(), null, it.range.first)
        }
        // A number after the title, followed by nothing or by release tags: "[Group] Show 05 (1080p)".
        BARE_NUMBER.findAll(cleaned).firstOrNull { m ->
            val rest = cleaned.substring(m.range.last + 1).trim()
            m.range.first > 0 && !isYear(m.groupValues[1]) &&
                (rest.isEmpty() || rest.startsWith("(") || rest.startsWith("-") || JUNK.find(rest)?.range?.first == 0)
        }?.let { m ->
            val digits = m.groupValues[1]
            val compact = digits.length == 3 && ' ' !in baseName(fileName) && digits.substring(1).toInt() > 0
            return EpisodeNumbers(null, digits.toInt(), null, m.range.first, compact)
        }
        LEADING_NUMBER.find(cleaned)?.let { return EpisodeNumbers(null, it.groupValues[1].toInt(), null, 0) }
        return null
    }

    /** True when one name contains the other ("The Office US" / "Office"), ignoring case and punctuation. */
    private fun overlaps(a: String, b: String): Boolean {
        val x = normalizeForCompare(a)
        val y = normalizeForCompare(b)
        return x.isNotEmpty() && y.isNotEmpty() && (x.contains(y) || y.contains(x))
    }

    /**
     * [folders] are the folder names between the TV library root and the file. The show name comes from the
     * nearest folder that names something ("Breaking Bad (2008)", "Below.S01.480p"), skipping season folders,
     * category folders ("English Shows") and quality folders ("480p x264"); otherwise from the file name.
     */
    fun parseEpisode(fileName: String, folders: List<String> = emptyList()): EpisodeGuess? {
        val cleaned = clean(fileName)
        val numbers = episodeNumbers(cleaned, fileName) ?: return null
        val cleanedFolders = folders.map { clean(it, isFile = false) }
        var season = numbers.season ?: cleanedFolders.asReversed().firstNotNullOfOrNull { seasonOfFolder(it) }
        val showFolder = titleFolders(folders).firstOrNull()
        if (season == null && showFolder != null) season = seasonFromTag(showFolder)
        var episode = numbers.episode
        if (numbers.compact && season == null) {
            season = episode / 100
            episode %= 100
        }

        val fromFolder = showFolder?.let { showTitleAndYear(it) }?.takeIf { it.title.isNotEmpty() }
        val fromFile = if (numbers.titleEnd > 0) showTitleAndYear(cleaned.substring(0, numbers.titleEnd)) else null
        val show = when {
            fromFolder == null -> fromFile
            fromFolder.year == null && fromFile?.year != null && overlaps(fromFolder.title, fromFile.title) ->
                fromFolder.copy(year = fromFile.year)
            else -> fromFolder
        }
        if (show == null || show.title.isEmpty()) return null
        return EpisodeGuess(show.title, show.year, season ?: 1, episode, numbers.episodeEnd)
    }

    /** Titles to try on TMDB for a movie file, best guess first. */
    fun movieCandidates(fileName: String, folders: List<String> = emptyList()): List<TitleCandidate> {
        val primary = parseMovie(fileName, folders)
        val fromFile = titleAndYear(clean(fileName))
        val parents = titleFolders(folders).map { titleAndYear(it) }
        return candidates(listOf(primary, fromFile) + parents)
    }

    /** Titles to try on TMDB for an episode file's show, best guess first. */
    fun showCandidates(fileName: String, folders: List<String> = emptyList()): List<TitleCandidate> {
        val primary = parseEpisode(fileName, folders) ?: return emptyList()
        val cleaned = clean(fileName)
        val fromFile = episodeNumbers(cleaned, fileName)?.titleEnd?.takeIf { it > 0 }?.let { showTitleAndYear(cleaned.substring(0, it)) }
        val fromFolders = titleFolders(folders).map { showTitleAndYear(it) }
        return candidates(listOfNotNull(MovieGuess(primary.showTitle, primary.showYear), fromFile) + fromFolders)
    }

    /**
     * The guesses themselves, then trimmed versions for leftovers the parser couldn't recognise: the part
     * before " - " ("Title - Subtitle"), and the title without its last one or two words ("Movie Name Hindi").
     * Trimmed versions must keep two words or a year, so a clip can't shrink into a common one-word title.
     */
    private fun candidates(guesses: List<MovieGuess>): List<TitleCandidate> {
        val out = LinkedHashMap<Pair<String, Int?>, TitleCandidate>()
        fun add(title: String, year: Int?, exactOnly: Boolean) {
            val key = normalizeForCompare(title) to year
            if (key.first.length >= 2 && key !in out) out[key] = TitleCandidate(title, year, exactOnly)
        }
        val real = guesses.filter { it.title.isNotBlank() }
        real.forEach { add(it.title, it.year, exactOnly = false) }
        real.forEach { g ->
            g.title.split(" - ").first().trim().takeIf { it != g.title }?.let { add(it, g.year, exactOnly = true) }
            val words = g.title.split(' ').filter { it.isNotEmpty() }
            for (drop in 1..2) {
                val keep = words.size - drop
                if (keep >= 2 || (keep >= 1 && g.year != null)) add(words.take(keep).joinToString(" "), g.year, exactOnly = true)
            }
        }
        return out.values.toList()
    }

    fun normalizeForCompare(s: String): String {
        // Drop Latin accents ("Amélie" -> "amelie") but keep every script's letters and vowel signs (Hindi, Japanese...).
        val unaccented = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("""[\x{0300}-\x{036F}]+"""), "")
        return Normalizer.normalize(unaccented, Normalizer.Form.NFC).lowercase()
            // Apostrophes join words ("Don't" == "Dont", "Stine's" == "Stines"); file names usually drop them.
            .replace(Regex("""['`\x{2018}\x{2019}\x{02BC}]"""), "")
            .replace("&", " and ")
            .replace(Regex("""[^\p{L}\p{M}\p{N} ]"""), " ")
            .replace(Regex("""\s+"""), " ")
            .trim()
            .removePrefix("the ")
    }

    /** Quality hints for badges, read from the file name ("2160p", "HEVC", "DTS"...). */
    fun qualityTags(fileName: String, height: Int): List<String> {
        val n = fileName.lowercase()
        val tags = mutableListOf<String>()
        when {
            height >= 2000 || "2160p" in n || Regex("""(?<![a-z0-9])(4k|uhd)(?![a-z0-9])""").containsMatchIn(n) -> tags += "4K"
            height >= 1000 || "1080p" in n -> tags += "1080p"
            height >= 700 || "720p" in n -> tags += "720p"
            height in 1..699 -> tags += "SD"
        }
        if (Regex("""dolby ?vision|(?<![a-z])dv(?![a-z])|dovi""").containsMatchIn(n)) tags += "Dolby Vision"
        else if ("hdr" in n) tags += "HDR"
        if (Regex("""hevc|x265|h ?\.?265""").containsMatchIn(n)) tags += "HEVC"
        when {
            "atmos" in n -> tags += "Atmos"
            "truehd" in n -> tags += "TrueHD"
            Regex("""dts""").containsMatchIn(n) -> tags += "DTS"
            Regex("""ddp|eac3|e-ac-3|dd\+""").containsMatchIn(n) -> tags += "DD+"
        }
        if (Regex("""7[ .]1""").containsMatchIn(n)) tags += "7.1" else if (Regex("""5[ .]1""").containsMatchIn(n)) tags += "5.1"
        if ("remux" in n) tags += "Remux"
        return tags
    }
}
