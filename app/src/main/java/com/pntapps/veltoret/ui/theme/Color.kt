package com.pntapps.veltoret.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Veltoret palette. Depth comes from layered flat surfaces and hairline outlines —
 * the design language intentionally never uses gradients.
 */
object VColors {
    val Background = Color(0xFF0B0B0D)
    val BackgroundOled = Color(0xFF000000)
    val Surface = Color(0xFF15151A)
    val SurfaceHigh = Color(0xFF1E1E25)
    val SurfaceHighest = Color(0xFF26262F)
    val Outline = Color(0xFF2C2C35)
    val OutlineStrong = Color(0xFF3B3B46)

    val Text = Color(0xFFF3EFE6)
    val TextMuted = Color(0xFF9C9AA3)
    val TextFaint = Color(0xFF6B6973)

    val Amber = Color(0xFFE8A33D)
    val AmberSoft = Color(0xFFF3C77F)
    val AmberDim = Color(0xFF3A2B14)
    val OnAmber = Color(0xFF1B1206)

    val Danger = Color(0xFFFF6B5E)
    val Success = Color(0xFF6FCF97)

    /** Flat (single-tone) dim used when anything must sit on top of imagery. */
    val ImageDim = Color(0x99000000)
    val PlayerChrome = Color(0x8C000000)
}
