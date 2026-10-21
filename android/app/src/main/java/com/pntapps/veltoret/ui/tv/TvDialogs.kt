package com.pntapps.veltoret.ui.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.pntapps.veltoret.ui.components.VTextField
import com.pntapps.veltoret.ui.theme.VColors

/**
 * A side panel that slides over the right of the screen, like Google TV's settings. Back closes
 * it. The first focusable element inside should take focus (pass [initialFocus]).
 */
@Composable
fun TvSidePanel(
    title: String,
    onDismiss: () -> Unit,
    subtitle: String? = null,
    width: Dp = 420.dp,
    initialFocus: FocusRequester? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    ReturnFocusWhenClosed()
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize()) {
            Column(
                Modifier
                    .align(Alignment.CenterEnd)
                    .fillMaxHeight()
                    .width(width)
                    .background(VColors.SurfaceHigh)
                    .padding(horizontal = 28.dp, vertical = TvDimens.Top + 8.dp),
            ) {
                Text(title, style = MaterialTheme.typography.headlineSmall, color = VColors.Text)
                if (subtitle != null) {
                    Spacer(Modifier.height(6.dp))
                    Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
                }
                Spacer(Modifier.height(20.dp))
                content()
            }
        }
    }
    LaunchedEffect(initialFocus) { initialFocus?.focusSoon() }
}

/** Pick one option from a list; the current one is ticked and focused first. */
@Composable
fun <T> TvChoiceDialog(
    title: String,
    options: List<T>,
    label: (T) -> String,
    selected: T?,
    onDismiss: () -> Unit,
    onSelect: (T) -> Unit,
    subtitle: String? = null,
    detail: ((T) -> String?)? = null,
) {
    val requesters = remember(options) { options.map { FocusRequester() } }
    val start = options.indexOf(selected).coerceAtLeast(0)
    TvSidePanel(title, onDismiss, subtitle, initialFocus = requesters.getOrNull(start)) {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
            itemsIndexed(options) { i, option ->
                TvListItem(
                    title = label(option),
                    subtitle = detail?.invoke(option),
                    selected = option == selected,
                    onClick = { onSelect(option) },
                    focusRequester = requesters[i],
                )
            }
        }
    }
}

/** One labelled action in a [TvActionsDialog]. */
class TvAction(val label: String, val icon: ImageVector? = null, val detail: String? = null, val danger: Boolean = false, val run: () -> Unit)

/** A list of actions for an item (what "hold OK" opens on files and cards). */
@Composable
fun TvActionsDialog(title: String, actions: List<TvAction>, onDismiss: () -> Unit, subtitle: String? = null) {
    val first = remember { FocusRequester() }
    TvSidePanel(title, onDismiss, subtitle, initialFocus = first) {
        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            itemsIndexed(actions) { i, action ->
                TvListItem(
                    title = action.label,
                    subtitle = action.detail,
                    leading = action.icon,
                    onClick = { onDismiss(); action.run() },
                    focusRequester = if (i == 0) first else null,
                )
            }
        }
    }
}

@Composable
fun TvConfirmDialog(
    title: String,
    message: String,
    confirm: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    // Cancel is focused first so a stray OK press can't delete anything.
    val cancel = remember { FocusRequester() }
    TvSidePanel(title, onDismiss, initialFocus = cancel) {
        Text(message, style = MaterialTheme.typography.bodyLarge, color = VColors.TextMuted)
        Spacer(Modifier.height(28.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TvButton("Cancel", onDismiss, focusRequester = cancel)
            TvButton(confirm, { onDismiss(); onConfirm() })
        }
    }
}

/** Text entry; the TV's on-screen keyboard opens when the field is selected. */
@Composable
fun TvTextDialog(
    title: String,
    initial: String,
    confirm: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
    label: String = title,
    subtitle: String? = null,
    secret: Boolean = false,
) {
    var value by remember { mutableStateOf(initial) }
    val field = remember { FocusRequester() }
    TvSidePanel(title, onDismiss, subtitle, width = 520.dp, initialFocus = field) {
        VTextField(
            value = value,
            onValueChange = { value = it },
            label = label,
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                keyboardType = if (secret) KeyboardType.Password else KeyboardType.Text,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { if (value.isNotBlank()) { onDismiss(); onConfirm(value.trim()) } }),
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(field)
                .tvTextFieldExit(),
        )
        Spacer(Modifier.height(24.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TvButton(confirm, { onDismiss(); onConfirm(value.trim()) }, enabled = value.isNotBlank())
            TvButton("Cancel", onDismiss)
        }
    }
}
