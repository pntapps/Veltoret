package com.pntapps.veltoret.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.pntapps.veltoret.R
import com.pntapps.veltoret.ui.theme.VColors

/** Who makes Veltoret, shown in Settings → About and the README. */
object Developer {
    const val NAME = "PNT Apps"
    const val WEBSITE = "https://www.pntapps.com"
    const val ABOUT = "https://www.pntapps.com/about"
    const val PRIVACY = "https://www.pntapps.com/privacy"
}

/** The notice TMDB's API terms (section 3, Attribution) require, word for word. */
const val TMDB_NOTICE = "This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."

/**
 * TMDB's logo over the required notice. TMDB's terms require both, with the logo less prominent than
 * Veltoret's own name, so keep it small.
 */
@Composable
fun TmdbAttribution(
    modifier: Modifier = Modifier,
    logoHeight: Dp = 12.dp,
    style: TextStyle = MaterialTheme.typography.bodySmall,
    color: Color = VColors.TextFaint,
) {
    Column(modifier) {
        Image(
            painterResource(R.drawable.tmdb_logo),
            contentDescription = "TMDB",
            modifier = Modifier.height(logoHeight).aspectRatio(273.42f / 35.52f),
        )
        Spacer(Modifier.height(8.dp))
        Text(TMDB_NOTICE, style = style, color = color)
    }
}
