# iOS/iPadOS ortak çekirdek fizibilitesi

Son güncelleme: 20 Ağustos 2026

Bu belge başlangıçtaki teknik spike sınırını ve 20 Ağustos otomatik kabul
kanıtını kaydeder. iOS/iPadOS ürünü D-034 ile yetkilidir; pitch sözleşmesinin tek
otoritesi C ABI v1'dir: `docs/PITCH_ENGINE_C_ABI_V1.md`.

## Sonuç

**iOS/iPadOS 17+ ürünü D-034 ile yetkilidir. Otomatik kapılar ile gerçek
iPhone ve iPad kritik ürün regresyonları geçti; yalnız fiziksel VoiceOver turu
kullanıcı kararıyla çalıştırılmadı.**

Yerel Xcode 26.2, iPhoneOS ve iPhone Simulator SDK'larını içerir. 13 Ağustos
smoke'ında aşağıdaki sekiz C++ kaynak, `-std=c++20`, `arm64-apple-ios14.0` ve
`arm64-apple-ios14.0-simulator` hedefleriyle yalnız geçici nesne dosyalarına
derlendi:

`analysis_engine`, `analysis_engine_c`, `mpm`, `pitch_engine_v2`,
`fixed_lag_tracker`, `pitch_engine_v2_session`, `swipe_prime`, `vpm_like`.

Her hedefte sekiz, toplam 16 Mach-O arm64 nesnesi oluştu; C ABI uygulaması
`analysis_engine_c.cpp` da bu duman testinin içindedir. Bu, kaynakların
platform bağımsız derlenebilirliğini gösterir; imzalı uygulama, gerçek cihaz
mikrofonu, arka plan davranışı veya App Store kabulü kanıtı değildir.

## Sabit sınırlar

- iOS tüketicisi yalnız C ABI v1'i bağlar: üç motor kimliği, 48 kHz mono
  Float32 PCM, `1536/512` pencere/hop, kaynak-pencere merkezi zamanı ve
  `create/reset/process/finish/destroy` yaşam döngüsü değişmez.
- `yin_v1`, `pitch_engine_v2` ve `vpm_like` Dinleme ve Çalma seçimlerinde eşit
  seçenekler olarak kalır. YIN'in ilk açılış tercihi yalnız geriye uyumludur;
  mobilde de öneri veya kalite sıralaması yapılamaz.
- iOS katmanı Python çalıştırmaz, motor eşiği taşımaz ve C++ kararını Swift'te
  yeniden üretmez. Paketlenmiş C++ sınırı tek analiz yoludur.
- Veriler yerel kalır. Ağdan içe aktarma, bulut eşitleme, paylaşım, puanlama
  ve referans-öğrenci karşılaştırması bu spike'ın ve mobil tasarımın dışındadır.

## Hedef mimari

| Katman | Sorumluluk | iOS/iPadOS yaklaşımı |
|---|---|---|
| `KlariVisionCore` | Pitch hesaplama ve ABI | Sekiz C++ kaynak + public `analysis_engine_c.h` ile cihaz/simulator için statik kütüphane/XCFramework. Swift yalnız C header'ını görür. |
| `PitchSessionAdapter` | PCM ve oturum yaşam döngüsü | Tek seri işleme hattı; cihaz formatını `AVAudioConverter` ile 48 kHz mono Float32'ye çevirir, tamamlanmış 1536 örnek pencereyi merkez kaynak zamanı ile C ABI'ye verir. Dur/arka plan/kesinti `finish`, sonra `destroy`; yeni başlatma yeni `create`/`reset` yapar. |
| Dinleme medya köprüsü | Yerel medya, A/B, zaman | `UIViewRepresentable` içindeki tek `WKWebView`; mevcut mesaj adları ve JavaScript canvas sözleşmesi korunur. Geniş/dar iPad yerleşimi aynı web görünümünü tekrar oluşturmaz. |
| Çalma | Mikrofon, kayıt ve canlı grafik | Platform adaptörü `AVAudioSession` + `AVAudioEngine` tap'i yönetir; C++ kareleri en çok mevcut sözleşmenin toplu akışıyla WebKit canvas'a taşınır. |
| Dosya/veri | Kullanıcı dosyaları ve önbellek | SwiftUI `fileImporter` ile alınan security-scoped URL kısa süre açılır, koordineli biçimde app-sandbox `Application Support` altına kopyalanır; kalıcı çalışma/önbellek yalnız bu kopyayı kullanır. Kullanıcı URL'si ve scope'u tutulmaz. |
| SwiftUI kabuk | Telefon/tablet yerleşimi | iPhone'da ardışık, iPad genişlikte medya+grafik yan yana; aynı durum modeli ve tek WebKit kimliği kullanılır. Sabit macOS pencere boyutları taşınmaz. |

