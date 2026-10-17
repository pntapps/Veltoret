package com.pntapps.veltoret.data.library

import java.text.Normalizer

/**
 * Turns release-style file and folder names ("The.Matrix.1999.1080p.BluRay.x264.mkv",
 * "Show Name - S02E05 - Title.mkv", "[Group] Show - 05 [1080p].mkv") into searchable guesses.
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

    fun extension(name: String) = name.substringAfterLast('.', "").lowercase()

    fun baseName(name: String) = if ('.' in name) name.substringBeforeLast('.') else name

    fun isVideo(name: String, mimeType: String): Boolean =
        extension(name) in VIDEO_EXTENSIONS || (mimeType.startsWith("video/") && extension(name) != "")

    fun isSubtitle(name: String) = extension(name) in SUBTITLE_EXTENSIONS

    /** Archives Veltoret can unpack into Drive (see ExtractWorker). */
    fun isArchive(name: String) = extension(name) == "zip"

    private val YEAR = Regex("""(?<![0-9])(19[0-9]{2}|20[0-3][0-9])(?![0-9])""")
    private val BRACKETED = Regex("""\[[^\]]*\]|\{[^\}]*\}""")
    private val JUNK = Regex(
        """(?i)(?<![a-z0-9])(2160p|1440p|1080p|1080i|720p|576p|480p|4k|uhd|hdr10\+?|hdr|dolby ?vision|dovi|blu-?ray|bdrip|brrip|bdremux|remux|webrip|web-?dl|hdtv|hdrip|dvdrip|dvdscr|x264|x265|h ?26[45]|hevc|avc|xvid|divx|aac[0-9]?|e?ac3|ddp?[0-9]|dts(-?hd)?|truehd|atmos|10bit|8bit|proper|repack|extended|unrated|uncut|directors? cut|imax|remastered|dual audio|esubs?|amzn|dsnp|hmax|atvp)(?![a-z0-9])"""
    )
    private val SXE = Regex("""(?i)(?<![a-z0-9])s([0-9]{1,2}) ?e([0-9]{1,3})(?:-?e([0-9]{1,3}))?(?![0-9])""")
    private val NXN = Regex("""(?i)(?<![0-9])([0-9]{1,2})x([0-9]{2,3})(?![0-9])""")
    private val WORDY = Regex("""(?i)season ?([0-9]{1,2}) ?episode ?([0-9]{1,3})""")
    private val EP_ONLY = Regex("""(?i)(?<![a-z0-9])(?:ep|episode|e) ?([0-9]{1,3})(?![0-9])""")
    private val DASH_NUMBER = Regex("""(?<![0-9]) - ([0-9]{1,3})(?:v[0-9])?(?![0-9])""")
    private val LEADING_NUMBER = Regex("""^([0-9]{1,3})(?![0-9])""")
    private val SEASON_FOLDER = Regex("""(?i)^(?:season|series|s) ?([0-9]{1,2})(?![0-9])""")
    private val SPECIALS_FOLDER = Regex("""(?i)^(specials?|extras?)$""")
    private val GENERIC_NAMES = setOf("movie", "video", "film", "sample", "trailer", "cd1", "cd2", "part1", "part2")

    /** Strips extension (for files), bracketed group tags, and separators. */
    fun clean(raw: String, isFile: Boolean = true): String {
        var s = if (isFile) baseName(raw) else raw
        s = s.replace(BRACKETED, " ")
        s = s.replace('_', ' ')
        // Dots between words are separators ("The.Matrix" -> "The Matrix", "Mr.Robot" -> "Mr Robot").
        s = s.replace(Regex("""(?<=[A-Za-z0-9])\.(?=[A-Za-z0-9])"""), " ")
        s = s.replace(Regex("""\s+"""), " ")
        return s.trim()
    }

    private fun tidyTitle(s: String) = s
        .replace(Regex("""[()]"""), " ")
        .replace(Regex("""\s+"""), " ")
        .trim(' ', '-', '.', ',', ':', '[', ']', '_')

    /** Splits a cleaned string into a title and an optional release year. */
    private fun titleAndYear(cleaned: String): MovieGuess {
        val years = YEAR.findAll(cleaned).filter { it.range.first > 0 }.toList()
        val year = years.lastOrNull()
        if (year != null) {
            val title = tidyTitle(cleaned.substring(0, year.range.first))
            if (title.isNotEmpty()) return MovieGuess(title, year.value.toInt())
        }
        val junk = JUNK.find(cleaned)?.takeIf { it.range.first > 0 }
        val title = tidyTitle(if (junk != null) cleaned.substring(0, junk.range.first) else cleaned)
        return MovieGuess(title, null)
    }

    fun parseMovie(fileName: String, folders: List<String> = emptyList()): MovieGuess {
        val fromFile = titleAndYear(clean(fileName))
        val parent = folders.lastOrNull()?.let { titleAndYear(clean(it, isFile = false)) }
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

    /**
     * [folders] are the folder names between the TV library root and the file. The first one is
     * normally the show folder ("Breaking Bad (2008)"), followed by an optional season folder.
     */
    fun parseEpisode(fileName: String, folders: List<String> = emptyList()): EpisodeGuess? {
        val cleaned = clean(fileName)
        var season: Int? = null
        var episode: Int? = null
        var episodeEnd: Int? = null
        var titleEnd = -1

        val sxe = SXE.find(cleaned)
        val nxn = if (sxe == null) NXN.find(cleaned) else null
        val wordy = if (sxe == null && nxn == null) WORDY.find(cleaned) else null
        when {
            sxe != null -> {
                season = sxe.groupValues[1].toInt()
                episode = sxe.groupValues[2].toInt()
                episodeEnd = sxe.groupValues[3].toIntOrNull()?.takeIf { it > episode }
                titleEnd = sxe.range.first
            }
            nxn != null -> {
                season = nxn.groupValues[1].toInt()
                episode = nxn.groupValues[2].toInt()
                titleEnd = nxn.range.first
            }
            wordy != null -> {
                season = wordy.groupValues[1].toInt()
                episode = wordy.groupValues[2].toInt()
                titleEnd = wordy.range.first
            }
            else -> {
                val dash = DASH_NUMBER.find(cleaned)
                val epOnly = EP_ONLY.find(cleaned)
                val leading = LEADING_NUMBER.find(cleaned)
                when {
                    dash != null -> { episode = dash.groupValues[1].toInt(); titleEnd = dash.range.first }
                    epOnly != null -> { episode = epOnly.groupValues[1].toInt(); titleEnd = epOnly.range.first }
                    leading != null -> { episode = leading.groupValues[1].toInt(); titleEnd = 0 }
                }
            }
        }
        if (episode == null) return null

        val seasonFolder = folders.drop(1).lastOrNull { SEASON_FOLDER.containsMatchIn(it) || SPECIALS_FOLDER.matches(it) }
        if (season == null && seasonFolder != null) {
            season = if (SPECIALS_FOLDER.matches(seasonFolder)) 0
            else SEASON_FOLDER.find(seasonFolder)?.groupValues?.get(1)?.toInt()
        }

        val showFolder = folders.firstOrNull()?.takeUnless { SEASON_FOLDER.containsMatchIn(it) || SPECIALS_FOLDER.matches(it) }
        val show = when {
            showFolder != null -> titleAndYear(clean(showFolder, isFile = false))
            titleEnd > 0 -> titleAndYear(cleaned.substring(0, titleEnd))
            else -> MovieGuess("", null)
        }
        if (show.title.isEmpty()) return null
        return EpisodeGuess(show.title, show.year, season ?: 1, episode, episodeEnd)
    }

    fun normalizeForCompare(s: String): String {
        val ascii = Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("""\p{M}+"""), "")
        return ascii.lowercase()
            .replace("&", " and ")
            .replace(Regex("""[^a-z0-9 ]"""), " ")
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
