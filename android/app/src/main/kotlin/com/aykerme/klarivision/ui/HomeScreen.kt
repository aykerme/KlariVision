// KlariVision Android — Ana Sayfa ekranı, Swift iPadHomeView/
// iPadCompactHomeView'den port edildi. İki mod kartı: Dinleme (dosya seç) ve
// Çalma (canlı başlat). Çalma modu başladığında (D-01 "Dinleme/Çalma kök
// sekme DEĞİL, Ana Sayfa'dan girilen çalışma alanı") kartların yerini
// `LiveWorkspace` alır — Swift `iPadHomeView`'ın `live.phase == .running`
// dalıyla birebir aynı davranış. Bu dosya pitch kararı üretmez, yalnız niyet iletir.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.Modifier
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
        )
        return
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            // Kaydırma ŞART: iki mod kartı + başlıklar dar telefon ekranına
            // sığmıyor ve kaydırma olmadan ikinci kartın eylem düğmesi
            // ("Başlat") gezinme çubuğunun altında kalıp erişilemez oluyordu.
            // Cihazda (SM-A736B) gözlendi.
            .verticalScroll(rememberScrollState())
            .padding(KvSpacing.xxl),
        verticalArrangement = Arrangement.spacedBy(KvSpacing.xxl),
    ) {
        Text("Bugün nasıl çalışmak istersin?", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Yerel analizini dinle veya klarnetinle canlı çalış.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (liveUiState.phase == LivePhase2.FAILED) {
            LiveRestartCard(message = liveUiState.errorMessage ?: "Canlı çalışma durdu.", onRestart = onStartLive)
        }

        if (widthClass == KvWidthClass.GENIS) {
            Row(horizontalArrangement = Arrangement.spacedBy(KvSpacing.xl)) {
                ModeCard(
                    title = "Dinleme Modu",
                    subtitle = "Ses veya video dosyanı analiz et, pitch eğrisini medya ile birlikte çalış.",
                    icon = KvIcons.Listening,
                    tint = KvColors.AccentListening,
                    actionLabel = "Dosya Seç",
                    actionIcon = KvIcons.PickFile,
                    onClick = onOpenLibraryImport,
                    modifier = Modifier.weight(1f),
                )
                ModeCard(
                    title = "Çalma Modu",
                    subtitle = "Mikrofonla canlı pitch analizi yap, tüneri izle ve kaydet.",
                    icon = KvIcons.Practice,
                    tint = KvColors.AccentPractice,
                    actionLabel = "Başlat",
                    actionIcon = KvIcons.Practice,
                    onClick = onStartLive,
                    modifier = Modifier.weight(1f),
                )
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(KvSpacing.lg)) {
                ModeCard(
                    title = "Dinleme Modu",
                    subtitle = "Ses veya video dosyanı analiz et, pitch eğrisini medya ile birlikte çalış.",
                    icon = KvIcons.Listening,
                    tint = KvColors.AccentListening,
                    actionLabel = "Dosya Seç",
                    actionIcon = KvIcons.PickFile,
                    onClick = onOpenLibraryImport,
                )
                ModeCard(
                    title = "Çalma Modu",
                    subtitle = "Mikrofonla canlı pitch analizi yap, tüneri izle ve kaydet.",
                    icon = KvIcons.Practice,
                    tint = KvColors.AccentPractice,
                    actionLabel = "Başlat",
                    actionIcon = KvIcons.Practice,
                    onClick = onStartLive,
                )
            }
        }
    }
}

@Composable
private fun LiveRestartCard(message: String, onRestart: () -> Unit) {
    Card(shape = RoundedCornerShape(KvRadius.panel)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(KvSpacing.lg),
            verticalArrangement = Arrangement.spacedBy(KvSpacing.md),
        ) {
            Text("Canlı çalışma durdu", style = MaterialTheme.typography.titleMedium)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = onRestart) { Text("Yeniden Başlat") }
        }
    }
}

@Composable
private fun ModeCard(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: androidx.compose.ui.graphics.Color,
    actionLabel: String,
    actionIcon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(modifier = modifier.fillMaxWidth(), shape = RoundedCornerShape(KvRadius.modeCard)) {
        Column(modifier = Modifier.padding(KvSpacing.xxl), verticalArrangement = Arrangement.spacedBy(KvSpacing.md)) {
            Row(
                modifier = Modifier
                    .size(64.dp)
                    .background(tint.copy(alpha = 0.13f), CircleShape),
                horizontalArrangement = Arrangement.Center,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.padding(16.dp).size(32.dp),
                )
            }
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(modifier = Modifier.padding(2.dp))
            Button(onClick = onClick) {
                Icon(actionIcon, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.padding(horizontal = 4.dp))
                Text(actionLabel)
            }
        }
    }
}