### Medya, izin ve yaşam döngüsü riskleri

- Mikrofon için iOS'a özgü kayıt izni ve `NSMicrophoneUsageDescription` gerekir.
  Ses oturumu `.playAndRecord` politikasını, rota değişimini (Bluetooth dahil),
  örnekleme hızı değişimini, kesintiyi ve media-services resetini açıkça ele
  almalıdır. Donanım 48 kHz vermediğinde dönüştürme zorunludur.
- Kesinti veya arka plana geçişte mevcut kayıt temizce sonlandırılır, C++
  oturumu kapatılır ve grafikte sahte bağlama yapılmaz. Arka planda sürekli
  mikrofon/kayıt vaadi bu spike'ın parçası değildir; yeniden başlatma kullanıcı
  eylemi ve izin/oturum durumuna bağlıdır.
- `UIDocumentPicker`/`fileImporter` güvenlik kapsamı geçicidir. Medya ve yan
  analiz dosyalarını app sandbox'a kopyalamadan WebKit veya uzun analiz süreci
  için kaynak URL saklamak güvenli değildir. Kopya hatası kullanıcıya görünür
  yerel hata metni üretmelidir.
- `WKWebView` iOS'ta `UIViewRepresentable` olur. Yerel HTML `loadFileURL`
  için dar bir read-access köküyle açılır; JS köprüsü yalnız bilinen mesaj
  adlarını kabul eder. Canlı canvas'ın 30 Hz toplu iletimi ve teardown'da
  handler kaldırılması korunur.

## Mevcut Swift kaynaklarının paylaşılabilirlik haritası

| Kaynak | Kanıt | Değerlendirme | Spike sonrası hedef |
|---|---|---|---|
| `StudyModels.swift` | Foundation veri/parsing; yalnız gereksiz SwiftUI importu | Büyük ölçüde paylaşılabilir. `StudyPitchTrack` dosya okumasını iOS sandbox adaptörü çağırır. | `KlariVisionShared` saf Foundation modeli |
| `AppSettings.swift` | `PitchEngineSettings`, hex kalıcılığı paylaşılabilir; `NSColor`, `NSApplication`, macOS `Settings` içerir | Bölünmeli. Üç motor tercihi ve hex doğrulaması paylaşılır; tema renk dönüşümü/kabuk platforma özgü kalır. | shared preferences + iOS tema/kabuk |
| `LiveVisuals.swift` | `LiveScale`, makam, tüner ve grafik geometrisi saf; `NSViewRepresentable`, `NSView`, `NSColor`, `NSEvent` içerir | Bölünmeli. Müzik/geometry modelleri paylaşılır; Native AppKit grafik taşınmaz. Üretim WebKit grafiği `UIViewRepresentable` adaptörüne port edilir. | shared music/graph model + iOS WebKit adapter |
| `StudyWorkspace.swift` | PlaybackClock/Viewport/yerleşim hesabı saf; `NSSlider`, `NSViewRepresentable`, `WKWebView` kullanır | Bölünmeli. Saat/viewport korunur; dikey slider ve LocalViewer iOS'a ayrı yazılır. | shared playback model + iOS viewer |
| `PracticeViews.swift` | SwiftUI form mantığı; `AppKit` importu ve sabit macOS sheet ölçüleri | Kısmen paylaşılabilir. Form içeriği uyarlanabilir; pencere boyutları/iPad sunumu yeniden tasarlanır. | platform SwiftUI views |
| `LivePitchAnalyzer.swift` | AVFoundation/Accelerate ve C ABI adaptörü; `NSAlert`, `Process`, macOS test/diagnostic yolları | Bölünmeli. Frame türleri, sinyal kapısı, C ABI adapter protokolü paylaşılabilir; ses oturumu, izin, kayıt, hata sunumu iOS'a özgü olur. | shared analyzer domain + iOS audio adapter |
| `KlariVisionApp.swift` | `NSOpenPanel`, `Process`, macOS dosya kökleri ve split navigation | Taşınmaz. RecentLibrary veri şekli yeniden kullanılabilir, dosya alma/yerel analiz/persistence iOS adaptörü olur. | iOS app shell + document import service |
| `KlariVisionBridge.h` | Yalnız `analysis_engine_c.h` içe aktarır | Doğrudan yeniden kullanılabilir. | public C header/module map |

