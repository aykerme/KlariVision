# Codex Görev Devri

Son güncelleme: 6 Eylül 2026

## Dış karşılaştırmada ölçüm hatası — 6 Eylül 2026

**Sonraki oturum bu bölümden başlamalı.** Klarnet dışı ötüm kapsaması iş
kalemine girildi ve kalemin dayanağının büyük kısmının ölçüm hatası olduğu
bulundu. Ayrıntı ve sayılar `TEST_BASELINE.md`'nin en üstünde, karar notu
D-038'in altında.

Özetle: `on_hop_grid` motorun karelerinin ~%33'ünü puanlamadan önce siliyordu;
pYIN referansları etkilenmiyordu, yani tablo tek yönde bozuktu. Düzeltilmiş
tabloda `unified_v1` RPA bach10'da 0,64 → **0,95**, vocadito'da ~0,63 →
**0,92**, mdb'de 0,31 → **0,47**. Oktav iddiası ayakta (mdb'de pYIN'in
3,4–7,2 katı daha az), çarpanı düzeltildi.

### Kalan açık, artık dar ve nicel

Geliştirme bölümünün tamamında (96 dosya), aralık içi ötümlü karelerin
kaderi: kaçırmanın baskın sebebi **sabit RMS kapısı (0,015)**, çekimserlik
değil — mdb'de %26,6'ya karşı %4,2, vocadito'da %14,6'ya karşı %2,0.

**Kalem kapatıldı (D-040).** Kapı olduğu yerde kalır. Projenin kendi donmuş
yargıcı kapıyı suçlamıyor (`adverse_v1` vetosunun 23 karesinde 0 kapı), kapının
baskın çıktığı tek yer yeniden sentezlenmiş dış stem'ler, ve o tabloya bakarak
eşik indirmek D-038'in yasakladığı hareket. Kalem yeniden açılacaksa gereken
yeni bir eşik denemesi değil, **ürün tarafından kanıttır**: sessiz çalınmış
gerçek bir klarnet kaydında kapının ne kadarını kestiğinin ölçümü.

### Bölme hazır

`data/benchmarks/external-pitch-split-v1.json` (`afe1d9abdb40bbc2`):
geliştirme 96 / holdout 72 / yedek 142. Koşucu `--split` alır ve hangi bölümden
üretildiğini tabloya yazar. Ayar yalnız `--split development` ile yapılır.

### Sonraki oturumun bilmesi gerekenler

- **Ölçüm hattı da ölçülmeli.** Bu turda üç ayrı ızgara hatası çıktı ve üçü de
  motorun kusuru gibi görünüyordu (çakışan yuvalar, kapsam dışı kalan baştaki
  sessizlik, `3,5e-18` faz artığı). `tests/test_external_pitch_benchmark.py`
  bunları bağladı; yeni bir ölçüt eklenirken aynısı yapılmalı.
- `unified_trace --diagnostic` kare başına ret gerekçesi verir; bir "neden bu
  nota yok" sorusu doğrudan buradan cevaplanır.
### Açık kalanlar

1. **iPad `xcodebuild`** — kod ve proje değişikliği yapıldı, doğrulama
   koşulmadı: bu makinede Xcode'da iOS platformu kurulu değil. Kurulunca ilk
   iş budur.
2. **`adverse_v1` vetosu** (23 kare, sınır 12). Artık gerekçesi de ölçülü:
   17 `unvoiced`, 2 `contested`, 2 `abstain-recovery`, 0 RMS kapısı. Ucuz ayar
   yok; ölçülüp reddedilen altı kol tekrar denenmemeli.
3. **Küçük borç:** `pitch_candidate.hpp`'nin `klarivision::core::v2` ad alanı;
   mekanik yeniden adlandırma.

## Faz 7 tamamlandı — `swipe_prime` `FrameSpectrum` üstüne katlandı — 6 Eylül 2026

`swipe_prime.cpp` kendi pencere/FFT/interpolasyon kopyasını taşıyordu (216 →
153 satır) ve aynı history'yi karede ikinci kez dönüştürüyordu.
`swipe_prime_harmonic_supports()` artık ham örnek yerine hazır bir
`FrameSpectrum` alır; çağıran `harmonic_evidence.cpp` ona `spectra.low`'u
verir — SWIPE′ adayı **kendi** parçalılarına karşı puanladığı için pencere en
düşük frekansı çözebilmeli ve düşük bant zaten tam history penceresidir.

