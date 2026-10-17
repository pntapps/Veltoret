package com.pntapps.veltoret.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation3.runtime.NavBackStack
import androidx.navigation3.runtime.NavKey
import kotlinx.serialization.Serializable

@Serializable data object HomeRoute : NavKey
@Serializable data object MoviesRoute : NavKey
@Serializable data object ShowsRoute : NavKey
@Serializable data object FilesRoute : NavKey
@Serializable data object SettingsRoute : NavKey
@Serializable data object SearchRoute : NavKey
@Serializable data object UnmatchedRoute : NavKey
@Serializable data object ArchivesRoute : NavKey
@Serializable data class MovieRoute(val id: Int) : NavKey
@Serializable data class ShowRoute(val id: Int) : NavKey
@Serializable data class FixMatchRoute(val fileIds: List<String>, val kind: String, val query: String) : NavKey

data class TopLevelDestination(val route: NavKey, val label: String, val icon: ImageVector)

val TopLevelDestinations = listOf(
    TopLevelDestination(HomeRoute, "Home", Icons.Rounded.Home),
    TopLevelDestination(MoviesRoute, "Movies", Icons.Rounded.Movie),
    TopLevelDestination(ShowsRoute, "TV Shows", Icons.Rounded.LiveTv),
    TopLevelDestination(FilesRoute, "Files", Icons.Rounded.Folder),
    TopLevelDestination(SettingsRoute, "Settings", Icons.Rounded.Settings),
)

private val topLevelRoutes = TopLevelDestinations.map { it.route }.toSet()

/**
 * Single back stack with "exit through Home": switching tabs resets to [Home, tab], and detail
 * screens push on top of the current tab.
 */
class Navigator(private val backStack: NavBackStack<NavKey>) {

    val currentTopLevel: NavKey
        get() = backStack.lastOrNull { it in topLevelRoutes } ?: HomeRoute

    fun navigate(route: NavKey) {
        if (backStack.lastOrNull() != route) backStack.add(route)
    }

    fun selectTab(route: NavKey) {
        if (backStack.lastOrNull() == route) return
        backStack.clear()
        backStack.add(HomeRoute)
        if (route != HomeRoute) backStack.add(route)
    }

    fun back() {
        if (backStack.size > 1) backStack.removeAt(backStack.lastIndex)
    }
}