`rg` incelemesinin saptadığı başlıca macOS bağları: `NSOpenPanel`,
`NSApplication`, `NSAlert`, `NSColor`, `NSViewRepresentable`, `NSSlider`,
`NSEvent` ve `NSView`. Bunlar ortak Swift hedefe doğrudan alınmaz.

## D-034 öncesi Core Smoke planı — tamamlandı

İlk teknik aşamada tek amaçlı bir **iOS Core Smoke** hedefi planlandı. Bu
tarihsel giriş kapısı uygulandı ve ardından D-034 ürün yetkisiyle uygulama,
WebKit, dosya alma ve mikrofon dilimleri ayrıca tamamlandı.

1. C++ kaynaklarından cihaz arm64 ve simulator arm64 statik ürünleri oluştur.
2. Swift test hedefi C ABI'den `kv_pitch_contract_get_v1` çağırır; ABI v1,
   üç capability biti, 48 kHz, `1536/512` ve v2 beş-hop bilgisini doğrular.
3. Her üç motor için sentetik sessiz/tek pencere `create/process/finish/destroy`
   yaşam döngüsü çağrılır; sonuçta C++ eşik veya algoritma değiştirilmez.

### Giriş kapıları

- macOS çekirdeği ve Swift paket regresyonları yeşil kalır.
- iPhoneOS + simulator arm64 derlemesi ve C ABI kontrat testi geçer.
- Yeni hedef yalnız sürüm kontrollü sentetik veriyi kullanır; kullanıcı medya
  dizinleri ve `.numbers` çalışma kitabı dışarıda kalır.

### Çıkış kapıları

- Cihaz/simulator static-link ve kontrat testleri geçer.
- Üç motorun kimliği ve eşit kullanıcı-seçeneği politikası değişmeden kalır.
- iOS ses/dosya/WebKit kodu eklenmediği için yeni izin, veri göçü veya ürün
  davranışı oluşmaz.

Bu ilk kapılar, D-034 öncesindeki teknik spike için tasarlanmıştı; ürün başlatma
kararı sonradan kullanıcı tarafından D-034 ile verildi.

## Core Smoke uygulama durumu — 20 Ağustos

`ipad/KlariVisioniPadCoreSmoke.xcodeproj` eklendi. Statik `KlariVisionCore`
hedefi sekiz C++ kaynağıyla, Swift `KlariVisionCoreSmokeTests` ise doğrudan
`analysis_engine_c.h` ile bağlanır. Swift test gövdesi ABI v1'i, üç motor
capability bitini, 48 kHz mono Float32 / `1536/512` / V2 beş-hop bilgisini ve
her motorun üretim oturumunda `create → process → finish → reset → destroy`
yaşam döngüsünü çağırır.

20 Ağustos'ta iOS 17 iPad Pro 11 inç (4. nesil) arm64 Simulator'da aynı
`CoreSmokeTests.testContractAndEveryEngineLifecycle` gerçek çalıştırmada `1/1`
geçti. Final kaynakla generic iPhoneOS arm64 `build-for-testing`, uygulama ve
test bundle'ını üretti. Bu, önceki iPhoneOS/Simulator arm64 derleme ve arm64
Mac Catalyst Core Smoke kanıtlarını tamamlar.

## Ürün başlangıcı güncellemesi — 13 Ağustos

Kullanıcının açık ürün yetkisi D-034 olarak kaydedildi ve D-032'nin ürün
başlatılmaz sınırını iOS/iPadOS için geçersiz kıldı. Aynı proje içinde iOS/iPadOS
17+ ve iPhone+iPad (`TARGETED_DEVICE_FAMILY = "1,2"`) `KlariVisioniPad` hedefi
eklendi.
Bu hedef `KlariVisionCore` statik hedefine bağlanır; Ana Sayfa'nın iki eşit
mod kartı, regular genişlikte sidebar, compact genişlikte üç tab, Çalışmalar,
Ayarlar ve mod başına ayrı
kalıcı motor tercihini sağlar. Dosya alma/analiz, yerel medya/WebKit, mikrofon
ve kayıt dilimleri uygulandı; gerçek iPhone kabulü ve ardından gerçek iPad
regresyonu beklemektedir.

## Dinleme uygulama güncellemesi — 13 Ağustos

Yerel Dinleme dilimi eklendi. `fileImporter` güvenlik kapsamını yalnız
`NSFileCoordinator` ile Application Support/KlariVision/Imports'a UUID'li
kopya oluşturma süresince kullanır. `AVAssetReader` 48 kHz mono Float32 PCM
çıktısı verir; C ABI `kv_production_pitch_session_*` çağrıları 1536/512
pencerelerden gerçek offline-track karelerini üretir. Paketli mobil-safe
viewer, app-owned alanda tek `WKWebView` olarak yüklenir; medya playback,
seek, hız, A/B, loop ve takip komutlarını aynı görünümde tutar. Ağ, Python,
Process ve sahte analiz sonucu yoktur.

