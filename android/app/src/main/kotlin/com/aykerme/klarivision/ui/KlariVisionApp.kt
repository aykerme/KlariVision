// KlariVision Android — evrensel Compose kabuğu, Swift KlariVisioniPadApp.swift'ten
// port edildi. Bilgi mimarisi docs/ipad-ui-ux/01-information-architecture.md ile
// birebir: üç kök bölüm (Ana Sayfa, Çalışmalar, Ayarlar); Dinleme ve Çalma kök
// sekme DEĞİLDİR, Ana Sayfa'dan (Çalma) ve Çalışmalar'dan (Dinleme) girilen
// çalışma alanlarıdır (bkz. HomeScreen.kt, LibraryScreen.kt).
//
// Genişlik sınıfı `BoxWithConstraints` ile ölçülen ham genişlikten türetilir
// (KvWidthClass.fromSize — tek 700 pt eşiği, Material3'ün kendi
// Compact/Medium/Expanded eşikleri değil). Swift gibi yalnız iki düzen var:
// GENIS'te 280 pt kalıcı kenar çubuğu (regular → NavigationSplitView), DAR'da
// alt gezinme çubuğu (compact → TabView; çalışma alanı açıkken gizlenir).
//
// Grafik WebView'leri (`web/LiveGraphBridge`/`StudyGraphBridge`) burada bir kez
// `remember`lenip `movableContentOf` ile sarılır ki genişlik/yön değişiminde
// (dar ↔ geniş) aynı WebView örneği yalnız yeni kapsayıcıya taşınsın —
// asla yeniden yaratılmasın (aksi halde grafik durumu sıfırlanır, bu iOS
// tarafında zaten bilinçle çözülmüş bir sorun, bkz. iPadLiveWebViewStore/
// iPadStudyWebViewStore "stable identity" yorumları).

package com.aykerme.klarivision.ui

import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Color
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.DisposableEffect
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.runtime.LaunchedEffect
import java.io.File
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.aykerme.klarivision.music.Makam
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.settings.SettingsStore
import com.aykerme.klarivision.state.LiveOrchestrator
import com.aykerme.klarivision.state.LivePhase2
import com.aykerme.klarivision.state.StudyOrchestrator
import com.aykerme.klarivision.state.StudyPhase
import com.aykerme.klarivision.study.Study
import com.aykerme.klarivision.together.TogetherOrchestrator
import com.aykerme.klarivision.web.LiveGraphBridge
import com.aykerme.klarivision.web.StudyGraphBridge

/** Kök bölümlerin üç sabit hedefi — docs/ipad-ui-ux/01-information-architecture.md § Birincil yapı. */
enum class Destination(val title: String) {
    HOME("Ana Sayfa"),
    LIBRARY("Çalışmalar"),
    SETTINGS("Ayarlar"),
}

/**
 * Uygulamanın evrensel kökü. `widthSizeClass` parametresi geriye dönük
 * uyumluluk için tutulur ama artık genişlik sınıfı kararını vermez —
 * gerçek genişlik `BoxWithConstraints` ile bu composable içinde ölçülür
 * (bkz. dosya başlığı).
 */
