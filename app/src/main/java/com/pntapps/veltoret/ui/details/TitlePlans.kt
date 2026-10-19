package com.pntapps.veltoret.ui.details

import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.EditCalendar
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TimePickerDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.ReminderEntity
import com.pntapps.veltoret.data.plans.PlanNotifications
import com.pntapps.veltoret.data.plans.Plans
import com.pntapps.veltoret.ui.components.CardShape
import com.pntapps.veltoret.ui.components.VIconButton
import com.pntapps.veltoret.ui.files.rememberNotificationPermission
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneOffset

/** Watchlist and reminders for one movie or show, shared by its detail page view models (phone and TV). */
class TitlePlans(private val container: AppContainer, private val scope: CoroutineScope, private val type: String, private val id: Int) {
    val saved: StateFlow<Boolean> = container.plans.inWatchlist(type, id).stateIn(scope, SharingStarted.WhileSubscribed(5_000), false)
    val reminders: StateFlow<List<ReminderEntity>> = container.plans.remindersFor(type, id).stateIn(scope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun toggleWatchlist() {
        scope.launch { container.plans.setInWatchlist(type, id, !saved.value) }
    }

    fun remind(title: String, at: Long, season: Int? = null, episode: Int? = null) {
        scope.launch { container.plans.addReminder(type, id, season, episode, title, at) }
    }

    fun cancelReminder(reminderId: Long) {
        scope.launch { container.plans.cancelReminder(reminderId) }
    }
}

/** Bookmark toggle: amber and filled once the title is on the Watchlist. */
@Composable
fun WatchlistButton(saved: Boolean, onToggle: () -> Unit) {
    val context = LocalContext.current
    VIconButton(
        if (saved) Icons.Rounded.Bookmark else Icons.Rounded.BookmarkBorder,
        if (saved) "Remove from Watchlist" else "Watch later",
        {
            Toast.makeText(context, if (saved) "Removed from your Watchlist" else "Added to your Watchlist", Toast.LENGTH_SHORT).show()
            onToggle()
        },
        size = 48.dp,
        tint = if (saved) VColors.Amber else VColors.Text,
    )
}

/** The title's pending reminders, each with a way to cancel it. */
@Composable
fun ReminderList(reminders: List<ReminderEntity>, onCancel: (Long) -> Unit) {
    if (reminders.isEmpty()) return
    val now = LocalDateTime.now()
    Column(Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        reminders.forEach { r ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.NotificationsActive, null, tint = VColors.Amber, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(
                    listOfNotNull(
                        if (r.season != null && r.episode != null) Format.episodeCode(r.season, r.episode) else null,
                        "Reminder ${Plans.reminderLabel(r.at, now)}",
                    ).joinToString("  ·  "),
                    style = MaterialTheme.typography.bodyMedium,
                    color = VColors.Text,
                    modifier = Modifier.weight(1f, fill = false),
                )
                IconButton(onClick = { onCancel(r.id) }, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Rounded.Close, "Cancel reminder", tint = VColors.TextMuted, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

/**
 * "Remind me": one-tap times (tonight, tomorrow, Saturday; [extra] adds e.g. the air day) or any date and
 * time. Asks for the notification permission when needed. [onPick] gets epoch milliseconds.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReminderDialog(title: String, onDismiss: () -> Unit, onPick: (Long) -> Unit, extra: List<Pair<String, LocalDateTime>> = emptyList()) {
    val context = LocalContext.current
    val askPermission = rememberNotificationPermission()
    var step by remember { mutableStateOf(0) } // 0 choices, 1 date, 2 time
    var date by remember { mutableStateOf(LocalDate.now()) }

    fun pick(at: LocalDateTime) {
        val label = Plans.reminderLabel(Plans.toMillis(at), LocalDateTime.now())
        if (PlanNotifications.canPost(context)) {
            Toast.makeText(context, "Reminder set for $label", Toast.LENGTH_SHORT).show()
        } else {
            // Android 13+ asks now; if the answer is no, Settings → Reminders & alerts says why nothing appears.
            askPermission()
            Toast.makeText(context, "Reminder set for $label. Allow notifications so it can appear.", Toast.LENGTH_LONG).show()
        }
        onPick(Plans.toMillis(at))
    }

    when (step) {
        0 -> AlertDialog(
            onDismissRequest = onDismiss,
            containerColor = VColors.SurfaceHigh,
            title = { Text("Remind me") },
            text = {
                Column {
                    Text(title, style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted)
                    Spacer(Modifier.height(12.dp))
                    val now = LocalDateTime.now()
                    (extra.filter { it.second.isAfter(now) } + Plans.quickTimes(now)).forEach { (label, at) ->
                        ChoiceRow(Icons.Rounded.NotificationsActive, label) { pick(at) }
                    }
                    ChoiceRow(Icons.Rounded.EditCalendar, "Pick a date and time…") { step = 1 }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onDismiss) { Text("Cancel", color = VColors.Text) } },
        )
        1 -> {
            val today = LocalDate.now()
            val state = rememberDatePickerState(
                initialSelectedDateMillis = today.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli(),
                selectableDates = object : SelectableDates {
                    override fun isSelectableDate(utcTimeMillis: Long) =
                        !Instant.ofEpochMilli(utcTimeMillis).atZone(ZoneOffset.UTC).toLocalDate().isBefore(today)
                    override fun isSelectableYear(year: Int) = year >= today.year
                },
            )
            DatePickerDialog(
                onDismissRequest = onDismiss,
                confirmButton = {
                    TextButton({
                        state.selectedDateMillis?.let { date = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
                        step = 2
                    }) { Text("Next", color = VColors.Amber) }
                },
                dismissButton = { TextButton(onDismiss) { Text("Cancel", color = VColors.Text) } },
                colors = DatePickerDefaults.colors(containerColor = VColors.SurfaceHigh),
            ) {
                DatePicker(
                    state,
                    colors = DatePickerDefaults.colors(
                        containerColor = VColors.SurfaceHigh,
                        selectedDayContainerColor = VColors.Amber,
                        selectedDayContentColor = VColors.OnAmber,
                        todayDateBorderColor = VColors.Amber,
                        todayContentColor = VColors.Amber,
                    ),
                )
            }
        }
        else -> {
            val state = rememberTimePickerState(initialHour = 20, initialMinute = 0, is24Hour = false)
            AlertDialog(
                onDismissRequest = onDismiss,
                containerColor = VColors.SurfaceHigh,
                title = { Text(Format.date(date.toString()) ?: "Time") },
                text = {
                    TimePicker(
                        state,
                        colors = TimePickerDefaults.colors(
                            clockDialColor = VColors.Surface,
                            selectorColor = VColors.Amber,
                            periodSelectorSelectedContainerColor = VColors.AmberDim,
                            timeSelectorSelectedContainerColor = VColors.AmberDim,
                        ),
                    )
                },
                confirmButton = {
                    val at = date.atTime(LocalTime.of(state.hour, state.minute))
                    TextButton({ pick(at) }, enabled = at.isAfter(LocalDateTime.now())) { Text("Set reminder", color = VColors.Amber) }
                },
                dismissButton = { TextButton({ step = 1 }) { Text("Back", color = VColors.Text) } },
            )
        }
    }
}

@Composable
private fun ChoiceRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(CardShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = VColors.Amber, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(14.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}
