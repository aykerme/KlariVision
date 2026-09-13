# KlariVision macOS Localization Inventory
**Türkçe → İngilizce Çeviri Envanteri**

Belge: Türkçe arayüz metinlerinin İngilizce karşılıkları ve çevrim notları.  
Oluşturma tarihi: 2026-09-13  
Tarama kapsamı: Swift UI metinleri, Python motor mesajları, HTML/JS şablonları, Info.plist

---

## Özet Tablo: Dosya Bazında Sayılar

| Dosya | Metin Sayısı | Interpolasyon | Çoğul/Sayı | Not |
|-------|-------------|---------------|-----------|----|
| `KlariVisionApp.swift` | 28 | 5 | 0 | Progress mesajları (KV-PROGRESS mapping), error details |
| `AppSettings.swift` | 4 | 0 | 0 | Tema adları, motor açıklaması |
| `PracticeViews.swift` | 13 | 3 | 1 | Ayar sayfaları, Geri sayım, Aralık |
| `StudyWorkspace.swift` | 8 | 1 | 0 | Workspace kontrolleri, toolbar |
| `LiveVisuals.swift` | 6 | 2 | 0 | Not adları, tuner etiketleri |
| `StudyModels.swift` | 0 | 0 | 0 | Veri modeli, metin yok |
| `Info.plist` | 1 | 0 | 0 | Mikrofon izni açıklaması |
| `local_app.py` | 13 | 2 | 0 | Hata mesajları, ilerleme |
| `frequency_viewer.py` | 8 | 0 | 0 | Engine labels, sayfa başlıkları |
| `contour_viewer.py` | 0 | 0 | 0 | Sabitler (özel isimler, makam adları) |
| `engine_cli.py` | 2 | 0 | 0 | Parser error, help |
| **Toplam** | **83** | **13** | **1** | |

---

## Bölüm A: Swift Arayüz Metinleri

### KlariVisionApp.swift

