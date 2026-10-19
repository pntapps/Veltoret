package com.pntapps.veltoret.ui.navigation

import android.app.SearchManager
import android.content.Intent
import android.provider.MediaStore
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.library.VoiceQuery
import com.pntapps.veltoret.data.plans.OpenTarget
import com.pntapps.veltoret.data.plans.Plans
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * "Hey Google, play Hokum on Veltoret" (MEDIA_PLAY_FROM_SEARCH) and "search for … on Veltoret" (SEARCH),
 * both delivered to MainActivity. Play finds the title in the library ([VoiceQuery]) and plays it through
 * `openRequests` like a notification's Play; with no match, or for a search, Search opens with the words.
 */
object VoiceRequests {

    /** True when [intent] was a voice request (handled in the background). */
    fun consume(intent: Intent?, container: AppContainer): Boolean {
        val action = intent?.action ?: return false
        if (action != MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH && action != Intent.ACTION_SEARCH) return false
        // The Assistant fills in the title separately when it recognised one; the query is the whole phrase.
        val said = (intent.getStringExtra(MediaStore.EXTRA_MEDIA_TITLE) ?: intent.getStringExtra(SearchManager.QUERY)).orEmpty().trim()
        // Consumed once: a later relaunch from Recents must not replay it.
        intent.action = null
        if (said.isEmpty()) return action == MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH
        if (action == Intent.ACTION_SEARCH) {
            container.searchRequests.value = VoiceQuery.parse(said).title.ifEmpty { said }
            return true
        }
        container.appScope.launch {
            val parsed = VoiceQuery.parse(said)
            val library = container.libraryRepository
            val candidates = library.movies().first().map { VoiceQuery.Candidate(it.movie.tmdbId, false, it.movie.title, it.movie.year) } +
                library.shows().first().map { VoiceQuery.Candidate(it.show.tmdbId, true, it.show.name, it.show.year) }
            val match = VoiceQuery.best(parsed, candidates)
            if (match == null) {
                container.searchRequests.value = parsed.title.ifEmpty { said }
                return@launch
            }
            container.openRequests.value = OpenTarget(
                mediaType = if (match.isShow) Plans.TV else Plans.MOVIE,
                mediaId = match.id,
                season = parsed.season.takeIf { match.isShow },
                episode = parsed.episode.takeIf { match.isShow },
                play = true,
            )
        }
        return true
    }
}
