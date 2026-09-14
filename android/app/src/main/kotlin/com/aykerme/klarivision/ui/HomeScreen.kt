// KlariVision Android — Ana Sayfa ekranı, Swift iPadHomeView/
// iPadCompactHomeView'den port edildi. İki mod kartı: Dinleme (dosya seç) ve
// Çalma (canlı başlat). Çalma modu başladığında (D-01 "Dinleme/Çalma kök
// sekme DEĞİL, Ana Sayfa'dan girilen çalışma alanı") kartların yerini
// `LiveWorkspace` alır — Swift `iPadHomeView`'ın `live.phase == .running`
// dalıyla birebir aynı davranış. Bu dosya pitch kararı üretmez, yalnız niyet iletir.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.settings.SettingsStore
import com.aykerme.klarivision.state.LiveOrchestrator
import com.aykerme.klarivision.state.LivePhase2

/**
 * Ana Sayfa: karşılama metni, iki mod kartı ve (Çalma başladığında) gömülü
 * canlı çalışma alanı. `widthClass` yalnız kartların yatay/dikey dizilişini
 * ve çalışma alanının iç düzenini belirler.
 */
@Composable
fun HomeScreen(
    widthClass: KvWidthClass,
    liveOrchestrator: LiveOrchestrator,
    settingsStore: SettingsStore,
    intervalsStore: MakamIntervalsStore,
    liveGraphContent: @Composable () -> Unit,
    onOpenLibraryImport: () -> Unit,
    onStartLive: () -> Unit,
    modifier: Modifier = Modifier,
    /** Tamamlanmış kaydı Çalışmalara ekler (bkz. LiveWorkspace). */
    onAddRecordingToStudies: ((String) -> Unit)? = null,
    isRecordingImported: (String) -> Boolean = { false },
    isImporting: Boolean = false,
) {
    val liveUiState by liveOrchestrator.uiState.collectAsState()
    val liveActive = liveUiState.phase == LivePhase2.RUNNING || liveUiState.phase == LivePhase2.STARTING

    if (liveActive) {
        LiveWorkspace(
            orchestrator = liveOrchestrator,
            settingsStore = settingsStore,
            intervalsStore = intervalsStore,
            graphContent = liveGraphContent,
            widthClass = widthClass,
            modifier = modifier,
            // Oturum durunca `liveActive` düşer ve Ana Sayfa kendiliğinden döner.
            onClose = { liveOrchestrator.stop() },
            onAddRecordingToStudies = onAddRecordingToStudies,
            isRecordingImported = isRecordingImported,
            isImporting = isImporting,
        )
        return
    }

    // Swift'in iki Ana Sayfa'sı: regular `iPadHomeView` (32 pt dolgu, 24 pt
    // aralık, en fazla 1100 pt genişlik) ve compact `iPadCompactHomeView`
    // (20 pt dolgu ve aralık, daha sade kartlar, kısa alt metinler).
    val isWide = widthClass == KvWidthClass.GENIS
    val listeningCard = ModeCardContent(
        title = "Dinleme Modu",
        subtitle = if (isWide) "Ses veya video dosyanı analiz et, pitch eğrisini medya ile birlikte çalış." else "Ses veya video dosyanı analiz et.",
        icon = KvIcons.Listening,
        tint = KvColors.AccentListening,
        actionLabel = "Dosya Seç",
        onClick = onOpenLibraryImport,
    )
    val practiceCard = ModeCardContent(
        title = "Çalma Modu",
        subtitle = if (isWide) "Mikrofonla canlı pitch analizi yap, tüneri izle ve kaydet." else "Mikrofonla canlı pitch analizi yap.",
        icon = KvIcons.Practice,
        tint = KvColors.AccentPractice,
        actionLabel = "Başlat",
        onClick = onStartLive,
    )

    Column(
        modifier = modifier
            .fillMaxWidth()
            // Kenardan kenara çizimde (targetSdk 35) başlık durum çubuğunun
            // altına giriyordu; Swift içeriği güvenli alanın içinde tutar.
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
            // Kaydırma ŞART: iki mod kartı + başlıklar dar telefon ekranına
            // sığmıyor ve kaydırma olmadan ikinci kartın eylem düğmesi
            // ("Başlat") gezinme çubuğunun altında kalıp erişilemez oluyordu.
            // Cihazda (SM-A736B) gözlendi.
            .verticalScroll(rememberScrollState())
            .padding(if (isWide) KvSpacing.xxxl else KvSpacing.xl)
            .widthIn(max = 1100.dp),
        verticalArrangement = Arrangement.spacedBy(if (isWide) KvSpacing.xxl else KvSpacing.xl),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(if (isWide) KvSpacing.sm else KvSpacing.xl)) {
            Text("Bugün nasıl çalışmak istersin?", style = MaterialTheme.typography.headlineLarge)
            Text(
                "Yerel analizini dinle veya klarnetinle canlı çalış.",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (liveUiState.phase == LivePhase2.FAILED) {
            LiveRestartCard(message = liveUiState.errorMessage ?: "Canlı çalışma durdu.", onRestart = onStartLive)
        }

        if (isWide) {
            Row(
                modifier = Modifier.height(IntrinsicSize.Max),
                horizontalArrangement = Arrangement.spacedBy(KvSpacing.xl),
            ) {
                ModeCard(listeningCard, modifier = Modifier.weight(1f).fillMaxHeight())
                ModeCard(practiceCard, modifier = Modifier.weight(1f).fillMaxHeight())
            }
        } else {
            CompactModeCard(listeningCard)
            CompactModeCard(practiceCard)
        }
    }
}

private class ModeCardContent(
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val tint: Color,
    val actionLabel: String,
    val onClick: () -> Unit,
)

@Composable
private fun LiveRestartCard(message: String, onRestart: () -> Unit) {
    Card(shape = RoundedCornerShape(KvRadius.panel)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(KvSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(KvSpacing.md),
        ) {
            Text("Canlı çalışma durdu", style = MaterialTheme.typography.titleMedium)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = onRestart, colors = kvButtonColors()) { Text("Yeniden Başlat") }
        }
    }
}

