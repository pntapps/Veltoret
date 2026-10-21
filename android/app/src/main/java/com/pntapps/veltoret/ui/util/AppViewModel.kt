package com.pntapps.veltoret.ui.util

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.VeltoretApp

val Context.container: AppContainer get() = (applicationContext as VeltoretApp).container

/** Creates a ViewModel scoped to the current nav entry with access to the app's dependencies. */
@Composable
inline fun <reified VM : ViewModel> appViewModel(key: String? = null, crossinline create: (AppContainer) -> VM): VM {
    val container = LocalContext.current.container
    return viewModel(key = key) { create(container) }
}

enum class WidthClass { Compact, Medium, Expanded }

/** Window width bucket, provided once at the root from the measured window size. */
val LocalWidthClass = staticCompositionLocalOf { WidthClass.Compact }

fun widthClassFor(width: Dp): WidthClass = when {
    width >= 840.dp -> WidthClass.Expanded
    width >= 600.dp -> WidthClass.Medium
    else -> WidthClass.Compact
}

/** Horizontal page margin: roomier on tablets so content doesn't hug the edges. */
val WidthClass.gutter: Dp
    get() = when (this) {
        WidthClass.Compact -> 20.dp
        WidthClass.Medium -> 28.dp
        WidthClass.Expanded -> 40.dp
    }

@Composable
fun gutter(): Dp = LocalWidthClass.current.gutter
