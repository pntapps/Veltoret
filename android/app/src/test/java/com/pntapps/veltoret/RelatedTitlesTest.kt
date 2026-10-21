package com.pntapps.veltoret

import com.pntapps.veltoret.data.library.RelatedTitles
import org.junit.Assert.assertEquals
import org.junit.Test

class RelatedTitlesTest {

    private val library = mapOf(1 to "Self", 2 to "Two", 3 to "Three", 4 to "Four", 5 to "Five")

    @Test
    fun keepsTmdbOrderAndOnlyLibraryTitles() {
        assertEquals(listOf("Four", "Two", "Five"), RelatedTitles.inLibrary(listOf(99, 4, 2, 77, 5), library, selfId = 1))
    }

    @Test
    fun skipsSelfAndRepeats() {
        assertEquals(listOf("Three", "Two"), RelatedTitles.inLibrary(listOf(1, 3, 3, 2, 1), library, selfId = 1))
    }

    @Test
    fun capsAtLimit() {
        assertEquals(listOf("Two", "Three"), RelatedTitles.inLibrary(listOf(2, 3, 4, 5), library, selfId = 1, limit = 2))
    }

    @Test
    fun nothingRecommendedOrNotFetchedIsEmpty() {
        assertEquals(emptyList<String>(), RelatedTitles.inLibrary(RelatedTitles.parseIds(null), library, selfId = 1))
        assertEquals(emptyList<String>(), RelatedTitles.inLibrary(RelatedTitles.parseIds(""), library, selfId = 1))
    }

    @Test
    fun parsesStoredIds() {
        assertEquals(listOf(12, 345, 6), RelatedTitles.parseIds("12,345, 6,,x"))
    }
}
