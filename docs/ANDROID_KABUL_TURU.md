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
| 7 | Çalışma görüntüleyici (grafik) | **geçti** (düzeltildi) | Boştu; kök sebep bulundu — B-2 |
| 8 | Oynatma | **geçti** (şartlı) | Çalışıyor; erken basınca takılıyor — B-2b |
| 9 | A/B döngüsü | **BAŞARISIZ** | Dönüyor, sonra oynatma kilitleniyor — B-9 |
| 10 | Oynatma hızı | **BAŞARISIZ** | Yalnız yavaşlatılabiliyor, geri hızlandırılamıyor — B-3 |
| 11 | Video/grafik geçişi | **kısmen** | Geçiş çalışıyor, video görüntüsü gelmiyor — B-11 |
| 12 | Kulaklık/Bluetooth rota değişimi | **koşulmadı** | Fiziksel donanım gerekir |
| 13 | Telefon kesintisi | **koşulmadı** | Gerçek çağrı gerekir |
| 14 | Arka plan dönüşü | **geçti** | Arka plana geçince mikrofon güvenle duruyor |
| 15 | Yön değişimi | **BAŞARISIZ** | Yatay yerleşim kullanılamaz — B-10 |

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

### B-2 — ÇÖZÜLDÜ: `load` yükü `evaluateJavascript`'in sınırını aşıyordu

**Kök sebep bulundu ve düzeltildi.** `StudyGraphBridge` `load` komutunu TEK
`evaluateJavascript` çağrısında gönderiyordu. 191 saniyelik bir çalışma
17258 kare = **~880 KB betik** demektir; `WebView.evaluateJavascript` bu
boyuttaki betiği **sessizce düşürüyor** — istisna atmıyor, konsola bir şey
yazmıyor, sadece hiçbir şey olmuyor. Sayfa ilk (boş) durumunda kalıyordu.

Kanıt, ikili deney:

| Kare sayısı | Betik boyutu | Sonuç |
|---:|---:|---|
| 17258 (tam) | 880 615 B | grafik hiç çizilmiyor |
| 500 (kırpık) | 24 929 B | perde çizgileri, nota etiketleri, imleç, eğri — tamamı çiziliyor |

Bu, `LiveGraphBridge`'in neden çalıştığını da açıklıyor: o kareleri küçük
partiler hâlinde (medyan 294 B) yolluyor.

**Düzeltme:** kareler artık sayfada bir ara diziye 1000'erlik parçalarla
biriktiriliyor, sonra tek bir `receive` çağrısı o diziyi kullanıyor.
Paylaşılan `StudyViewer.html` sözleşmesi DEĞİŞMEDİ (iPad kopyasıyla
byte-eşit kalmalı) — sayfa yine tek bir `{type:'load', url, frames}` nesnesi
görüyor. Cihazda tam 17258 kareyle doğrulandı: grafik çiziliyor, oynatma
0:19 / 3:04 ilerliyor.

**Yanlış iz — kayda geçsin:** ilk tanılamada sayfaya `frames` değişkenini
sordum ve `frames=0` okudum. Bu ölçüm GEÇERSİZDİ: sayfanın kendi `frames`'i
kapalı kapsamda, sorgu tarayıcının yerleşik `window.frames`'ini (iframe
listesi) okuyordu ve onun uzunluğu her zaman 0'dır.

### B-2b — Medya hazır olmadan Oynat'a basınca oynatıcı kalıcı takılıyor

Ayrı ve HÂLÂ AÇIK bir kusur. Çalışma açıldıktan hemen sonra (medya
`readyState=0`, `src` henüz atanmamışken) Oynat'a basılırsa süre `0:00`'a
düşüyor ve bir daha kendine gelmiyor; konum hiç ilerlemiyor. Aynı çalışma,
medya hazır olana kadar (~2 sn) beklenip oynatıldığında sorunsuz çalışıyor.

İlk turda "oynatma tamamen bozuk" görünmesinin sebebi buydu — ölçüm hatası
değil, gerçek bir yarış durumu, ama tarifi düzeltildi.

