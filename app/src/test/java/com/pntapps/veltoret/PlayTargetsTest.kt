package com.pntapps.veltoret

import com.pntapps.veltoret.data.db.MatchState
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.db.WatchStateEntity
import com.pntapps.veltoret.data.library.PlayTargets
import com.pntapps.veltoret.data.library.WatchKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlayTargetsTest {

    private val show = 42

    private fun file(season: Int, episode: Int) = MediaFileEntity(
        driveId = "f$season-$episode", accountEmail = "a@b.c", libraryFolderId = 1, name = "S${season}E$episode.mkv",
        parentId = "p", relativePath = "", sizeBytes = 1, modifiedTime = null, mimeType = "video/x-matroska",
        durationMs = 0, width = 0, height = 0, kind = MediaKind.EPISODE, parsedTitle = "Show", parsedYear = null,
        season = season, episode = episode, episodeEnd = null, movieId = null, showId = show,
        matchState = MatchState.MATCHED, addedAt = 0,
    )

    private fun state(season: Int, episode: Int, watched: Boolean, at: Long, position: Long = 0) = WatchStateEntity(
        WatchKeys.episode(show, season, episode), position, 3_000_000, watched, at, null, null, show, season, episode,
    )

    private val files = listOf(file(1, 1), file(1, 2), file(1, 3), file(2, 1), file(0, 1))

    @Test fun freshShowStartsAtS1E1() {
        val t = PlayTargets.nextEpisode(files, emptyList())!!
        assertEquals(1 to 1, t.file.season to t.file.episode)
        assertTrue(t.fresh)
    }

    @Test fun continuesAfterLastWatched() {
        val t = PlayTargets.nextEpisode(files, listOf(state(1, 1, true, 10), state(1, 2, true, 20)))!!
        assertEquals(1 to 3, t.file.season to t.file.episode)
    }

    @Test fun crossesSeasonBoundaryAndSkipsSpecials() {
        val t = PlayTargets.nextEpisode(files, listOf(state(1, 3, true, 30)))!!
        assertEquals(2 to 1, t.file.season to t.file.episode)
    }

    @Test fun resumesNewerInProgressEpisode() {
        val t = PlayTargets.nextEpisode(files, listOf(state(1, 1, true, 10), state(1, 2, false, 20, position = 600_000)))!!
        assertEquals(1 to 2, t.file.season to t.file.episode)
        assertTrue(t.resuming)
    }

    @Test fun allCaughtUp() {
        assertNull(PlayTargets.nextEpisode(files, listOf(state(2, 1, true, 99))))
    }
}