/**
 * Geniş düzen kartı — Swift `iPadModeCard`: 72 pt tonlu daire içinde ikon,
 * 28 pt dolgu, en az 260 pt yükseklik, %5,5 tonlu zemin ve %28 tonlu çerçeve,
 * 20 pt köşe. Eylem düğmesi kartın rengini alır ve alta yaslanır.
 */
@Composable
private fun ModeCard(content: ModeCardContent, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(KvRadius.modeCard)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 260.dp)
            .background(content.tint.copy(alpha = 0.055f), shape)
            .border(1.dp, content.tint.copy(alpha = 0.28f), shape)
            .padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Box(
            modifier = Modifier
                .size(72.dp)
                .background(content.tint.copy(alpha = 0.13f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(content.icon, contentDescription = null, tint = content.tint, modifier = Modifier.size(32.dp))
        }
        Text(content.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text(content.subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.weight(1f))
        TintedActionButton(content)
    }
}

/**
 * Dar düzen kartı — Swift `iPadCompactHomeView.compactCard`: dairesiz ikon,
 * 20 pt dolgu, 12 pt aralık, %7 tonlu zemin, 18 pt köşe, çerçeve yok.
 */
@Composable
private fun CompactModeCard(content: ModeCardContent) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(content.tint.copy(alpha = 0.07f), RoundedCornerShape(18.dp))
            .padding(KvSpacing.xl),
        verticalArrangement = Arrangement.spacedBy(KvSpacing.md),
    ) {
        Icon(content.icon, contentDescription = null, tint = content.tint, modifier = Modifier.size(28.dp))
        Text(content.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Text(content.subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TintedActionButton(content)
    }
}

/**
 * Swift `.buttonStyle(.borderedProminent).tint(tint)`: kart renginde dolu, ikonsuz
 * düğme. Zemin beyaz yazı AA kontrastına göre koyulaştırılır (bkz. [kvButtonColors]).
 */
@Composable
private fun TintedActionButton(content: ModeCardContent) {
    Button(
        onClick = content.onClick,
        colors = kvButtonColors(content.tint),
    ) {
        Text(content.actionLabel)
    }
}
