# Android Fiziksel Kabul Turu — 10 Eylül 2026

Cihaz: **SM-A736B (Galaxy A73)**, Android 16. Derleme: `:app:installDebug`.
Tur adb ile sürüldü; klarnetli canlı bölüm kullanıcı tarafından çalındı.

CODEX_HANDOFF'ta **NOT RUN** olarak duran liste ilk kez koşuldu.

## Sonuç tablosu

| # | Kontrol | Sonuç | Not |
|---|---|---|---|
| 1 | Mikrofon izni ve canlı grafik akışı | **geçti** | Çökme bulundu ve düzeltildi (b453fb2) |
| 2 | WAV kaydı başlat/bitir | **geçti** | Dosyalar `files/Recordings/` altına yazılıyor |
| 3 | WAV kaydı → Çalışmalara ekleme | **geçti** (yazıldı) | Akış hiç yoktu; portlandı — B-1 |
| 4 | SAF ile dosya alma | **geçti** | mp4 alındı, `files/Imports/` altına kopyalandı |
| 5 | Çözümleme | **geçti** | 191 s video ≈ 3,5 dk; `Studies-v1.json` doğru (`duration: 191,226418`, kareler tam) |
| 6 | Kütüphaneye kayıt | **geçti** | Çalışma listede görünüyor, yeniden açılıyor |
| 7 | Çalışma görüntüleyici (grafik) | **geçti** (düzeltildi) | Boştu; kök sebep bulundu — B-2 |
| 8 | Oynatma | **geçti** | B-2b çözüldü |
| 9 | A/B döngüsü | **BAŞARISIZ** | Dönüyor, sonra oynatma kilitleniyor — B-9 |
| 10 | Oynatma hızı | **geçti** (düzeltildi) | B-3 — cihazda doğrulandı |
| 11 | Video/grafik geçişi | **geçti** | Video oynuyor ve görüntü geliyor — B-11 |
| 12 | Kulaklık/Bluetooth rota değişimi | **koşulmadı** | Fiziksel donanım gerekir |
| 13 | Telefon kesintisi | **koşulmadı** | Gerçek çağrı gerekir |
| 14 | Arka plan dönüşü | **geçti** | Arka plana geçince mikrofon güvenle duruyor |
| 15 | Yön değişimi | **geçti** (düzeltildi) | B-10 — cihazda doğrulandı |

## Bulgular

### B-1 — ÇÖZÜLDÜ: kayıt → Çalışmalar akışı portlandı

Akış bir hata değil, hiç yazılmamıştı: `LiveOrchestrator.onRecording` yalnız
`isRecording` boolean'ını set ediyor, `RecordingPhase.Completed(path)` yükünü
atıyordu ve `Recordings/` dizinini yazandan başka okuyan yoktu. Kayıtlar
uygulamaya özel depoya yazılıp orada kalıyordu — dinlenemiyor, çalışmaya
eklenemiyor, dışa aktarılamıyordu.

Swift tarafındaki kanonik davranış (`iPadCompactLiveWorkspace.recordingResult`
+ `addCompletedRecordingToStudies`) birebir portlandı:

1. `LiveUiState` artık `completedRecordingPath` tutuyor; yeni kayıt başlayınca
   temizleniyor, yani ekranda hep EN SON tamamlanan kayıt duruyor.
2. `CompletedRecordingRow` dosya adını gösteriyor ve ya "Çalışmalara Ekle"
   düğmesini ya da zaten eklendiyse "Bu kayıt Çalışmalar'a eklendi."
   bilgisini veriyor; içe aktarma sürerken düğme devre dışı.
3. `StudyOrchestrator.importRecordedAndAnalyze` kaydı `Imports/` altına
   KOPYALIYOR (taşımıyor), analiz ediyor, kütüphaneye yazıyor. Kayıt
   `Recordings/` altında olduğu gibi kalıyor: kalıcı çalışma her zaman kendi
   kopyasını kullanır, böylece kullanıcı kaydı silse bile çalışma bozulmaz —
   SAF yolundaki kuralın aynısı.
4. Sıra Swift'le aynı: önce canlıyı durdur (mikrofon açıkken analiz başlatmak
   CPU ve ses odağını çakıştırır), sonra kütüphaneye geç, sonra al ve analiz et.

