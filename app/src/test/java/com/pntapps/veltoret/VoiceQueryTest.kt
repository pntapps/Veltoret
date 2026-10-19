package com.pntapps.veltoret

import com.pntapps.veltoret.data.library.VoiceQuery
import com.pntapps.veltoret.data.library.VoiceQuery.Candidate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VoiceQueryTest {

    private val library = listOf(
        Candidate(1, false, "The Wrecking Crew", 2026),
        Candidate(2, false, "Hokum", 2026),
        Candidate(3, false, "Spider-Man: No Way Home", 2021),
        Candidate(4, true, "Below", 2025),
        Candidate(5, false, "Below Deck Movie", 2019),
        Candidate(6, false, "Dune", 2021),
        Candidate(7, false, "Dune", 1984),
        Candidate(8, true, "House of the Dragon", 2022),
        Candidate(9, false, "1917", 2019),
        Candidate(10, false, "Don't Look Up", 2021),
    )

    private fun pick(said: String) = VoiceQuery.best(VoiceQuery.parse(said), library)?.id

    @Test
    fun parsesSeasonsEpisodesAndFillerWords() {
        assertEquals(VoiceQuery.Parsed("Below", 1, 2), VoiceQuery.parse("Below season 1 episode 2"))
        assertEquals(VoiceQuery.Parsed("House of the Dragon", 2, 5), VoiceQuery.parse("play House of the Dragon S02E05 on Veltoret"))
        assertEquals(VoiceQuery.Parsed("Below", 1, 3), VoiceQuery.parse("Below episode 3"))
        assertEquals(VoiceQuery.Parsed("Dune", year = 2021), VoiceQuery.parse("watch Dune 2021"))
        // A title that is only a year stays a title.
        assertEquals(VoiceQuery.Parsed("1917"), VoiceQuery.parse("1917"))
    }

    @Test
    fun matchesSpokenTitles() {
        assertEquals(1, pick("the wrecking crew"))
        assertEquals(1, pick("wrecking crew"))
        assertEquals(2, pick("hokum"))
        assertEquals(3, pick("spider man no way home"))
        assertEquals(10, pick("dont look up"))
        assertEquals(9, pick("1917"))
    }

    @Test
    fun exactTitlesBeatLongerOnes() {
        assertEquals(4, pick("Below"))
        assertEquals(5, pick("below deck movie"))
    }

    @Test
    fun episodesOnlyMatchShowsAndYearsPickTheRightVersion() {
        assertEquals(4, pick("Below season 1 episode 2"))
        assertEquals(6, pick("Dune 2021"))
        assertEquals(7, pick("Dune 1984"))
    }

    @Test
    fun nothingCloseMeansNoMatch() {
        assertNull(pick("the godfather"))
        assertNull(pick(""))
    }
}
