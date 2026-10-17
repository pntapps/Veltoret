package com.pntapps.veltoret.ui.files

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Unarchive
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.pntapps.veltoret.data.drive.ExtractWorker
import com.pntapps.veltoret.data.drive.ZipAfterExtract
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.ui.components.VProgress
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.Format
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

data class ExtractUi(
    val workId: String,
    val zipId: String,
    val name: String,
    val progress: Float,
    val current: String?,
    val extracted: Int,
    val state: WorkInfo.State,
    val error: String?,
    val zipNote: String?,
) {
    val active get() = !state.isFinished
}

/** Live (and recently failed/finished) archive extractions, newest first. */
fun extractions(context: Context): Flow<List<ExtractUi>> =
    WorkManager.getInstance(context).getWorkInfosByTagFlow(ExtractWorker.TAG).map { infos ->
        infos.map { info ->
            val data = if (info.state.isFinished) info.outputData else info.progress
            ExtractUi(
                workId = info.id.toString(),
                zipId = info.tags.firstOrNull { it.startsWith("zip:") }?.removePrefix("zip:").orEmpty(),
                name = data.getString(ExtractWorker.KEY_NAME) ?: "Archive",
                progress = data.getFloat(ExtractWorker.KEY_PROGRESS, if (info.state == WorkInfo.State.SUCCEEDED) 1f else 0f),
                current = data.getString(ExtractWorker.KEY_CURRENT),
                extracted = data.getInt(ExtractWorker.KEY_COUNT, 0),
                state = info.state,
                error = data.getString(ExtractWorker.KEY_ERROR),
                zipNote = data.getString(ExtractWorker.KEY_ZIP_NOTE),
            )
        }
    }

/** Android 13+ hides upload/extract progress notifications unless the user allows them. */
@Composable
fun rememberNotificationPermission(): () -> Unit {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    return remember {
        {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }
}

@Composable
fun ExtractDialog(
    name: String,
    sizeBytes: Long,
    onDismiss: () -> Unit,
    onConfirm: (wifiOnly: Boolean, after: ZipAfterExtract) -> Unit,
) {
    var wifiOnly by remember { mutableStateOf(true) }
    var after by remember { mutableStateOf(ZipAfterExtract.Keep) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = VColors.SurfaceHigh,
        icon = { Icon(Icons.Rounded.Unarchive, null, tint = VColors.Amber) },
        title = { Text("Extract to Google Drive?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "The videos in \"$name\" will be unpacked into a new folder named " +
                        "\"${FilenameParser.baseName(name)}\" right next to it, then added to your library.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    "Nothing is saved on this phone — the archive streams through it. It does use about " +
                        "${Format.bytes(sizeBytes * 2)} of data (downloading and uploading once), and runs in the background.",
                    style = MaterialTheme.typography.bodySmall,
                    color = VColors.TextMuted,
                )
                CheckRow("Only on Wi-Fi", wifiOnly) { wifiOnly = it }
                Text("When it's done", style = MaterialTheme.typography.labelLarge, color = VColors.Amber)
                Column {
                    ChoiceRow("Keep the ZIP", null, after == ZipAfterExtract.Keep) { after = ZipAfterExtract.Keep }
                    ChoiceRow("Move the ZIP to trash", "Recoverable from Drive for 30 days", after == ZipAfterExtract.Trash) {
                        after = ZipAfterExtract.Trash
                    }
                    ChoiceRow("Delete the ZIP permanently", "Frees the space now. This can't be undone.", after == ZipAfterExtract.Delete) {
                        after = ZipAfterExtract.Delete
                    }
                }
                Text(
                    "The ZIP is only removed after every file inside it has been extracted successfully.",
                    style = MaterialTheme.typography.bodySmall,
                    color = VColors.TextFaint,
                )
            }
        },
        confirmButton = {
            TextButton({ onConfirm(wifiOnly, after) }) {
                Text(if (after == ZipAfterExtract.Delete) "Extract & delete ZIP" else "Extract", color = VColors.Amber)
            }
        },
        dismissButton = { TextButton(onDismiss) { Text("Cancel", color = VColors.Text) } },
    )
}

@Composable
private fun ChoiceRow(label: String, detail: String?, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected,
            onClick = onClick,
            colors = RadioButtonDefaults.colors(selectedColor = VColors.Amber, unselectedColor = VColors.TextMuted),
        )
        Column {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            if (detail != null) Text(detail, style = MaterialTheme.typography.bodySmall, color = VColors.TextMuted)
        }
    }
}

@Composable
private fun CheckRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable { onChange(!checked) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = checked,
            onCheckedChange = onChange,
            colors = CheckboxDefaults.colors(checkedColor = VColors.Amber, checkmarkColor = VColors.OnAmber, uncheckedColor = VColors.TextMuted),
        )
        Text(label, style = MaterialTheme.typography.bodyMedium)
    }
}

/** Compact progress card for an upload or an extraction. */
@Composable
fun TransferCard(
    icon: ImageVector,
    title: String,
    detail: String?,
    progress: Float,
    state: WorkInfo.State,
    modifier: Modifier = Modifier,
    onDismiss: (() -> Unit)? = null,
) {
    val failed = state == WorkInfo.State.FAILED
    val done = state == WorkInfo.State.SUCCEEDED
    Column(
        modifier
            .widthIn(max = 320.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(VColors.SurfaceHigh)
            .border(1.dp, if (failed) VColors.Danger.copy(alpha = 0.5f) else VColors.Outline, RoundedCornerShape(14.dp))
            .then(if (onDismiss != null) Modifier.clickable(onClick = onDismiss) else Modifier)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                when {
                    failed -> Icons.Rounded.ErrorOutline
                    done -> Icons.Rounded.CheckCircle
                    else -> icon
                },
                null,
                tint = if (failed) VColors.Danger else VColors.Amber,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(title, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Text(
                when (state) {
                    WorkInfo.State.FAILED -> "Failed"
                    WorkInfo.State.SUCCEEDED -> "Done"
                    WorkInfo.State.ENQUEUED, WorkInfo.State.BLOCKED -> "Waiting"
                    else -> "${(progress * 100).toInt()}%"
                },
                style = MaterialTheme.typography.labelMedium,
                color = VColors.TextMuted,
            )
        }
        if (!detail.isNullOrBlank()) {
            Spacer(Modifier.height(4.dp))
            Text(detail, style = MaterialTheme.typography.bodySmall, color = if (failed) VColors.Danger else VColors.TextMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (!state.isFinished) {
            Spacer(Modifier.height(8.dp))
            VProgress(progress)
        }
    }
}

fun ExtractUi.detail(): String? = when {
    error != null -> error
    state == WorkInfo.State.SUCCEEDED ->
        listOfNotNull("$extracted file${if (extracted == 1) "" else "s"} extracted", zipNote, "scanning library").joinToString(" · ")
    state == WorkInfo.State.ENQUEUED -> "Waiting for a connection (Wi-Fi only?)"
    current != null -> "Unpacking $current"
    else -> null
}

val UploadIcon: ImageVector get() = Icons.Rounded.CloudUpload
val ExtractIcon: ImageVector get() = Icons.Rounded.Unarchive