### ABI tüketici doğrulaması — 13 Ağustos

C ABI v1'in başarı dönüşü `1`, hata dönüşü `0` olarak mobil adapter'da
açıkça uygulanır. Production session'ın çıktı vektörü her `process_frame` ve
`finish` çağrısında değiştirildiğinden adapter her sonuç setini indeks `0`'dan
okur; kalıcı çıktı cursor'u yoktur. Arm64 Mac Catalyst gerçek XCTest'inde 440
Hz sentetik pencerelerle üç motorun contract/create/process/output/finish
yaşam döngüsü uygulama adaptörü üzerinden, ayrı Dinleme ve Çalma tüketicileri
için doğrulandı: 10/10 test geçti (0,106 sn). Offline biriktirici yalnız tam
1536 örneklik pencereyi ABI'ye verir; uzun pencere adapter testiyle reddedilir.
Çalma tap'i önce sahipli Float kopyasına dönüştürülür; dönüştürücü, kayıt ve
core yaşam döngüsü tek Swift 6 actor'ünde serileşir, UI yalnız MainActor'da
güncellenir. İki iOS arm64 build/link kapısı da bu düzeltmeden sonra yeniden
geçti.

## Çalma uygulama güncellemesi — 13 Ağustos

Canlı kullanım yalnız kullanıcı eylemiyle başlar. Mikrofon izni ve
`NSMicrophoneUsageDescription` tanımlıdır; `AVAudioSession` `.playAndRecord`
ve `.measurement` ile açılır. Input tap donanım biçimini `AVAudioConverter`
üzerinden 48 kHz mono Float32'ye dönüştürür. 1536/512 window/hop biriktiricisi
ve C ABI üretim oturumu üç motoru eşit biçimde çalıştırır; motor eşiği Swift'e
taşınmaz.

Canlı kareler yaklaşık 30 Hz batch ile tek yerel WebKit canvas'a gider; tüner,
kullanıcı seçimi makam/karar ve takip yereldir. WAV kayıt yalnız app-owned
Application Support/Recordings alanına yazılır. Kesinti, rota değişimi, arka
plan ve medya hizmeti reseti için tap kaldırılır, core `finish/destroy` edilir,
kayıt biter ve audio session kapanır; yeniden başlatma otomatik değildir.

## Ürün davranışı takip sözleşmesi — 13 Ağustos

Gezinme aktif mikrofonu gizli bırakmaz: Ana Sayfa dışı seçim canlı/kayıt
oturumunu durdurur; Çalışmalar dışı seçim ve arka plan playback'i duraklatır.
Playback idle timer politikası testte enjekte edilir ve önceki sistem değeri
mutlaka geri yüklenir. Makam/karar yalnız kullanıcı bağlamıdır: sekiz makam,
yedi karar, takip ve graph renkleri yerel Study/Live viewer'a kılavuz
frekanslar ve etiketlerle aktarılır; fiziksel frekans ve transpoze/gösterim
katmanı ayrıdır.

Uygulama çalışma kütüphanesi sadece app-owned import URL'si, metadata ve
cached karelerle atomik Codable dosyada saklanır; listeden kaldırma kullanıcının
medyasını veya cache dosyasını silmez. Canlı sinyal kapısı `-60…-20 dBFS`
aralığından C ABI minimum RMS'e dönüştürülür. 53-koma editörü 12 pozitif
aralık ve toplam 53 doğrulamasını, ayrıca varsayılan geri yüklemeyi sağlar.

## Ürün otomatik ve fiziksel kabul güncellemesi — 20 Ağustos

