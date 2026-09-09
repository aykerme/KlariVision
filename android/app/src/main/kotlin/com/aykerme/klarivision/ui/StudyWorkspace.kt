// KlariVision Android — Dinleme çalışma alanı, Swift iPadStudyWorkspace /
// iPadCompactStudyWorkspace'ten port edildi. Oynatma durumu ve grafiği
// `state.StudyOrchestrator` yönetir; transport düğmeleri native'dir, oynatma
// sayfanın (WebView) içindedir.
//
// Üç genişlik sınıfı (03-responsive-contract.md) LiveWorkspace ile aynı
// mantığı paylaşır: GENIS'te 320 pt yan panel + 16 pt aralık, ORTA'da üstte
// bant + altta en az 360 pt grafik, DAR'da grafik tüm yüzeyi kaplar ve
// denetimler yüzen bir kart olur.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import com.aykerme.klarivision.together.TogetherOrchestrator
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
    togetherOrchestrator: TogetherOrchestrator,
    graphContent: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    widthClass: KvWidthClass = KvWidthClass.DAR,
    onClose: (() -> Unit)? = null,
    onRequestMicPermission: () -> Unit = {},
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
            togetherOrchestrator = togetherOrchestrator,
            graphContent = graphContent,
            modifier = modifier,
            widthClass = widthClass,
            onClose = onClose,
            onRequestMicPermission = onRequestMicPermission,
        )
    }
}

