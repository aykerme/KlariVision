// KlariVision Android — uygulama teması, Swift iPadTheme'den port edildi.
// Üç tema: "focus" (çalışma odaklı, açık), "studio" (stüdyo, koyu),
// "classic" (sıcak klasik, açık) — settings/SettingsKeys.THEME_DEFAULT ile
// aynı üç anahtar. Renk yüzeyleri docs/ipad-ui-ux/05-design-tokens.md'deki
// sekiz token'dan (KvColors, DesignTokens.kt) türetilir. Bu dosya yalnız
// renk şemasını ve tipografi ölçeğini seçer; kalıcılık settings/SettingsStore'un
// işi.

package com.aykerme.klarivision.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** settings/SettingsKeys.THEME olası değerleri — buradaki adlarla birebir eşleşir. */
object KlariVisionThemeNames {
    const val FOCUS = "focus"
    const val STUDIO = "studio"
    const val CLASSIC = "classic"
}

private val FocusLight = lightColorScheme(
    primary = KvColors.AccentListening,
    secondary = KvColors.AccentPractice,
    tertiary = KvColors.StatusRecording,
    background = androidx.compose.ui.graphics.Color(0xFFF6F8FB),
    surface = androidx.compose.ui.graphics.Color(0xFFFFFFFF),
    outline = KvColors.GraphGuide,
)

private val StudioDark = darkColorScheme(
    primary = KvColors.AccentListening,
    secondary = KvColors.AccentPractice,
    tertiary = KvColors.StatusRecording,
    background = KvColors.StudioSurface,
    surface = KvColors.StudioControl,
    outline = KvColors.GraphGuide,
)

private val ClassicLight = lightColorScheme(
    primary = androidx.compose.ui.graphics.Color(0xFFB5652E),
    secondary = KvColors.AccentPractice,
    tertiary = KvColors.StatusRecording,
    background = KvColors.ClassicSurface,
    surface = KvColors.ClassicControl,
    outline = KvColors.GraphGuide,
)

/**
 * 05-design-tokens.md § Ölçü ve tipografi ölçek hiyerarşisi — SF Pro yerine
 * platform varsayılan yazı tipi kullanılır (Decision #2: "SF Pro yerine
 * platform varsayılanı kullan, ama ölçü hiyerarşisini koru"), ama puan
 * boyutları birebir aynı: büyük başlık 34, başlık 28, bölüm 20, gövde 17,
 * yardımcı 13 sp.
 */
private val KvTypography = Typography(
    displaySmall = TextStyle(fontSize = 34.sp, lineHeight = 41.sp, fontWeight = FontWeight.Bold),
    headlineLarge = TextStyle(fontSize = 34.sp, lineHeight = 41.sp, fontWeight = FontWeight.Bold),
    headlineMedium = TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.Bold),
    titleLarge = TextStyle(fontSize = 20.sp, lineHeight = 25.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = TextStyle(fontSize = 20.sp, lineHeight = 25.sp, fontWeight = FontWeight.SemiBold),
    bodyLarge = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.Normal),
    bodyMedium = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.Normal),
    labelMedium = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
    bodySmall = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
    labelSmall = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
)

/**
 * Seçili tema adına göre renk şemasını ve tipografi ölçeğini uygular.
 * Bilinmeyen bir ad "focus"a düşer (settings/SettingsValidation.validateTheme
 * ile aynı ruh).
 */
@Composable
fun KlariVisionTheme(themeName: String, content: @Composable () -> Unit) {
    val scheme = when (themeName) {
        KlariVisionThemeNames.STUDIO -> StudioDark
        KlariVisionThemeNames.CLASSIC -> ClassicLight
        else -> FocusLight
    }
    MaterialTheme(colorScheme = scheme, typography = KvTypography, content = content)
}
