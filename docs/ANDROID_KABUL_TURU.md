# Android Fiziksel Kabul Turu — 10 Eylül 2026

Cihaz: **SM-A736B (Galaxy A73)**, Android 16. Derleme: `:app:installDebug`.
Tur adb ile sürüldü; klarnetli canlı bölüm kullanıcı tarafından çalındı.

CODEX_HANDOFF'ta **NOT RUN** olarak duran liste ilk kez koşuldu.

## Sonuç tablosu

| # | Kontrol | Sonuç | Not |
|---|---|---|---|
| 1 | Mikrofon izni ve canlı grafik akışı | **geçti** | Çökme bulundu ve düzeltildi (b453fb2) |
| 2 | WAV kaydı başlat/bitir | **geçti** | Dosyalar `files/Recordings/` altına yazılıyor |
| 3 | WAV kaydı → Çalışmalara ekleme | **BAŞARISIZ** | Akış yok — aşağıda B-1 |
| 4 | SAF ile dosya alma | **geçti** | mp4 alındı, `files/Imports/` altına kopyalandı |
| 5 | Çözümleme | **geçti** | 191 s video ≈ 3,5 dk; `Studies-v1.json` doğru (`duration: 191,226418`, kareler tam) |
| 6 | Kütüphaneye kayıt | **geçti** | Çalışma listede görünüyor, yeniden açılıyor |
| 7 | Çalışma görüntüleyici (grafik) | **BAŞARISIZ** | Ekran tamamen boş — B-2 |
| 8 | Oynatma | **BAŞARISIZ** | 0:00 / 0:16, ilerlemiyor — B-2 |
| 9 | A/B döngüsü | **koşulamadı** | 8 engelliyor |
| 10 | Oynatma hızı | **BAŞARISIZ** | "Hızı artır" düğmesi ekran dışında — B-3 |
| 11 | Video/grafik geçişi | **koşulamadı** | 7-8 engelliyor |
| 12 | Kulaklık/Bluetooth rota değişimi | **koşulmadı** | Fiziksel donanım gerekir |
| 13 | Telefon kesintisi | **koşulmadı** | Gerçek çağrı gerekir |
| 14 | Arka plan dönüşü | **geçti** | Arka plana geçince mikrofon güvenle duruyor |
| 15 | Yön değişimi | **koşulmadı** | 7-8 engellediği için anlamlı değil |

## Bulgular

### B-1 — Kayıtlar erişilemez durumda (akış hiç yok)
`LiveOrchestrator.onRecording` yalnız `isRecording` boolean'ını set ediyor;
`RecordingPhase.Completed(path)` yükü atılıyor. `AppDirectories.recordings()`
dizinini yazandan başka OKUYAN yok. Sonuç: kayıtlar uygulamaya özel depoya
yazılıp orada kalıyor — dinlenemiyor, çalışmaya eklenemiyor, dışa
aktarılamıyor. Cihazda 20,9 MB'lık gerçek bir klarnet kaydı bu şekilde
mahsur kaldı.

macOS kabul listesi bunu açıkça şart koşuyor: "kaydedilen WAV dosyası yeniden
dinlenebilmelidir".

### B-2 — Çalışma görüntüleyici hiçbir şey çizmiyor, oynatma çalışmıyor
Ekran görüntüsü: grafik yok, video yok, yalnız koyu zemin ve alt panel.
Süre `0:00 / 0:16` gösteriyor; gerçek süre **191,2 s** ve `Studies-v1.json`
bunu doğru tutuyor. Oynat'a dokununca konum ilerlemiyor ve süre `0:00`'a
düşüyor.

**Elenenler (ölçüldü, sebep DEĞİL):**
- Görüntüleyici HTML'leri sağlam ve iPad kanonik kopyasıyla byte-eşit.
- Medya taşıma katmanı çalışıyor: range istekleri doğru sunuluyor
  (`bytes=819200-` → `skipped=819200`), 206 yolu işliyor.
- Sayfa yükleniyor ve WebView tam ekran çiziyor (`onDraw` akıyor).
- Uygulama çökmüyor, JS konsolunda hata yok.

**Bilinen:** H.264 çözücü (`c2.qti.avc.decoder`) oynat'a basınca kuruluyor ve
hemen `RELEASED` durumuna geçip yıkılıyor.

**Kök sebep BULUNAMADI.** Bu bir hipotez listesi değil, ölçülmüş bir durum
tespitidir; sonraki oturum buradan devam etmelidir.

### B-3 — Alt kontrol paneli ekrandan taşıyor
"Hızı artır" düğmesinin erişilebilirlik sınırları `(0,0,0,0)` — yerleşimde yer
almıyor, dokunulamıyor. "Hızı azalt" görünür. Panel ekranın altından kesiliyor.

### B-4 — Çalışma silmede onay yok
Çalışma kartındaki "kaldır" düğmesi tek dokunuşta, onay sormadan siliyor.
Bu tur sırasında 3,5 dakikalık bir çözümleme kazara böyle silindi.

### B-5 — Imports dizini tekilleştirme yapmıyor
Aynı 17,7 MB'lık mp4'ün **7 kopyası** (≈124 MB) birikmiş. Her alma yeni bir
UUID ile tam kopya yazıyor; eski kopyaları toplayan bir şey yok.

### B-6 — Ortam gürültüsü motorun EN KÖTÜ durumu
Canlı yol ölçümü iki farklı malzemede:

| Malzeme | JNI+motor p50 | p95 | max |
|---|---:|---:|---:|
| Klarnet (kullanıcı çaldı) | 7,679 ms | 9,684 ms | 14,167 ms |
| Ortam gürültüsü (sessiz oda) | 9,128 ms | **10,467 ms** | 16,885 ms |

Hop bütçesi 10,667 ms. Ortam gürültüsünde p95 bütçenin **%98'i**. Sessizlik
eşiğini geçen zayıf adaylar motoru klarnetten daha çok yoruyor — sentetik RTF
testi (tek kararlı ton) bu durumu hiç görmüyor.

### B-7 — StudyGraphBridge'de konsol köprüsü eksikti
`LiveGraphBridge` sayfanın `console` çıktısını logcat'e bağlıyor,
`StudyGraphBridge` bağlamıyordu. Görüntüleyici hatalarında tek belirti "boş
grafik" olduğu için bu körlük, sessizliği sağlık sanmaya yol açıyor.
Parite kuruldu.

### B-8 — Range işleyicisinde `skip()` sözleşmesi
`InputStream.skip()` istenen kadar atlamayı garanti etmez; eksik atlarsa
sunulan baytlar kayar ve medya sessizce bozulur. Bu cihazda tam atlıyor (yani
B-2'nin sebebi değil), ama sözleşme bunu vaat etmiyor. `channel.position()`
ile değiştirildi.

## Çıkış kapısı

**Geçmedi.** Dinleme Modu'nun tamamı (grafik + oynatma + A/B + hız) kullanılamaz
durumda; canlı kayıtlar erişilemez. Otomatik kapıların hepsi yeşilken bu tablo
görünmüyordu — yeşil kapı tablosu, koşulmamış bir turun yerini tutmaz.