**Bir incelik kayda geçsin:** `DuplicateImportGuard` `IdentityHashMap`
tabanlıdır, yani REFERANS eşitliğine bakar. `recording.absolutePath` her
çağrıda EŞİT ama FARKLI bir `String` nesnesi üretir; anahtar intern
edilmeseydi muhafız aynı kaydı iki ayrı kayıt sayar ve tek kayıt iki kez
eklenirdi. Anahtar `absolutePath.intern()`'dir ve bunu koruyan bir JVM testi
vardır.

Cihazda uçtan uca doğrulandı: kayıt bitir → düğme → içe aktarma + analiz →
çalışma açıldı (süre 0:10, kayıt süresiyle tutarlı) → kütüphanede göründü →
Çalma Modu'na dönünce düğme yerine "Bu kayıt Çalışmalar'a eklendi." çıktı.

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

### B-2b — ÇÖZÜLDÜ: `load()` iki kez çağrılıyordu

**Teşhisim yanlıştı.** Kusuru "medya hazır olmadan Oynat'a basınca takılıyor"
diye kaydetmiştim; gerçek sebep hazırlıkla ilgili değil, çift yükleme
yarışıydı. Erken-Oynat yalnızca yarışın kaybedilen tarafını görünür kılıyordu.

`StudyGraphBridge.load()` İKİ yerden çağrılıyordu:

1. `StudyOrchestrator.openStudy` → `defaultViewerLoad`, hemen ardından
   `load`/`context` komutlarını kuyruğa koyarak;
2. `KlariVisionApp`'teki `AndroidView` fabrikası,
   `factory = { studyGraphBridge.webView.also { studyGraphBridge.load() } }`.

İkinci çağrı ikinci bir `loadUrl` başlatıyordu. Birinci sayfa önce bitip
kuyruğu boşaltırsa, ikinci `loadUrl` o sayfayı — yeni kurulmuş medya elemanı
ve 17 bin karesiyle birlikte — yok ediyor, yeni sayfaya ise BOŞ kuyruk
akıyordu. Sonuç hiçbir zaman kendine gelmeyen bir oynatıcı: süre 0:00, konum
ilerlemiyor.

Kanıt, cihazda komut akışı logu (kilitlenen tur):

    close(): about:blank yükleniyor
    load(): StudyViewer yükleniyor
    load(): StudyViewer yükleniyor      ← İKİ KEZ
    gönderiliyor: Load
    gönderiliyor: Context

ve sayfaya sorulduğunda `querySelector('video,audio')` **null** dönüyordu —
yani medya elemanı hiç kurulmamıştı.

Yarışın neden aralıklı olduğu da buradan çıkıyor: çalışma kapatılıp yeniden
açıldığında WebView sıcak olduğu için birinci sayfa hızlı bitiyor ve yarış
çoğunlukla kaybedilen tarafa düşüyor. Temiz açılışta beş agresif denemede bir
kez bile tekrarlanmamıştı.

**Düzeltme:** fabrikadan `load()` kaldırıldı. Sayfanın yaşam döngüsü
orkestratöre aittir. Canlı köprüde tek çağıran fabrikadır, orada `load()`
yerinde kalır — bu yüzden Çalma Modu bu kusurdan hiç etkilenmemişti.

Doğrulama (SM-A736B): kilidi tetikleyen tam dizi (çalışma aç → kapat → başka
çalışma aç → hemen Oynat) düzeltme öncesi kilitleniyordu; sonrasında dört
denemenin dördünde de `0:08–0:09 / 0:10`. Ayrıca üç gerileme senaryosu
(temiz açılış + hemen oynat, aynı çalışmayı kapat-aç, üç çalışma arasında
gezinme) temiz.

### B-3 / B-10 — ÇÖZÜLDÜ, cihazda doğrulandı

İkisinin de tek ortak sebebi vardı: yerleşim kararları sığmayan durumu hiç
ele almıyordu.

**B-3** — `FlowRowButtons` adının vaat ettiğini yapmıyor, dar modda düz bir
`Row` kuruyordu; yedi çocuk sığmayınca sondakiler sıfır genişlik alıyordu.
Artık gerçek `FlowRow`.

Doğrulama (SM-A736B, dikey): "Hızı artır" düğmesinin sınırları
`(0,0,0,0)` → **`(653, 2047, 766, 2160)`**. Daha önce hiç görünmeyen hız
metni de geldi. İşlevsel tur: 4× azalt 1,00 → **0,80**, ardından 6× artır
0,80 → **1,10** — tam 0,05'lik adımlar, ve kullanıcı artık 1,00×'in içinden
geçip yukarı çıkabiliyor. B-3'ün asıl kaybı buydu.

