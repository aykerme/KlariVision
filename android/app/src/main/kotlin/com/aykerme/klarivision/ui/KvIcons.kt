// KlariVision Android — SF Symbols → Compose ikon eşlemesi.
// docs/ipad-ui-ux/assets/ipad-ui-symbol-map.md içindeki her satırın Android
// karşılığı burada tutulur; emoji kullanılmaz. `material-icons-extended`
// bağımlılığı yalnız bu dosyanın ihtiyaç duyduğu genişletilmiş ikonlar için
// eklendi (build.gradle.kts / libs.versions.toml).
//
// | Eylem            | SF Symbol                     | Compose karşılığı            |
// |------------------|--------------------------------|-------------------------------|
// | KlariVision      | waveform.path.ecg              | Icons.Filled.MonitorHeart     |
// | Dinleme          | headphones                     | Icons.Filled.Headphones       |
// | Çalma            | mic.fill                       | Icons.Filled.Mic              |
// | Dosya seç        | folder                         | Icons.Filled.Folder           |
// | Oynat / duraklat | play.fill / pause.fill         | Icons.Filled.PlayArrow/Pause  |
// | Başa dön         | backward.end.fill              | Icons.Filled.SkipPrevious     |
// | Ayarlar          | gearshape / gearshape.fill     | Icons.Filled.Settings         |
// | Yeniden analiz   | arrow.triangle.2.circlepath    | Icons.Filled.Refresh          |
// | Kayıt            | record.circle.fill             | Icons.Filled.FiberManualRecord|
// | Durum başarı     | checkmark.circle.fill          | Icons.Filled.CheckCircle      |
// | Hata             | exclamationmark.triangle.fill  | Icons.Filled.Warning          |
// | Çalışmalar       | waveform.path                  | Icons.Filled.GraphicEq        |
// | Ana Sayfa        | house                          | Icons.Filled.Home             |
// | Ses aç (Birlikte)| speaker.wave.2                 | Icons.Filled.VolumeUp         |
// | Sessiz (Birlikte)| speaker.slash                  | Icons.Filled.VolumeOff        |
//
// Son iki satır macOS `StudyPlaybackBar.toggleMute`'un simgeleriyle birebir
// eşleşir (bkz. macos/KlariVision/.../StudyWorkspace.swift) — Birlikte Çal
// modunda yalnız medya ÇIKIŞ sesini kapatır, mikrofon çizimini etkilemez.
//
// "Ayarlar" için sembol tablosu `slider.horizontal.3` verir, ama referans
// uygulamanın kendisi (AppState.swift `iPadSection.settings.symbol` ve
// WorkspaceControls.swift `gearshape.fill`) tutarlı biçimde dişli simgesini
// kullanır; kararlar bölümünün "referans uygulama yetkilidir" ilkesi gereği
// gerçek kullanım (dişli) izlendi.

package com.aykerme.klarivision.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Warning
import androidx.compose.ui.graphics.vector.ImageVector

/** Sembol eşleme tablosunun tek gerçek kaynağı — her giriş bir SF Symbol satırına karşılık gelir. */
object KvIcons {
    val AppMark: ImageVector = Icons.Filled.MonitorHeart
    val Listening: ImageVector = Icons.Filled.Headphones
    val Practice: ImageVector = Icons.Filled.Mic
    val PickFile: ImageVector = Icons.Filled.Folder
    val Play: ImageVector = Icons.Filled.PlayArrow
    val Pause: ImageVector = Icons.Filled.Pause
    val Restart: ImageVector = Icons.Filled.SkipPrevious
    val Settings: ImageVector = Icons.Filled.Settings
    val Reanalyze: ImageVector = Icons.Filled.Refresh
    val Record: ImageVector = Icons.Filled.FiberManualRecord
    val Success: ImageVector = Icons.Filled.CheckCircle
    val Error: ImageVector = Icons.Filled.Warning
    val Studies: ImageVector = Icons.Filled.GraphicEq
    val Home: ImageVector = Icons.Filled.Home
    val SpeakerOn: ImageVector = Icons.AutoMirrored.Filled.VolumeUp
    val SpeakerMuted: ImageVector = Icons.AutoMirrored.Filled.VolumeOff
}
