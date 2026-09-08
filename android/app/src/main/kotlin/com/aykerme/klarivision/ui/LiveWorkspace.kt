// KlariVision Android — Çalma (canlı) çalışma alanı, Swift iPadLiveWorkspace /
// iPadCompactLiveWorkspace'ten port edildi. Grafik `state.LiveOrchestrator`
// tarafından yönetilir; bu dosya yalnız düzeni ve kullanıcı niyetlerini
// (başlat/durdur/kaydet/makam-karar) iletir — pitch kararı üretmez.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.aykerme.klarivision.music.Karar
import com.aykerme.klarivision.music.Makam
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.music.ScaleDisplay
import com.aykerme.klarivision.settings.SettingsStore
import com.aykerme.klarivision.state.LiveOrchestrator
import com.aykerme.klarivision.state.LivePhase2
import kotlinx.coroutines.launch

/**
 * Çalma modu ekranı. `graphContent`, çağıran tarafından `remember`/
 * `movableContentOf` ile sarılmış WebView barındırıcısıdır — bu sayede
 * genişlik/yön değişiminde WebView yeniden yaratılmaz (bkz. ui/KlariVisionApp.kt).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LiveWorkspace(
    orchestrator: LiveOrchestrator,
    settingsStore: SettingsStore,
    intervalsStore: MakamIntervalsStore,
    graphContent: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    /** Geniş (tablet) ekranda kontroller grafiğin yanında sabit bir panelde durur;
     *  dar ekranda grafiğin üstünde yüzen bir şerit olarak kalır. */
    isWide: Boolean = false,
    onClose: (() -> Unit)? = null,
) {
    val uiState by orchestrator.uiState.collectAsState()
    val scope = rememberCoroutineScope()

    val makamName by settingsStore.liveMakam().collectAsState(initial = Makam.NIHAVEND.displayName)
    val kararName by settingsStore.liveKarar().collectAsState(initial = Karar.RE.displayName)
    val scaleDisplayName by settingsStore.liveScaleDisplay().collectAsState(initial = ScaleDisplay.MAKAM.displayName)

    val makam = Makam.fromDisplayName(makamName) ?: Makam.NIHAVEND
    val karar = Karar.fromDisplayName(kararName)
    val scaleDisplay = ScaleDisplay.fromDisplayName(scaleDisplayName)

    // Makam/karar/gösterim her değiştiğinde bağlamı orkestratöre it — grafik
    // kılavuz çizgilerini bundan türetir.
    LaunchedEffect(makam, karar, scaleDisplay) {
        orchestrator.applyMusicContext(makam, karar, scaleDisplay)
    }

    var isPresentingSettings by remember { mutableStateOf(false) }
    var isPresentingIntervalEditor by remember { mutableStateOf<Makam?>(null) }

    val controls: @Composable ColumnScope.() -> Unit = {
        uiState.errorMessage?.let { message -> StatusLine(message, isError = true) }
        if (uiState.permissionRequired) {
            StatusLine("Mikrofon izni gerekiyor.", isError = false)
        }
        if (uiState.phase == LivePhase2.STARTING) {
            StatusLine("Mikrofon başlatılıyor…", isError = false)
        }
        TunerBadge(note = uiState.tunerNote, cents = uiState.tunerCents)
        FlowRowButtons(isWide) {
            WorkspaceSettingsButton(label = "Makam ve karar") { isPresentingSettings = true }
            RecordButton(
                isRecording = uiState.isRecording,
                isEnabled = uiState.phase == LivePhase2.RUNNING || uiState.isRecording,
                onClick = { orchestrator.toggleRecording() },
            )
            if (uiState.phase == LivePhase2.RUNNING || uiState.phase == LivePhase2.STARTING) {
                Button(onClick = { orchestrator.stop() }) { Text("Durdur") }
            } else {
                Button(onClick = { orchestrator.start() }) { Text("Başlat") }
            }
            onClose?.let { close ->
                Button(onClick = { orchestrator.stop(); close() }) { Text("Kapat") }
            }
        }
    }

    if (isWide) {
        Row(modifier = modifier.fillMaxSize()) {
            Box(modifier = Modifier.weight(1f).fillMaxSize()) { graphContent() }
            Column(
                modifier = Modifier
                    .width(300.dp)
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                content = controls,
            )
        }
    } else {
        Box(modifier = modifier.fillMaxSize()) {
            graphContent()
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(12.dp)
                    .background(
                        MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
                        RoundedCornerShape(20.dp),
                    )
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                content = controls,
            )
        }
    }

    if (isPresentingSettings) {
        ModalBottomSheet(onDismissRequest = { isPresentingSettings = false }) {
            Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                Text("Çalma Ayarları", style = MaterialTheme.typography.titleLarge)
                Spacer(modifier = Modifier.padding(4.dp))
                MusicContextSection(
                    makam = makam,
                    karar = karar,
                    scaleDisplay = scaleDisplay,
                    intervalsStore = intervalsStore,
                    onMakamChange = { scope.launch { settingsStore.setLiveMakam(it.displayName) } },
                    onKararChange = { scope.launch { settingsStore.setLiveKarar(it.displayName) } },
                    onScaleDisplayChange = { scope.launch { settingsStore.setLiveScaleDisplay(it.displayName) } },
                    onOpenIntervalEditor = { isPresentingIntervalEditor = it; isPresentingSettings = false },
                )
            }
        }
    }

    isPresentingIntervalEditor?.let { editingMakam ->
        val editable = editingMakam != Makam.MAJOR && editingMakam != Makam.MINOR
        ModalBottomSheet(onDismissRequest = { isPresentingIntervalEditor = null }) {
            MakamIntervalEditor(
                makam = editingMakam,
                store = intervalsStore,
                isEditable = editable,
                onIntervalsChange = { intervalsStore.setIntervals(editingMakam, it) },
                onReset = { intervalsStore.reset(editingMakam) },
            )
        }
    }
}

/** `— Hz` yerine iPad tarzı nota etiketi + sapma (cents) rozeti. */
@Composable
private fun TunerBadge(note: String?, cents: Double?) {
    Column(
        modifier = Modifier
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f), RoundedCornerShape(50))
            .padding(horizontal = 14.dp, vertical = 6.dp)
            .semantics { contentDescription = "Tüner: ${note ?: "—"}" },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(note ?: "—", style = MaterialTheme.typography.titleMedium)
        Text(
            cents?.let { "%+.0f cent".format(it) } ?: "",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
