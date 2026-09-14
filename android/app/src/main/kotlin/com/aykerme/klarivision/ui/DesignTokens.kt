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
 * iOS'un iki boyut sınıfının karşılığı — cihaz adına değil kullanılabilir
 * genişliğe göre uygulanır. Swift `iPadRootView` yalnız
 * `horizontalSizeClass`'a bakar: compact'ta TabView + tam ekran çalışma
 * alanı, regular'da NavigationSplitView + grafik üstte/denetim çubuğu altta.
 * Ara bir "orta" düzen yoktur (docs/ANDROID_IOS_UI_PARITY_PLAN.md §1.1).
 * Android boyut sınıfını ham ölçüden türettiği için compact/regular sınırı
 * 700 pt olarak alınır (en küçük tam ekran iPad, 744 pt, regular'dır).
 */
enum class KvWidthClass {
    /** <700 pt — iOS compact: alt gezinme çubuğu, grafik tüm yüzeyi kaplar, denetimler yüzen kart. */
    DAR,

    /** ≥700 pt — iOS regular: kalıcı kenar çubuğu, grafik üstte, denetim çubuğu altta. */
    GENIS,
    ;

    companion object {
        fun fromWidth(widthDp: Dp): KvWidthClass =
            if (widthDp < 700.dp) DAR else GENIS

        /**
         * Genişlik VE yüksekliğe bakan sınıf. Yalnız genişliğe bakmak yatay
         * çevrilmiş bir telefonda yanlış cevap veriyordu: 2400×1080 piksel,
         * yani 853×384 dp — genişlik eşiği geçiyor ve geniş yerleşim
         * seçiliyordu, oysa geniş yerleşimde grafik ile denetim çubuğu dikey
         * yığılır. 384 dp'lik pencerede sonuç, denetimlerin ekranı kaplaması
         * ve grafiğin ~60 piksellik bir şeride sıkışmasıydı (fiziksel kabul
         * turu bulgusu B-10).
         *
         * Pencere bu yüksekliği veremiyorsa DAR'a düşülür. Bu koşul iOS'ta
         * yoktur; Android'e özgü bir güvenlik ağıdır. Tablet yatayda
         * (≥580 dp yükseklik) davranış DEĞİŞMEZ.
         */
        fun fromSize(widthDp: Dp, heightDp: Dp): KvWidthClass =
            if (heightDp < MinimumHeightForWideLayouts) DAR else fromWidth(widthDp)

        /** Geniş yerleşimin dikey olarak isteyebileceği en az yükseklik. */
        private val MinimumHeightForWideLayouts: Dp = 580.dp
    }
}

/** Geniş sınıfta kalıcı kenar çubuğu genişliği. */
val KvSidebarWidthWide: Dp = 280.dp

/** Geniş çalışma alanında dinleme medyasının iç alandaki payı (%32). */
const val KvMediaFractionWide = 0.32f

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

/** Genişlik ve yüksekliğe birlikte bakan sürüm — bkz. [KvWidthClass.fromSize]. */
@Composable
fun rememberWidthClass(maxWidth: Dp, maxHeight: Dp): KvWidthClass =
    KvWidthClass.fromSize(maxWidth, maxHeight)
