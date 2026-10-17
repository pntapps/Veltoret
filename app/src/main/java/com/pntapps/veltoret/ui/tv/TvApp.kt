package com.pntapps.veltoret.ui.tv

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.foundation.focusGroup
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import com.pntapps.veltoret.ui.navigation.FilesRoute
import com.pntapps.veltoret.ui.navigation.FixMatchRoute
import com.pntapps.veltoret.ui.navigation.HomeRoute
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.MoviesRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.SearchRoute
import com.pntapps.veltoret.ui.navigation.SettingsRoute
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.navigation.ShowsRoute
import com.pntapps.veltoret.ui.navigation.UnmatchedRoute
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.rememberOnline

private data class TvTab(val route: NavKey, val label: String, val icon: ImageVector)

private val TvTabs = listOf(
    TvTab(SearchRoute, "Search", Icons.Rounded.Search),
    TvTab(HomeRoute, "Home", Icons.Rounded.Home),
    TvTab(MoviesRoute, "Movies", Icons.Rounded.Movie),
    TvTab(ShowsRoute, "TV Shows", Icons.Rounded.LiveTv),
    TvTab(FilesRoute, "Files", Icons.Rounded.Folder),
    TvTab(SettingsRoute, "Settings", Icons.Rounded.Settings),
)
private val TvTabRoutes = TvTabs.map { it.route }.toSet()

/**
 * The TV app: a navigation rail on the left (it expands with labels while focused) and the
 * current screen beside it. Back from a tab's content first moves focus to the rail, then
 * goes Home, then leaves the app, the way Google TV apps behave.
 */
@Composable
fun TvApp() {
    val backStack = rememberNavBackStack(HomeRoute)
    val navigator = remember(backStack) { Navigator(backStack) }
    val top = backStack.lastOrNull() ?: HomeRoute
    // The tab a detail page was opened from (Search included), for the rail highlight.
    val current = backStack.lastOrNull { it in TvTabRoutes } ?: HomeRoute
    var railFocused by remember { mutableStateOf(false) }
    val railRequester = remember { FocusRequester() }
    val online = rememberOnline()

    // Back: content → rail → Home → leave the app (the handler steps aside on Home's rail).
    BackHandler(enabled = top in TvTabRoutes && !(top == HomeRoute && railFocused)) {
        when {
            !railFocused -> runCatching { railRequester.requestFocus() }
            top != HomeRoute -> navigator.selectTab(HomeRoute)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .padding(start = TvDimens.RailCollapsed)
        ) {
            NavDisplay(
                backStack = backStack,
                onBack = { navigator.back() },
                entryDecorators = listOf(
                    rememberSaveableStateHolderNavEntryDecorator(),
                    rememberViewModelStoreNavEntryDecorator(),
                ),
                transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
                popTransitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
                predictivePopTransitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(160)) },
                entryProvider = entryProvider {
                    entry<HomeRoute> { TvHomeScreen(navigator) }
                    entry<MoviesRoute> { TvLibraryScreen(isShows = false, navigator) }
                    entry<ShowsRoute> { TvLibraryScreen(isShows = true, navigator) }
                    entry<SearchRoute> { TvSearchScreen(navigator) }
                    entry<FilesRoute> { TvFilesScreen(navigator) }
                    entry<SettingsRoute> { TvSettingsScreen(navigator) }
                    entry<UnmatchedRoute> { TvUnmatchedScreen(navigator) }
                    entry<FixMatchRoute> { TvFixMatchScreen(it, navigator) }
                    entry<MovieRoute> { TvMovieDetailScreen(it.id, navigator) }
                    entry<ShowRoute> { TvShowDetailScreen(it.id, navigator) }
                },
            )
        }
        // Flat dim (no gradient) over the page while the menu is open.
        androidx.compose.animation.AnimatedVisibility(railFocused, enter = fadeIn(tween(200)), exit = fadeOut(tween(160))) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.55f))
            )
        }
        TvRail(
            selected = current,
            expanded = railFocused,
            online = online,
            requester = railRequester,
            onFocusChanged = { railFocused = it },
            onSelect = { navigator.selectTab(it) },
        )
    }
}

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun TvRail(
    selected: NavKey,
    expanded: Boolean,
    online: Boolean,
    requester: FocusRequester,
    onFocusChanged: (Boolean) -> Unit,
    onSelect: (NavKey) -> Unit,
) {
    val width by animateDpAsState(if (expanded) TvDimens.RailExpanded else TvDimens.RailCollapsed, tween(200), label = "rail")
    Column(
        Modifier
            .fillMaxHeight()
            .width(width)
            .background(if (expanded) VColors.SurfaceHigh else VColors.Surface)
            .padding(vertical = TvDimens.Top, horizontal = 12.dp)
            .onFocusChanged { onFocusChanged(it.hasFocus) }
            // Entering the rail always lands on the current tab, not the nearest item.
            .focusProperties {
                enter = { requester }
                // Only → leaves the rail; ↑/↓ stop at its first and last tab.
                exit = { direction ->
                    if (direction == androidx.compose.ui.focus.FocusDirection.Up || direction == androidx.compose.ui.focus.FocusDirection.Down) {
                        FocusRequester.Cancel
                    } else FocusRequester.Default
                }
            }
            .focusGroup(),
    ) {
        Row(Modifier.padding(start = 14.dp, bottom = 28.dp), verticalAlignment = Alignment.Top) {
            Text("V", style = MaterialTheme.typography.headlineMedium, color = VColors.Text)
            Box(
                Modifier
                    .padding(top = 20.dp, start = 1.dp)
                    .size(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(VColors.Amber)
            )
        }
        TvTabs.forEach { tab ->
            val isSelected = tab.route == selected
            TvSurface(
                onClick = { onSelect(tab.route) },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 3.dp)
                    .height(48.dp),
                shape = RoundedCornerShape(24.dp),
                color = if (isSelected && !expanded) VColors.AmberDim else androidx.compose.ui.graphics.Color.Transparent,
                focusedColor = VColors.Amber,
                focusedScale = 1f,
                showRing = false,
                focusRequester = if (isSelected) requester else null,
            ) { focused ->
                Row(
                    Modifier
                        .align(Alignment.CenterStart)
                        .padding(start = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        tab.icon, tab.label,
                        tint = when {
                            focused -> VColors.OnAmber
                            isSelected -> VColors.Amber
                            else -> VColors.TextMuted
                        },
                        modifier = Modifier.size(24.dp),
                    )
                    if (expanded) {
                        Spacer(Modifier.width(16.dp))
                        Text(
                            tab.label,
                            style = MaterialTheme.typography.titleSmall,
                            color = if (focused) VColors.OnAmber else if (isSelected) VColors.Amber else VColors.Text,
                            maxLines = 1,
                        )
                    }
                }
            }
        }
        Spacer(Modifier.weight(1f))
        if (!online) {
            Row(Modifier.padding(start = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.CloudOff, "Offline", tint = VColors.AmberSoft, modifier = Modifier.size(22.dp))
                if (expanded) {
                    Spacer(Modifier.width(14.dp))
                    Text("Offline", style = MaterialTheme.typography.labelLarge, color = VColors.AmberSoft)
                }
            }
            Spacer(Modifier.height(4.dp))
        }
    }
}