**B-10** — Genişlik sınıfı yalnız genişliğe bakıyordu; yatay telefon
(853×384 dp) ORTA seçiyor, o yerleşim ise dikey yığıldığı için 580 dp
yükseklik istiyordu. `KvWidthClass.fromSize` artık yüksekliği de istiyor ve
yetmezse DAR'a düşüyor. Tablet yatayda davranış değişmez; beş JVM testi
sınırları (579/580 dp dahil) tutuyor.

Doğrulama (yatay): kontrollerin tamamı TEK yatay satırda
(⏸ A B döngü Takip − 1,10× + ⚙), hiçbirinin sınırı sıfır değil; grafik
ekranı kaplıyor (perde çizgileri, nota etiketleri, imleç, eğri görünür);
panel alt sayfa olarak duruyor. Öncesinde panel tüm ekranı kaplıyor, A/B
sola dikey diziliyor, "Kapat" durum çubuğunun altında kesiliyor ve grafik
~60 piksellik bir şeride sıkışıyordu.

Döndürme gidiş-dönüşünde durum korunuyor: hız 1,10× dikeye dönünce de
duruyor.

**Ölçüm sırasında bir kez B-2b'ye takıldım:** hız dokunuşlarının ilk turu hiç
kayıt olmadı, çünkü çalışmayı açar açmaz Oynat'a basmıştım ve oynatıcı
kilitlenmişti (süre 0:00'a düşmüştü). Hazır olana kadar (~18 sn) bekleyince
aynı dokunuşlar sorunsuz işledi. B-2b'nin başka ölçümleri de sessizce
bozabileceğinin somut örneği.

### B-9 — A/B döngüsünde grafik ve konum donuyor (AÇIK)

B-2b düzeltildikten SONRA yeniden ölçüldü ve duruyor: ayrı bir kusur.

**Tarif düzeltildi.** "Oynatma kilitleniyor" değil — **oynatma sürüyor**.
Sayfaya sorulduğunda medya `paused=false`, `readyState=4`, hatasız ve
`currentTime` A↔B arasında düzgün dönüyor (22,86 → 8,49). Donan şey
grafik ve konum göstergesidir; ses döngüye devam eder. Dışarıdan
"oynatma durdu" gibi görünmesinin sebebi budur.

**Ölçülen mekanizma.** Sayfaya BAĞIMSIZ bir `requestAnimationFrame` sayacı
enjekte edildi. Sayaç, döngü açıldıktan sonra ~3,6 saniye daha normal koştu
(~120/s), sonra **ilk geri atlama anında** ~1/s'ye çöktü:

    t=19,21  rafSayac=3957
    t=22,86  rafSayac=4390   (+433 / ~3,6 sn — normal)
    t=8,49   rafSayac=4393   (+3 / ~3 sn — çökmüş)

Yani sayfanın kendi `tick`'i patlamış değil; karesi gelmiyor. Elenenler:
`document.visibilityState` **visible**, `document.hidden` **false** (Page
Visibility kısıtlaması DEĞİL); JS konsolunda hata yok; çökme yok. Grafiğe
dokunmak, döngüyü kapatmak ve başka komut göndermek canlandırmıyor —
kalıcı.

Ekran görüntüsü kıyası da bunu doğruluyor: 5 saniye arayla alınan iki kare
byte-birebir aynı.

**Kök sebep BULUNAMADI.** Bilinen: döngü atlaması paylaşılan
`StudyViewer.html`'in `tick` fonksiyonunda yapılıyor
(`media.currentTime=a; media.play(); snapClock();`) ve çöküş tam o anda
oluyor. O dosya iPad kopyasıyla byte-eşit olmak zorunda olduğu için
düzeltme iki platformu birden ilgilendirir; tek taraflı yapılmadı.

Sonraki oturum için yön: sorun oynatma mantığında değil, **kare
zamanlamasında** aranmalı.

### B-10 — Yatay yerleşim kullanılamaz

Cihaz yatay çevrildiğinde kontrol paneli tüm ekranı kaplıyor, A ve B
düğmeleri sol kenara dikey diziliyor, "Kapat" düğmesi durum çubuğunun altında
kesiliyor ve grafik en altta ~60 piksellik bir şeride sıkışıyor. Çökme yok,
ama ekran çalışılamaz durumda.

### B-11 — yeniden ölçüldü: video SORUNSUZ; kalan tek sorun SÜRE

İlk gözlem B-2b düzeltilmeden önce yapılmıştı ve büyük kısmı o yarışın
eseriymiş. Temiz derlemede yeniden ölçüldü.

**Video çalışıyor.** Beş ardışık turda da oynattı: konum 11 saniyede 0:10'a
ilerledi, kod çözme hatası sıfır. Tam ekran video modunda gerçek kare
geliyor (dosyanın başlık karesi okunuyor) ve ardışık ekran görüntüleri
farklı — yani görüntü akıyor. "Tarayıcının yedek oynat simgesi" gözlemi,
B-2b'nin sayfayı komutsuz bırakmasından kaynaklanıyormuş: sayfada medya
elemanı hiç kurulmadığı için yer tutucu görünüyordu.

**Kalan gerçek kusur: süre yanlış.** Çalışma 3:11 (191,226 sn) olmasına ve
`Studies-v1.json` bunu doğru tutmasına rağmen arayüz 0:16 gösteriyor.

Sebep ölçüldü ve dosyanın kendisinde: bu bir **parçalı MP4** (fMP4).
Atom yapısı `ftyp` + `moov`/`mvex` + 49 adet `moof`/`mdat` şeklinde ve:

- `mvhd.duration` = **0**,
- `mvex` içinde yalnız iki `trex` var, **`mehd` yok**,
- üst düzeyde **`sidx` yok**.

Yani dosya toplam süresini HİÇBİR YERDE bildirmiyor; süre ancak 49 parçanın
tamamı taranarak bulunur. Bizim çevrimdışı çözümleyicimiz (MediaExtractor)
dosyanın tamamını okuduğu için 191,2 sn buluyor. Chromium ise akarken
gördüğü kadarını bildiriyor: ölçümde süre oynatma ilerledikçe **büyüdü**
(5,53 → 11 → 16,5).

Bu, motorun ya da köprünün kusuru değil; medya elemanının bu dosya sınıfı
için verebileceği en iyi cevap. Ama sonucu gerçek: konum çubuğu, A/B
işaretleri ve grafiğin zaman ekseni yanlış bir toplam süreye göre çalışıyor.

**ÇÖZÜLDÜ — `load` sözleşmesine `duration` eklendi.** Doğru süre Kotlin ve
Swift taraflarında zaten vardı (`study.duration`, çevrimdışı çözümlemeden);
artık sayfaya açıkça bildiriliyor. `StudyViewer.html` yeni bir
`mediaDuration()` yardımcısı kullanıyor: bildirilen süre geçerliyse onu,
değilse `media.duration`'ı döndürür — yani alan gelmeyen eski göndericilerde
davranış birebir aynı kalır.

Değişiklik iki platformda birlikte gitti: kanonik `ipad/.../Resources/
StudyViewer.html` düzenlendi ve Android kopyasına byte-eşit kopyalandı,
`iPadStudyCommand.load` ve Kotlin `StudyCommand.Load` birer `duration`
alanı kazandı. macOS etkilenmiyor — o ayrı bir görüntüleyici kullanıyor
(`window.klariVisionStudyViewer`).

Doğrulama (SM-A736B): video çalışması **0:16 → 3:11**; oynatma 0:10'a
ilerliyor ve grafik eğriyi doğru zaman ekseninde çiziyor. Ses çalışması
gerilemedi (3:04, oynatma 0:09). iPad hedefi Mac Catalyst ile derleniyor.

**Bir yanlış iz kayda geçsin:** ölçüm sırasında bir kez
`PIPELINE_ERROR_DECODE: Failed to send audio packet for decoding` hatası
görüldü ve range sunucumuz suçlandı; range kapatılınca video oynadı, bu da
teşhisi doğruluyor gibi göründü. Tekrarlı ölçüm bunu ÇÜRÜTTÜ: range açık
beş turun beşinde de kod çözme hatası sıfır çıktı. Hata bir kerelikti,
sebebi belirlenemedi. Tek A/B turuna dayanarak kök sebep ilan etmenin
maliyeti burada görülüyor.


## Çıkış kapısı

**Geçmedi**, ama en ağır engel kalktı: Dinleme Modu'nun boş ekranı (B-2)
çözüldü ve grafik + oynatma cihazda çalışıyor.

Kapıyı hâlâ kapalı tutan tek kalem: A/B döngüsünde grafik ve konum donuyor
(B-9). B-11 kapandı.

Rota değişimi ve telefon kesintisi fiziksel donanım beklediği için hâlâ
koşulmadı; listenin geri kalanı koşuldu.

Otomatik kapıların hepsi yeşilken bu tablo görünmüyordu — yeşil kapı
tablosu, koşulmamış bir turun yerini tutmaz.