iOS 17 iPhone SE (3. nesil), iPad Pro 11 inç (4. nesil) arm64 Simulator'da ve
arm64 Mac Catalyst'te başlangıç `KlariVisioniPad` ürün XCTest tabanı `33/33`;
iPad Simulator C ABI smoke `1/1` geçti. Fiziksel kabul düzeltmeleri ve bağımsız
denetimde eklenen geç-viewer-hatası atomiklik testiyle final iPhone SE ürün
paketi `38/38` geçti. Yeni kapsam, tamamlanan app-owned WAV'ın
`Çalışmalara Ekle` ile seçili Dinleme motorunda analizini, kaynak kaydın
korunmasını, aynı oturumdaki tekilleştirmeyi ve hata sonrası yeniden denemeyi
doğrular. Generic
iPhoneOS arm64 `build-for-testing` başarılı oldu; iPhone SE portre
install-launch ve erişilebilirlik XXL Dynamic Type görsel smoke'ında üç tab ve
kaydırılabilir içerik korundu. iOS 26 iPad Pro 13 inç (M5)
Simulator'da final uygulama build/install/
launch edildi ve Ana Sayfa görsel smoke geçti. İlk gerçek Simulator derlemesi,
yalnız `iPadKarar.frequency` switch dönüş sözdizimi ile Optional `Double` test
karşılaştırmasındaki iki derleme kusurunu yakaladı; ikisi düzeltildi. Pitch
algoritması veya ürün davranışı değiştirilmedi.

Bu Simulator/Mac sonuçları otomasyon olarak kalır ve fiziksel cihaz kanıtı
sayılmaz. Ayrı fiziksel kabul, iPhone 15 Pro / iOS 26.6.1 ve iPad (9. nesil) /
iPadOS 26.6 üzerinde güncel imzalı build ile yapıldı. Dinleme medya, takip,
hız, seek ve 20 kısa A/B dönüşünde; Çalma üç motor, WAV aktarımı, Bluetooth,
interruption, background, rota/sidebar kapanışı ve yön değişiminde geçti.
VoiceOver turu çalıştırılmadı.

## Fiziksel kabul kapıları

| Sıra | Cihaz | Kabul kapsamı | Sonuç |
|---:|---|---|---|
| 1 | iPhone 15 Pro / iOS 26.6.1 | Ses/video, analiz, seek, hız, takip, 20 kısa A/B dönüşü | PASS |
| 2 | iPhone 15 Pro / iOS 26.6.1 | Mikrofon izin akışı, üç motor, WAV kayıt/Çalışmalar/yeniden dinleme | PASS |
| 3 | iPhone 15 Pro / iOS 26.6.1 | D-035 Bluetooth, interruption, background ve rota kapanışı | PASS |
| 4 | iPhone 15 Pro / iOS 26.6.1 + iPhone SE Simulator | Portre/landscape, safe area, küçük/büyük ekran, XXL Dynamic Type | PASS |
| 4a | iPhone 15 Pro / iOS 26.6.1 | VoiceOver odak/ad/değer/ipucu | NOT RUN — kullanıcı erteledi |
| 5 | iPad (9. nesil) / iPadOS 26.6 | Kritik akışlar, yön ve regular sidebar regresyonu | PASS |

VoiceOver satırı tamamlanmadan tam erişilebilirlik kapısı veya dağıtım hazırlığı
geçmiş sayılmaz. Motor terfisi ve kalıcı veri göçü yapılmadı.

### Fiziksel kusur ve yeniden kabul kaydı — 20 Ağustos 2026

- Dinleme takip penceresi gerçek playback'te ilerlemedi; hareketli zaman
  penceresi ve dikey takip düzeltildi, iPhone ve iPad'de geçti.
- İlk mikrofon tap callback'i Swift 6 izolasyon denetiminde uygulamayı kapattı;
  sahipli ve Sendable PCM kopyasıyla actor hattı ayrıldı, tekrar çökmedi.
- Retina ölçekte canvas backing yüksekliği eksikti; canlı eğri yalnız gerçek
  ses varken görünür ve üç motorda doğru güncellenir hale geldi.
- Bluetooth ayrıldıktan sonra restart yinelenen input tap ile
  `AVAudioEngineImpl::InstallTapOnNode` içinde çöktü; tap tam kabul eden node'dan
  kaldırılıyor ve teardown sonrası yeni engine kuruluyor. iPhone/iPad tekrarları
  geçti.
- Arka plan dönüşündeki iki stop kaynağı Restart'ı gri ve grafiği ölü
  bırakabiliyordu; analyzer tek lifecycle sahibi oldu ve restart erişilebilir
  kaldı. Fiziksel tekrar geçti.
- Bağımsız denetim, viewer geç hatasının erken kalıcı kayıt bırakabildiğini
  buldu. Viewer hazırlığı commit öncesine alındı; hata sonrası retry tek çalışma
  üretir ve kaynak WAV'ı korur. Final ürün testi `38/38` geçti. Bu kaynaktan
  komut satırı takım/bundle override'larıyla üretilen son imzalı build iPhone ve
  iPad'e kuruldu; iPhone'da WAV → Çalışmalar → oynatma ve tekrar-ekleme
  tekilleştirmesi fiziksel olarak yeniden geçti.