SWIPE′ çekirdeği değişmedi. sqrt sıkıştırması hâlâ interpolasyondan **önce**
yapılır; tersi çekirdeği değiştirirdi. Tek davranış farkı bin çözünürlüğü
(kendi FFT'si 4096, `FrameSpectrum` 4× dolguyla 16384).

**Ölçüldü, varsayılmadı:** temiz ve oda holdout'ları bit düzeyinde aynı;
adverse holdout'ta ciddi eksik ötüm **24 → 23**, sent farkı +0,003; ciddi
harmonik hata beş holdout'un bütün varyantlarında hâlâ sıfır. Çevrimdışı iz
%2,7 hızlandı. Sayılar `TEST_BASELINE.md`'nin en üstünde.
`ACCEPTED_VETO_MISSING_VOICED_FRAMES` 24 → 23'e indirildi.

### Sonraki oturumun işleri — öncelik sırasıyla

1. **Klarnet dışı ötüm kapsaması** (D-038'den devam, kullanıcı bu turu
   onayladı). Dış karşılaştırmada RPA 0,315–0,635, pYIN 0,66–0,99; fark
   neredeyse tamamen voicing recall — perde doğru ölçülüyor, yayımlanmıyor.
   **Sıra önemli:** önce ayrı bir doğrulama kümesi ayrılır, sonra girilir.
   Dış tablo elimizdeki tek ayarlanmamış ölçüttür; ona bakarak ayar yapmak onu
   ölçüt olmaktan çıkarır.
2. **iPad `xcodebuild`** — bu makinede iOS platformu kurulu olmadığı için
   koşulamadı (kullanıcı en sona bıraktı). Kurulduğunda ilk iş budur.
3. **`adverse_v1` vetosu** (23 kare, sınır 12): ucuz ayar yok, mimari iş
   gerekir; ölçülüp reddedilen altı kol `TEST_BASELINE.md`'de, tekrar
   denenmemeli.
4. **Küçük borç:** `pitch_candidate.hpp`'nin ad alanı hâlâ
   `klarivision::core::v2`; mekanik yeniden adlandırma.

## Faz 6 tamamlandı — dört eski motor silindi (D-039) — 6 Eylül 2026

Kullanıcı kararıyla D-037'nin nihai hedefi uygulandı. **Sonraki oturum bu
bölümden başlamalı.**

### Yapılanlar

- **C++:** `hapt`, `vpm_like`, `pitch_engine_v2`, `pitch_engine_v2_session`
  kaynakları/başlıkları/testleri/araçları silindi. `analysis_engine.cpp`
  2120 → 284 satır: geriye oturum yaşam döngüsü, pencereleme ve çevrimdışı
  stray-run temizliği kaldı; her perde kararı artık `unified_*` dosyalarında.
  Paylaşılan aday sözlüğü `pitch_candidate.hpp`'ye taşındı.
- **ABI:** v1 **mutasyona uğratılmadı**. 0–3 kimlikleri ve yetenek bitleri
  rezerve; kaldırılmış kimlikle create **hata döner** (hayatta kalan motora
  yönlendirilmez). `kv_v2_session_*` sembolleri duruyor ve temiz başarısız
  oluyor. `v2_fixed_lag_frames` rezerve alan olarak `5` bildirmeye devam ediyor.
- **UI:** macOS ve iPad'de motor seçicileri kaldırıldı; yerine ne çalıştığını
  söyleyen tek satır kondu. Kaldırılmış motoru adlandıran kayıtlı seçimler
  `unified_v1`'e düşüyor; **çözümlenmiş çalışmalar kendi motor kimliklerini
  koruyor** ve görüntüleyici onları "(kaldırıldı)" etiketiyle gösteriyor.
- **Swift:** V2/VPM/YIN Swift aynaları, parite dışa aktarımları, karşılaştırma
  grafiği (`LiveGraphDisplay`, yin/autocorrelation benchmark kareleri) ve
  `ExperimentalHarmonicJumpGate` silindi. Canlı yol tek dal: C++ üretim
  oturumu.
- **Turnuva:** artık seçim değil ölçüm. `benchmark_winner`/`default_engine`/
  `outcome` kaldırıldı; güvenlik kapısı aynı eşikle mutlak orana çevrildi
  (`SAFETY_RATE_LIMIT = 0.005`).
- **Silinen geliştirme araçları:** v2/vpm parite denetimleri, VPM kalibrasyonu,
  Şükrü Tunar VPM tanılaması, motor ayrışma haritası (+HTML şablonu),
  `run_pitch_regression_suite.py` (canlı-YIN ↔ pYIN kapısı) ve iki `evaluate_*`
  tüketicisi, `pitch_track_cli --diagnostic`.

### Bu turda bulunan iki gerçek kusur

**macOS ve iPad Xcode projeleri `unified_*` kaynaklarını hiç derlemiyordu.**
D-037'den beri her iki uygulama da kazanan motoru bağlayamazdı; `build_beta_app.sh`'de
aynı hata bir önceki oturumda bulunmuştu, proje dosyalarında kalmıştı. İkisi de
düzeltildi ve macOS Debug derlemesi geçti.

### Sonraki oturumun işleri — öncelik sırasıyla

1. **iPad hedefi bu makinede derlenemedi:** Xcode'da iOS 26.5 platformu kurulu
   değil. Kod ve proje değişikliği yapıldı, `xcodebuild` doğrulaması
   **koşulmadı**. Platform kurulduğunda ilk iş budur.
2. **Faz 7 —** `swipe_prime.cpp`'nin `FrameSpectrum` üstüne katlanması, ardından
   `graphify update .`.
3. **Klarnet dışı ötüm kapsaması** (D-038'den devam). Dış karşılaştırmada
   RPA 0,315–0,635, pYIN 0,66–0,99; fark neredeyse tamamen voicing recall.
   **Uyarı:** dış tabloya bakılarak ayarlanamaz — o tablo elimizdeki tek
   ayarlanmamış ölçüt. Önce ayrı bir doğrulama kümesi ayrılmalı.
4. **`adverse_v1` vetosu** (D-038'den devam): 24 kare ciddi eksik ötüm, sınır
   12. Artık teste sabitlendi (`ACCEPTED_VETO_MISSING_VOICED_FRAMES = 24`), yani
   büyürse kırmızıya döner. `TEST_BASELINE.md`'de ölçülüp reddedilen altı kol
   kayıtlı; **tekrar denenmemeli**, mimari iş gerekir.
5. **Küçük borç:** `pitch_candidate.hpp`'nin ad alanı hâlâ
   `klarivision::core::v2`. Mekanik bir yeniden adlandırma; motor silme
   commit'ini okunabilir tutmak için ayrı bırakıldı.

### Sonraki oturumun bilmesi gereken tuzaklar

- **Turnuvanın kıyas tarafı artık yeniden üretilemez.** D-038'in koruduğu
  `benchmark_winner=vpm_like` satırı yalnız `outputs/` altındaki raporlarda
  kayıtlıdır. Bu, kararın bilinen bedelidir; "kaybolmuş" bir sonuç değildir.
- Sayısal eşikler donmuş holdout'lara bakılarak seçildi. Hangi sabitin
  `frozen-no-retuning-after-first-result`, hangisinin `diagnostic-may-be-retuned`
  olduğu `TEST_BASELINE.md`'de yazılı.
- `KLARIVISION_PITCH_TRACK_CLI` ayarlı değilse `build/klarivision-pitch-track-cli`
  kullanılır ve **bayat kalabilir**; sabitler değiştiğinde yeniden derlenmeli.
- `outputs/` altındaki motor izleri farklı derlemelerden kalmış olabilir;
  kıyaslamadan önce tazelenir.
- Motor davranışını değiştiren her tur, üç yerde birden duran gecikme sabitini
  senkron tutmalı: `unified::kDefaultLagFrames`,
  `scripts/pitch_tournament_engines.py:UNIFIED_DEFAULT_LAG_FRAMES` (C++
  varsayılanını **gölgeler**) ve `src/klarivision/pitch/cpp_engine.py`.

## Dokümantasyon ve kaynak açıklama turu — 20 Ağustos

Ana `README.md`, macOS/mobil README'leri ve metin mimari özeti güncel ürün
durumuna göre sadeleştirildi; beta.1, çevrimiçi link akışı ve “mobil ürün yok”
gibi geçersiz yönlendirmeler kaldırıldı. Tarihsel kabul/karar kayıtları kanıt
zinciri oldukları için silinmedi; ana README bunları güncel kaynaklardan açıkça
ayırıyor.

`docs/architecture.html`, ağ bağımlılığı olmayan responsive geliştirici rehberi
olarak eklendi. Katmanlar, dosya analizi, canlı mikrofon, yaşam döngüsü, veri
sahipliği ve kod haritasını gömülü SVG grafikler/tablo/kartlarla açıklar. Bütün
üretim Swift dosyalarına dosyanın görevi, veri akışı, sahiplik ve güvenlik
sözleşmesini anlatan başlık yorumları; iki mobil viewer HTML'ine Swift ↔
JavaScript API sınırı eklendi. Her fiziksel kod satırını tekrar eden yorumlarla
ikiye katlamak yerine karar ve akış açıklamaları kullanıldı; bu seçim kaynak
okunabilirliğini korur.

Kullanıcının devam talebiyle aynı HTML rehberine pitch motorları bölümü eklendi.
YIN v1, Pitch Engine v2 ve VPM-benzeri motorların aday üretme, spektral kanıt,
zaman sürekliliği, release/boşluk ve yayın adımları iki yeni SVG akış şemasıyla
gösterilir. Swift motor seçiminden C ABI v1'e, `ProductionPitchSession`'a ve
motorun gerçek C++ kaynak dosyalarına kadar kod çağrı zinciri ile canlı/dosya
veri akışı ayrıca eşleme tablosunda kayıtlıdır. HTML parse ve yinelenen DOM
kimliği denetimi temizdir; pitch davranışı veya eşikleri değiştirilmedi.

Kaynak kontrolüne alınmayan yerel sentetik WAV corpus'u olmayan temiz çalışma
ağacında Python paketi artık fixture bağımlı iki entegrasyon testini açık
gerekçeyle atlar. Böylece uygulama ve birim testleri, kişisel/yerel veriyi
Git'e ekleme zorunluluğu olmadan tekrarlanabilir kalır.

Bu turda pitch motoru, eşikleri ve kalıcı veri biçimi değişmedi. SwiftUI güncel
API denetiminde bulunan tek eski `onChange(of:perform:)` kullanımı modern
sıfır-parametreli closure'a geçirildi. C++ `scripts/test_core.sh`, Python
`79 passed`, macOS Swift Package `44 passed / 2 skipped`, macOS imzasız Debug
Xcode derlemesi ve evrensel iOS Simulator `build-for-testing` geçti. HTML parse,
yerel Markdown bağlantıları ve `git diff --check` temizdir. Sıradaki tek ürün
işi değişmedi: gerçek iPhone VoiceOver odak/ad/değer/ipucu kabul turu.

## `unified_v1` kazanan ilan edildi — 6 Eylül 2026 (oturum sonu)

Karar D-038, sayılar `TEST_BASELINE.md`'nin en üst bölümünde. Sonraki oturum bu
bölümden başlamalı.

### Bu oturumda yapılanlar

- **Karar gecikmesi 15 hop (160 ms) → 5 hop (53,3 ms).** 160 ms'nin gerekçesi
  ölçümle çürüdü: harmonik hata 5–25 hop arasında her değerde sıfır, sent
  hassasiyeti üç ondalığa kadar aynı. Değer **üç yerde birden** durur ve üçü
  ayrı düşerse turnuva gönderilenden başka bir motoru ölçer:
  `unified::kDefaultLagFrames`, `scripts/pitch_tournament_engines.py`
  (`UNIFIED_DEFAULT_LAG_FRAMES` — C++ varsayılanını **gölgeler**) ve
  `src/klarivision/pitch/cpp_engine.py`. Üçü de güncellendi, uyarı yorumları
  yazıldı.
- **Tam turnuva yeni değerle yeniden koşuldu.** Ciddi harmonik hata hâlâ 0;
  veto hâlâ tek dosya. `fingerprint=00a55e42…`.
- **Yeni kurulum varsayılanı `unified_v1`.** macOS `PitchEngineSettings.initialEngine`
  ve iPad `iPadAppState.engine(_:)` yedeği. Mevcut kurulumlar kendi kayıtlı
  seçimlerini korur.
- **Üç bayat kayıt düzeltildi:** `LiveNotationTests.swift` beş motor eklendiğinden
  beri kırmızıydı; `scripts/build_beta_app.sh` `unified_*` kaynaklarını
  derlemiyordu (beta paketi link edemezdi); `tests/test_cpp_engine.py`
  sözleşme stub'ı 15'i sabitlemişti.

Doğrulandı: `scripts/test_core.sh` temiz, `pytest` 127 geçti / 1 atlandı,
`swift test` (macos/KlariVision) 50 test / 2 atlandı / **0 hata**, tam sentetik
turnuva koşuldu.

### Sonraki oturumun işleri — öncelik sırasıyla

1. **Klarnet dışı ötüm kapsaması.** Dış karşılaştırmada RPA 0,315–0,635, pYIN
   0,66–0,99; fark neredeyse tamamen voicing recall. Perde doğru ölçülüyor,
   yayımlanmıyor. **Uyarı:** bu, dış tabloya bakılarak ayarlanamaz — o tablo
   elimizdeki tek ayarlanmamış ölçüt. Önce ayrı bir doğrulama kümesi ayrılmalı,
   sonra girilmeli.
2. **`adverse_v1` vetosu.** Kullanıcı şimdilik kabul etti ama kapanmadı: ciddi
   eksik ötüm 24 kare, sınır 12. `TEST_BASELINE.md`'de ölçülüp reddedilen altı
   kol kayıtlı (düşük register onayı, geçiş genişliği, yapışkan kurtarma,
   gecikme, ötüm tabanları, emisyon kalibrasyonu) — hiçbiri kımıldatmıyor.
   Ucuz ayar yok; mimari iş gerekir. Kollar tekrar denenmemeli.
3. **Faz 6 — dört eski motorun silinmesi** (D-037'nin nihai hedefi) ve
   `analysis_engine.cpp:538-689` ölü kodu. ABI numaraları 0–3 kalıcıdır,
   yeniden numaralandırılmaz.
4. **Faz 7 —** `swipe_prime.cpp`'nin `FrameSpectrum` üstüne katlanması,
   ardından `graphify update .`.

### Sonraki oturumun bilmesi gereken tuzaklar

- Sayısal eşikler donmuş holdout'lara bakılarak seçildi. Dış tablo onların
  **zarar vermediğini** gösterir, onları haklı çıkarmaz. Hangi sabitin
  `frozen-no-retuning-after-first-result`, hangisinin `diagnostic-may-be-retuned`
  olduğu `TEST_BASELINE.md`'de yazılı — yeni bir ayar turuna girmeden önce
  okunmalı.
- Turnuvanın `benchmark_winner=vpm_like` / `outcome=candidate_requires_parity`
  satırları **kasten** öyle bırakıldı. Kazanan ilanı ürün kararıdır (D-038),
  ölçümün üstüne konur; ölçümü yeniden yazmak bu ayrımı yok eder.
- `KLARIVISION_PITCH_TRACK_CLI` ayarlı değilse `build/klarivision-pitch-track-cli`
  kullanılır ve **bayat kalabilir**. Sabitler değiştiğinde yeniden derlenmeli;
  `pytest` sözleşme testi bunu yakalamaz (stub kullanır).
- `outputs/` altındaki motor izleri farklı derlemelerden kalmış olabilir;
  kıyaslamadan önce tazelenir.

## Birleşik motor `unified_v1` — 6 Eylül 2026

Beşinci motor eklendi ve her seçim yüzeyine kaydedildi; `yin_v1` varsayılan
olarak kaldı. Karar gerekçesi ve kalıcı sözleşmeler `docs/DECISIONS.md` D-037,
ölçülmüş sonuç `docs/TEST_BASELINE.md`'dedir.

Özet sonuç: oktav tuzağı paketinin üç varyantında da **ciddi harmonik hatası
sıfır** olan tek motor; donmuş dinleyici kararlarının 85 aralığının tamamında
sıfır yeni kusur; sentetik oturum testlerinde %100 kapsama. Gerçek kayıtta
kapsama sevkiyattaki motorla başabaş (%77,9 / %86,5 / %78,5 karşısında %79,5 /
%87,1 / %80,8), iki kayıtta hiç harmonik uyuşmazlık yok.

Doğrulandı: `zsh scripts/test_core.sh`, `pytest` (128 test), macOS `xcodebuild`
Debug derlemesi, `quick_pitch_check.py`.

### Sıradaki tek somut iş

`scripts/run_external_pitch_benchmark.py` yazılacak.
`scripts/fetch_external_pitch_datasets.py` hazır ve hangi kümenin gerçekten
indirilebilir olduğunu kaydediyor (MDB-stem-synth, PTDB-TUG, vocadito
otomatik; MIR-1K erişim kısıtlı). Runner `mir_eval.melody` ile RPA, RCA, GPE,
voicing recall/false alarm raporlamalı; **RPA − RCA** birinci sınıf sütun
olmalı, çünkü o fark tanımı gereği oktav hata oranıdır ve bu proje için en
bilgilendirici tek sayıdır.

Bu takım bir **iddia kapısıdır, ayar hedefi değildir**: klarnet yargıçları neyi
optimize ettiğimizi söyler, bu küme neyi bozmadığımızı. Sayıları kaydedilir ve
gerilememesi beklenir; doğrudan onlara karşı ayar yapılmaz. Motoru genel amaçlı
diye adlandırıp yalnız klarnetle ölçmek, ölçülmemiş bir iddiadır.

Ondan sonra: eski dört motorun tek commit'te silinmesi (D-037'deki ABI kuralına
uyarak) ve `analysis_engine.cpp:538-689` ölü kodunun temizlenmesi.

## Aktif handoff özeti

Evrensel iPhone+iPad dönüşümü kod ve otomatik test düzeyinde tamamlandı.
`KlariVisioniPad` hedefi iOS/iPadOS 17+ için `TARGETED_DEVICE_FAMILY = "1,2"`
kullanır. iPhone compact genişlikte üç sekmeli `TabView`, iPad regular
genişlikte mevcut `NavigationSplitView` düzenini kullanır. Dinleme ve Çalma
rotaları aynı kök state ve kalıcı `WKWebView` nesneleriyle çalışır; bundle
kimliği, UserDefaults anahtarları ve `Studies-v1.json` değişmedi.

Tamamlanan WAV kaydı artık Çalma ekranındaki `Çalışmalara Ekle` eylemiyle
canlı oturum güvenle kapatıldıktan sonra seçili Dinleme motoruyla analiz edilir
ve Çalışmalar'da açılır. Başarılı aktarım aynı uygulama oturumunda yinelenmez;
hata kaynak WAV'ı korur ve görünür yeniden deneme sunar. `Studies-v1.json`,
UserDefaults ve C ABI biçimleri değişmedi.

Son otomatik durum: generic iPhoneOS arm64 `build-for-testing` başarılı;
başlangıçtaki iOS 17 iPhone SE, iPad Pro 11 ve Mac Catalyst ürün tabanı
`33/33`, iPad Simulator C ABI smoke `1/1` geçti. Fiziksel kabulde bulunan
düzeltmeler ve son atomik retry denetimiyle iPhone SE ürün testleri `38/38`
geçti (`/private/tmp/KlariVisionFinalAudit.xcresult`). C++ core testleri geçti,
Python `79 passed`, macOS Swift Package `44 passed / 2 skipped` sonucundadır.
Pitch motoru/eşikleri değiştirilmedi; `TEST_BASELINE.md` bu nedenle
güncellenmedi.

Fiziksel kabul 20 Ağustos'ta iPhone 15 Pro / iOS 26.6.1 ve iPad (9. nesil) /
iPadOS 26.6 üzerinde güncel imzalı build ile yapıldı. Dinleme; ses/video,
playback/seek/hız, takip ve 20 kısa A/B dönüşünde geçti. Çalma; üç motor, WAV
kayıt, `Çalışmalara Ekle`, Bluetooth, interruption, arka plan, rota/sidebar
kapanışı ve yön değişiminde geçti. iPad kritik regresyonu ve regular sidebar
davranışı da geçti. Büyük iPhone safe area, portre/landscape ve XXL Dynamic
Type geçti. **VoiceOver fiziksel turu kullanıcı kararıyla çalıştırılmadı; PASS
sayılmaz.** Sıradaki tek somut iş VoiceOver odak/ad/değer/ipucu kabulüdür.

Bağımsız atomiklik düzeltmesinden üretilen son imzalı build, proje dosyasına
takım kimliği yazılmadan `DEVELOPMENT_TEAM=9J2BC3Q77C` ve
`com.aykerme.KlariVisionMobileAcceptance` komut satırı override'larıyla hem
iPhone'a hem iPad'e kuruldu. Bu build'de iPhone üzerinde kısa WAV kayıt,
`Çalışmalara Ekle`, Dinleme'de oynatma ve aynı kaydı yeniden eklememe fiziksel
olarak tekrar geçti.

## Mobil kabul sonucu ve açık iş

Fiziksel kullanım sırasında beş gerçek ürün kusuru bulundu ve aynı cihazlarda
yeniden kabul edildi: Dinleme takip penceresi, Swift 6 ses-tap izolasyon çökmesi,
Retina canlı canvas yüksekliği, Bluetooth sonrası yinelenen tap/restart çökmesi
ve arka plan dönüşündeki gri Restart/ölü grafik yarışı. Son build'de bu tekrar
adımlarının tümü geçti; crash logları Bluetooth kusurunu
`AVAudioEngineImpl::InstallTapOnNode` içinde doğrulamıştı.

Bağımsız kod denetimi ayrıca viewer'ın geç hata vermesi halinde çalışmanın
erken kaydedilebildiğini buldu. Viewer hazırlığı kalıcı kayıt öncesine alındı;
geç hata + retry artık tam olarak bir `Studies-v1.json` kaydı üretir ve yeni
testle doğrulanır. Kaynak WAV korunur.

Tamamlanan fiziksel bloklar: iPhone Dinleme; iPhone Çalma ve yaşam döngüsü;
iPhone yön/safe area/XXL Dynamic Type; iPad Dinleme, Çalma, WAV aktarımı,
Bluetooth/interruption/background/yön ve regular sidebar regresyonu. Tek açık
kapı **gerçek iPhone VoiceOver** turudur. Kullanıcı bu maddeyi ertelediğinden
mobil kabul bütünü “koşullu geçti” olarak kaydedilir; VoiceOver çalıştırılmadan
tam erişilebilirlik PASS'i veya TestFlight/App Store hazırlığı iddia edilmez.

## Son sonuç

20 Ağustos 2026'da güncel yerel çalışma ağacından
`dist/KlariVision Beta.app` yeniden paketlendi. PyInstaller motor paketi ve
arm64 macOS Release derlemesi başarılıdır; paket sıkı ad-hoc imza denetimini
geçti. Paketli `klarivision-pitch-track-cli --contract` sorgusu ABI v1,
`offline_track_v1`, 48 kHz ve `yin_v1` / `pitch_engine_v2` / `vpm_like`
üçlüsünü doğruladı. Kaynak anı `v0.6.0-beta.3-dirty` olduğundan bu çıktı,
etiketten sonraki korunmuş yerel değişiklikleri de içerir. Sıradaki tek somut
ürün işi değişmedi: gerçek iPhone'da VoiceOver odak/ad/değer/ipucu kabul
turunu tamamlamak.

13 Ağustos son entegrasyon doğrulaması tamamlandı: çekirdek testleri, tam
Python paketi (`79 passed`, bir Python `cgi` kullanım ömrü uyarısı), Swift
paketi (`44 passed`, iki isteğe bağlı çapraz-dil parite dışa aktarma testi
atlandı), imzasız Debug ve imzasız Release geçti. Beta paketleme betiği C ABI
uygulamasını komut satırı aracına da bağlayacak biçimde düzeltildi; yeniden
üretilen paket sıkı ad-hoc imza denetimini geçti. CLI `--contract`, ABI v1,
`offline_track_v1` profilini ve üç eşit motoru doğruladı. Kilidi açık Mac'teki
P1 erişilebilirlik kabul listesi de tamamlandı; yeni P0/P1 bulunmadı. Bu
kabul kaydı, `v0.6.0-beta.3` kaynak kontrol noktasıyla etiketlendi.

13 Ağustos odaklı WebKit yeniden kabulü tamamlandı ve beta kapısı **geçti**.
C++ kontrolleri, 77 Python testi, 41 Swift testi, imzasız Debug ve Release
paketleme geçti. Video ilk oynatma/başa dönüşü, 20'den fazla kısa A/B dönüşü,
A/B sırasında 20 pencere küçültme-büyütme, yalnız-ses grafiği ve canlı
mikrofon grafiği çalıştı. Kullanıcının son kesintisiz fiziksel kontrolünde
grafik akıcılığı, Finder sürükle-bırak, uygulama geneli tema, yalnız-ses
grafiğinden oynat/duraklat ve çalışmadan çıkınca medyanın durması olumlu
doğrulandı. Önceki arayüz bloklayıcıları güncel beta paketinde yeniden
üretilemedi.

Geçen ana akışlar: açılış, dosya seçiciyle analiz, oynatma, A/B loop işlevi,
Ayarlar/Uygula/Bitti/53-koma koruması, eski `.vamp.json` bulunmayan ses,
YIN v1 canlı perde davranışı, mikrofon kaydı ve WAV yeniden dinleme, V2 r4 ve
VPM r5 temel gerçek cihaz kontrolleri. YIN v1, Pitch Engine v2 ve VPM-benzeri
eşit son kullanıcı seçenekleridir; YIN'in ilk açılışta seçili gelmesi yalnız
geriye uyumluluk içindir.

## Motor seçim politikası

Üç kullanıcı motoru Dinleme ve Çalma Modu ayarlarında aynı nötr adlarla
görünür ve her modun seçimi ayrı saklanır. Çalışma önbelleği motor kimliği ile
`offline_track` profil sürümünü taşır; motor değişimi eski eğriyi yeniden
kullanmaz. Turnuva/parite raporları regresyon kanıtıdır, ürünün motor önerisi
veya terfi mekanizması değildir.

Tam kabul kaydı ve tekrar adımları:
`docs/BETA_ACCEPTANCE_CHECKLIST.md`.

## Sürüm kontrol noktası — v0.6.0-beta.3

13 Ağustos 2026'da erişilebilirlik kabulünü de içeren kaynak durumu
`v0.6.0-beta.3` annotated etiketiyle donduruldu. C++ çekirdek testleri,
tam Python paketi (`79 passed`), Swift Package (`44 passed`, iki isteğe bağlı
parite dışa aktarma testi atlandı), imzasız Release paketleme, sıkı ad-hoc
imza doğrulaması ve paketli `pitch-track-cli --contract` bu kaynakta yeniden
geçti. Kontrat ABI v1, `offline_track_v1` ve üç eşit motor kimliğini doğrular.
`v0.6.0-beta.2` değiştirilmeden önceki kontrol noktası olarak korunur. Paket
`dist/KlariVision Beta.app` olarak yerelde üretilir; kullanıcı verileri ve
paket ikilisi Git'e alınmaz.

## macOS kontrol noktası sonrası durum

Swift ayrıştırması tamamlandı; kaynaklar ayarlar, çalışma modelleri/medya
köprüsü, Çalma görünümleri, canlı analiz ve görsel/tüner desteği olarak
ayrıldı. Her dilimde Swift testleri ve imzasız Debug derlemesi geçti; UI
smoke Mac kilitli olduğunda otomatik olarak koşturulamadı. D-030, D-027'nin
WebKit üretim yolunun D-025'teki eski SwiftUI Canvas anlatımını geçersiz
kıldığını açıklar.

Erişilebilirlik turu ve `v0.6.0-beta.3` kaynak kontrol noktası tamamlandı.
Zorunlu açık ürün işi yoktur. Kullanıcı isterse sıradaki tek somut iş,
beta.3 için yeni fiziksel kullanım geri bildirimi toplamaktır. Referans–öğrenci
karşılaştırması geliştirilmez; üç motor eşit son kullanıcı seçenekleri olarak
kalır.

Mobil ürün, kullanıcı yetkisiyle iOS/iPadOS 17+ için başlatıldı (D-034); aynı
hedef iPhone ve iPad'i kapsar. Generic iPhoneOS arm64 `build-for-testing`
başarılıdır. İlk `28/28` ürün tabanı WAV aktarımı ve fiziksel kabul regresyon
testleriyle finalde `38/38` oldu. iPhone SE Simulator küçük ekran/XXL Dynamic
Type otomasyonunu; gerçek iPhone ve iPad yukarıda kayıtlı kritik akışları geçti.
Simulator fiziksel kanıt sayılmaz; yalnız gerçek iPhone VoiceOver turu açıktır.

Android ürünü de başlatılmaz. Yerel Android SDK/NDK/CMake/Gradle yoktur; araç
kurulmayacaktır. Kullanıcı ayrıca yetki verirse ilk Android işi yalnız
`ANDROID_FEASIBILITY.md` içindeki arm64-v8a NDK Core Smoke + JNI kontrat
testidir; Compose, ses, dosya, WebView veya dağıtım eklenmez.

Ek sınır: Ortak C++ pitch ABI v1 donduruldu; yeni tüketici C
`kv_pitch_contract_get_v1` veya Python CLI `--contract` doğrulamasını kullanır.

Üç kullanıcı motorunun eşit kabul raporu
`PITCH_ENGINE_USER_OPTION_ACCEPTANCE_V1.md` ile günceldir. Sonraki fiziksel
oturum yalnız aynı protokolün klarnet/mikrofon/WAV satırlarını yeniler; motor
terfisi veya varsayılan değişimi yapmaz.

## P1 erişilebilirlik turu — 13 Ağustos

Swift kod denetimi; ikon denetimlerinde VoiceOver adı, Dinleme/Çalma durum
değerleri, nötr motor Picker ipuçları, `⌘O`, güvenli sürükle-bırak ret metni
ve Reduce Motion düzeltmelerini içerir. Swift Package: 44 test geçti, 2
isteğe bağlı çapraz-dil dışa aktarma testi atlandı; imzasız Debug ve Release
derlemeleri geçti. Kilidi açık Mac'te `⌘O`, medya ve A/B denetimleri,
VoiceOver ad/değer/ipucu zinciri, üç nötr motor seçicisi, üç tema ve Reduce
Motion denetlendi. Mikrofon izin isteği beklemede kaldığı için canlı kayıt ve
Finder destekli bırakmada aynı beta paketinin önceki geçen fiziksel kanıtı;
desteklenmeyen bırakmada Swift testi ve ret-yolu denetimi kullanıldı. Yeni
P0/P1 yoktur ve kalıcı kontrol listesinde açık madde kalmamıştır:
`docs/ACCESSIBILITY_ACCEPTANCE_CHECKLIST.md`.

## iOS/iPadOS fizibilitesi — 20 Ağustos

Sekiz C++ core kaynağı, C ABI uygulaması dahil, iPhoneOS ve iPhone Simulator
arm64 için derlendi/bağlandı. D-034 ile iPhone+iPad ürünü yetkilidir; teknik kapılar
artık gerçek Simulator XCTest'i, iPhoneOS arm64 `build-for-testing` ve iOS 26
uygulama görsel smoke'ını da kapsar. Paylaşılabilir Swift modelleri ve
ses/izin/dosya/WebKit/lifecycle kabul sınırları:
`docs/IOS_IPADOS_FEASIBILITY.md`.

İlk iPad UI/UX tasarım paketi `docs/ipad-ui-ux/` altında tamamlandı: 13
yüksek sadakatli SVG ekran, kritik durum panosu, birincil akış ve uygulanabilir
yerleşim/erişilebilirlik sözleşmeleri içerir. Aynı projedeki `KlariVisioniPad`
uygulama hedefi iOS/iPadOS 17+ için aynı `TARGETED_DEVICE_FAMILY = "1,2"`
ürünüdür, `KlariVisionCore` statik hedefine bağlanır ve Ana Sayfa'nın iki eşit
mod kartını, regular genişlikte sidebar'ı, compact genişlikte üç tabı,
Çalışmalar'ı, Ayarlar'ı ve mod başına ayrı kalıcı motor seçimini içerir.
Dummy analiz sonucu üretmez. Uygulama ile `KlariVisioniPadTests` iPhoneOS
arm64 için final `build-for-testing` ile üretildi; iOS 17 arm64 Simulator'da
ürün testi `18/18` geçti. Testler motor tercihlerinin bağımsızlığını, güvenli
varsayılanı, eşit nötr etiketleri ve takip/persistence/müzik bağlamını doğrular.

## iPad Dinleme dikey dilimi — 13 Ağustos

`fileImporter` yalnız ses/video UTType'larını alır. Security-scoped URL yalnız
`NSFileCoordinator` ile Application Support/KlariVision/Imports altına UUID
adlı app-owned kopya alınırken açıktır; kullanıcı URL'si tutulmaz. Kopya ve
tür hataları ile analiz ilerlemesi görünür yerel durumdur.

`AVAssetReader`, ses yolunu 48 kHz mono Float32 PCM olarak açar; tamamlanmış
1536/512 pencereleri seçili C ABI üretim oturumuna verir ve yalnız çekirdeğin
döndürdüğü pitch karelerini taşır. Python/Process/ağ ve sahte sonuç yoktur.
Paketlenmiş `StudyViewer.html`, Application Support altındaki viewer kopyası
olarak tek `WKWebView`'de yüklenir; responsive yeniden yerleşim görünümü
oluşturmaz. Yerel medya oynatma, seek, hız, A/B, loop, takip ve kapat/duraklat
teardown'ı çalışır. Uygulama/test bundle final iPhoneOS arm64
`build-for-testing` ile üretildi; ürün XCTest'i iOS 17 arm64 Simulator'da
`18/18` geçti.

P0 ABI tüketici düzeltmesi: C ABI başarı değeri `1`, hata değeri `0`'dır ve
üretim oturumunun çıktı vektörü her `process`/`finish` çağrısında yenilenir.
iPad tüketicileri bunu `iPadProductionPitchSession` adaptöründe tekleştirir ve
her çıktı setini sıfırıncı indisten okur. 20 Ağustos'ta 440 Hz sentetik
pencerelerle üç motorun contract/create/process/output/finish yaşam döngüsü
hem Dinleme hem Çalma tüketicisinde doğrulandı: arm64 Mac Catalyst ve iOS 17
arm64 Simulator ürün XCTest'leri ayrı ayrı `18/18` geçti. Offline biriktirici,
her ABI çağrısına tam 1536 örnek verir; daha uzun buffer adapter tarafından
reddedilir. Çalma tarafında PCM tap verisi önce sahipli Float kopyasına alınır;
dönüştürücü, kayıt, üretim oturumu ve bitiriş tek Swift 6 actor'ünde serileşir;
UI bildirimi MainActor'a döner.

## iPad Çalma dikey dilimi — 13 Ağustos

Kullanıcı eylemiyle başlayan Çalma akışı `NSMicrophoneUsageDescription`,
mikrofon izni ve `.playAndRecord`/`.measurement` ses oturumunu kullanır.
`AVAudioEngine` input tap'i, donanım biçimini `AVAudioConverter` ile 48 kHz
mono Float32'ye dönüştürür; 1536/512 pencere biriktiricisi seçili C ABI
üretim oturumuna gider. Üç motor eşit kullanıcı seçeneğidir.

Canlı kareler yaklaşık 30 Hz toplu olarak tek `WKWebView` canvas'a taşınır;
native tüner ile kullanıcı seçimi makam/karar ve takip denetimi görünür.
WAV kayıt app-owned Application Support/Recordings altında gerçek yazılır ve
başlatıldı/tamamlandı/yazma hatası durumlarını gösterir. Kesinti, rota
değişimi, arka plan ve media-services reset tap'i kaldırır, motoru
`finish/destroy` eder, kaydı bitirir, ses oturumunu kapatır ve idle timer'ı
eski durumuna getirir. Yeniden başlatma yalnız kullanıcı eylemidir; arka
planda sürekli mikrofon yoktur.

## iPad ürün güvenliği ve müzik bağlamı — 13 Ağustos

Sidebar ile Ana Sayfa dışına geçiş, görünmeyen canlı oturumu/kaydı async
durdurur; Çalışmalar dışına geçiş ve arka plan, yerel playback'i duraklatır.
Study playback'in `isPlaying` snapshot'ı enjekte edilebilir idle-timer
politikası üzerinden süre aşımını açıp önceki değere geri döndürür. Sekiz
kullanıcı seçimi makam (Majör, Minör, Nihavend, Kürdi, Uşşak, Hicaz, Hicazkâr,
Kürdilihicazkâr), yedi karar ve takip tercihi hem canlı hem dosya graph'ına
kılavuz frekans/etiket olarak gider; fiziksel pitch karesi değiştirilmez ve
otomatik makam tespiti yapılmaz.

Analiz edilmiş çalışmalar yalnız app-owned URL, başlık, motor, makam/karar,
tarih ve cached karelerle atomik `Studies-v1.json` listesinde tutulur; tekrar
açma analiz yapmaz, listeden kaldırma medya veya pitch verisini silmez.
Ayarlar canlı `-60…-20 dBFS` kapısını C ABI minimum RMS'e dönüştürür; ortak
pitch/kılavuz renkleri iki yerel viewer'a iletilir; 12 pozitif aralık/toplam
53-koma doğrulaması ve varsayılan geri yükleme vardır. Takip dilimi
state/persistence/müzik testleri 20 Ağustos'ta arm64 Mac Catalyst ve iOS 17
arm64 Simulator ürün XCTest'lerinde `18/18` geçti.

İlk gerçek Simulator derlemesi yalnız iki derleme kusurunu açığa çıkardı:
`iPadKarar.frequency` switch'inde eksik `return` ifadeleri ve Optional
`Double` test karşılaştırması. İkisi düzeltildi; pitch veya ürün algoritması
değişmedi.

## Sıradaki tek iş — gerçek iPhone, ardından iPad kabulü

Önce gerçek iPhone'da import/analiz/playback/seek/hız/A-B, mikrofon izni
(kabul/ret), üç motor, WAV, kulaklık/Bluetooth rota, interruption/background
ve yön değişimi sürekliliğini kabul et; ardından aynı kritik akışları gerçek
iPad'de regresyonla. Simulator veya Mac mikrofonu fiziksel kanıtın yerine
geçmez; bu iki kapı görülmeden TestFlight/App Store dağıtımı yapılmaz.

## Android fizibilitesi — 13 Ağustos

Android SDK/NDK, Gradle, CMake ve Ninja yerelde bulunamadı; Android smoke
çalıştırılmadı ve kurulum yapılmadı. NDK CMake komutu, JNI/AudioRecord/WebView/
SAF/lifecycle tasarımı, üç eşit motor sınırı ve Android RTF/test kapıları:
`docs/ANDROID_FEASIBILITY.md`. Koşullu sonuç yalnız teknik spike için go,
tam Android ürün için no-go'dur. Karar D-033'tür.
