# KlariVision macOS — Apple İnceleme Notları Taslağı

Sürüm 0.6.0 (7) · Taslak tarihi 2026-09-13

> Bu metin App Store Connect → App Review Information → Notes alanına girer.
> Gönderimden önce ffmpeg'in paketten çıkarılmış ve sandbox'lı TestFlight
> derlemesinin doğrulanmış olması gerekir (bkz. `PLAN.md`). Lisans veya iç
> yapılacaklar Apple'a yazılmaz; not yalnız uygulamanın bugünkü hâlini anlatır.

## 1. Notes alanı (İngilizce)

```
KlariVision is a practice tool for clarinet and other melody instruments in
Turkish makam music. It draws the pitch contour of what is played against the
degrees of the selected makam. The interface is available in Turkish and English.

No account, sign-in, network access, analytics or in-app purchase.
All analysis runs on the Mac.

MICROPHONE
Used only while Playing Mode is active, to draw the live pitch curve. Audio is analysed in memory. It is written to
disk only when the user explicitly starts a recording.

BUNDLED ANALYSIS ENGINE
File analysis runs in a helper executable inside the app bundle
(Contents/Resources/Engine). It is signed with the app's team identity,
sandboxed and inherits the app's sandbox. It contains a native C++ pitch
tracker and an embedded Python runtime used only for the app's own bundled
modules. No code is downloaded, and users cannot run or install scripts.

HOW TO TEST
1. Launch the app and choose Listening Mode.
2. Open the attached sample file (File dialog). A pitch curve appears after
   analysis (a few seconds).
3. Go back and choose Playing Mode. Allow microphone access when asked.
4. Play or sing a sustained note; the live curve follows it.
```

Karakter sınırı 4000; yukarıdaki metin bunun çok altında.

## 2. İnceleme için hazırlanacaklar

- [ ] 20–40 saniyelik telifsiz örnek kayıt (tercihen kendi klarnet kaydın, `.m4a` veya `.wav`). App Review Information'a ek olarak yüklenir veya herkese açık bir bağlantı verilir.
- [ ] İletişim adı, telefon, e-posta (App Review Information alanları).
- [ ] Notes metnindeki mod adlarının son derlemedeki ekran metinleriyle aynı olduğunun kontrolü.

## 3. Ekran görüntüleri

Kabul edilen boyutlar (16:10): 1280×800, 1440×900, 2560×1600, 2880×1800. Dil başına en az 1,
en fazla 10. Görüntüler **TestFlight derlemesinden** alınır: analiz motoru yalnız imzalı
pakette gömülü, Xcode Release derlemesinde Dinleme Modu analiz yapamaz.

Yakalama: `zsh scripts/capture_app_store_screenshot.sh <ad> <tr|en>` — pencereyi 1440×900
noktaya getirir, gölgesiz yakalar, `dist/app-store-screenshots/<dil>/` altına yazar (git
dışı). Uygulamayı dil için `open -a KlariVision --args -AppleLanguages "(en)"` ile aç.

| # | Ad | Ekran | Hazırlık |
|---|---|---|---|
| 1 | `01-calma-modu` | Çalma Modu: canlı eğri + tüner | Nihavend, karar La; birkaç uzun nota çal, eğri ekranda dururken yakala |
| 2 | `02-dinleme-modu` | Dinleme Modu: kayıt eğrisi, video yan yana | Kendi telifsiz klarnet kaydın (video varsa daha iyi); A-B işaretleri görünür |
| 3 | `03-makam-ekseni` | Aynı kayıt, makam ekseni seçili | Kürdilihicazkâr ya da Hicaz; koma rehberi açık |
| 4 | `04-makam-araliklari` | Ayarlar: makam aralıkları (53 koma) | Dinleme Modu Ayarları penceresi açık |
| 5 | `05-baslangic` | Mod seçimi + kütüphane | Kenar çubuğunda 3–5 çalışma, adları anlamlı |

İngilizce setinde **Nota adları: C D E**, Türkçe setinde **Do Re Mi** seçili olsun. Birlikte
Çal Sürüm 1'de gizli; hiçbir görüntüde görünmemeli. Kütüphanede kişisel dosya adları
görünüyorsa önce çalışma adlarını düzenle.

İsteğe bağlı: 15–30 saniyelik App Preview videosu (Çalma Modu en güçlü görüntü).

## 4. Gönderim akışı

1. `scripts/build_app_store.sh` → arşiv + `ExportOptions.plist` (method `app-store-connect`). App Store derlemesi **notarize edilmez**; imza ve doğrulamayı App Store Connect yapar.
2. Transporter veya `xcrun altool --upload-app` ile yükle → TestFlight'ta sandbox'lı QA (PLAN.md Aşama 4).
3. Metinler (`metadata.md`), gizlilik yanıtları (`privacy.md`), yaş derecesi, ihracat uyumu (`ITSAppUsesNonExemptEncryption = false`).
4. Build'i seç → Notes'u yapıştır → Submit for Review.

## 5. Olası ret sebepleri

| Sebep | Önlem |
|---|---|
| 2.5.2 — yürütülebilir kod | Motor yalnız paketlenmiş modülleri çalıştırıyor; kod indirme veya kullanıcı betiği yok. Notes'ta açıkça yazıyor |
| 2.4.5 — sandbox / yardımcı süreç | Motordaki her Mach-O `app-sandbox` + `inherit` ile imzalı; Console'da `sandboxd` ihlali olmadığı TestFlight'ta doğrulanır |
| 5.1.1 — izin açıklaması | `NSMicrophoneUsageDescription` mevcut; izin yalnız mikrofon kullanan modda istenmeli |
| 2.1 — işlev çalışmıyor | Örnek dosya + adım adım test talimatı; temiz hesapta TestFlight denemesi |
| 2.3 — metadata doğruluğu | Sürüm 1'de gizli olan Birlikte Çal hiçbir metin veya ekran görüntüsünde geçmez; İngilizce mod adları son derlemeyle aynı |
