// KlariVision Android — Dinleme ve Çalma çalışma alanlarının ortak kontrolleri,
// Swift WorkspaceControls.swift'ten port edildi: ayar düğmesi, konum göstergesi,
// kayıt düğmesi, makam/karar seçici ve koma aralık düzenleyicisi. Durum burada
// sahiplenilmez, yalnız bağlamalar tüketilir.

package com.aykerme.klarivision.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.aykerme.klarivision.music.Karar
import com.aykerme.klarivision.music.Makam
import com.aykerme.klarivision.music.MakamIntervalsStore
import com.aykerme.klarivision.music.ScaleDisplay

/**
 * Ayar sayfasını açan dişli düğmesi — Swift `iPadWorkspaceSettingsButton` ile
 * aynı görev. VoiceOver adı (contentDescription) her zaman verilir.
 */
@Composable
fun WorkspaceSettingsButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = modifier.size(44.dp)) {
        Icon(Icons.Filled.Settings, contentDescription = label)
    }
}

/**
 * Oynatma konumu göstergesi — native transport, `t / süre` biçiminde.
 * Kaydırma grafiğin kendi tek-parmak yatay sürüklemesiyle yapılır; bu salt
 * okunabilir bir konum etiketidir (Swift `iPadStudyPositionReadout`).
 */
@Composable
fun PositionReadout(time: Double, duration: Double, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.semantics {
            contentDescription = "Konum: ${formatTime(time)} / ${formatTime(duration)}"
        },
        horizontalArrangement = Arrangement.Center,
    ) {
        Text(formatTime(time), style = MaterialTheme.typography.labelMedium)
        Text(" / ", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(formatTime(duration), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun formatTime(value: Double): String {
    if (!value.isFinite() || value <= 0) return "0:00"
    val total = value.toInt()
    return "%d:%02d".format(total / 60, total % 60)
}

/**
 * Yuvarlak kayıt düğmesi. Boşta kırmızı nokta, kayıt sırasında yuvarlatılmış
 * kare olur ve yanıp söner — Swift `iPadRecordButton` ile aynı davranış.
 */
@Composable
fun RecordButton(isRecording: Boolean, isEnabled: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "record-blink")
    val alpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = if (isRecording) 0.3f else 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 800, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "record-blink-alpha",
    )
    IconButton(
        onClick = onClick,
        enabled = isEnabled,
        modifier = modifier
            .size(44.dp)
            .semantics {
                contentDescription = if (isRecording) "WAV kaydını bitir" else "WAV kaydı başlat"
            },
    ) {
        Box(
            modifier = Modifier
                .size(28.dp)
                .border(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.5f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(if (isRecording) 14.dp else 16.dp)
                    .background(
                        color = Color(0xFFE53935).copy(alpha = if (isRecording) alpha else 1f),
                        shape = if (isRecording) RoundedCornerShape(4.dp) else CircleShape,
                    ),
            )
        }
    }
}

/**
 * Makam/Karar/gösterim seçici bölümü — Swift `iPadMusicContextSection` ile
 * aynı üç satır: makam açılır menüsü, karar açılır menüsü, aralık düzenleyici
 * bağlantısı.
 */
@Composable
fun MusicContextSection(
    makam: Makam,
    karar: Karar,
    scaleDisplay: ScaleDisplay,
    intervalsStore: MakamIntervalsStore,
    onMakamChange: (Makam) -> Unit,
    onKararChange: (Karar) -> Unit,
    onScaleDisplayChange: ((ScaleDisplay) -> Unit)? = null,
    onOpenIntervalEditor: (Makam) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Makam ve Karar", style = MaterialTheme.typography.titleSmall)
        EnumDropdownRow(
            label = "Makam",
            selected = makam.displayName,
            options = Makam.values().map { it.displayName },
            onSelected = { name -> Makam.fromDisplayName(name)?.let(onMakamChange) },
        )
        EnumDropdownRow(
            label = "Karar",
            selected = karar.displayName,
            options = Karar.values().map { it.displayName },
            onSelected = { name -> onKararChange(Karar.fromDisplayName(name)) },
        )
        if (onScaleDisplayChange != null) {
            EnumDropdownRow(
                label = "Gösterim",
                selected = scaleDisplay.displayName,
                options = ScaleDisplay.values().map { it.displayName },
                onSelected = { name -> onScaleDisplayChange(ScaleDisplay.fromDisplayName(name)) },
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onOpenIntervalEditor(makam) }
                .padding(vertical = 10.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("Aralıklar")
            Text(
                intervalSummary(makam, intervalsStore),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            "Aralıklar, seçili makamın koma düzenini gösterir. Değiştirilmediyse \"Teori\" yazar.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun intervalSummary(makam: Makam, store: MakamIntervalsStore): String {
    val editable = setOf(
        Makam.NIHAVEND, Makam.KURDI, Makam.USSAK, Makam.HICAZ, Makam.HICAZKAR, Makam.KURDILIHICAZKAR,
    )
    if (makam !in editable) return "Sabit"
    return if (store.intervals(makam) == store.defaultIntervals(makam)) "Teori" else "Özel"
}

/** Basit açılır seçim satırı — makam/karar/gösterim seçicileri için ortak parça. */
@Composable
private fun EnumDropdownRow(label: String, selected: String, options: List<String>, onSelected: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = true }
                .padding(vertical = 10.dp)
                .semantics { contentDescription = "$label: $selected" },
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(label)
            Text(selected, color = MaterialTheme.colorScheme.primary)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option) },
                    onClick = {
                        expanded = false
                        onSelected(option)
                    },
                )
            }
        }
    }
}

