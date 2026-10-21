package com.pntapps.veltoret.ui.tv

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.ui.theme.VColors
import com.pntapps.veltoret.ui.util.container

/**
 * "Play on TV" pairing: while a phone pairs, the TV shows the code to type on the phone. Shown over any
 * Veltoret screen on TV (MainActivity); closes by itself once the phone has paired.
 */
@Composable
fun TvLinkPairingPanel() {
    val host = LocalContext.current.container.tvLinkHost
    val prompt by host.pairing.collectAsStateWithLifecycle()
    val current = prompt ?: return
    val cancel = remember { FocusRequester() }
    TvSidePanel(
        title = "Pair ${current.phoneName}",
        subtitle = "Enter this code on the phone. You only do this once.",
        onDismiss = host::endPairing,
        initialFocus = cancel,
    ) {
        Spacer(Modifier.height(12.dp))
        Text(
            current.code.chunked(3).joinToString(" "),
            style = MaterialTheme.typography.displayMedium.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 6.sp),
            color = VColors.Amber,
        )
        Spacer(Modifier.height(20.dp))
        Text(
            "Then the phone can play movies and shows here and act as the remote.",
            style = MaterialTheme.typography.bodyMedium, color = VColors.TextMuted,
        )
        Spacer(Modifier.height(28.dp))
        TvButton("Cancel", host::endPairing, focusRequester = cancel)
    }
}
