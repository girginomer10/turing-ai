package com.omergirgin.mosaic.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable

/*
 * The default Material type scale is defined in `sp`, so it already follows the system font
 * scale and the platform font (DESIGN.md: "System text styles and fonts; no fixed body-text
 * sizes"). Keeping it unmodified is deliberate.
 */
private val TuringTypography = Typography()

/**
 * Brand theme. Light/dark follow the system setting only; dynamic (wallpaper) color is not used
 * so the product keeps one recognizable accent across devices, like the iOS build.
 */
@Composable
fun TuringTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
  MaterialTheme(
    colorScheme = if (darkTheme) TuringDarkColors else TuringLightColors,
    typography = TuringTypography,
    content = content,
  )
}