/**
 * Bir makam için 7 koma-aralığı düzenleyicisi — Swift `iPadMakamIntervalsView`
 * ile aynı sözleşme: her aralık 1–13, toplam 53'e ulaşana kadar kaydedilmez.
 * Majör/Minör gibi sabit makamlarda salt okunur gösterilir.
 */
@Composable
fun MakamIntervalEditor(
    makam: Makam,
    store: MakamIntervalsStore,
    isEditable: Boolean,
    onIntervalsChange: (List<Int>) -> Unit,
    onReset: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val values = store.intervals(makam)
    val total = values.sum()

    Column(modifier = modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Toplam")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("$total koma")
                Icon(
                    imageVector = if (total == 53) Icons.Filled.CheckCircle else Icons.Filled.Warning,
                    contentDescription = if (total == 53) "Geçerli" else "Toplam 53 koma değil",
                    tint = if (total == 53) Color(0xFF2E7D32) else Color(0xFFC62828),
                )
            }
        }
        HorizontalDivider()
        values.forEachIndexed { index, value ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("${index + 1}. aralık")
                if (isEditable) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(
                            onClick = {
                                if (value > 1) {
                                    val next = values.toMutableList().also { it[index] = value - 1 }
                                    onIntervalsChange(next)
                                }
                            },
                            modifier = Modifier.semantics { contentDescription = "${index + 1}. aralığı azalt" },
                        ) { Text("−") }
                        Text("$value", modifier = Modifier.padding(horizontal = 8.dp))
                        IconButton(
                            onClick = {
                                if (value < 13) {
                                    val next = values.toMutableList().also { it[index] = value + 1 }
                                    onIntervalsChange(next)
                                }
                            },
                            modifier = Modifier.semantics { contentDescription = "${index + 1}. aralığı artır" },
                        ) { Text("+") }
                    }
                } else {
                    Text("$value")
                }
            }
        }
        Text(
            if (isEditable) "Her aralık 1–13 koma. Toplam 53'e dönene kadar değişiklik kaydedilmez."
            else "Bu makam teorik düzenle sabittir; aralıkları değiştirilemez.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (isEditable) {
            TextButton(onClick = onReset) { Text("Teoriye Dön") }
        }
    }
}

/**
 * Geniş (tablet) ekranda düğmeleri dikey bir panelde, dar ekranda yatay bir
 * şeritte dizen ortak yardımcı. Çalma ve Dinleme çalışma alanlarının ikisi de
 * kullanır ki "ardışık/yan yana" karar tek yerde alınsın.
 */
@Composable
internal fun FlowRowButtons(isWide: Boolean, content: @Composable () -> Unit) {
    if (isWide) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { content() }
    } else {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) { content() }
    }
}

/** Belirsiz/yüzdeli ilerleme göstergesi — progress == null iken belirsiz döner (donmuş yüzde yok). */
@Composable
fun ProgressStatus(title: String, detail: String, progress: Float?, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Sıra: başlık → açıklama → yüzde → çubuk. Çubuk yüzdenin ALTINDA
        // durur; okuma yönü yukarıdan aşağı olduğu için sayı önce gelir.
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (progress != null) {
            Text("%${(progress * 100).toInt()}", style = MaterialTheme.typography.labelLarge)
            androidx.compose.material3.LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            // progress == null: belirsiz aşama (çevrimdışı motorun tek
            // bloklayıcı `finish()` çağrısı) — donmuş yüzde gösterilmez.
            androidx.compose.material3.LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
    }
}

/** Playback hızı gösterge/adım düğmeleri — 0.10–2.00 arası 0.05 adımlarla. */
@Composable
fun RateStepper(rate: Double, onRateChange: (Double) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        IconButton(
            onClick = { onRateChange((rate - 0.05).coerceAtLeast(0.10)) },
            modifier = Modifier.semantics { contentDescription = "Hızı azalt" },
        ) { Text("−") }
        Text(
            "%.2f×".format(rate),
            modifier = Modifier
                .padding(horizontal = 4.dp)
                .semantics { contentDescription = "Çalma hızı %.2f kat".format(rate) },
        )
        IconButton(
            onClick = { onRateChange((rate + 0.05).coerceAtMost(2.00)) },
            modifier = Modifier.semantics { contentDescription = "Hızı artır" },
        ) { Text("+") }
    }
}

/** İki durumlu (açık/kapalı) etiketli anahtar — Takip/Döngü gibi geçişler için. */
@Composable
fun LabeledToggle(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.semantics { contentDescription = "$label: ${if (checked) "Açık" else "Kapalı"}" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(label, style = MaterialTheme.typography.labelLarge)
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/** Durum/hata satırı — kırmızı/turuncu/nötr metin, VoiceOver ile birlikte okunur. */
@Composable
fun StatusLine(message: String, isError: Boolean, modifier: Modifier = Modifier) {
    Text(
        message,
        modifier = modifier
            .fillMaxWidth()
            .semantics { contentDescription = message },
        color = if (isError) MaterialTheme.colorScheme.error else LocalContentColor.current,
        style = MaterialTheme.typography.bodySmall,
    )
}