@Composable
private fun EmptyStudyState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(KvSpacing.xxxl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(KvIcons.Studies, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("Çalışma seçilmedi", style = MaterialTheme.typography.titleLarge)
        Text(
            "Çalışmalar'dan bir çalışma açın.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun FailedStudyState(message: String, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxSize().padding(KvSpacing.xxxl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(KvSpacing.lg, Alignment.CenterVertically),
    ) {
        Icon(KvIcons.Error, contentDescription = null, tint = MaterialTheme.colorScheme.error)
        Text("Çalışma Açılamadı", style = MaterialTheme.typography.titleLarge)
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button(onClick = onRetry) {
            Icon(KvIcons.Reanalyze, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.padding(horizontal = 4.dp))
            Text("Yeniden Dene")
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReadyStudyWorkspace(
    orchestrator: StudyOrchestrator,
    study: Study?,
    intervalsStore: MakamIntervalsStore,
    togetherOrchestrator: TogetherOrchestrator,
    graphContent: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    widthClass: KvWidthClass = KvWidthClass.DAR,
    onClose: (() -> Unit)? = null,
    onRequestMicPermission: () -> Unit = {},
) {
    val uiState by orchestrator.uiState.collectAsState()
    val playback = uiState.playback
    val isWide = widthClass != KvWidthClass.DAR

    var isVideoFullscreen by remember { mutableStateOf(false) }
    var isPresentingSettings by remember { mutableStateOf(false) }
    var isPresentingIntervalEditor by remember { mutableStateOf<Makam?>(null) }

    // Her yeni oynatma anlık görüntüsü Birlikte Çal orkestratörüne iletilir —
    // kare→medya zamanı çevirisi ve geriye sıçrama (arama/loop B→A) tespiti
    // bunun üzerinden yürür (bkz. TogetherOrchestrator.onPlaybackSnapshot).
    LaunchedEffect(playback) {
        playback?.let { togetherOrchestrator.onPlaybackSnapshot(it) }
    }

    // TEK teardown noktası: bu çalışma alanı kompozisyondan çıktığında
    // (ekran değişimi, yeni içe aktarma, "Kapat") mikrofon MUTLAKA kapanır —
    // aksi halde açık kalır. `stop()` idempotenttir, güvenle çağrılabilir.
    DisposableEffect(togetherOrchestrator) {
        onDispose { togetherOrchestrator.stop() }
    }

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
                Icon(if (isVideoFullscreen) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen, contentDescription = null)
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
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = if (isWide) Modifier.width(260.dp) else Modifier.weight(1f),
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

        TogetherModeControls(
            togetherOrchestrator = togetherOrchestrator,
            isWide = isWide,
            onRequestMicPermission = onRequestMicPermission,
        )
    }

    when (widthClass) {
        KvWidthClass.GENIS -> Row(modifier = modifier.fillMaxSize()) {
            Box(modifier = Modifier.weight(1f).fillMaxSize()) {
                graphContent()
                Box(modifier = Modifier.align(Alignment.TopEnd).padding(KvSpacing.lg)) { fullscreenToggle() }
            }
            Spacer(modifier = Modifier.width(KvSpacing.lg))
            Column(
                modifier = Modifier
                    .width(320.dp)
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(KvRadius.panel))
                    .padding(KvSpacing.lg),
                verticalArrangement = Arrangement.spacedBy(KvSpacing.md),
                content = transport,
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
                content = transport,
            )
            Box(modifier = Modifier.fillMaxWidth().heightIn(min = KvGraphMinHeight).weight(1f)) {
                graphContent()
                Box(modifier = Modifier.align(Alignment.TopEnd).padding(KvSpacing.lg)) { fullscreenToggle() }
            }
        }

        KvWidthClass.DAR -> Box(modifier = modifier.fillMaxSize()) {
            graphContent()
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(KvSpacing.lg),
            ) { fullscreenToggle() }
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    // Dar ekranda denetimler grafiğin ÜSTÜNDE yüzen bir karttır;
                    // yığılan satırlar (başlık, konum, aktarım, Birlikte Çal)
                    // sınırsız bırakılırsa ekranın yarısını kaplıyordu. Kart
                    // yüksekliği sınırlanır ve içerik kaydırılabilir olur —
                    // hiçbir denetim erişilemez hâle gelmez.
                    .heightIn(max = 320.dp)
                    .verticalScroll(rememberScrollState())
                    // Spesifikasyon (03-responsive-contract.md, "Güvenli alanlar"):
                    // gezinme ve alt denetim çubuğu sistem güvenli alanının
                    // İÇİNDE kalır; grafik ise tüm yüzeyi kaplar. targetSdk 35
                    // ile Android 15+ kenardan kenara çizmeye zorladığı için
                    // boşluk açıkça verilmeli (cihazda gözlendi).
                    .windowInsetsPadding(WindowInsets.safeDrawing)
                    .padding(KvSpacing.md)
                    .background(
                        MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
                        RoundedCornerShape(KvRadius.panel),
                    )
                    .padding(KvSpacing.md),
                verticalArrangement = Arrangement.spacedBy(KvSpacing.sm),
                content = transport,
            )
        }
    }

    if (isPresentingSettings) {
        ModalBottomSheet(onDismissRequest = { isPresentingSettings = false }) {
            Column(modifier = Modifier.fillMaxWidth().padding(KvSpacing.lg)) {
                Text("Dinleme Ayarları", style = MaterialTheme.typography.titleLarge)
                Spacer(modifier = Modifier.padding(KvSpacing.xs))
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
            Icon(imageVector = if (playback?.isPlaying == true) Icons.Filled.Pause else KvIcons.Play, contentDescription = null)
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
            Icon(Icons.Filled.Repeat, contentDescription = null)
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

/**
 * Birlikte Çal denetimleri: aç/kapa, sessize alma, izin/hata durumları ve
 * kulaklık önerisi. `transport` lambdası içine gömülür ki genişlik sınıfına
 * göre yerleşim (DAR'da yüzen kart, ORTA/GENIS'te denetim paneli) otomatik
 * olarak StudyWorkspace'in mevcut düzen kararına uysun — burada ayrı bir
 * yerleşim kararı ALINMAZ.
 */
@Composable
private fun TogetherModeControls(
    togetherOrchestrator: TogetherOrchestrator,
    isWide: Boolean,
    onRequestMicPermission: () -> Unit,
) {
    val uiState by togetherOrchestrator.uiState.collectAsState()

    FlowRowButtons(isWide) {
        FilledIconToggleButton(
            checked = uiState.isRunning,
            onCheckedChange = { checked ->
                if (checked) togetherOrchestrator.start() else togetherOrchestrator.stop()
            },
            modifier = Modifier.semantics {
                contentDescription = "Birlikte Çal: ${if (uiState.isRunning) "Açık" else "Kapalı"}"
            },
        ) {
            Icon(KvIcons.Practice, contentDescription = null)
        }

        if (uiState.isRunning) {
            IconButton(
                onClick = { togetherOrchestrator.setMuted(!uiState.muted) },
                modifier = Modifier.semantics {
                    contentDescription = if (uiState.muted) {
                        "Medya sesini aç"
                    } else {
                        "Medya sesini kapat (akustik geri besleme önleme)"
                    }
                },
            ) {
                Icon(
                    imageVector = if (uiState.muted) KvIcons.SpeakerMuted else KvIcons.SpeakerOn,
                    contentDescription = null,
                )
            }
        }
    }

    if (uiState.isRunning) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(KvSpacing.xs),
            modifier = Modifier.semantics { contentDescription = "Mikrofon aktif" },
        ) {
            Icon(
                KvIcons.Record,
                contentDescription = null,
                tint = KvColors.StatusRecording,
                modifier = Modifier.size(10.dp),
            )
            Text("Mikrofon Aktif", style = MaterialTheme.typography.labelMedium)
        }
        Text(
            "En iyi sonuç için kulaklık kullanın — hoparlörden çalarken referans, mikrofona " +
                "girip kendi eğriniz gibi çizilebilir.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    if (uiState.permissionRequired) {
        StatusLine("Mikrofon izni gerekiyor.", isError = false)
        Button(onClick = onRequestMicPermission) { Text("Mikrofon İzni İste") }
    }

    uiState.errorMessage?.let { message -> StatusLine(message, isError = true) }
}
