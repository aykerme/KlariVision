// KlariVision Android — Çalma (canlı) çalışma alanı, Swift iPadLiveWorkspace /
// iPadCompactLiveWorkspace'ten port edildi. Grafik `state.LiveOrchestrator`
// tarafından yönetilir; bu dosya yalnız düzeni ve kullanıcı niyetlerini
// (başlat/durdur/kaydet/makam-karar) iletir — pitch kararı üretmez.
//
// Üç genişlik sınıfı (03-responsive-contract.md):
// - GENIS: grafik + 320 pt sabit denetim paneli, 16 pt aralıkla yan yana.
// - ORTA: tüner/denetim şeridi üstte (220–360 pt bandı), grafik altta en az 360 pt.
// - DAR: grafik tüm yüzeyi kaplar (alt safe area dahil), denetimler grafiğin
//   üstünde yüzen yarı saydam kart; tüner ayrı bir yüzer rozettir.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
    widthClass: KvWidthClass = KvWidthClass.DAR,
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
    val isWide = widthClass != KvWidthClass.DAR

    val controls: @Composable ColumnScope.() -> Unit = {
        uiState.errorMessage?.let { message -> StatusLine(message, isError = true) }
        if (uiState.permissionRequired) {
            StatusLine("Mikrofon izni gerekiyor.", isError = false)
        }
        if (uiState.phase == LivePhase2.STARTING) {
            StatusLine("Mikrofon başlatılıyor…", isError = false)
        }
        if (widthClass != KvWidthClass.DAR) {
            TunerBadge(note = uiState.tunerNote, cents = uiState.tunerCents)
        }
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

    when (widthClass) {
        KvWidthClass.GENIS -> Row(modifier = modifier.fillMaxSize()) {
            Box(modifier = Modifier.weight(1f).fillMaxSize()) { graphContent() }
            Spacer(modifier = Modifier.width(KvSpacing.lg))
            Column(
                modifier = Modifier
                    .width(320.dp)
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(KvRadius.panel)),
                verticalArrangement = Arrangement.spacedBy(KvSpacing.md),
                content = { Column(Modifier.padding(KvSpacing.lg), verticalArrangement = Arrangement.spacedBy(KvSpacing.md), content = controls) },
            )
        }

        KvWidthClass.ORTA -> Column(modifier = modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 220.dp, max = 360.dp)
                    .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(KvRadius.panel))
                    .padding(KvSpacing.lg),
                verticalArrangement = Arrangement.spacedBy(KvSpacing.md),
                content = controls,
            )
            Box(modifier = Modifier.fillMaxWidth().heightIn(min = KvGraphMinHeight).weight(1f)) { graphContent() }
        }

        KvWidthClass.DAR -> Box(modifier = modifier.fillMaxSize()) {
            graphContent()
            TunerBadge(
                note = uiState.tunerNote,
                cents = uiState.tunerCents,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(top = KvSpacing.md),
            )
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    // Spesifikasyon (03-responsive-contract.md, "Güvenli alanlar"):
                    // gezinme ve alt denetim çubuğu sistem güvenli alanının
                    // İÇİNDE kalır; grafik ise tüm yüzeyi kaplar. targetSdk 35
                    // ile Android 15+ kenardan kenara çizmeye zorladığı için
                    // boşluk açıkça verilmeli — verilmezse denetimler sistem
                    // gezinme çubuğunun altında kalıyor (cihazda gözlendi).
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(KvSpacing.md)
                    .background(
                        MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
                        RoundedCornerShape(KvRadius.panel),
                    )
                    .padding(KvSpacing.md),
                verticalArrangement = Arrangement.spacedBy(KvSpacing.sm),
                content = controls,
            )
        }
    }

    if (isPresentingSettings) {
        ModalBottomSheet(onDismissRequest = { isPresentingSettings = false }) {
            Column(modifier = Modifier.fillMaxWidth().padding(KvSpacing.lg)) {
                Text("Çalma Ayarları", style = MaterialTheme.typography.titleLarge)
                Spacer(modifier = Modifier.padding(KvSpacing.xs))
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
private fun TunerBadge(note: String?, cents: Double?, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.9f), RoundedCornerShape(50))
            .padding(horizontal = KvSpacing.md + KvSpacing.xs, vertical = KvSpacing.sm)
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
