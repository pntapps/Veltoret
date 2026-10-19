package com.pntapps.veltoret.data.library

/**
 * Turns what someone said ("Hey Google, play Below season 1 episode 2 on Veltoret") into a library title.
 * Pure, so it's unit tested (VoiceQueryTest). Matching ignores case, accents, punctuation and a leading
 * "the" ([FilenameParser.normalizeForCompare]), because speech never says "Spider-Man" with its hyphen.
 */
object VoiceQuery {

    data class Parsed(val title: String, val season: Int? = null, val episode: Int? = null, val year: Int? = null)

    /** A movie or show in the library. */
    data class Candidate(val id: Int, val isShow: Boolean, val title: String, val year: Int?)

    // Android's ICU regex engine: escape braces and keep patterns simple (see FilenameParserDeviceTest).
    private val seasonEpisode = Regex("""(?i)\bseason\s+(\d{1,2})\s*,?\s*(?:episode|ep)\s+(\d{1,3})\b""")
    private val code = Regex("""(?i)\bs(\d{1,2})\s*e(\d{1,3})\b""")
    private val episodeOnly = Regex("""(?i)\b(?:episode|ep)\s+(\d{1,3})\b""")
    private val year = Regex("""\b(19\d\d|20\d\d)\b""")
    private val leading = Regex("""(?i)^\s*(?:play|watch|start|resume|search(?:\s+for)?|find|open)\s+""")
    private val trailing = Regex("""(?i)\s+(?:on|in|with|using)\s+veltoret\s*$""")

    fun parse(raw: String): Parsed {
        var text = raw.trim().replace(trailing, "").replace(leading, "")
        var season: Int? = null
        var episode: Int? = null
        (seasonEpisode.find(text) ?: code.find(text))?.let { m ->
            season = m.groupValues[1].toInt()
            episode = m.groupValues[2].toInt()
            text = text.removeRange(m.range)
        } ?: episodeOnly.find(text)?.let { m ->
            season = 1
            episode = m.groupValues[1].toInt()
            text = text.removeRange(m.range)
        }
        // A year narrows the match ("Dune 2021"), but a title that is only a year ("1917") stays a title.
        var y: Int? = null
        val withoutYear = year.find(text)?.let { m -> text.removeRange(m.range) }
        if (withoutYear != null && withoutYear.isNotBlank()) {
            y = year.find(text)!!.value.toInt()
            text = withoutYear
        }
        return Parsed(text.replace(Regex("""\s+"""), " ").trim(), season, episode, y)
    }

    /** The title [parsed] most likely means, or null when nothing is close enough to play. */
    fun best(parsed: Parsed, candidates: List<Candidate>): Candidate? {
        val wanted = FilenameParser.normalizeForCompare(parsed.title)
        if (wanted.isEmpty()) return null
        val pool = if (parsed.episode != null) candidates.filter { it.isShow } else candidates
        return pool
            .map { it to score(wanted, parsed.year, it) }
            .filter { (_, s) -> s >= MIN_SCORE }
            // Ties: an exact year, then a movie (people say "play X" for films more often), then the shorter title.
            .maxWithOrNull(compareBy<Pair<Candidate, Int>> { it.second }.thenBy { !it.first.isShow }.thenBy { -it.first.title.length })
            ?.first
    }

    private fun score(wanted: String, year: Int?, c: Candidate): Int {
        val title = FilenameParser.normalizeForCompare(c.title)
        if (title.isEmpty()) return 0
        val base = when {
            title == wanted -> 100
            title.startsWith("$wanted ") || wanted.startsWith("$title ") -> 80
            title.contains(wanted) && wanted.length >= 4 -> 65
            else -> {
                // Most of the spoken words appear in the title ("wrecking crew" for "The Wrecking Crew").
                val words = wanted.split(' ').filter { it.length > 1 }.toSet()
                val have = title.split(' ').toSet()
                if (words.isEmpty()) 0 else (50 * words.count { it in have } / words.size).let { if (it >= 35) it else 0 }
            }
        }
        val yearBonus = when {
            year == null || c.year == null -> 0
            year == c.year -> 10
            else -> -20
        }
        return base + yearBonus
    }

    private const val MIN_SCORE = 40
}