@OptIn(ExperimentalMaterial3WindowSizeClassApi::class, ExperimentalMaterial3Api::class)
@Composable
fun KlariVisionApp(
    widthSizeClass: WindowWidthSizeClass,
    studyOrchestrator: StudyOrchestrator,
    liveOrchestrator: LiveOrchestrator,
    togetherOrchestrator: TogetherOrchestrator,
    settingsStore: SettingsStore,
    intervalsStore: MakamIntervalsStore,
    liveGraphBridge: LiveGraphBridge,
    studyGraphBridge: StudyGraphBridge,
    onRequestImport: () -> Unit,
    modifier: Modifier = Modifier,
    onRequestMicPermission: () -> Unit = {},
) {
    val themeName by settingsStore.theme().collectAsState(initial = KlariVisionThemeNames.FOCUS)
    val studyUiState by studyOrchestrator.uiState.collectAsState()

    val safeInsets = WindowInsets.safeDrawing.asPaddingValues()
    val safeTop = safeInsets.calculateTopPadding()
    val safeBottom = safeInsets.calculateBottomPadding()

    val liveUiState by liveOrchestrator.uiState.collectAsState()

    // Not `rememberSaveable`: Destination bir Bundle-uyumlu türe otomatik
    // dönüşmez; süreç ölümünde varsayılan Ana Sayfa'ya dönmek kabul edilebilir
    // (P5a kapsamı — kalıcı gezinme durumu `state/` katmanının işi değil, salt
    // UI kabuğunun geçici seçimi).
    var destination by remember { mutableStateOf(Destination.HOME) }
    var settingsEditingMakam by remember { mutableStateOf<Makam?>(null) }

    // WebView'lerin kalıcı sarmalayıcıları — bir kez oluşturulur, genişlik
    // sınıfı ya da rota değişse de (dar bottom-bar ↔ geniş
    // sidebar) AndroidView `factory` yeniden çağrılmaz; içerik yalnız yeni
    // konumuna taşınır (bkz. dosya başlığı).
    val liveGraphContent = remember {
        movableContentOf {
            AndroidView(
                factory = { liveGraphBridge.webView.also { liveGraphBridge.load() } },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
    // Dinleme köprüsünde fabrika `load()` ÇAĞIRMAZ — canlı köprüden farkı
    // budur ve kasıtlıdır. Sayfanın yaşam döngüsü `StudyOrchestrator`'a
    // aittir: `openStudy` → `defaultViewerLoad` önce `bridge.load()` çağırır,
    // HEMEN ARDINDAN `load`/`context` komutlarını kuyruğa koyar.
    //
    // Fabrika da `load()` çağırınca ikinci bir `loadUrl` başlıyordu ve ortaya
    // bir yarış çıkıyordu: birinci sayfa önce bitip kuyruğu boşaltırsa,
    // ikinci `loadUrl` o sayfayı (medya elemanı ve kareleriyle birlikte) yok
    // ediyor, yeni sayfaya ise boş kuyruk akıyordu. Sonuç, hiçbir zaman
    // kendine gelmeyen bir oynatıcıydı: süre 0:00, konum ilerlemiyor, sayfada
    // medya elemanı bile yok (kabul turu bulgusu B-2b). Çalışma kapatılıp
    // yeniden açıldığında WebView sıcak olduğu için birinci sayfa hızlı
    // bitiyor ve yarış çoğunlukla bu tarafa düşüyordu.
    //
    // Canlı köprüde (`liveGraphBridge`) tek çağıran fabrikadır, orada
    // `load()` yerinde kalır.
    val studyGraphContent = remember {
        movableContentOf {
            AndroidView(
                factory = { studyGraphBridge.webView },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }

    // Bir çalışma alanı (Çalma ya da Dinleme) etkinken dar sınıfta gezinme
    // tam ekran gözden kaybolur — 03-responsive-contract.md § Dar ekran.
    val liveActive = liveUiState.phase == LivePhase2.RUNNING || liveUiState.phase == LivePhase2.STARTING
    val studyActive = studyUiState.phase != StudyPhase.IDLE
    val workspaceActive = (destination == Destination.HOME && liveActive) || (destination == Destination.LIBRARY && studyActive)

    val content: @Composable (Modifier, KvWidthClass) -> Unit = { contentModifier, widthClass ->
        when (destination) {
            Destination.HOME -> HomeScreen(
                widthClass = widthClass,
                liveOrchestrator = liveOrchestrator,
                settingsStore = settingsStore,
                intervalsStore = intervalsStore,
                liveGraphContent = liveGraphContent,
                onOpenLibraryImport = { destination = Destination.LIBRARY; onRequestImport() },
                onStartLive = { liveOrchestrator.start() },
                modifier = contentModifier,
                // Swift `addCompletedRecordingToStudies` ile aynı sıra:
                // önce canlıyı durdur (mikrofon açıkken analiz başlatmak
                // hem CPU'yu hem ses odağını çakıştırır), sonra kütüphaneye
                // geç, sonra al ve analiz et.
                onAddRecordingToStudies = { path ->
                    liveOrchestrator.stop()
                    destination = Destination.LIBRARY
                    studyOrchestrator.importRecordedAndAnalyze(File(path))
                },
                isRecordingImported = { path -> studyOrchestrator.hasImportedRecording(File(path)) },
                isImporting = studyUiState.phase == StudyPhase.IMPORTING ||
                    studyUiState.phase == StudyPhase.ANALYZING,
            )
            Destination.LIBRARY -> LibraryScreen(
                studies = studyUiState.studies,
                orchestrator = studyOrchestrator,
                intervalsStore = intervalsStore,
                togetherOrchestrator = togetherOrchestrator,
                studyGraphContent = studyGraphContent,
                onOpen = { study: Study -> studyOrchestrator.openStudy(study.id) },
                onRemove = { study: Study -> studyOrchestrator.removeStudy(study.id) },
                widthClass = widthClass,
                modifier = contentModifier,
                onRequestMicPermission = onRequestMicPermission,
            )
            Destination.SETTINGS -> SettingsScreen(
                settingsStore = settingsStore,
                intervalsStore = intervalsStore,
                togetherOrchestrator = togetherOrchestrator,
                onOpenMakamIntervals = { settingsEditingMakam = it },
                modifier = contentModifier,
            )
        }
    }

    KlariVisionTheme(themeName = themeName) {
        // Swift'te Ayarlar'daki makam satırı `NavigationLink` ile
        // `iPadMakamIntervalsView`'a gider; burada çalışma alanlarındaki gibi
        // aynı düzenleyici bir alt sayfada açılır.
        settingsEditingMakam?.let { editingMakam ->
            ModalBottomSheet(onDismissRequest = { settingsEditingMakam = null }) {
                MakamIntervalsScreen(makam = editingMakam, store = intervalsStore)
            }
        }

        Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val widthClass = rememberWidthClass(maxWidth, maxHeight)

                // Dar düzende grafik sayfaları kenardan kenara çizilir; sistem
                // çubuğu boşluklarını Compose ölçer ve köprüler üzerinden
                // sayfaya bildirir. View seviyesindeki inset dinleyicisi Compose
                // barındırıcısında güvenilir ateşlenmiyor, bu yüzden değer
                // buradan AÇIKÇA veriliyor. Geniş düzende içerik zaten güvenli
                // alanın içinde durduğu için sayfaya 0 gider; yoksa boşluk iki
                // kez uygulanır.
                val graphInsetTop = if (widthClass == KvWidthClass.GENIS) 0f else safeTop.value
                val graphInsetBottom = if (widthClass == KvWidthClass.GENIS) 0f else safeBottom.value
                LaunchedEffect(graphInsetTop, graphInsetBottom) {
                    liveGraphBridge.setSafeAreaInsets(graphInsetTop, graphInsetBottom)
                    studyGraphBridge.setSafeAreaInsets(graphInsetTop, graphInsetBottom)
                }

                when (widthClass) {
                    // Swift regular düzeni gibi içerik sistem çubuklarının
                    // İÇİNDE kalır. Kenar çubuğunun zemini çubukların altına
                    // uzanır, satırları uzanmaz. Cihazda (yoğunluk 200,
                    // 864×1920 dp) alt denetim çubuğu gezinme çubuğunun
                    // altında kalıyordu.
                    KvWidthClass.GENIS -> Row(modifier = Modifier.fillMaxSize()) {
                        PermanentSidebar(destination = destination, onSelect = { destination = it })
                        content(
                            Modifier
                                .weight(1f)
                                .fillMaxSize()
                                .windowInsetsPadding(
                                    WindowInsets.safeDrawing.only(
                                        WindowInsetsSides.Top + WindowInsetsSides.Bottom + WindowInsetsSides.End,
                                    ),
                                ),
                            widthClass,
                        )
                    }
                    KvWidthClass.DAR -> if (workspaceActive) {
                        // Modal: gezinme çubuğu tamamen gizlenir, grafik tüm yüzeyi kaplar.
                        content(Modifier.fillMaxSize(), widthClass)
                    } else {
                        Column(modifier = Modifier.fillMaxSize()) {
                            content(Modifier.weight(1f).fillMaxWidth(), widthClass)
                            NavigationBar {
                                Destination.values().forEach { dest ->
                                    NavigationBarItem(
                                        selected = destination == dest,
                                        onClick = { destination = dest },
                                        icon = { NavGlyph(dest) },
                                        label = { Text(dest.title) },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Geniş sınıf (≥700 pt): 280 pt kalıcı kenar çubuğu, çalışma alanı açıkken
 * de görünür — Swift regular düzenindeki NavigationSplitView kenar çubuğu:
 * büyük "KlariVision" başlığı, "GEZİNME" bölümü ve ikon + etiketi yan yana
 * duran satırlar. Seçili satır vurgu renginde yazılır, zemini %12 vurgu tonudur.
 */
@Composable
private fun PermanentSidebar(destination: Destination, onSelect: (Destination) -> Unit) {
    Column(
        modifier = Modifier
            .width(KvSidebarWidthWide)
            .fillMaxHeight()
            .background(MaterialTheme.colorScheme.surface)
            .windowInsetsPadding(
                WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Bottom + WindowInsetsSides.Start),
            )
            .padding(horizontal = KvSpacing.md),
        verticalArrangement = Arrangement.spacedBy(KvSpacing.xs),
    ) {
        Text(
            "KlariVision",
            style = MaterialTheme.typography.headlineLarge,
            modifier = Modifier.padding(start = KvSpacing.md, top = KvSpacing.lg, bottom = KvSpacing.lg),
        )
        Text(
            "GEZİNME",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = KvSpacing.md, bottom = KvSpacing.xs),
        )
        Destination.values().forEach { dest ->
            val selected = destination == dest
            val accent = MaterialTheme.colorScheme.primary
            NavigationDrawerItem(
                selected = selected,
                onClick = { onSelect(dest) },
                icon = { Icon(navIcon(dest), contentDescription = null) },
                label = { Text(dest.title) },
                shape = RoundedCornerShape(KvRadius.control),
                colors = NavigationDrawerItemDefaults.colors(
                    selectedContainerColor = accent.copy(alpha = 0.12f),
                    unselectedContainerColor = Color.Transparent,
                    selectedIconColor = accent,
                    selectedTextColor = accent,
                ),
            )
        }
    }
}

/**
 * Gezinme simgesi — docs/ipad-ui-ux/assets/ipad-ui-symbol-map.md eşlemesi
 * (KvIcons). Emoji kullanılmaz; her ikon `contentDescription` taşır.
 */
@Composable
private fun NavGlyph(destination: Destination) {
    Icon(navIcon(destination), contentDescription = destination.title)
}

private fun navIcon(destination: Destination) =
    when (destination) {
        Destination.HOME -> KvIcons.Home
        Destination.LIBRARY -> KvIcons.Studies
        Destination.SETTINGS -> KvIcons.Settings
    }
