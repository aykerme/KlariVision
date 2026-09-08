// KlariVision Android — Kütüphane ekranı, Swift iPadLibraryView/
// iPadStudyLibraryList/iPadCompactLibraryView'den port edildi. Çalışma
// listesi, açma ve kaldırma (kaldırma medyayı silmez) burada.

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.aykerme.klarivision.study.Study

/**
 * Kütüphane ekranı: kayıtlı çalışmaların listesi. Boşken bilgilendirici bir
 * mesaj gösterir; her satır açma ve kaldırma sunar — kaldırma yalnız kayıt
 * meta-verisini siler, kaynak medya dosyasına dokunmaz.
 */
@Composable
fun LibraryScreen(
    studies: List<Study>,
    onOpen: (Study) -> Unit,
    onRemove: (Study) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (studies.isEmpty()) {
        Column(
            modifier = modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text("Kayıt Bulunmadı", style = MaterialTheme.typography.titleLarge)
            Text(
                "Dinleme Modu'ndan yerel bir ses veya video dosyası seçin.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }

    LazyColumn(modifier = modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp)) {
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
