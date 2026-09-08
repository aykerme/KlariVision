// KlariVision Android — Dinleme çalışma alanı, Swift iPadStudyWorkspace /
// iPadCompactStudyWorkspace'ten port edildi. Oynatma durumu ve grafiği
// `state.StudyOrchestrator` yönetir; transport düğmeleri native'dir, oynatma
// sayfanın (WebView) içindedir.

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import com.aykerme.klarivision.study.Study
import com.aykerme.klarivision.state.StudyOrchestrator
import com.aykerme.klarivision.state.StudyPhase
import com.aykerme.klarivision.web.PlaybackSnapshot

/**
 * Dinleme modu ekranı. `graphContent`, çağıranın `remember`/`movableContentOf`
 * ile sarıp genişlik/yön değişiminde yeniden yaratmadığı WebView barındırıcısıdır.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudyWorkspace(
    orchestrator: StudyOrchestrator,
    intervalsStore: MakamIntervalsStore,
    graphContent: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    /** Geniş (tablet) ekranda transport grafiğin yanında sabit bir panelde durur;
     *  dar ekranda grafiğin üstünde yüzen bir şerit olarak kalır. */
    isWide: Boolean = false,
    onClose: (() -> Unit)? = null,
) {
    val uiState by orchestrator.uiState.collectAsState()

    when (uiState.phase) {
        StudyPhase.IDLE -> EmptyStudyState(modifier)
        StudyPhase.IMPORTING -> ProgressStatus(
            title = "Dosya hazırlanıyor",
            detail = "Dosya yerel çalışma alanına kopyalanıyor.",
            progress = uiState.progress,
            modifier = modifier,
        )
        StudyPhase.DECODING -> ProgressStatus(
            title = "Ses çözülüyor",
            detail = "Ses/görüntü akışı 48 kHz mono Float32'ye çözülüyor.",
            progress = uiState.progress,
            modifier = modifier,
        )
        StudyPhase.ANALYZING -> ProgressStatus(
            title = "Yerel pitch analizi yapılıyor",
            detail = "Kareler unified_v1 motoruyla işleniyor.",
            progress = uiState.progress,
            modifier = modifier,
        )
        StudyPhase.WRITING -> ProgressStatus(
            title = "Sonuçlar kaydediliyor",
            detail = "Çalışma kütüphaneye yazılıyor.",
            progress = uiState.progress,
            modifier = modifier,
        )
        StudyPhase.FAILED -> FailedStudyState(
            message = uiState.errorMessage ?: "Çalışma açılamadı.",
            onRetry = { orchestrator.retry() },
            modifier = modifier,
        )
        StudyPhase.READY -> ReadyStudyWorkspace(
            orchestrator = orchestrator,
            study = uiState.current,
            intervalsStore = intervalsStore,
            graphContent = graphContent,
            modifier = modifier,
            isWide = isWide,
            onClose = onClose,
        )
    }
}

