package com.pntapps.veltoret.ui.files

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.LiveTv
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.PhoneAndroid
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.storage.LocalStorage
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.theme.VColors

/**
 * Opens the system folder picker, which reaches internal storage, SD cards and USB drives.
 * Returns a launcher; [onPicked] gets the granted tree URI.
 */
@Composable
fun rememberLocalFolderPicker(onPicked: (Uri) -> Unit): () -> Unit {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) onPicked(uri)
    }
    return { launcher.launch(null) }
}

/** Asks whether a folder holds movies or TV shows. */
@Composable
fun LibraryTypeDialog(
    folderName: String,
    onDismiss: () -> Unit,
    dismissLabel: String = "Not now",
    onPick: (LibraryType) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = VColors.SurfaceHigh,
        title = { Text("What's in \"$folderName\"?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Veltoret will scan it and match everything with TMDB.", color = VColors.TextMuted)
                VButton("Movies", { onPick(LibraryType.MOVIES) }, Modifier.fillMaxWidth(), icon = Icons.Rounded.Movie)
                VButton("TV Shows", { onPick(LibraryType.SHOWS) }, Modifier.fillMaxWidth(), style = ButtonStyle.Secondary, icon = Icons.Rounded.LiveTv)
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onDismiss) { Text(dismissLabel, color = VColors.Text) } },
    )
}

/** Account avatar: an initial for Google accounts, a phone for "This device". */
@Composable
fun AccountAvatar(account: AccountEntity, size: Dp = 32.dp) {
    if (LocalStorage.isLocal(account.email)) {
        Box(
            Modifier
                .size(size)
                .clip(CircleShape)
                .background(VColors.AmberDim),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.PhoneAndroid, null, tint = VColors.AmberSoft, modifier = Modifier.size(size * 0.55f))
        }
    } else {
        Avatar(account.displayName, size)
    }
}

/** Second line under an account's name. */
fun accountSubtitle(account: AccountEntity): String =
    if (LocalStorage.isLocal(account.email)) "Phone storage, SD card and USB" else account.email
