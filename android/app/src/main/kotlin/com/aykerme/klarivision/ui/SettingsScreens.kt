// KlariVision Android — Ayarlar ekranı, Swift iPadSettingsView'den port edildi.
// Tema, motor bilgisi (tek satır — motor seçici yok, D-040), sinyal kapısı,
// grafik renkleri, 53-koma sistemi ve makam aralık düzenleyicisi.
// Tüm anahtar/clamp/varsayılan değerler settings/ paketinden gelir; burada
// tekrarlanmaz.

package com.aykerme.klarivision.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
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
import com.aykerme.klarivision.music.Makam
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.together.InputLatencySource
import com.aykerme.klarivision.together.TogetherOrchestrator
// SettingsKeys, SettingsValidation.kt ile birlikte paket bildirimi olmadan
// (kök pakette) tanımlı — Kotlin'de kök paket üyeleri modül genelinde
// içe aktarma gerekmeden görünür (settings/SettingsStore.kt'nin kendisi de
// aynı şekilde tekilleştirmeden kullanıyor). Burada da bilerek içe aktarılmıyor.
import com.aykerme.klarivision.settings.SettingsStore
import kotlinx.coroutines.launch

/**
 * Ana Ayarlar listesi. `onOpenMakamIntervals`, dokunulan makam için aralık
 * düzenleyicisini açacak üst düzeye geri çağrı — hem burası hem de her
 * çalışma alanının kendi ayar sayfası aynı düzenleyiciye gider.
 */
