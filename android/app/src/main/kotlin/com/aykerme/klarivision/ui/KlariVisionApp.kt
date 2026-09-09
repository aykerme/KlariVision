// KlariVision Android — evrensel Compose kabuğu, Swift KlariVisioniPadApp.swift'ten
// port edildi. Bilgi mimarisi docs/ipad-ui-ux/01-information-architecture.md ile
// birebir: üç kök bölüm (Ana Sayfa, Çalışmalar, Ayarlar); Dinleme ve Çalma kök
// sekme DEĞİLDİR, Ana Sayfa'dan (Çalma) ve Çalışmalar'dan (Dinleme) girilen
// çalışma alanlarıdır (bkz. HomeScreen.kt, LibraryScreen.kt).
//
// Genişlik sınıfı `BoxWithConstraints` ile ölçülen ham genişlikten türetilir
// (KvWidthClass.fromWidth — 700/1000 pt eşikleri, Material3'ün kendi
// Compact/Medium/Expanded eşikleri değil): GENIS'te 280 pt kalıcı kenar
// çubuğu, ORTA'da 320 pt drawer, DAR'da modal gezinme (bottom bar, çalışma
// alanı açıkken gizlenir).
//
// Grafik WebView'leri (`web/LiveGraphBridge`/`StudyGraphBridge`) burada bir kez
// `remember`lenip `movableContentOf` ile sarılır ki genişlik/yön değişiminde
// (dar ↔ orta ↔ geniş) aynı WebView örneği yalnız yeni kapsayıcıya taşınsın —
// asla yeniden yaratılmasın (aksi halde grafik durumu sıfırlanır, bu iOS
// tarafında zaten bilinçle çözülmüş bir sorun, bkz. iPadLiveWebViewStore/
// iPadStudyWebViewStore "stable identity" yorumları).

package com.aykerme.klarivision.ui

import androidx.compose.foundation.background
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.DisposableEffect
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
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
@OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
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

    // Grafik sayfaları kenardan kenara çizilir; sistem çubuğu boşluklarını
    // Compose ölçer ve köprüler üzerinden sayfaya bildirir. View seviyesindeki
    // inset dinleyicisi Compose barındırıcısında güvenilir ateşlenmiyor,
    // bu yüzden değer buradan AÇIKÇA veriliyor.
    val safeInsets = WindowInsets.safeDrawing.asPaddingValues()
    val safeTop = safeInsets.calculateTopPadding()
    val safeBottom = safeInsets.calculateBottomPadding()
    LaunchedEffect(safeTop, safeBottom) {
        liveGraphBridge.setSafeAreaInsets(safeTop.value, safeBottom.value)
        studyGraphBridge.setSafeAreaInsets(safeTop.value, safeBottom.value)
    }

    val liveUiState by liveOrchestrator.uiState.collectAsState()

    // Not `rememberSaveable`: Destination bir Bundle-uyumlu türe otomatik
    // dönüşmez; süreç ölümünde varsayılan Ana Sayfa'ya dönmek kabul edilebilir
    // (P5a kapsamı — kalıcı gezinme durumu `state/` katmanının işi değil, salt
    // UI kabuğunun geçici seçimi).
    var destination by remember { mutableStateOf(Destination.HOME) }

    // WebView'lerin kalıcı sarmalayıcıları — bir kez oluşturulur, genişlik
    // sınıfı ya da rota değişse de (dar bottom-bar ↔ orta drawer ↔ geniş
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
    val studyGraphContent = remember {
        movableContentOf {
            AndroidView(
                factory = { studyGraphBridge.webView.also { studyGraphBridge.load() } },
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
                onOpenMakamIntervals = { /* Ayarlar sayfası kendi içinde makam satırlarını gösterir. */ },
                modifier = contentModifier,
            )
        }
    }

    KlariVisionTheme(themeName = themeName) {
        Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val widthClass = rememberWidthClass(maxWidth)
                when (widthClass) {
                    KvWidthClass.GENIS -> Row(modifier = Modifier.fillMaxSize()) {
                        PermanentSidebar(destination = destination, onSelect = { destination = it })
                        content(Modifier.weight(1f).fillMaxSize(), widthClass)
                    }
                    KvWidthClass.ORTA -> Row(modifier = Modifier.fillMaxSize()) {
                        if (!workspaceActive) {
                            NavigationDrawerPanel(destination = destination, onSelect = { destination = it })
                        }
                        content(Modifier.weight(1f).fillMaxSize(), widthClass)
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

/** Geniş sınıf (≥1000 pt): 280 pt kalıcı kenar çubuğu, her zaman görünür. */
@Composable
private fun PermanentSidebar(destination: Destination, onSelect: (Destination) -> Unit) {
    Column(
        modifier = Modifier
            .width(KvSidebarWidthWide)
            .fillMaxHeight()
            .background(MaterialTheme.colorScheme.surface),
    ) {
        SidebarHeader()
        HorizontalDivider()
        Destination.values().forEach { dest ->
            NavigationRailItem(
                selected = destination == dest,
                onClick = { onSelect(dest) },
                icon = { NavGlyph(dest) },
                label = { Text(dest.title) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** Orta sınıf (700–999 pt): 320 pt drawer, çalışma alanı etkin değilken görünür. */
@Composable
private fun NavigationDrawerPanel(destination: Destination, onSelect: (Destination) -> Unit) {
    Column(
        modifier = Modifier
            .width(KvDrawerWidthMedium)
            .fillMaxHeight()
            .background(MaterialTheme.colorScheme.surface),
    ) {
        SidebarHeader()
        HorizontalDivider()
        Destination.values().forEach { dest ->
            NavigationRailItem(
                selected = destination == dest,
                onClick = { onSelect(dest) },
                icon = { NavGlyph(dest) },
                label = { Text(dest.title) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun SidebarHeader() {
    Row(
        modifier = Modifier.fillMaxWidth().padding(KvSpacing.lg),
    ) {
        Icon(KvIcons.AppMark, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Spacer(modifier = Modifier.width(KvSpacing.sm))
        Text("KlariVision", style = MaterialTheme.typography.titleLarge)
    }
    Spacer(modifier = Modifier.height(KvSpacing.xs))
}

/**
 * Gezinme simgesi — docs/ipad-ui-ux/assets/ipad-ui-symbol-map.md eşlemesi
 * (KvIcons). Emoji kullanılmaz; her ikon `contentDescription` taşır.
 */
@Composable
private fun NavGlyph(destination: Destination) {
    val icon = when (destination) {
        Destination.HOME -> KvIcons.Home
        Destination.LIBRARY -> KvIcons.Studies
        Destination.SETTINGS -> KvIcons.Settings
    }
    Icon(icon, contentDescription = destination.title)
}
