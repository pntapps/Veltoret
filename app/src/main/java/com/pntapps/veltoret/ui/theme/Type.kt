package com.pntapps.veltoret.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.pntapps.veltoret.R

@OptIn(ExperimentalTextApi::class)
private fun fraunces(weight: Int) = Font(
    resId = R.font.fraunces,
    weight = FontWeight(weight),
    variationSettings = FontVariation.Settings(
        FontVariation.weight(weight),
        FontVariation.Setting("opsz", 72f),
        FontVariation.Setting("SOFT", 50f),
    ),
)

@OptIn(ExperimentalTextApi::class)
private fun inter(weight: Int) = Font(
    resId = R.font.inter,
    weight = FontWeight(weight),
    variationSettings = FontVariation.Settings(FontVariation.weight(weight)),
)

/** Editorial serif for titles. */
val SerifFamily = FontFamily(fraunces(400), fraunces(500), fraunces(600), fraunces(700))

/** Neutral sans for everything else. */
val SansFamily = FontFamily(inter(400), inter(500), inter(600), inter(700))

private fun serif(size: Int, weight: Int, line: Int, spacing: Double = -0.01) = TextStyle(
    fontFamily = SerifFamily,
    fontWeight = FontWeight(weight),
    fontSize = size.sp,
    lineHeight = line.sp,
    letterSpacing = spacing.em,
)

private fun sans(size: Int, weight: Int, line: Int, spacing: Double = 0.0) = TextStyle(
    fontFamily = SansFamily,
    fontWeight = FontWeight(weight),
    fontSize = size.sp,
    lineHeight = line.sp,
    letterSpacing = spacing.em,
)

val VeltoretTypography = Typography(
    displayLarge = serif(48, 600, 54, -0.02),
    displayMedium = serif(38, 600, 44, -0.02),
    displaySmall = serif(30, 600, 36, -0.015),
    headlineLarge = serif(28, 600, 34),
    headlineMedium = serif(24, 600, 30),
    headlineSmall = serif(20, 600, 26),
    titleLarge = sans(19, 600, 26),
    titleMedium = sans(16, 600, 22),
    titleSmall = sans(14, 600, 20),
    bodyLarge = sans(16, 400, 24),
    bodyMedium = sans(14, 400, 21),
    bodySmall = sans(12, 400, 17),
    labelLarge = sans(14, 600, 20, 0.01),
    labelMedium = sans(12, 600, 16, 0.02),
    labelSmall = sans(11, 600, 14, 0.06),
)
