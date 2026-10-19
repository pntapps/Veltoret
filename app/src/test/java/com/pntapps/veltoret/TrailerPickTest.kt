package com.pntapps.veltoret

import com.pntapps.veltoret.data.tmdb.TmdbRepository.Companion.pickTrailer
import com.pntapps.veltoret.data.tmdb.TmdbVideo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TrailerPickTest {

    private fun video(key: String, type: String = "Trailer", official: Boolean = true, date: String? = "2020-01-01", site: String = "YouTube") =
        TmdbVideo(key = key, site = site, type = type, official = official, publishedAt = date)

    @Test
    fun trailerBeatsTeaserAndClips() {
        val videos = listOf(video("clip", type = "Clip"), video("teaser", type = "Teaser"), video("trailer"), video("bts", type = "Behind the Scenes"))
        assertEquals("trailer", pickTrailer(videos, newest = false))
    }

    @Test
    fun teaserWhenThereIsNoTrailer() {
        assertEquals("teaser", pickTrailer(listOf(video("clip", type = "Clip"), video("teaser", type = "Teaser")), newest = false))
    }

    @Test
    fun officialBeatsFanUploads() {
        assertEquals("official", pickTrailer(listOf(video("fan", official = false, date = "2019-01-01"), video("official")), newest = false))
    }

    @Test
    fun moviesTakeTheOriginalTrailerShowsTheLatest() {
        val videos = listOf(video("rerelease", date = "2021-05-01"), video("original", date = "1999-02-01"), video("undated", date = null))
        assertEquals("original", pickTrailer(videos, newest = false))
        assertEquals("rerelease", pickTrailer(videos, newest = true))
    }

    @Test
    fun onlyYouTube() {
        assertNull(pickTrailer(listOf(video("vimeo", site = "Vimeo"), video("", site = "YouTube")), newest = false))
    }
}