### B-3 — Hız tek yönlü: yavaşlatılabiliyor, geri hızlandırılamıyor
"Hızı artır" düğmesinin erişilebilirlik sınırları `(0,0,0,0)` — yerleşimde yer
almıyor, dokunulamıyor. "Hızı azalt" erişilebilir. Pratik sonuç: kullanıcı
hızı düşürdükten sonra 1,00×'e geri dönemez. Panel ekranın altından kesiliyor.

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

### B-9 — A/B döngüsü birkaç turdan sonra oynatmayı kilitliyor

Döngünün kendisi çalışıyor: medya B'ye ulaşınca A'ya dönüyor (ölçüldü,
`currentTime` 17,96 → 7,52). Ama birkaç turdan sonra oynatma kalıcı olarak
duruyor — konum 40+ saniye boyunca sabit kaldı, düğme "Duraklat" göstermeye
devam ediyor (yani oynadığını sanıyor). Gözlenen dizi (A≈0:05, B≈0:09):

    0:09 → 0:12 → 0:08 → 0:10 → 0:13 → 0:13 → 0:13 → ... (kilit)

İki yan gözlem: konum B'yi aşıyor (0:09 sınırına karşı 0:12–0:13'e çıkıyor),
yani döngü sınırları gevşek uygulanıyor.

**Tanılama uyarısı:** ilk denemede sayfada bir `Uncaught TypeError: Cannot
read properties of null (reading 'style')` göründü ve sebep sanıldı. DEĞİLDİ:
o hata TANILAMA İÇİN ENJEKTE ETTİĞİM betikten geliyordu. Enjeksiyonlar
tamamen söküldükten sonra kilit aynen tekrarlandı ve konsol temiz kaldı.

Kök sebep bulunamadı. Döngü mantığı paylaşılan `StudyViewer.html` içindedir
ve o dosya iPad kopyasıyla byte-eşit olmak zorundadır — düzeltme iki platformu
birden ilgilendiren bir karardır, tek taraflı yapılmadı.

### B-10 — Yatay yerleşim kullanılamaz

Cihaz yatay çevrildiğinde kontrol paneli tüm ekranı kaplıyor, A ve B
düğmeleri sol kenara dikey diziliyor, "Kapat" düğmesi durum çubuğunun altında
kesiliyor ve grafik en altta ~60 piksellik bir şeride sıkışıyor. Çökme yok,
ama ekran çalışılamaz durumda.

### B-11 — Video görüntüsü gelmiyor; süre yanlış kalıyor

Video/grafik geçişinin kendisi çalışıyor (düğme "Grafiği tam ekran yap"a
dönüyor, sahne değişiyor). Ama video alanında gerçek kare yerine tarayıcının
yedek oynat simgesi duruyor.

Video çalışmasında süre hâlâ **0:16** görünüyor; `Studies-v1.json` aynı
çalışma için `duration: 191,226418` tutuyor. B-2'nin kare düzeltmesi bu
çalışmada grafiği getirdi, ama video kod çözme yolunu düzeltmedi — bunlar
ayrı kusurlar. Aynı dosyanın SES yolu sorunsuz (mp3 çalışmasında süre
3:04 doğru ve oynatma ilerliyor), yani sorun video kod çözmeye özgü.

## Çıkış kapısı

**Geçmedi**, ama en ağır engel kalktı: Dinleme Modu'nun boş ekranı (B-2)
çözüldü ve grafik + oynatma cihazda çalışıyor.

Kapıyı hâlâ kapalı tutanlar: canlı kayıtlar erişilemez (B-1), oynatıcı erken
basınca takılıyor (B-2b), hız tek yönlü (B-3), A/B döngüsü oynatmayı
kilitliyor (B-9), yatay yerleşim kullanılamaz (B-10), video görüntüsü
gelmiyor (B-11).

Rota değişimi ve telefon kesintisi fiziksel donanım beklediği için hâlâ
koşulmadı; listenin geri kalanı koşuldu.

Otomatik kapıların hepsi yeşilken bu tablo görünmüyordu — yeşil kapı
tablosu, koşulmamış bir turun yerini tutmaz.
