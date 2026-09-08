// KlariVision Android — uygulama girişi. Orkestratörleri (state/ paketi) ve
// grafik köprülerini (web/ paketi) kurar, izin/SAF sonuçlarını bağlar ve
// Compose kabuğunu (ui/KlariVisionApp) başlatır. Bu dosya kendisi pitch
// kararı üretmez, motor seçici de barındırmaz — tek motor unified_v1'dir.

package com.aykerme.klarivision

import android.Manifest
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.settings.SettingsStore
import com.aykerme.klarivision.state.LiveAudioCaptureEngine
import com.aykerme.klarivision.state.LiveOrchestrator
import com.aykerme.klarivision.state.StudyOrchestrator
import com.aykerme.klarivision.study.AppDirectories
import com.aykerme.klarivision.study.StudyImportService
import com.aykerme.klarivision.ui.KlariVisionApp
import com.aykerme.klarivision.web.LiveGraphBridge
import com.aykerme.klarivision.web.StudyGraphBridge

class MainActivity : ComponentActivity() {
    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Orkestratörler (state/) ve paylaşılan mağazalar — aktivite ömrü
        // boyunca tek örnek. Grafik köprüleri (web/) burada, UI katmanında
        // kurulur çünkü WebView'in Android Context'e ihtiyacı var; sahiplik
        // `attachBridge` ile orkestratöre devredilir.
        val settingsStore = SettingsStore(applicationContext)
        val intervalsStore = MakamIntervalsStore()
        val studyOrchestrator = StudyOrchestrator(applicationContext)
        // Gerçek AudioRecord motoru (live/LiveAudioCapture) adaptör üzerinden
        // bağlanır; LiveOrchestrator(context) kısayolu yer tutucu motorla
        // gelir ve mikrofonu hiç açmaz.
        val liveCaptureEngine = LiveAudioCaptureEngine(applicationContext)
        val liveOrchestrator = LiveOrchestrator(capture = liveCaptureEngine)
        val importsDir = AppDirectories.imports(applicationContext)
        val liveGraphBridge = LiveGraphBridge(this, importsDir)
        // StudyGraphBridge'in onSnapshot geri çağrısı yapım anında sabitlenir
        // (bkz. web/StudyGraphBridge.kt); bu köprü UI'da (Context gerektiği
        // için) kurulduğundan, JS→Kotlin oynatma anlık görüntüsünü
        // orkestratörün `onPlaybackSnapshot` alanına burada bağlıyoruz
        // (state/StudyOrchestrator.kt'nin kendi belgelediği sözleşme).
        val studyGraphBridge = StudyGraphBridge(this, importsDir, onSnapshot = studyOrchestrator.onPlaybackSnapshot)

        studyOrchestrator.attachBridge(studyGraphBridge)
        liveOrchestrator.attachBridge(liveGraphBridge)
        liveCaptureEngine.attachLifecycle(this)

        // RECORD_AUDIO izin akışı: sistem diyaloğu yalnız burada açılabilir;
        // sonucu orkestratöre bildirmek onun işi.
        val permissionLauncher = registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { granted -> liveOrchestrator.onPermissionResult(granted) }

        // SAF dosya seçici — MIME kümesi study/StudyImportService'ten, seçilen
        // Uri doğrudan importAndAnalyze'a gider (kalıcı izin alınmaz, kopya
        // zaten uygulamanın kendi dosyasıdır).
        val importLauncher = registerForActivityResult(
            StudyImportService.openDocumentContract(),
        ) { uri -> uri?.let { studyOrchestrator.importAndAnalyze(it) } }

        setContent {
            val windowSizeClass = calculateWindowSizeClass(this)
            val liveUiState by liveOrchestrator.uiState.collectAsState()

            LaunchedEffect(liveUiState.permissionRequired) {
                if (liveUiState.permissionRequired) {
                    permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                }
            }

            KlariVisionApp(
                widthSizeClass = windowSizeClass.widthSizeClass,
                studyOrchestrator = studyOrchestrator,
                liveOrchestrator = liveOrchestrator,
                settingsStore = settingsStore,
                intervalsStore = intervalsStore,
                liveGraphBridge = liveGraphBridge,
                studyGraphBridge = studyGraphBridge,
                onRequestImport = {
                    importLauncher.launch(StudyImportService.openDocumentMimeTypes)
                },
            )
        }
    }
}
