package com.pntapps.veltoret.ui.tv

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.home.PosterItem
import com.pntapps.veltoret.ui.navigation.MovieRoute
import com.pntapps.veltoret.ui.navigation.Navigator
import com.pntapps.veltoret.ui.navigation.ShowRoute
import com.pntapps.veltoret.ui.search.SearchViewModel
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.appViewModel

@Composable
fun TvSearchScreen(navigator: Navigator) {
    val vm = appViewModel("tv-search") { SearchViewModel(it) }
    val state by vm.state.collectAsStateWithLifecycle()
    val query by vm.query.collectAsStateWithLifecycle()
    val field = remember { FocusRequester() }
    val box = remember { FocusRequester() }
    val focus = LocalFocusManager.current
    // TV pattern: the keyboard opens only when the box is selected with OK (or straight away when
    // there's nothing typed yet), so moving past the box with the arrows never pops it up.
    var editing by remember { mutableStateOf(query.isBlank()) }
    // Focus returns to the box only when the keyboard closes on it, not when the user arrows away.
    var focusBox by remember { mutableStateOf(true) }
    var fieldHadFocus by remember { mutableStateOf(false) }
    LaunchedEffect(editing) {
        if (editing) field.focusSoon() else if (focusBox) box.focusSoon()
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = TvDimens.Top, bottom = 80.dp)) {
        item("field") {
            Column(Modifier.padding(horizontal = TvDimens.Edge)) {
                Text("Search", style = MaterialTheme.typography.displaySmall, color = VColors.Text)
                Spacer(Modifier.height(16.dp))
                if (editing) {
                    VTextField(
                        value = query,
                        onValueChange = { vm.query.value = it },
                        label = "Titles, actors, collections",
                        leadingIcon = Icons.Rounded.Search,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        // "Search" on the keyboard closes it and jumps down to the results.
                        keyboardActions = KeyboardActions(onSearch = {
                            val results = state.movies.isNotEmpty() || state.shows.isNotEmpty()
                            focusBox = !results
                            editing = false
                            if (results) focus.moveFocus(FocusDirection.Down)
                        }),
                        modifier = Modifier
                            .width(560.dp)
                            .focusRequester(field)
                            .onFocusChanged {
                                // React only to focus actually leaving (the first callback reports "not focused").
                                if (it.isFocused) fieldHadFocus = true
                                else if (fieldHadFocus && editing) { fieldHadFocus = false; focusBox = false; editing = false }
                            }
                            .tvTextFieldExit(),
                    )
                } else {
                    TvSurface(
                        onClick = { focusBox = true; editing = true },
                        modifier = Modifier.width(560.dp).height(60.dp),
                        shape = RoundedCornerShape(14.dp),
                        color = VColors.Surface,
                        focusedColor = VColors.SurfaceHigh,
                        focusedScale = 1.02f,
                        focusRequester = box,
                    ) { focused ->
                        Row(Modifier.align(Alignment.CenterStart).padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Rounded.Search, null, tint = if (focused) VColors.Amber else VColors.TextMuted)
                            Spacer(Modifier.width(14.dp))
                            Text(
                                query.ifBlank { "Titles, actors, collections" },
                                style = MaterialTheme.typography.titleMedium,
                                color = if (query.isBlank()) VColors.TextMuted else VColors.Text,
                                maxLines = 1,
                            )
                            if (focused) {
                                Spacer(Modifier.width(14.dp))
                                Text("OK to type", style = MaterialTheme.typography.labelMedium, color = VColors.TextMuted)
                            }
                        }
                    }
                }
                Spacer(Modifier.height(20.dp))
                if (query.isNotBlank() && state.movies.isEmpty() && state.shows.isEmpty()) {
                    Text("No matches for \"$query\".", style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted)
                }
            }
        }
        if (state.movies.isNotEmpty()) item("movies") { ResultRow("Movies", state.movies, navigator) }
        if (state.shows.isNotEmpty()) item("shows") { ResultRow("TV Shows", state.shows, navigator) }
    }
}

@Composable
private fun ResultRow(title: String, items: List<PosterItem>, navigator: Navigator) {
    Column(Modifier.padding(top = 12.dp)) {
        TvRowTitle(title)
        PivotScrolling {
            LazyRow(contentPadding = TvRowPadding, horizontalArrangement = TvRowArrangement) {
                items(items, key = { "${it.isShow}-${it.id}" }) { item ->
                    TvPosterCard(
                        title = item.title,
                        subtitle = item.subtitle,
                        imageUrl = item.posterUrl,
                        progress = item.progress,
                        watched = item.watched,
                        width = 116.dp,
                        onClick = { navigator.navigate(if (item.isShow) ShowRoute(item.id) else MovieRoute(item.id)) },
                    )
                }
            }
        }
    }
}
