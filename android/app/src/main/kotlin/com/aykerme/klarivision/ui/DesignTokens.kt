// KlariVision Android — görsel tokenlar, docs/ipad-ui-ux/05-design-tokens.md ve
// 03-responsive-contract.md'den birebir taşındı. Renk, boşluk, köşe, dokunma
// hedefi ve genişlik sınıfı sabitleri burada tek yerde toplanır ki iPad ile
// Android aynı sayısal sözleşmeyi paylaşsın.

package com.aykerme.klarivision.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** 05-design-tokens.md § Renk — sekiz token, iPad ile birebir aynı hex değerler. */
object KvColors {
    val AccentListening = Color(0xFF0A84FF)
    val AccentPractice = Color(0xFF34C759)
    val StatusRecording = Color(0xFFFF453A)
    val GraphGuide = Color(0xFF8E8E93)
    val StudioSurface = Color(0xFF181E25)
    val StudioControl = Color(0xFF27303A)
    val ClassicSurface = Color(0xFFFAF4EA)
    val ClassicControl = Color(0xFFFFFAF1)
}

/** 05-design-tokens.md § Ölçü ve tipografi — boşluk 4/8/12/16/20/24/32 pt. */
object KvSpacing {
    val xs: Dp = 4.dp
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val xl: Dp = 20.dp
    val xxl: Dp = 24.dp
    val xxxl: Dp = 32.dp
}

/** Köşe: denetim 12, panel 16, mod kartı 20 pt. */
object KvRadius {
    val control: Dp = 12.dp
    val panel: Dp = 16.dp
    val modeCard: Dp = 20.dp
}

/** Dokunma hedefi: en az 44×44 pt. */
val KvMinTouchTarget: Dp = 44.dp

/**
 * 02-screen-frame-matrix.md ve 03-responsive-contract.md'deki üç genişlik
 * sınıfı — cihaz adına değil kullanılabilir genişliğe göre uygulanır.
 * Material3'ün kendi Compact/Medium/Expanded eşikleri (600/840dp) yerine
 * spesifikasyonun kendi eşikleri (700/1000pt) kullanılır.
 */
enum class KvWidthClass {
    /** <700 pt: tek sütun, modal gezinme, grafik tüm yüzeyi kaplar. */
    DAR,

    /** 700–999 pt: 320 pt drawer, medya üstte 220–360 pt. */
    ORTA,

    /** ≥1000 pt: 280 pt kalıcı kenar çubuğu, medya %32 / grafik kalan, 16 pt aralık. */
    GENIS,
    ;

    companion object {
        fun fromWidth(widthDp: Dp): KvWidthClass = when {
            widthDp < 700.dp -> DAR
            widthDp < 1000.dp -> ORTA
            else -> GENIS
        }
    }
}

/** Geniş sınıfta kalıcı kenar çubuğu genişliği. */
val KvSidebarWidthWide: Dp = 280.dp

/** Orta sınıfta gezinme drawer genişliği. */
val KvDrawerWidthMedium: Dp = 320.dp

/** Geniş çalışma alanında dinleme medyasının iç alandaki payı (%32). */
const val KvMediaFractionWide = 0.32f

/** Orta sınıfta dinleme medyası yüksekliği aralığı. */
val KvMediaHeightMediumMin: Dp = 220.dp
val KvMediaHeightMediumMax: Dp = 360.dp

/** Hiçbir sınıfta grafiğin bu değerin altına düşmemesi gerekir. */
val KvGraphMinHeight: Dp = 360.dp

/** Dar sınıfta medya yüksekliği. */
val KvMediaHeightNarrow: Dp = 220.dp

/**
 * Yardımcı: `BoxWithConstraints` içinden çağrılıp mevcut genişliğe göre
 * [KvWidthClass] türetmek için kullanılır. Ayrı bir composable olmasının
 * sebebi çağrı yerlerinde tekrar tekrar aynı eşik mantığını yazmamak.
 */
@Composable
fun rememberWidthClass(maxWidth: Dp): KvWidthClass = KvWidthClass.fromWidth(maxWidth)
