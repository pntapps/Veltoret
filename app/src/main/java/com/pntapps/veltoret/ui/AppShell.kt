package com.pntapps.veltoret.ui

import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.navigation3.rememberViewModelStoreNavEntryDecorator
import androidx.navigation3.runtime.NavKey
import androidx.navigation3.runtime.entryProvider
import androidx.navigation3.runtime.rememberNavBackStack
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import com.pntapps.veltoret.ui.details.MovieDetailScreen
import com.pntapps.veltoret.ui.details.ShowDetailScreen
import com.pntapps.veltoret.ui.files.FilesScreen
import com.pntapps.veltoret.ui.fixmatch.FixMatchScreen
import com.pntapps.veltoret.ui.fixmatch.UnmatchedScreen
import com.pntapps.veltoret.ui.home.HomeScreen
import com.pntapps.veltoret.ui.library.MoviesScreen
import com.pntapps.veltoret.ui.library.ShowsScreen
import com.pntapps.veltoret.ui.files.ArchivesScreen
import com.pntapps.veltoret.ui.navigation.ArchivesRoute
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
import com.pntapps.veltoret.ui.navigation.TopLevelDestinations
import com.pntapps.veltoret.ui.navigation.UnmatchedRoute
import com.pntapps.veltoret.ui.search.SearchScreen
import com.pntapps.veltoret.ui.settings.SettingsScreen
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.LocalWidthClass
import com.pntapps.veltoret.ui.util.WidthClass

@Composable
fun AppShell() {
    val backStack = rememberNavBackStack(HomeRoute)
    val navigator = remember(backStack) { Navigator(backStack) }
    val useRail = LocalWidthClass.current != WidthClass.Compact
    val current = navigator.currentTopLevel

    val content: @Composable BoxScope.() -> Unit = {
        NavDisplay(
            backStack = backStack,
            onBack = { navigator.back() },
            entryDecorators = listOf(
                rememberSaveableStateHolderNavEntryDecorator(),
                rememberViewModelStoreNavEntryDecorator(),
            ),
            transitionSpec = {
                (slideInHorizontally(tween(320)) { it / 6 } + fadeIn(tween(320))) togetherWith fadeOut(tween(180))
            },
            popTransitionSpec = {
                fadeIn(tween(260)) togetherWith (slideOutHorizontally(tween(260)) { it / 6 } + fadeOut(tween(260)))
            },
            predictivePopTransitionSpec = {
                fadeIn(tween(260)) togetherWith (slideOutHorizontally(tween(260)) { it / 6 } + fadeOut(tween(260)))
            },
            entryProvider = entryProvider {
                entry<HomeRoute> { HomeScreen(navigator) }
                entry<MoviesRoute> { MoviesScreen(navigator) }
                entry<ShowsRoute> { ShowsScreen(navigator) }
                entry<FilesRoute> { FilesScreen(navigator) }
                entry<SettingsRoute> { SettingsScreen(navigator) }
                entry<SearchRoute> { SearchScreen(navigator) }
                entry<UnmatchedRoute> { UnmatchedScreen(navigator) }
                entry<ArchivesRoute> { ArchivesScreen(navigator) }
                entry<MovieRoute> { MovieDetailScreen(it.id, navigator) }
                entry<ShowRoute> { ShowDetailScreen(it.id, navigator) }
                entry<FixMatchRoute> { FixMatchScreen(it, navigator) }
            },
        )
        // Flat strip behind the status bar so scrolled content never collides with the clock and icons.
        Box(
            Modifier
                .fillMaxWidth()
                .windowInsetsTopHeight(WindowInsets.statusBars)
                .background(MaterialTheme.colorScheme.background.copy(alpha = 0.94f))
        )
    }

    if (useRail) {
        Row(Modifier.fillMaxSize()) {
            NavRail(current) { navigator.selectTab(it) }
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .windowInsetsPadding(WindowInsets.navigationBars.only(WindowInsetsSides.Bottom + WindowInsetsSides.End))
            ) { content() }
        }
    } else {
        Column(Modifier.fillMaxSize()) {
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
            ) { content() }
            BottomBar(current) { navigator.selectTab(it) }
        }
    }
}

@Composable
private fun BottomBar(current: NavKey, onSelect: (NavKey) -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(VColors.Surface)
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(VColors.Outline)
        )
        Row(
            Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.navigationBars)
                .height(68.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TopLevelDestinations.forEach { dest ->
                val selected = dest.route == current
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clickable { onSelect(dest.route) },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .background(if (selected) VColors.AmberDim else VColors.Surface)
                            .padding(horizontal = 16.dp, vertical = 4.dp)
                    ) {
                        Icon(
                            dest.icon,
                            dest.label,
                            tint = if (selected) VColors.Amber else VColors.TextMuted,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        dest.label,
                        style = MaterialTheme.typography.labelSmall,
                        color = if (selected) VColors.Amber else VColors.TextMuted,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun NavRail(current: NavKey, onSelect: (NavKey) -> Unit) {
    Row(Modifier.fillMaxHeight()) {
        Column(
            Modifier
                .fillMaxHeight()
                .width(92.dp)
                .background(VColors.Surface)
                .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Vertical + WindowInsetsSides.Start))
                .padding(vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(verticalAlignment = Alignment.Top) {
                Text("V", style = MaterialTheme.typography.displaySmall)
                Box(
                    Modifier
                        .padding(top = 22.dp, start = 1.dp)
                        .size(6.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(VColors.Amber)
                )
            }
            Spacer(Modifier.height(28.dp))
            TopLevelDestinations.forEach { dest ->
                val selected = dest.route == current
                Column(
                    Modifier
                        .padding(vertical = 6.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .clickable { onSelect(dest.route) }
                        .padding(horizontal = 6.dp, vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(14.dp))
                            .background(if (selected) VColors.AmberDim else VColors.Surface)
                            .padding(horizontal = 18.dp, vertical = 8.dp)
                    ) {
                        Icon(dest.icon, dest.label, tint = if (selected) VColors.Amber else VColors.TextMuted)
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        dest.label,
                        style = MaterialTheme.typography.labelSmall,
                        color = if (selected) VColors.Amber else VColors.TextMuted,
                    )
                }
            }
        }
        Box(
            Modifier
                .fillMaxHeight()
                .width(1.dp)
                .background(VColors.Outline)
        )
    }
}
