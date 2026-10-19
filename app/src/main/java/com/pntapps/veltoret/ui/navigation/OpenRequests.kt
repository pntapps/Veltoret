package com.pntapps.veltoret.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.flow.filterNotNull
import com.pntapps.veltoret.data.plans.Plans
import com.pntapps.veltoret.player.playFile
import com.pntapps.veltoret.ui.util.container

/**
 * Opens what a notification asked for (`AppContainer.openRequests`, set by MainActivity): the title's page,
 * and with "Play" the movie, the episode, or the show's next episode on top of it.
 */
@Composable
fun HandleOpenRequests(navigator: Navigator) {
    val context = LocalContext.current
    val container = context.container
    // One long-lived collector: clearing the request must not cancel the lookup that starts playback
    // (a LaunchedEffect keyed on the request restarted, and was cancelled, as soon as it was cleared).
    LaunchedEffect(Unit) {
        container.openRequests.filterNotNull().collect { t ->
            container.openRequests.value = null
            navigator.navigate(if (t.mediaType == Plans.MOVIE) MovieRoute(t.mediaId) else ShowRoute(t.mediaId))
            if (!t.play) return@collect
            val file = when {
                t.mediaType == Plans.MOVIE -> container.playback.movieFile(t.mediaId)
                t.season != null && t.episode != null -> container.playback.episodeFile(t.mediaId, t.season, t.episode)
                else -> container.playback.showPlayTarget(t.mediaId)?.file
            }
            file?.let { context.playFile(it.driveId, it.accountEmail) }
        }
    }
}
