// KlariVision Android — evrensel Compose kabuğu, Swift KlariVisioniPadApp.swift'ten
// port edildi. Compact genişlikte alt gezinme (TabView eşdeğeri), Medium/Expanded
// genişlikte kalıcı yan panel (NavigationSplitView eşdeğeri) kurar. Grafik
// WebView'leri (`web/LiveGraphBridge`/`StudyGraphBridge`) burada bir kez
// `remember`lenip `movableContentOf` ile sarılır ki genişlik/yön değişiminde
// (compact ↔ medium/expanded) aynı WebView örneği yalnız yeni kapsayıcıya
// taşınsın — asla yeniden yaratılmasın (aksi halde grafik durumu sıfırlanır,
// bu iOS tarafında zaten bilinçle çözülmüş bir sorun, bkz. iPadLiveWebViewStore/
// iPadStudyWebViewStore "stable identity" yorumları).

package com.aykerme.klarivision.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.viewinterop.AndroidView
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.settings.SettingsStore
import com.aykerme.klarivision.state.LiveOrchestrator
import com.aykerme.klarivision.state.StudyOrchestrator
import com.aykerme.klarivision.study.Study
import com.aykerme.klarivision.web.LiveGraphBridge
import com.aykerme.klarivision.web.StudyGraphBridge

/** Alt gezinme / yan panelin beş sabit hedefi. */
enum class Destination(val title: String) {
    HOME("Ana Sayfa"),
    LIBRARY("Kütüphane"),
    LIVE("Çalma"),
    STUDY("Dinleme"),
    SETTINGS("Ayarlar"),
}

/**
 * Uygulamanın evrensel kökü. `widthSizeClass`, `MainActivity`'de
 * `calculateWindowSizeClass(activity)` ile hesaplanıp buraya taşınır.
 */
@OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
@Composable
fun KlariVisionApp(
    widthSizeClass: WindowWidthSizeClass,
    studyOrchestrator: StudyOrchestrator,
    liveOrchestrator: LiveOrchestrator,
    settingsStore: SettingsStore,
    intervalsStore: MakamIntervalsStore,
    liveGraphBridge: LiveGraphBridge,
    studyGraphBridge: StudyGraphBridge,
    onRequestImport: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val themeName by settingsStore.theme().collectAsState(initial = KlariVisionThemeNames.FOCUS)
    val studyUiState by studyOrchestrator.uiState.collectAsState()

    // Not `rememberSaveable`: Destination bir Bundle-uyumlu türe otomatik
    // dönüşmez; süreç ölümünde varsayılan Ana Sayfa'ya dönmek kabul edilebilir
    // (P5a kapsamı — kalıcı gezinme durumu `state/` katmanının işi değil, salt
    // UI kabuğunun geçici seçimi).
    var destination by remember { mutableStateOf(Destination.HOME) }
    val isWide = widthSizeClass != WindowWidthSizeClass.Compact

    // WebView'lerin kalıcı sarmalayıcıları — bir kez oluşturulur, genişlik
    // sınıfı ya da rota değişse de (compact bottom-bar ↔ geniş yan panel)
    // AndroidView `factory` yeniden çağrılmaz; içerik yalnız yeni konumuna
    // taşınır (bkz. dosya başlığı).
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

    val content: @Composable (Modifier) -> Unit = { contentModifier ->
        when (destination) {
            Destination.HOME -> HomeScreen(
                isWide = isWide,
                onOpenLibraryImport = { destination = Destination.LIBRARY; onRequestImport() },
                onStartLive = { destination = Destination.LIVE; liveOrchestrator.start() },
                modifier = contentModifier,
            )
            Destination.LIBRARY -> LibraryScreen(
                studies = studyUiState.studies,
                onOpen = { study: Study -> studyOrchestrator.openStudy(study.id); destination = Destination.STUDY },
                onRemove = { study: Study -> studyOrchestrator.removeStudy(study.id) },
                modifier = contentModifier,
            )
            Destination.LIVE -> LiveWorkspace(
                orchestrator = liveOrchestrator,
                settingsStore = settingsStore,
                intervalsStore = intervalsStore,
                graphContent = liveGraphContent,
                isWide = isWide,
                modifier = contentModifier,
            )
            Destination.STUDY -> StudyWorkspace(
                orchestrator = studyOrchestrator,
                intervalsStore = intervalsStore,
                graphContent = studyGraphContent,
                isWide = isWide,
                modifier = contentModifier,
            )
            Destination.SETTINGS -> SettingsScreen(
                settingsStore = settingsStore,
                intervalsStore = intervalsStore,
                onOpenMakamIntervals = { /* Ayarlar sayfası kendi içinde makam satırlarını gösterir. */ },
                modifier = contentModifier,
            )
        }
    }

    KlariVisionTheme(themeName = themeName) {
        Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            if (isWide) {
                Row(modifier = Modifier.fillMaxSize()) {
                    NavigationRail {
                        Destination.values().forEach { dest ->
                            NavigationRailItem(
                                selected = destination == dest,
                                onClick = { destination = dest },
                                icon = { NavGlyph(dest) },
                                label = { Text(dest.title) },
                            )
                        }
                    }
                    content(Modifier.weight(1f).fillMaxSize())
                }
            } else {
                Scaffold(
                    bottomBar = {
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
                    },
                ) { padding ->
                    content(Modifier.padding(padding).fillMaxSize())
                }
            }
        }
    }
}

/**
 * Gezinme simgesi. `androidx.compose.material.icons.filled` yalnız çekirdek
 * simge kümesini taşır (Kütüphane/Çalma/Dinleme için karşılık yok); Ana
 * Sayfa ve Ayarlar gerçek `Icon`, diğerleri anlamlı bir Unicode glifi kullanır
 * — ikisi de `contentDescription` ile VoiceOver/TalkBack adını taşır.
 */
@Composable
private fun NavGlyph(destination: Destination) {
    when (destination) {
        Destination.HOME -> androidx.compose.material3.Icon(Icons.Filled.Home, contentDescription = destination.title)
        Destination.SETTINGS -> androidx.compose.material3.Icon(Icons.Filled.Settings, contentDescription = destination.title)
        Destination.LIBRARY -> Text("📚", modifier = Modifier.semanticsLabel(destination.title))
        Destination.LIVE -> Text("🎙", modifier = Modifier.semanticsLabel(destination.title))
        Destination.STUDY -> Text("🎧", modifier = Modifier.semanticsLabel(destination.title))
    }
}

private fun Modifier.semanticsLabel(label: String): Modifier =
    this.then(Modifier.semantics { contentDescription = label })
