// KlariVision Android — Ana Sayfa ekranı, Swift iPadHomeView/
// iPadCompactHomeView'den port edildi. İki mod kartı: Dinleme (dosya seç) ve
// Çalma (canlı başlat). Pitch kararı üretmez, yalnız niyet iletir.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Ana Sayfa: karşılama metni ve iki mod kartı. `isWide` geniş ekranda
 * kartları yan yana, dar ekranda alt alta dizer (task: ardışık/yan yana).
 */
@Composable
fun HomeScreen(
    isWide: Boolean,
    onOpenLibraryImport: () -> Unit,
    onStartLive: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Text("Bugün nasıl çalışmak istersin?", style = MaterialTheme.typography.headlineMedium)
        Text(
            "Yerel analizini dinle veya klarnetinle canlı çalış.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (isWide) {
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                ModeCard(
                    title = "Dinleme Modu",
                    subtitle = "Ses veya video dosyanı analiz et, pitch eğrisini medya ile birlikte çalış.",
                    glyph = "🎧",
                    actionLabel = "Dosya Seç",
                    onClick = onOpenLibraryImport,
                    modifier = Modifier.weight(1f),
                )
                ModeCard(
                    title = "Çalma Modu",
                    subtitle = "Mikrofonla canlı pitch analizi yap, tüneri izle ve kaydet.",
                    glyph = "🎙",
                    actionLabel = "Başlat",
                    onClick = onStartLive,
                    modifier = Modifier.weight(1f),
                )
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                ModeCard(
                    title = "Dinleme Modu",
                    subtitle = "Ses veya video dosyanı analiz et, pitch eğrisini medya ile birlikte çalış.",
                    glyph = "🎧",
                    actionLabel = "Dosya Seç",
                    onClick = onOpenLibraryImport,
                )
                ModeCard(
                    title = "Çalma Modu",
                    subtitle = "Mikrofonla canlı pitch analizi yap, tüneri izle ve kaydet.",
                    glyph = "🎙",
                    actionLabel = "Başlat",
                    onClick = onStartLive,
                )
            }
        }
    }
}

@Composable
private fun ModeCard(
    title: String,
    subtitle: String,
    glyph: String,
    actionLabel: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(modifier = modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp)) {
        Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(glyph, style = MaterialTheme.typography.displaySmall)
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(modifier = Modifier.padding(2.dp))
            Button(onClick = onClick) { Text(actionLabel) }
        }
    }
}