#### Progress Mesajları (Satır 104-127)
KV-PROGRESS protokol mapping (motor çıktısından UI'ya):

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 105 | "Ses çıkarılıyor" | "Extracting audio" | extract stage |
| 106 | "Ses okunuyor" | "Decoding audio" | decode stage |
| 107 | "Temel geçiş" | "Causal filter" | causal stage |
| 108 | "Perde analizi" | "Pitch analysis" | pitch stage |
| 109 | "Sonuçlar yazılıyor" | "Writing results" | write stage |
| 110 | "Görünüm oluşturuluyor" | "Building viewer" | viewer stage |
| 117 | "İşleniyor" | "Processing" | default/unknown |

**Not:** Python `src/klarivision/local_app.py` aynı sabitler:
```python
stageLabels: [String: String] = [
    "extract": "Extracting audio",
    "decode": "Decoding audio", ...
]
```

#### Hata ve Durum Mesajleri (Satır 326–585)

| Satır | Türkçe | İngilizce | Interpolasyon |
|------|--------|-----------|---|
| 326 | "Bu dosya desteklenen bir ses veya video biçimi değil. WAV, MP3, M4A ya da desteklenen bir video seçin." | "This file is not a supported audio or video format. Choose a WAV, MP3, M4A, or supported video file." | — |
| 335 | "Bırakılan dosya desteklenmiyor. WAV, MP3, M4A veya video dosyası bırakın." | "Dropped file is not supported. Drop a WAV, MP3, M4A, or video file." | — |
| 343 | AccessibilityText.unsupportedDrop ("Dosya alınamadı...") | "File could not be read. Drop a supported audio or video file." | — |
| 365 | "KlariVision analiz motoru bulunamadı. Projeyi Xcode içinden açtığından emin ol." | "KlariVision analysis engine not found. Make sure you opened the project from Xcode." | — |
| 369 | "Python çalışma ortamı bulunamadı." | "Python virtual environment not found." | — |
| 374 | "Pitch analizi hazırlanıyor…" | "Preparing pitch analysis…" | — |
| 414 | "Analiz oluşturulamadı. Lütfen tekrar dene." | "Analysis could not be created. Please try again." | detail interpolated |
| 414–415 | "Analiz oluşturulamadı. `\(detail)`" | "Analysis could not be created. `\(detail)`" | **Interpolasyon** |
| 418 | "Pitch eğrisi hazır." | "Pitch curve ready." | — |
| 425 | "Analiz motoru başlatılamadı: `\(error.localizedDescription)`" | "Analysis engine could not be started: `\(error.localizedDescription)`" | **Interpolasyon** |
| 463 | "Analiz oluşturulamadı. \(standardError)" | "Analysis could not be created. \(standardError)" | **Interpolasyon** |
| 467 | "Pitch eğrisi hazır." | "Pitch curve ready." | — |
| 473 | "Analiz motoru başlatılamadı: \(error.localizedDescription)" | "Analysis engine could not be started: \(error.localizedDescription)" | **Interpolasyon** |
| 504 | "Çalışma güncel arayüzle hazırlanıyor…" | "Study being updated with current interface…" | — |
| 543 | "Seçili motorla yeniden analiz yalnız paketlenmiş C++ analiz motorunda kullanılabilir." | "Re-analysis with the selected engine is only available with the bundled C++ analysis engine." | — |
| 548 | "`\(selectedEngine)` ile pitch eğrisi hazırlanıyor…" | "Preparing pitch curve with `\(selectedEngine)`…" | **Interpolasyon** |
| 567 | "Seçili motorla analiz yapılamadı. \(standardError)" | "Analysis with the selected engine could not be completed. \(standardError)" | **Interpolasyon** |
| 571 | "`\(selectedEngine)` pitch eğrisi hazır." | "`\(selectedEngine)` pitch curve ready." | **Interpolasyon** |
| 576 | "Motor başlatılamadı: \(error.localizedDescription)" | "Engine could not be started: \(error.localizedDescription)" | **Interpolasyon** |

#### Kenar Çubuğu ve Listeler (Satır 686–777)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 686 | "Kayıt Bulunmadı" | "No Recordings" | Sidebar header, ContentUnavailableView |
| 688 | "Henüz analiz edilmiş bir çalışma yok." | "No analysed study yet." | Description |
| 704 | "Çalışmayı Düzenle" | "Edit Study" | Context menu |
| 710 | "Çalışmayı Sil" | "Delete Study" | Context menu (destructive) |
| 716 | "Çalışmalar" | "Studies" | Section header |
| 762 | "Çalışma silinsin mi?" | "Delete study?" | Alert title |
| 769 | "Vazgeç" | "Cancel" | Button |
| 770 | "Sil" | "Delete" | Button (destructive) |
| 775 | "`\(library.study(for: item).title)` listeden kaldırılır ve bu çalışmaya ait görünüm, ses kopyası ile pitch verileri silinir. Kendi seçtiğin özgün dosyaya dokunulmaz. Bu işlem geri alınamaz." | "`\(library.study(for: item).title)` will be removed from the list. The viewer, audio copy, and pitch data for this study will be deleted. Your original file will not be touched. This action cannot be undone." | **Interpolasyon + uzun metin** |

#### Mode Selection (Satır 783–1024)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 792 | "KlariVision" | "KlariVision" | — |
| 794 | "Pitch analizine nasıl başlamak istersiniz?" | "How would you like to start pitch analysis?" | — |
| 859 | "Dinleme durumu" (AccessibilityText) | "Listening status" | VoiceOver |
| 887 | "Dinleme Modu" | "Listening Mode" | Card title |
| 890 | "Ses veya video dosyanızı yükleyin, pitch analizini başlatın." | "Upload your audio or video file and start pitch analysis." | — |
| 898 | "Dosya Seç / Yükle" | "Choose / Upload File" | Button |
| 920 | "Dinleme Modu" | "Listening Mode" | accessibilityLabel |
| 920 | "Bir ses veya video dosyası seçin ya da bu karta sürükleyin." | "Choose an audio or video file or drag it to this card." | accessibilityHint |
| 940 | "Çalma Modu" | "Playing Mode" | Card title |
| 943 | "Mikrofonunuzu kullanarak canlı, gerçek zamanlı pitch analizi yapın." | "Use your microphone for live, real-time pitch analysis." | — |
| 951 | "Başlat" | "Start" | Button |
| 969 | "Çalma Modu" | "Playing Mode" | accessibilityLabel |
| 969 | "Mikrofonla canlı pitch analizini başlatır." | "Starts live pitch analysis with microphone." | accessibilityHint |
| 993 | "Birlikte Çal" | "Play Together" | Card title |
| 996 | "Dosya çalarken kendi çalışınızı aynı grafikte, ikinci renkle görün." | "See your performance in the same graph in a second color while playing the file." | — |
| 1004 | "Dosya Seç" | "Choose File" | Button |
| 1021 | "Birlikte Çal" | "Play Together" | accessibilityLabel |
| 1022 | "Bir dosya seçin; dosya çalarken mikrofonunuzdaki perde aynı grafiğe eklenir." | "Choose a file; your microphone pitch will be added to the same graph while playing." | accessibilityHint |
| 1054 | "Hazır" | "Cached" | Badge, cache hit |

#### Study Editor (Satır 1078–1144)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 1104 | "Çalışmayı Düzenle" | "Edit Study" | Dialog title |
| 1108 | "Çalışma adı" | "Study name" | TextField placeholder |
| 1109 | "Makam / dizi" | "Makam / Scale" | Picker label |
| 1110–1117 | Makam seçenekleri | Makam options (tablo A.2) | — |
| 1119 | "Karar" | "Karar (Tonic)" | Picker label |
| 1120–1126 | Nota adları | Note names (tablo A.3) | — |
| 1132 | "Vazgeç" | "Cancel" | Button |
| 1134 | "Kaydet" | "Save" | Button |

### AppSettings.swift

#### Tema Seçenekleri (Satır 28–31)

| Satır | Türkçe | İngilizce | Kullanım |
|------|--------|-----------|---------|
| 29 | "Çalışma odaklı" | "Focus" | Tema adı |
| 30 | "Stüdyo" | "Studio" | Tema adı |
| 31 | "Sıcak klasik" | "Warm Classic" | Tema adı |

#### Motor ve Erişilebilirlik (Satır 92, 124–125)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 92 | "Birleşik (Unified v1)" | "Unified (Unified v1)" | Motor başlığı |
| 118 | "Dinleme durumu" | "Listening status" | VoiceOver text |
| 119 | "Çalma durumu" | "Playing status" | VoiceOver text |
| 120 | "Dosya alınamadı. Desteklenen bir ses veya video dosyası bırakın." | "File could not be read. Drop a supported audio or video file." | Accessibility |
| 124 | "Ses çözümlemesi Birleşik (Unified v1) motoruyla yapılır. Seçilebilir başka motor yoktur." | "Audio analysis is performed with the Unified (Unified v1) engine. No other engine is available to choose." | Motor açıklaması |

**Not:** Bu metin, motor seçeneği artık yoksa görülür. Sabit motor ID'si.

### PracticeViews.swift (Çalma Modu Ayarları)

#### Settings Sheet (Satır 9–49)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 22 | "Bitti" | "Done" | Button |
| 39 | "Uygula" | "Apply" | Button |

#### Study Settings (Dinleme Modu) (Satır 50–133)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 69 | "Dinleme Modu Ayarları" | "Listening Mode Settings" | Sheet title |
| 74 | "Görünüm" | "Appearance" | Section |
| 75 | "Pitch eğrisi" | "Pitch curve" | Color picker |
| 76 | "Nota kılavuzları" | "Note guides" | Color picker |
| 77 | "Karar sesi" | "Karar tone" | Color picker |
| 78 | "Varsayılan renklere dön" | "Reset to default colors" | Button |
| 81 | "Çalışma bağlamı" | "Study context" | Section |
| 82 | "Makam / dizi" | "Makam / Scale" | Picker |
| 87 | "Karar" | "Karar (Tonic)" | Picker |
| 92 | "Geri sayım: `\(draft.countdown)` sn" | "Countdown: `\(draft.countdown)` sec" | **Interpolasyon** |
| 101 | "Makam Aralıkları" | "Makam Intervals" | Section |
| 102 | "Yedi aralık toplamı bir oktavda 53 koma olmalıdır." | "Seven intervals must sum to 53 komas in one octave." | Hint text |
| 105 | "Makam" | "Makam" | Picker |
| 109 | "Aralık `\(index + 1)`" | "Interval `\(index + 1)`" | **Interpolasyon** Picker label |
| 110 | "`\(koma)` koma" | "`\(koma)` komas" | **Interpolasyon + çoğul** |
| 114 | "Toplam: `\(total)` / 53 koma" | "Total: `\(total)` / 53 komas" | **Interpolasyon + çoğul** |
| 116 | "Teoriye Dön" | "Reset to Theory" | Button |

#### Live Practice Settings (Çalma Modu) (Satır 136–231)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 157 | "Çalma Modu Ayarları" | "Playing Mode Settings" | Sheet title |
| 164 | "Grafik renkleri" | "Graph colors" | Section |
| 165 | "Pitch eğrisi" | "Pitch curve" | Color picker |
| 166 | "Nota kılavuzları" | "Note guides" | Color picker |
| 167 | "Karar sesi" | "Karar tone" | Color picker |
| 168 | "Varsayılan renklere dön" | "Reset to default colors" | Button |
| 173 | "Sinyal Kapısı" | "Signal Gate" | Section |
| 177 | "Makam Aralıkları" | "Makam Intervals" | Section |
| 178 | "Yedi aralık toplamı bir oktavda 53 koma olmalıdır." | "Seven intervals must sum to 53 komas in one octave." | Hint |
| 182 | "Makam" | "Makam" | Picker |
| 189 | "Aralık `\(index + 1)`" | "Interval `\(index + 1)`" | **Interpolasyon** |
| 190 | "`\(koma)` koma" | "`\(koma)` komas" | **Interpolasyon + çoğul** |
| 197 | "Toplam: `\(total)` / 53 koma" | "Total: `\(total)` / 53 komas" | **Interpolasyon + çoğul** |
| 200 | "Teoriye Dön" | "Reset to Theory" | Button |

#### Live Practice View (Satır 233–515)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 255 | "Çalışmalara Dön" | "Back to Studies" | Button label |
| 261 | "Çalma Modu" | "Playing Mode" | Toolbar label |
| 293 | "Tekerlek: zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır" | "Wheel: zoom time · Shift+wheel: zoom pitch" | Hint text |
| 309 | "Ayarlar" | "Settings" | Button label |
| 311 | "Canlı sinyal eşiğini, ses seviyesini ve makam aralıklarını ayarla" | "Adjust live signal threshold, audio level, and makam intervals" | .help() |
| 411 | "Durdur" | "Stop" | Button (mic on) |
| 411 | "Mikrofonu Başlat" | "Start Microphone" | Button (mic off) |
| 419 | "Kaydı Durdur" | "Stop Recording" | Button (recording) |
| 419 | "Kayıt" | "Record" | Button (not recording) |
| 426 | "Kaydı durdur ve kaydet" | "Stop and save recording" | .help() |
| 426 | "Mikrofon sesini kaydet" | "Record microphone audio" | .help() |
| 429 | "Eğriyi takip et" | "Follow the curve" | Toggle label |
| 467 | "Canlı görünümü sıfırla" | "Reset live view" | Button (.help) |
| 469 | "Grafiğin zaman ve perde ölçeğini başlangıç değerlerine getirir." | "Resets graph time and pitch scale to initial values." | accessibilityHint |

### StudyWorkspace.swift

#### Workspace Header ve Toolbar (Satır 88–170)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 88 | "Çalışma bağlamı" | "Study context" | Bar label |
| 99 | "Seçili makam ve karar: ..." | "Selected makam and karar: ..." | accessibilityLabel |
| 122 | "Çalışmalara Dön" | "Back to Studies" | Button |
| 124 | "Çalışmalar listesine dön" | "Return to studies list" | .help() |
| 151 | "Seçili motorla yeniden analiz et" | "Re-analyze with selected engine" | Label |
| 153 | "Ayarlar'daki çalışma motoruyla yeni pitch eğrisi oluştur" | "Create new pitch curve with the study engine in Settings" | .help() |
| 159 | "Ayarlar" | "Settings" | Button label |
| 161 | "Dinleme modu görünümünü ve makam aralıklarını ayarla" | "Adjust Listening mode appearance and makam intervals" | .help() |
| 167 | "Çalışmayı Düzenle" | "Edit Study" | Button label |
| 169 | "Çalışma adı, makam ve karar bilgisini düzenle" | "Edit study name, makam, and karar information" | .help() |

**Not:** Satır 63: "Birlikte Çal modunda" ve Satır 209, 290: "Birlikte Çal" yorum yazısı; code comment.

### LiveVisuals.swift (Görünüm-Belirtim)

#### Scale Titles (Satır 18–23)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 20 | "Majör" | "Major" | Scale |
| 20 | "Minör" | "Minor" | Scale |
| 20 | "Nihavend" | "Nihavent" | Scale (Makam) |
| 20 | "Kürdi" | "Kurdi" | Scale (Makam) |
| 20 | "Uşşak" | "Ussak" | Scale (Makam) |
| 20 | "Hicaz" | "Hicaz" | Scale (Makam) |
| 20 | "Kürdilihicazkâr" | "Kurdilihicazkar" | Scale (Makam) |
| 20 | "Hicazkâr" | "Hicazkar" | Scale (Makam) |

**Not:** Makam adları kendi tablo B'sinde listelenir.

#### Note Names (Satır 199–209)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 20–21 | "Do", "Do♯ / Re♭", "Re", "Re♯ / Mi♭", "Mi", "Fa", … | "C", "C♯ / D♭", "D", "D♯ / E♭", "E", "F", … | Chromatic notes (12) |

**Not:** Türkçe "Do Re Mi Fa Sol La Si", İngilizce "C D E F G A B".

#### Tuner Text (Satır 293–296)

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 293–296 | "Tekerlek: zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır" | "Scroll: zoom time · Shift+Scroll: zoom pitch" | Help text |

---

## Bölüm B: Makam, Perde ve Nota Adları (Özel İsimler)

**Tavsiye:** Makam, perde, nota ve karar adları müzik terminolojisi olarak İngilizcede aynı kalması önerilir. Alternatif olarak tutarlı bir sistem:
- Makam adları: Hüzzam, Uşşak, Hicaz, Rast, Kürdî → Huzzam, Ussak, Hicaz, Rast, Kurdi (transliterate)
- Perde adları: Kaba Çârgâh, Dügâh, Rast, Segâh, … → Kaba Çargah, Dugah, Rast, Segah (diacritics removed)
- Nota adları (batı): Do, Re, Mi, … → C, D, E, F, G, A, B (standart)

### B.1: Makam Profilleri (`contour_viewer.py` satır 86–92)

| ID | Türkçe | İngilizce (Ön.) |
|----|--------|----------------|
| huzzam | Hüzzam | Huzzam |
| ussak | Uşşak | Ussak |
| hicaz | Hicaz | Hicaz |
| rast | Rast | Rast |
| kurdi | Kürdî | Kurdi |

### B.2: Karar Tonları / Karar Sesleri (`contour_viewer.py` satır 105–111)

| ID | Türkçe | İngilizce (Ön.) |
|----|--------|----------------|
| dugah | Dügâh (La) | Dugah (A) |
| rast | Rast (Sol) | Rast (G) |
| neva | Neva (Re) | Neva (D) |
| huseyni | Hüseynî (Mi) | Huseyni (E) |
| yegah | Yegâh (Re) | Yegah (D) |

### B.3: Perde Dereceleri / Tonal Degrees (`contour_viewer.py` satır 19–44)

Seçili örnekler:

| Türkçe | İngilizce (Ön.) | Batı Nota |
|--------|-----------------|-----------|
| Kaba Çârgâh | Kaba Çargah | C |
| Yegâh | Yegah | D |
| Rast | Rast | G |
| Dügâh | Dugah | A |
| Segâh | Segah | B |
| Çârgâh | Çargah | C |
| Neva | Neva | D |
| Hüseynî | Huseyni | E |
| Gerdâniye | Gerdaniye | G |
| Muhayyer | Muhayyer | A |

**Not:** Tam liste 44 perde içerir (öğrenci öğreniminin dışında). Transliteration tutarlı.

### B.4: Nota Adları (Batı Notasyonu)

Sağlanan skala kısaltması (frequency_viewer.py ve LiveVisuals.swift):

| Türkçe | İngilizce | MIDI |
|--------|-----------|------|
| Do | C | 0 |
| Re | D | 2 |
| Mi | E | 4 |
| Fa | F | 5 |
| Sol | G | 7 |
| La | A | 9 |
| Si | B | 11 |

Keskin / Bemol:
- Do♯ / Re♭ → C♯ / D♭
- Re♯ / Mi♭ → D♯ / E♭
- Fa♯ / Sol♭ → F♯ / G♭
- Sol♯ / La♭ → G♯ / A♭
- La♯ / Si♭ → A♯ / B♭

---

## Bölüm C: Python Motor Mesajleri

### C.1: local_app.py — Hata ve Durum Mesajleri

#### Byte Range / İstek Hataları

| Satır | Türkçe | İngilizce | Bağlam |
|------|--------|-----------|--------|
| 87 | "Geçersiz byte aralığı." | "Invalid byte range." | HTTP Range header parsing |
| 90 | "Geçersiz byte aralığı." | "Invalid byte range." | HTTP Range header parsing |
| 94 | "Geçersiz byte aralığı." | "Invalid byte range." | HTTP Range header parsing |
| 99 | "Karşılanamayan byte aralığı." | "Unsatisfiable byte range." | HTTP Range header parsing |

#### Ağ / İnternet Hataları

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 202 | "Geçerli bir internet bağlantısı gir." | "Provide a valid internet connection." | Network requirement |
| 206–207 | "Bağlantıdan medya alınamadı: ..." | "Media could not be extracted from link: ..." | RuntimeError message |
| 233 | "Bağlantıdan medya alınamadı: `\{error\}`" | "Media could not be extracted from link: `\{error\}`" | **Interpolasyon** |
| 235 | "Bağlantıdan medya alınamadı: `\{last_error\}`" | "Media could not be extracted from link: `\{last_error\}`" | **Interpolasyon** |
| 241 | "Bağlantıdan medya alınamadı." | "Media could not be extracted from link." | Final error |

#### Analiz ve Motor Hataları

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 265 | "Geçersiz makam veya karar sesi seçimi." | "Invalid makam or karar tone selection." | ValueError |
| 272 | "Geçersiz pitch motoru seçimi." | "Invalid pitch engine selection." | ValueError |

#### Dosya ve Önbellek Hataları

| Satır | Türkçe | İngilizce | Not |
|------|--------|-----------|-----|
| 321 | "Geçersiz kayıt görünümü." | "Invalid recording viewer." | ValueError |
| 323 | "Kaydedilmiş çalışma bulunamadı." | "Saved study not found." | FileNotFoundError |
| 327 | "Bu çalışma için ses önbelleği bulunamadı." | "Audio cache not found for this study." | FileNotFoundError |
| 346 | "Bu çalışma için pitch verisi bulunamadı." | "Pitch data not found for this study." | FileNotFoundError |
| 372 | "Bu çalışma için pitch verisi bulunamadı." | "Pitch data not found for this study." | FileNotFoundError |
| 408 | "Çalışma için taşınabilir bir C++ motor seç." | "Choose a portable C++ engine for the study." | ValueError |
| 411 | "Bu çalışma için ses önbelleği bulunamadı." | "Audio cache not found for this study." | FileNotFoundError |

#### HTTP Sunucu Hataları

| Satır | Türkçe | İngilizce | Bağlam |
|------|--------|-----------|--------|
| 565 | "Lütfen bir video veya ses dosyası seç." | "Please choose a video or audio file." | POST /analyse |
| 568 | "Dosyanın uzantısı tanınamadı." | "File extension not recognized." | POST /analyse |
| 580 | "Analiz oluşturulamadı: `\{error\}`" | "Analysis could not be created: `\{error\}`" | **Interpolasyon** Exception handler |
| 600 | "Linkten analiz oluşturulamadı: `\{error\}`" | "Analysis from link could not be created: `\{error\}`" | **Interpolasyon** Exception handler |
| 633 | "KlariVision hazır: http://127.0.0.1:`\{arguments.port\}`" | "KlariVision ready: http://127.0.0.1:`\{arguments.port\}`" | **Interpolasyon** Server startup |

### C.2: frequency_viewer.py — Engine Labels (Satır 158–166)

Engine ID, Türkçe (mevcut), İngilizce (önerilen):

| ID | Türkçe | İngilizce |
|----|--------|-----------|
| unified_v1 | Birleşik (Unified v1) | Unified (Unified v1) |
| yin_v1 | YIN v1 (kaldırıldı) | YIN v1 (removed) |
| pitch_engine_v2 | Pitch Engine v2 (kaldırıldı) | Pitch Engine v2 (removed) |
| vpm_like | VPM-benzeri (kaldırıldı) | VPM-like (removed) |
| hapt_v1 | Harmonik-Faz (HAPT) (kaldırıldı) | Harmonic-Phase (HAPT) (removed) |
| vamp | Vamp pYIN (referans) | Vamp pYIN (reference) |
| python | librosa pYIN (geliştirme) | librosa pYIN (development) |

**Not:** Satır 169 ve 176'da sayfa başlıkları:
- "Duyulan frekans" → "Sounding Frequency"
- "Pitch konturu" → "Pitch Contour"

### C.3: frequency_viewer.py — Media Labels (Satır 192–194)

| Türkçe | İngilizce | HTML |
|--------|-----------|------|
| "Ses kaydı" | "Audio recording" | `<div class="audio-content"><strong>Audio recording</strong>` |

### C.4: contour_viewer.py — Viewer Version (Satır 85–86)

| Metin | İngilizce |
|-------|-----------|
| "v0.6 Beta 1" | "v0.6 Beta 1" |
| "Stable local pitch viewer foundation with media-synchronised playback." | (comment, unchanged) |

### C.5: engine_cli.py — CLI Messages (Satır 32, 39)

| Satır | Türkçe | İngilizce | Bağlam |
|------|--------|-----------|--------|
| 32 | "Bir ses/video dosyası veya --refresh-viewer gerekli." | "An audio/video file or --refresh-viewer is required." | parser.error() |

---

## Bölüm D: Info.plist

### NSMicrophoneUsageDescription (Satır 26)

| Metin | İngilizce | Bağlam |
|-------|-----------|--------|
| "KlariVision, canlı pitch grafiğini oluşturmak ve siz istediğinizde çalışmanızı kaydetmek için mikrofonu kullanır." | "KlariVision uses your microphone to create live pitch graphs and to record your performance when you choose." | Privacy permission (macOS) |

---

## Bölüm E: HTML / JavaScript Şablonları

### E.1: local_app.py — HTML/JS İçeriği (Satır 474, 493)

**Dosya:** `local_app.py`, `startAnalysis()` fonksiyonu içinde embedded JS:

| Metin (HTML/JS içinde) | İngilizce | Not |
|-------|-----------|-----|
| "Dosya yükleniyor…" | "Uploading file…" | Başlangıç mesajı |
| "Pitch analizi yapılıyor veya cache kontrol ediliyor…" | "Running pitch analysis or checking cache…" | İşlem mesajı |

**Not:** Bu metinler doğrudan `startAnalysis()` JavaScript fonksiyonunda embedded; kullanıcıya showProgress() üzerinden görülür.

---

## Riskli Kalıplar ve Çeviri Zorlukları

### 1. Metin Birleştirme (String Concatenation)

**Risk:** Python'dan Swift'e iletilen mesajlerde metin birleştirme:
- `f"Analiz oluşturulamadı: {error}"` (Python) → Swift'te interpolasyon ile görünür
- Türkçe `…` sonlandırması tutarlı olmalı

**Çözüm:** Interpolation placeholder'larını koruyun; çeviriye dahil etmeyin.

### 2. Türkçe Ek Eklenen Interpolasyonlar

**Risk:** Yer tutucu + Türkçe ek:
- Örnek yok, ama `"\(name)'i seç"` gibi kalıplar olabilir (yok görünüyor)

**Çözüm:** Almanca gibi "Verb Inflection Chains" kaçının; İngilizce prepositional phrases kullanın ("select \(name)").

### 3. Sabit Genişlik Varsayımları

**Risk:** `"Tekerlek: zaman yakınlaştır · Shift+tekerlek:"` → İngilizce daha kısa/uzun olabilir
- Arayüz: 1 satırlı help text

**Çözüm:** SwiftUI `.lineLimit(n)` kullanıyorsa, italyan/almanca gibi daha uzun dillerin kırılmasına hazırlanın.

### 4. Python'dan Gelen Metinlerin Swift'te Doğrulanması

**Risk:** `analyse_upload(Path(...), "huzzam", "dugah", engine)` → Swift'te sabit string karşılaştırması:
```swift
if standardError.contains("Pitch analizi yapılamadı") { … }
```

**Bulgular:**
- Hata mesajleri `local_app.py` (İngilizce 206–207 satırları)
- Başarılı çıktı: `viewer.html` dosya yolu (metin yok)

**Çözüm:** Hata metinlerini lokalize etmek istiyorsanız, Python'a dil parametresi ekleyin (ör. `--lang tr|en`) veya Swift'te hata kodları kulla​nın.

### 5. Perde/Makam Adları (Özel İsimler)

**Risk:** `contour_viewer.py` sabit Türkçe perde adları (Kaba Çârgâh, Dügâh, …).

**Bulgu:** HTML/JS şablonunda kodlanmış; statik değer.

**Çözüm:**
- Perde adları için ayrı JSON dosyası ya da konstant (örn. `perde_names_tr.json`, `perde_names_en.json`)
- Veya Python'a dilsiz enum + localization dictionary ekleyin

### 6. Makam Aralığı Sayı Çoğulu

**Risk:** "Aralık 1", "1 koma" vs. "7 komas" — çoğul ek:

```swift
Text("\(koma) koma").tag(koma)  // → "1 koma", "7 koma"
Text("Toplam: \(total) / 53 koma")  // "53 koma" (çoğul, ama "koma" aynı)
```

**Çözüm:** İngilizce `\(koma) koma` → `\(koma) koma` (İngilizce "koma" singular-plural aynı). Alternatif: `.stringsdict` (Pluralization Rules) kullanın:
```xml
<key>interval-koma</key>
<dict>
  <key>NSStringFormatValueTypeKey</key>
  <string>d</string>
  <key>one</key>
  <string>%d koma</string>
  <key>other</key>
  <string>%d komas</string>
</dict>
```

---

## Bölüm F: Yerelleştirme Uygulanması için Öneriler

### F.1: Swift Tarafı

**Araç:** String Catalog (Xcode 14.3+) veya `.strings` dosyası

**Adımlar:**
1. **Localization.xcstrings** oluşturun:
   ```
   macos/KlariVision/Sources/KlariVisionApp/Localizable.xcstrings
   ```
   
2. **Geliştirme dili:** Turkish (`tr`)

3. **Desteklenen diller:** English (`en`)

4. **Format:**
   ```json
   {
     "sourceLanguage" : "tr",
     "strings" : {
       "Dinleme Modu" : {
         "extractionState" : "manual",
         "localizations" : {
           "en" : { "stringUnit" : { "state" : "translated", "value" : "Listening Mode" } },
           "tr" : { "stringUnit" : { "state" : "translated", "value" : "Dinleme Modu" } }
         }
       },
       ...
     },
     "version" : "1.0"
   }
   ```

5. **Info.plist Localization:**
   ```
   InfoPlist.xcstrings (veya InfoPlist.strings)
   ```
   `NSMicrophoneUsageDescription` için ayrı dosya

**SwiftPM Hedefi:** `Package.swift` güncelleme:
```swift
.target(
  name: "KlariVisionApp",
  defaultLocalization: "tr",  // Geliştirme dili
  resources: [
    .process("Localizable.xcstrings"),
    .process("InfoPlist.xcstrings"),
  ]
)
```

### F.2: Python / HTML Tarafı

**Problem:** Python `local_app.py` Türkçe metinler, HTML şablonları `frequency_viewer.py` ve `contour_viewer.py` içinde.

**Çözüm A (Basit):** JSON tercih dosyası:
```python
# src/klarivision/localization.py
LOCALES = {
    "tr": {
        "extracting_audio": "Ses çıkarılıyor",
        "analysis_created": "Analiz oluşturulamadı: {}",
        ...
    },
    "en": {
        "extracting_audio": "Extracting audio",
        "analysis_created": "Analysis could not be created: {}",
        ...
    }
}

def translate(key, locale="tr", **kwargs):
    text = LOCALES[locale].get(key, key)
    return text.format(**kwargs) if kwargs else text
```

**Çözüm B (Kurumsallaştırılmış):** `gettext` / `babel`:
```bash
xgettext src/klarivision/local_app.py -o messages.pot
pybabel init -i messages.pot -d src/klarivision/translations -l en
pybabel compile -d src/klarivision/translations
```

**HTML Şablonlarında:**
- `frequency_viewer.py`, `contour_viewer.py` → ayrı `_tr.py`, `_en.py` versiyonlar veya
- Şablon motoru (Jinja2) ile Python'dan dil parametresi geçin

**Tavsiye:** Başlangıç olarak JSON tercih dosyası, sonra `gettext` geçişi.

### F.3: Makam / Perde Verilerinin Lokalizasyonu

**Dosyalar:** `contour_viewer.py` içinde sabit:

```python
_PERDE_COMMAS = (
    (0, "Kaba Çârgâh", "Do"),
    (40, "Dügâh", "La"),
    ...
)
```

**Çözüm:**
```python
# src/klarivision/localization_data.py
PERDE_NAMES = {
    "tr": {
        0: "Kaba Çârgâh",
        40: "Dügâh",
        ...
    },
    "en": {
        0: "Kaba Çargah",
        40: "Dugah",
        ...
    }
}

MAKAM_NAMES = {
    "tr": { "huzzam": "Hüzzam", ... },
    "en": { "huzzam": "Huzzam", ... },
}
```

---

## Özet: Toplam Metin Envanteri

| Kategori | Sayı |
|----------|------|
| Swift UI Metinleri | 64 |
| Python Mesajları | 13 |
| HTML/JS Mesajları | 2 |
| Info.plist | 1 |
| Makam/Perde/Nota (Sabitler) | ~130 (perde + makam + nota kombinasyonu) |
| **Toplam Çevrilecek** | **80 metni** |

---

## Tarayamadığım Yerler ve Sınırlamalar

1. **iPad Tarafı** (`ipad/` dizini): Scope dışı (macOS sadece)
2. **C++ Motor** (`core/tools/pitch_track_cli.cpp`): KV-PROGRESS satırlarında aynalandı, kaynak Türkçe
3. **GraphQL / Web API**: Viewer arayüzü (HTML graph) statik, Türkçe arayüz metin yok
4. **Birim Test / Debug Metinleri**: Dahil edilmedi (kullanıcıya görülmez)
5. **Yorumlar / Dokümantasyon**: Kaynak koddaki İngilizce açıklamalar (code comments) çeviriye dahil değil
6. **Dinamik Motor İçeriği**: `frequency_viewer.py` satır 157–166 kaldırılan motorlar (kesin kimlik, tarihsel)

---

## Sonraki Adımlar (Tavsiyeler)

1. **SwiftUI Localization Catalog** başlatın (Xcode 14.3+)
2. **Python localization.py** modülü oluşturun
3. **Perde/Makam verisi** ayrı JSON dosyasına taşıyın
4. **Motor yapısındaki metin** (progress stages) Swift/Python'da senkronize tutun
5. **Test:** `--lang en` bayrağı ile çalıştırın, her metin kontrol edin

---

**Belgeler:**
- Satır numaraları: Orijinal dosya kaynak
- Interpolasyon: `{}`, `\()` işaretleri korunmuş
- Makam adları: Transliteration önerileri (dialekt işareti olmadan)

