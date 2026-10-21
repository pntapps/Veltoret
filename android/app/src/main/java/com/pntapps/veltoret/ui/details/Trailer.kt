package com.pntapps.veltoret.ui.details

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.SmartDisplay
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.ui.components.ButtonStyle
import com.pntapps.veltoret.ui.components.VButton
import com.pntapps.veltoret.ui.components.VIconButton

/** Trailers play in the YouTube app (or the browser); Veltoret's own player only plays the user's files. */
val TrailerIcon = Icons.Rounded.SmartDisplay

/** Opens a YouTube trailer: the YouTube app first, then any browser, else a short message. */
fun Context.openTrailer(youtubeKey: String) {
    val intents = listOf(
        Intent(Intent.ACTION_VIEW, Uri.parse("vnd.youtube:$youtubeKey")),
        Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/watch?v=$youtubeKey")),
    )
    for (intent in intents) {
        try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        } catch (_: ActivityNotFoundException) {
        }
    }
    Toast.makeText(this, "Install YouTube to watch trailers", Toast.LENGTH_LONG).show()
}

/** "Trailer" on wide screens; an icon on phones, where the button row is already full. */
@Composable
fun TrailerButton(youtubeKey: String, compact: Boolean) {
    val context = LocalContext.current
    if (compact) VIconButton(TrailerIcon, "Watch trailer", { context.openTrailer(youtubeKey) }, size = 48.dp)
    else VButton("Trailer", { context.openTrailer(youtubeKey) }, icon = TrailerIcon, style = ButtonStyle.Ghost)
}
