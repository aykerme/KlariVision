# macOS App Store Yayın Planı

Tarih: 2026-09-13 · Dal: `android-ios-ui-parity-4` · Sürüm: 0.6.0 (7)

## Mevcut durum (kodda doğrulandı)

| Konu | Durum | App Store için anlamı |
|---|---|---|
| Paketleme | `scripts/build_beta_app.sh`: Xcode Release + PyInstaller motoru `Contents/Resources/Engine`, `codesign --deep --sign -` (ad-hoc) | Takım kimliği, sandbox yetkileri ve içten dışa imza gerekiyor; `--deep` App Store için uygun değil |
| Sandbox | `.entitlements` dosyası yok, `DEVELOPMENT_TEAM = ""` | **Engelleyici.** Mac App Store sandbox'ı zorunlu tutar |
| Harici süreç | Swift, `Process()` ile `Engine/KlariVisionEngine`'i; motor da `imageio_ffmpeg` içindeki `ffmpeg` ikilisini çalıştırıyor | Her Mach-O, `app-sandbox` + `inherit` yetkisiyle imzalanmalı |
| ffmpeg | `_internal/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1` pakette | **Engelleyici (lisans).** GPL ffmpeg derlemesi App Store koşullarıyla uyumsuz; ayrıca 5.2 kapsamında risk |
| Geliştirici yolları | `projectRoot()` / `pythonExecutable()` `.venv/bin/python`, `/usr/bin/python3`, `~/Documents/KlariVision`, `currentDirectoryPath` arıyor | Sandbox'ta çalışmaz, incelemede "harici kod çalıştırma" gibi görünür; Release'te kapatılmalı |
| Veri yolu | `runtime_paths.user_data_root()` → `~/Library/Application Support/KlariVision` | Sandbox'ta otomatik olarak konteynere düşer; sorun yok, doğrulanmalı |
| yt-dlp / linkten açma | Beta pakette hariç tutulmuş | App Store sürümünde koddan da erişilemez olmalı (Yönerge 5.2.3) |
| Info.plist | Mikrofon açıklaması var; `LSApplicationCategoryType`, `ITSAppUsesNonExemptEncryption` yok; sürüm sabit yazılı | Eksik anahtarlar eklenmeli |
| Gizlilik manifesti | `PrivacyInfo.xcprivacy` yok | UserDefaults / dosya zaman damgası API'leri için gerekli |
| Simge | `AppIcon.iconset` + `.icns` (1024 dahil) | Asset catalog'a taşınması önerilir |
| Mimari | Motor yalnız `aarch64` | Ya `ARCHS=arm64` (Intel Mac'ler kuramaz) ya universal2 motor |
| Lisans | Depo **AGPL-3.0** | Telif tamamen geliştiricide → engel yok |

## Durum (2026-09-13 akşam)

| Adım | Durum |
|---|---|
| Aşama 1 — sandbox, AVFoundation, universal | ✅ `android-ios-ui-parity-4`'e birleşti (e3dbcc2). Dosya izni `read-write` yapıldı (Kaydı Sakla) |
| Aşama 1b — TR/EN, Birlikte Çal gizli, nota adları | ✅ birleşti; WKWebView'de doğrulandı |
| Aşama 2 — mağaza metinleri | ✅ `metadata.md` (doğrulanmış özellikler, sınırlar betikle), `privacy.md` yeniden yazıldı |
| Ekran görüntüleri | ⏳ TestFlight derlemesinden; betik: `scripts/capture_app_store_screenshot.sh` |
| Yerel sandbox testi | ✅ `scripts/build_sandbox_test_app.sh`; açılışta ihlal yok. Dosya açma + kayıt saklama elle denenecek |
| App Store motoru (arm64) | ✅ ffmpeg'siz derlendi (52 MB), 57 sn kayıt 18 sn'de analiz edildi |
| Aşama 3 — imza, TestFlight | ⏳ Takım 9J2BC3Q77C. Eksik: Apple Distribution + Mac Installer Distribution sertifikası, Mac App Store Connect profili (`KV_PROVISIONING_PROFILE`), x86_64 Python (`KV_X86_PYTHON`), App Store Connect kaydı |
| Risk: motor `Contents/Resources` altında Mach-O | ⚠️ ilk `altool --validate-app`/Transporter doğrulamasında görülecek; reddedilirse motor `Contents/Helpers`/`Frameworks` düzenine taşınır |
| Açık kaynak lisans bildirimi | ⏳ uygulamaya eklenecek (`third-party-licenses.md`) |

Not: "Kaynakla Test" / pYIN karşılaştırma (`startReferenceTest`, `validateSourceDirectly`)
arayüzden çağrılmıyor; `--engine vamp` sorunu kullanıcıya görünmez, Sürüm 1'i etkilemiyor.

## Alınan kararlar (2026-09-13)

- ffmpeg çıkıyor; ses/video çözme işini AVFoundation yapacak.
- Universal sürüm (arm64 + x86_64); iki mimari için ayrı motor dizini, çalışma zamanında seçim.
- Telif tamamen geliştiricide; AGPL App Store dağıtımına engel değil.
- İlk sürüm ücretsiz ve reklamsız. Reklam hiç eklenmeyecek (macOS'ta AdMob yok; "veri toplanmıyor" beyanı korunacak).
- İkinci sürümde tek seferlik "Pro" kilidi (StoreKit 2) gelecek — bkz. "Sürüm 2 — Pro kilidi".
- Arayüz Türkçe + İngilizce olacak (Aşama 1b).

### Aşama 1b — Yerelleştirme (TR + EN)
- Haiku: metin envanteri → `docs/app-store/localization-inventory.md` (tamamlandı; Swift sayımı eksik görünüyor — 64 metin raporlandı, kaba taramada ~210 Türkçe karakterli satır var. Uygulamada tam tarama şart).
- Sonnet (Aşama 1 bittikten sonra, çakışmasın diye): Swift String Catalog (`Localizable.xcstrings`, geliştirme dili tr), `InfoPlist.xcstrings` (mikrofon açıklaması), SwiftPM `defaultLocalization`, motora dil argümanı ve grafik sayfası metinleri.
- Aynı iş paketinde: Sürüm 1 için "Birlikte Çal" mod seçim ekranından gizlenir. Tek bir derleme bayrağı/sabit (ör. `FeatureFlags.togetherModeEnabled = false`) üzerinden; `AppRoute.together`'a hiçbir yoldan (menü, klavye kısayolu, son çalışmalar, kayıtlı durum geri yükleme) ulaşılamadığı test edilir. Kod ve testleri silinmez.
- Mağaza metinleri ve ekran görüntüleri iki dilde, son derlemeden.

## Yalnız senin verebileceğin kararlar / yapabileceğin işler

1. **Apple Developer Program** üyeliği (bireysel mi şirket mi) ve Team ID.
2. **Kalıcı bundle id** — `com.aykerme.KlariVisionNative` ile mi yayınlanacak? App Store Connect'te kayıt açıldıktan sonra değişmez.
3. ~~Lisans~~ — karar verildi (telif geliştiricide).
4. ~~ffmpeg yerine ne?~~ — karar verildi (AVFoundation).
5. ~~Mimari~~ — karar verildi (universal).
6. **Bölgeler, yaş derecesi**; gizlilik politikası ve destek sayfası için yayınlanacak bir URL (fiyat: ücretsiz).
7. App Store Connect'te uygulama kaydını açmak, sertifika/profil oluşturmak, TestFlight'a yüklemek ve incelemeye göndermek.

## Aşamalar

### Aşama 1 — Sandbox uyumlu çekirdek (kod) · Sonnet
- `KlariVision.entitlements`: `com.apple.security.app-sandbox`, `device.audio-input`, `files.user-selected.read-only` (dışa aktarma varsa `read-write`). Motor ve alt ikililer için ayrı `Engine.entitlements`: `app-sandbox` + `inherit`.
- Xcode projesine entitlements ve `ENABLE_HARDENED_RUNTIME` bağlanması; `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` Info.plist'e değişkenle.
- Info.plist: `LSApplicationCategoryType = public.app-category.music`, `ITSAppUsesNonExemptEncryption = false`.
- `PrivacyInfo.xcprivacy` (Swift + PyInstaller tarafında kullanılan gerekçeli API'ler; veri toplanmıyor).
- Release derlemede geliştirici yollarının (`.venv`, `/usr/bin/python3`, `~/Documents/KlariVision`, `currentDirectoryPath`) `#if DEBUG` arkasına alınması.
- ffmpeg'i AVFoundation ile değiştirmenin etki analizi ve (karar sonrası) uygulaması; `yt_dlp` yolunun App Store derlemesinde kapalı olduğunun garanti edilmesi.
- `scripts/build_app_store.sh`: motoru `Contents/Resources/Engine` (veya `Contents/Helpers`) içine koyup her Mach-O'yu içten dışa `--options runtime --entitlements` ile imzalayan, `xcodebuild archive` + `-exportArchive` (method `app-store-connect`) yapan betik. Team ID ve kimlik ortam değişkeninden okunur.

### Aşama 2 — Lisans ve mağaza metinleri (doküman) · Haiku
- Paketlenen her bileşenin (Python, numpy, openpyxl, charset_normalizer, cffi, setuptools, ffmpeg, C++ çekirdek) lisans envanteri → `docs/app-store/third-party-licenses.md`; App Store ile çelişenlerin işaretlenmesi.
- App Store Connect metinleri (TR + EN): ad, alt başlık, açıklama, anahtar kelimeler, yenilikler → `docs/app-store/metadata.md`.
- Gizlilik politikası taslağı (veri toplanmıyor, mikrofon yalnız cihazda işleniyor) ve gizlilik "nutrition label" yanıtları → `docs/app-store/privacy.md`.
- İnceleme notu taslağı (mikrofon kullanımı, örnek ses dosyası, test adımları) ve ekran görüntüsü listesi (2880×1800 vb.) → `docs/app-store/review-notes.md`.

### Aşama 3 — İmza, TestFlight (sen + ben)
- Sertifikalar: *Apple Distribution* + *Mac Installer Distribution*; App Store Connect'te kayıt.
- `build_app_store.sh` ile arşiv → `xcrun altool --validate-app` / Transporter ile doğrulama → TestFlight (macOS).

### Aşama 4 — Sandbox'lı QA
- Temiz bir kullanıcı hesabında TestFlight kurulumu.
- Kontrol listesi: mikrofon izni ilk açılışta; Downloads/Desktop'tan ses ve video açma; analiz + yeniden analiz; uygulama yeniden açıldığında son çalışmaların geri gelmesi (dış dosyalar için security-scoped bookmark gerekebilir); Dinleme / Çalma modları, Birlikte Çal'ın hiçbir yoldan açılamadığı; Console'da `sandboxd` ihlali olmaması.
- **Sandbox riski (doğrulanmadı):** motor, Swift'in verdiği WAV'ın yanında kullanıcının seçtiği özgün dosyayı da okuyor (önbellek imzası için SHA-256 ve videoyu `data/imports`'a kopyalama). Bu dosyaya erişim kullanıcının dosya seçme panelinden geliyor. `inherit` ile başlatılan motorun bu erişimi devralıp devralmadığı TestFlight'ta Downloads/Desktop'tan video açılarak denenmeli. Devralmıyorsa imza ve kopyalama Swift tarafına alınmalı.
- **Sürümden önce var olan hata:** `LivePitchAnalyzer.swift` kaynak karşılaştırmasında motora `--engine vamp` veriyor ve `engine_cli.py` bunu reddediyor. Bu akış arayüzden çağrılmadığı için Sürüm 1'de görünmez; özellik açılırsa düzeltilmeli.

### Aşama 5 — Gönderim
- Ekran görüntüleri, metinler, gizlilik yanıtları, yaş derecesi, ihracat uyumu → incelemeye gönder.
- Olası ret sebepleri: gömülü yorumlayıcı (2.5.2 — kod indirmediğimiz sürece kabul edilir), eksik mikrofon açıklaması, sandbox ihlali, işlevsiz görünen özellikler.

## Sürüm 2 — Pro kilidi (ilk sürüm yayınlandıktan sonra)

Model: uygulama ücretsiz kalır; tek seferlik, tüketilmeyen (non-consumable) uygulama içi satın alma "KlariVision Pro" ek özellikleri açar. Abonelik yok, reklam yok.

### Açık kararlar
- **Karar (2026-09-13): "Birlikte Çal" modu Pro'ya ayrılıyor.** Sürüm 1'de mod **gizlenir** (kod silinmez); Sürüm 2'de yeni Pro özelliği olarak açılır.
- **Pro'ya başka hangi özellikler girecek?** Temel kural: ücretsiz sürüm tek başına işe yarar kalmalı (Dinleme ve Çalma temel akışları açık). Aday örnekler, kullanım verisi olmadan seçilmemeli: sınırsız kayıt kütüphanesi, A-B döngüsü / geri sayım gibi çalışma araçları, gelişmiş grafik ayarları, dışa aktarma.
- Fiyat kademesi ve bölgesel fiyatlandırma.
- Aynı Apple hesabında iOS/iPad sürümüyle ortak satın alma istenip istenmediği (evrensel satın alma bundle id kararlarını etkiler).

### Teknik iş listesi
- App Store Connect: *Paid Apps* sözleşmesi, vergi ve banka bilgileri (uygulama ücretsiz olsa da IAP için zorunlu); non-consumable ürün kaydı (`com.aykerme.klarivision.pro` gibi — ürün kimliği sonradan değişmez).
- StoreKit 2: `Product.products(for:)`, `purchase()`, `Transaction.currentEntitlements` ile açılışta yetki kontrolü, `Transaction.updates` dinleyicisi, **Satın Alımları Geri Yükle** düğmesi (Yönerge 3.1.1 gereği zorunlu).
- Tek bir `EntitlementStore` (ör. `@Published var isPro`) — özellik kilitleri yalnız buradan okunsun; görünümlere dağınık `if` yazılmasın.
- Yerel test için `.storekit` yapılandırma dosyası; TestFlight'ta sandbox hesabıyla satın alma / geri yükleme / iade senaryoları.
- Satın alma ekranı TR + EN; fiyat `Product.displayPrice` ile gösterilir (sabit yazılmaz).
- Gizlilik: satın almayı yalnız StoreKit işler ve uygulama kendi sunucusuna bir şey göndermezse "Data Not Collected" beyanının korunup korunamayacağı gönderim anında Apple'ın güncel tanımına göre yeniden kontrol edilmeli.

### Sürüm 1'e etkisi
- Sürüm 1'de kod değişikliği yok. Yalnız: yeni özellikler eklenirken hangisinin Pro adayı olduğu not edilsin; ilk sürümde ücretsiz verilen bir özelliği sonradan kilitlemek kullanıcı tepkisi doğurur — kilitlenecek özellikler ya Sürüm 2 ile yeni gelmeli ya da mevcut kullanıcılar için açık bırakılmalı (`AppTransaction.originalAppVersion` ile ilk sürümü indirenler ayırt edilebilir).
