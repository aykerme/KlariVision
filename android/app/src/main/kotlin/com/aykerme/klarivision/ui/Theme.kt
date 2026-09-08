// KlariVision Android — uygulama teması, Swift iPadTheme'den port edildi.
// Üç tema: "focus" (çalışma odaklı, açık), "studio" (stüdyo, koyu),
// "classic" (sıcak klasik, açık) — settings/SettingsKeys.THEME_DEFAULT ile
// aynı üç anahtar. Bu dosya yalnız renk şemasını seçer; kalıcılık
// settings/SettingsStore'un işi.

package com.aykerme.klarivision.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** settings/SettingsKeys.THEME olası değerleri — buradaki adlarla birebir eşleşir. */
object KlariVisionThemeNames {
    const val FOCUS = "focus"
    const val STUDIO = "studio"
    const val CLASSIC = "classic"
}

private val FocusLight = lightColorScheme(
    primary = Color(0xFF2F7DE1),
    secondary = Color(0xFF67D5FF),
    tertiary = Color(0xFFE75A5A),
    background = Color(0xFFF6F8FB),
    surface = Color(0xFFFFFFFF),
)

private val StudioDark = darkColorScheme(
    primary = Color(0xFF67D5FF),
    secondary = Color(0xFFB7D8FF),
    tertiary = Color(0xFFE75A5A),
    background = Color(0xFF101418),
    surface = Color(0xFF181D22),
)

private val ClassicLight = lightColorScheme(
    primary = Color(0xFFB5652E),
    secondary = Color(0xFFD9A566),
    tertiary = Color(0xFFE75A5A),
    background = Color(0xFFFBF3E8),
    surface = Color(0xFFFFF8EE),
)

/**
 * Seçili tema adına göre renk şemasını uygular. Bilinmeyen bir ad "focus"a
 * düşer (settings/SettingsValidation.validateTheme ile aynı ruh).
 */
@Composable
fun KlariVisionTheme(themeName: String, content: @Composable () -> Unit) {
    val scheme = when (themeName) {
        KlariVisionThemeNames.STUDIO -> StudioDark
        KlariVisionThemeNames.CLASSIC -> ClassicLight
        else -> FocusLight
    }
    MaterialTheme(colorScheme = scheme, content = content)
}