@Composable
private fun EmptyStudyState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Çalışma seçilmedi", style = MaterialTheme.typography.titleLarge)
        Text(
            "Kütüphaneden bir çalışma açın.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun FailedStudyState(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Text("Çalışma Açılamadı", style = MaterialTheme.typography.titleLarge)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button(onClick = onRetry) { Text("Yeniden Dene") }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReadyStudyWorkspace(
    orchestrator: StudyOrchestrator,
    study: Study?,
    intervalsStore: MakamIntervalsStore,
    graphContent: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    isWide: Boolean = false,
    onClose: (() -> Unit)? = null,
) {
    val uiState by orchestrator.uiState.collectAsState()
    val playback = uiState.playback

    var isVideoFullscreen by remember { mutableStateOf(false) }
    var isPresentingSettings by remember { mutableStateOf(false) }
    var isPresentingIntervalEditor by remember { mutableStateOf<Makam?>(null) }

    val makam = study?.context?.let { Makam.fromDisplayName(it.makam) } ?: Makam.NIHAVEND
    val karar = study?.context?.let { Karar.fromDisplayName(it.karar) } ?: Karar.RE
    val scaleDisplay = study?.context?.let { ScaleDisplay.fromDisplayName(it.scaleDisplay) } ?: ScaleDisplay.MAKAM

    val fullscreenToggle: @Composable () -> Unit = {
        if (study?.isVideoSource == true) {
            IconButton(
                onClick = {
                    isVideoFullscreen = !isVideoFullscreen
                    orchestrator.setVideoFullscreen(isVideoFullscreen)
                },
                modifier = Modifier.semantics {
                    contentDescription = if (isVideoFullscreen) "Grafiği tam ekran yap" else "Videoyu tam ekran yap"
                },
            ) {
                Text(if (isVideoFullscreen) "🌊" else "⛶", style = MaterialTheme.typography.titleLarge)
            }
        }
    }

    val transport: @Composable ColumnScope.() -> Unit = {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                study?.title ?: "Dinleme",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.width(if (isWide) 260.dp else 180.dp),
            )
            onClose?.let { close ->
                Button(onClick = { orchestrator.pause(); close() }) { Text("Kapat") }
            }
        }

        PositionReadout(
            time = playback?.time ?: 0.0,
            duration = playback?.duration ?: (study?.duration ?: 0.0),
            modifier = Modifier.fillMaxWidth(),
        )

        StudyTransportButtons(orchestrator = orchestrator, playback = playback, isWide = isWide) {
            WorkspaceSettingsButton(label = "Çalışma ayarları") { isPresentingSettings = true }
        }
    }

    if (isWide) {
        Row(modifier = modifier.fillMaxSize()) {
            Box(modifier = Modifier.weight(1f).fillMaxSize()) {
                graphContent()
                Box(modifier = Modifier.align(Alignment.TopEnd).padding(16.dp)) { fullscreenToggle() }
            }
            Column(
                modifier = Modifier
                    .width(320.dp)
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surface)
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                content = transport,
            )
        }
    } else {
        Box(modifier = modifier.fillMaxSize()) {
            graphContent()
            Box(modifier = Modifier.align(Alignment.TopEnd).padding(16.dp)) { fullscreenToggle() }
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(12.dp)
                    .background(
                        MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
                        RoundedCornerShape(20.dp),
                    )
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                content = transport,
            )
        }
    }

    if (isPresentingSettings) {
        ModalBottomSheet(onDismissRequest = { isPresentingSettings = false }) {
            Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                Text("Dinleme Ayarları", style = MaterialTheme.typography.titleLarge)
                Spacer(modifier = Modifier.padding(4.dp))
                MusicContextSection(
                    makam = makam,
                    karar = karar,
                    scaleDisplay = scaleDisplay,
                    intervalsStore = intervalsStore,
                    onMakamChange = { orchestrator.applyMusicContext(it, karar, scaleDisplay) },
                    onKararChange = { orchestrator.applyMusicContext(makam, it, scaleDisplay) },
                    onScaleDisplayChange = { orchestrator.applyMusicContext(makam, karar, it) },
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

/**
 * Oynat/duraklat, A/B işaretleme, döngü, takip ve hız düğmeleri. Geniş
 * panelde dikey, dar şeritte yatay dizilir; `trailing` (ayar düğmesi) her
 * iki düzende de sona eklenir.
 */
@Composable
private fun StudyTransportButtons(
    orchestrator: StudyOrchestrator,
    playback: PlaybackSnapshot?,
    isWide: Boolean,
    trailing: @Composable () -> Unit,
) {
    FlowRowButtons(isWide) {
        IconButton(
            onClick = { orchestrator.playPause() },
            modifier = Modifier.semantics {
                contentDescription = if (playback?.isPlaying == true) "Duraklat" else "Oynat"
            },
        ) {
            if (playback?.isPlaying == true) {
                Text("❚❚", style = MaterialTheme.typography.titleMedium)
            } else {
                Icon(imageVector = Icons.Filled.PlayArrow, contentDescription = null)
            }
        }
        Button(onClick = { orchestrator.markA() }) { Text("A") }
        Button(onClick = { orchestrator.markB() }) { Text("B") }
        FilledIconToggleButton(
            checked = playback?.loopEnabled == true,
            onCheckedChange = { orchestrator.toggleLoop() },
            modifier = Modifier.semantics {
                contentDescription = "Döngü: ${if (playback?.loopEnabled == true) "Açık" else "Kapalı"}"
            },
        ) {
            Text("🔁")
        }
        LabeledToggle(
            label = "Takip",
            checked = playback?.followsCurve ?: true,
            onCheckedChange = { orchestrator.toggleFollow() },
        )
        RateStepper(rate = playback?.rate ?: 1.0, onRateChange = { orchestrator.setRate(it) })
        trailing()
    }
}