@Composable
fun SettingsScreen(
    settingsStore: SettingsStore,
    intervalsStore: MakamIntervalsStore,
    togetherOrchestrator: TogetherOrchestrator,
    onOpenMakamIntervals: (Makam) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scope = rememberCoroutineScope()
    val theme by settingsStore.theme().collectAsState(initial = SettingsKeys.THEME_DEFAULT)
    val studyEngine by settingsStore.studyPitchEngine().collectAsState(initial = SettingsKeys.STUDY_PITCH_ENGINE_DEFAULT)
    val liveEngine by settingsStore.livePitchEngine().collectAsState(initial = SettingsKeys.LIVE_PITCH_ENGINE_DEFAULT)
    val gateDbFS by settingsStore.liveSignalGateDbFS().collectAsState(initial = SettingsKeys.LIVE_SIGNAL_GATE_DBFS_DEFAULT)
    val pitchColor by settingsStore.graphPitchColor().collectAsState(initial = SettingsKeys.GRAPH_PITCH_COLOR_DEFAULT)
    val guideColor by settingsStore.graphGuideColor().collectAsState(initial = SettingsKeys.GRAPH_GUIDE_COLOR_DEFAULT)
    val kararColor by settingsStore.graphKararColor().collectAsState(initial = SettingsKeys.GRAPH_KARAR_COLOR_DEFAULT)
    val micColor by settingsStore.graphMicColor().collectAsState(initial = SettingsKeys.GRAPH_MIC_COLOR_DEFAULT)
    val micAlignmentMs by settingsStore.togetherMicAlignmentMs().collectAsState(initial = SettingsKeys.TOGETHER_MIC_ALIGNMENT_MS_DEFAULT)
    val komaIntervals by settingsStore.komaIntervals53().collectAsState(initial = SettingsKeys.KOMA_INTERVALS_53_DEFAULT)
    val togetherUiState by togetherOrchestrator.uiState.collectAsState()

    LazyColumn(modifier = modifier.fillMaxWidth(), contentPadding = PaddingValues(16.dp)) {
        item { SectionHeader("Görünüm") }
        item {
            ThemePicker(
                selected = theme,
                onSelect = { scope.launch { settingsStore.setTheme(it) } },
            )
        }

        item { HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp)) }
        item { SectionHeader("Pitch Motoru") }
        item {
            Column {
                Text("Dinleme Modu: $studyEngine")
                Text("Çalma Modu: $liveEngine")
                Text(
                    "Dinleme ve Çalma aynı motoru kullanır. Daha önce çözümlenmiş çalışmalar kendi sonuçlarını korur.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        item { HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp)) }
        item { SectionHeader("Çalma Modu — Sinyal Kapısı") }
        item {
            Column {
                Text("Sinyal kapısı: ${gateDbFS.toInt()} dBFS")
                Slider(
                    value = gateDbFS.toFloat(),
                    onValueChange = { scope.launch { settingsStore.setLiveSignalGateDbFS(it.toDouble()) } },
                    valueRange = SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MIN.toFloat()..SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MAX.toFloat(),
                    steps = (SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MAX - SettingsKeys.LIVE_SIGNAL_GATE_DBFS_MIN).toInt() - 1,
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "Sinyal kapısı: ${gateDbFS.toInt()} dBFS" },
                )
            }
        }

        item { HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp)) }
        item { SectionHeader("Grafik Renkleri") }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ColorField("Pitch rengi", pitchColor) { scope.launch { settingsStore.setGraphPitchColor(it) } }
                ColorField("Kılavuz rengi", guideColor) { scope.launch { settingsStore.setGraphGuideColor(it) } }
                ColorField("Karar rengi", kararColor) { scope.launch { settingsStore.setGraphKararColor(it) } }
                ColorField("Mikrofon eğrisi rengi", micColor) { scope.launch { settingsStore.setGraphMicColor(it) } }
            }
        }

        item { HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp)) }
        item { SectionHeader("Birlikte Çal — Mikrofon Hizalaması") }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Bu ince ayardır: uygulama giriş gecikmesini cihazdan ölçer, kaydırıcı yalnız " +
                        "kalan sapmayı düzeltir. Çalarken eğriye bakıp ayarlayın.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Hizalama")
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            "%+.0f ms".format(micAlignmentMs),
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        androidx.compose.material3.TextButton(
                            onClick = { scope.launch { settingsStore.setTogetherMicAlignmentMs(0.0) } },
                            modifier = Modifier.semantics { contentDescription = "Mikrofon hizalamasını sıfırla" },
                        ) { Text("Sıfırla") }
                    }
                }
                Slider(
                    value = micAlignmentMs.toFloat(),
                    onValueChange = { raw ->
                        val snapped = (raw / 5f).let { kotlin.math.round(it) } * 5f
                        scope.launch { settingsStore.setTogetherMicAlignmentMs(snapped.toDouble()) }
                    },
                    valueRange = -200f..200f,
                    steps = 79,
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "Mikrofon hizalaması: %+.0f milisaniye".format(micAlignmentMs) },
                )
                Text(
                    "Ölçülen giriş gecikmesi: ${togetherLatencyLabel(togetherUiState.latencySeconds, togetherUiState.latencySource)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        item { HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp)) }
        item { SectionHeader("53-Koma Aralıkları") }
        item {
            // Yerel taslak: DataStore yalnız toplam 53'e ulaştığında yazar
            // (SettingsStore.setKomaIntervals53), ama kullanıcı ara adımdaki
            // düzenlemesini görebilmeli — Swift tarafındaki davranışla aynı.
            var draft by remember(komaIntervals) { mutableStateOf(komaIntervals) }
            LaunchedEffect(komaIntervals) { draft = komaIntervals }
            Column {
                Text("Toplam: ${draft.sum()} koma")
                draft.forEachIndexed { index, value ->
                    KomaStepperRow(
                        label = "Aralık ${index + 1}",
                        value = value,
                        onChange = { newValue ->
                            val next = draft.toMutableList().also { it[index] = newValue }
                            draft = next
                            scope.launch { settingsStore.setKomaIntervals53(next) }
                        },
                    )
                }
                if (draft.sum() != 53) {
                    Text(
                        "Geçerli düzen 12 pozitif aralıktan ve toplam 53 komadan oluşmalıdır.",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }

        item { HorizontalDivider(modifier = Modifier.padding(vertical = 16.dp)) }
        item { SectionHeader("Makam Aralıkları") }
        items(SettingsKeys.EDITABLE_MAKAMS) { name ->
            val makam = Makam.fromDisplayName(name) ?: return@items
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 10.dp)
                    .semantics { contentDescription = "$name aralıklarını düzenle" },
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(name)
                Text(
                    if (intervalsStore.intervals(makam) == intervalsStore.defaultIntervals(makam)) "Teori" else "Özel",
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

/**
 * Tanılama satırı metni: kaydırıcının neye göre ayarlandığını kullanıcıya
 * gösterir. Mod bu oturumda hiç başlatılmadıysa [TogetherUiState.latencySeconds]
 * `null`dır — ölçüm yalnız `start()` çağrıldığında yapılır.
 */
private fun togetherLatencyLabel(latencySeconds: Double?, source: InputLatencySource?): String {
    if (latencySeconds == null || source == null) return "Henüz ölçülmedi — Birlikte Çal'ı bir kez başlatın."
    val sourceLabel = when (source) {
        InputLatencySource.AUDIO_TIMESTAMP -> "donanım zaman damgası"
        InputLatencySource.BUFFER_ESTIMATE -> "arabellek tahmini"
        InputLatencySource.FALLBACK_DEFAULT -> "varsayılan, ölçülemedi"
    }
    return "${(latencySeconds * 1_000).toInt()} ms ($sourceLabel)"
}

@Composable
private fun SectionHeader(title: String) {
    Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(bottom = 8.dp))
}

@Composable
private fun ThemePicker(selected: String, onSelect: (String) -> Unit) {
    val options = listOf(
        KlariVisionThemeNames.FOCUS to "Çalışma odaklı",
        KlariVisionThemeNames.STUDIO to "Stüdyo",
        KlariVisionThemeNames.CLASSIC to "Sıcak klasik",
    )
    Column {
        options.forEach { (value, label) ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.semantics { contentDescription = "Tema: $label" },
            ) {
                RadioButton(selected = selected == value, onClick = { onSelect(value) })
                Text(label)
            }
        }
    }
}

@Composable
private fun ColorField(label: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun KomaStepperRow(label: String, value: Int, onChange: (Int) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("$label: $value")
        Row {
            androidx.compose.material3.IconButton(
                onClick = { if (value > 1) onChange(value - 1) },
                modifier = Modifier.semantics { contentDescription = "$label azalt" },
            ) { Text("−") }
            androidx.compose.material3.IconButton(
                onClick = { if (value < 12) onChange(value + 1) },
                modifier = Modifier.semantics { contentDescription = "$label artır" },
            ) { Text("+") }
        }
    }
}

/**
 * Bir makamın 53-koma aralık düzenleyicisi sayfası — Ayarlar'dan ya da
 * çalışma alanı ayar sayfasından açılır, ikisi de aynı `MakamIntervalEditor`ı
 * kullanır.
 */
@Composable
fun MakamIntervalsScreen(makam: Makam, store: MakamIntervalsStore, modifier: Modifier = Modifier) {
    val editable = makam != Makam.MAJOR && makam != Makam.MINOR
    MakamIntervalEditor(
        makam = makam,
        store = store,
        isEditable = editable,
        onIntervalsChange = { store.setIntervals(makam, it) },
        onReset = { store.reset(makam) },
        modifier = modifier,
    )
}
