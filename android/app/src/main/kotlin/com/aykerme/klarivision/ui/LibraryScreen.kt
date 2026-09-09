// KlariVision Android — Çalışmalar ekranı, Swift iPadLibraryView/
// iPadStudyLibraryList'ten port edildi. Study.phase IDLE iken çalışma listesi
// gösterilir (Swift `study.phase == .idle` dalı); IDLE dışındaki her fazda
// (import/analiz/hata/hazır) aynı ekran `StudyWorkspace`'in kendisine döner —
// Dinleme, kök sekme değil buradan girilen bir çalışma alanıdır (D-01).
// Listeden kaldırma yalnız kayıt meta-verisini siler, kaynak medyaya dokunmaz.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
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
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.state.StudyOrchestrator
import com.aykerme.klarivision.state.StudyPhase
import com.aykerme.klarivision.study.Study
import com.aykerme.klarivision.together.TogetherOrchestrator

/**
 * Çalışmalar ekranı: boşta çalışma listesi, aksi halde gömülü Dinleme çalışma
 * alanı (import/analiz ilerlemesi, hata kartı ya da hazır oynatıcı).
 */
@Composable
fun LibraryScreen(
    studies: List<Study>,
    orchestrator: StudyOrchestrator,
    intervalsStore: MakamIntervalsStore,
    togetherOrchestrator: TogetherOrchestrator,
    studyGraphContent: @Composable () -> Unit,
    onOpen: (Study) -> Unit,
    onRemove: (Study) -> Unit,
    widthClass: KvWidthClass,
    modifier: Modifier = Modifier,
    onRequestMicPermission: () -> Unit = {},
) {
    val uiState by orchestrator.uiState.collectAsState()

    val showWorkspace = uiState.phase != StudyPhase.IDLE
    if (showWorkspace) {
        StudyWorkspace(
            orchestrator = orchestrator,
            intervalsStore = intervalsStore,
            togetherOrchestrator = togetherOrchestrator,
            graphContent = studyGraphContent,
            widthClass = widthClass,
            onClose = { orchestrator.closeCurrent() },
            modifier = modifier,
            onRequestMicPermission = onRequestMicPermission,
        )
        return
    }

    if (studies.isEmpty()) {
        Column(
            modifier = modifier.fillMaxSize().padding(KvSpacing.xxxl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(KvIcons.Studies, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("Kayıt Bulunmadı", style = MaterialTheme.typography.titleLarge)
            Text(
                "Dinleme Modu'ndan yerel bir ses veya video dosyası seçin.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }

    LazyColumn(modifier = modifier.fillMaxSize(), contentPadding = PaddingValues(KvSpacing.md)) {
        items(studies, key = { it.id }) { study ->
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp),
            ) {
                ListItem(
                    headlineContent = { Text(study.title) },
                    supportingContent = {
                        Text("${study.context.makam} · ${study.context.karar}")
                    },
                    trailingContent = {
                        IconButton(
                            onClick = { onRemove(study) },
                            modifier = Modifier.semantics { contentDescription = "${study.title} çalışmasını kaldır" },
                        ) {
                            Icon(Icons.Filled.Delete, contentDescription = null)
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpen(study) }
                        .semantics { contentDescription = "${study.title} çalışmasını aç" },
                )
            }
        }
    }
}
