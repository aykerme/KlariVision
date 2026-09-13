# ffmpeg'i AVFoundation ile değiştirme

Başlangıçta yalnız etki analizi istenmişti (PLAN.md, Aşama 1, madde 6);
kullanıcı kararıyla kapsam genişledi ve değişiklik uygulandı. Bu belge hem
analiz hem de gerçekleştirilen değişikliği ve doğrulama sonucunu içerir.

## Neredeydi: `imageio_ffmpeg`

`src/klarivision/local_app.py` içinde iki kullanım noktası vardı:

1. **`_to_wav(source, destination)`** — tek gerçek ses dönüştürme yolu.
   `imageio_ffmpeg.get_ffmpeg_exe()` ile pakete gömülü ffmpeg ikilisini
   bulup `-vn -ac 1 -ar 48000` bayraklarıyla kaynağı (video ya da
   sıkıştırılmış ses) 48 kHz mono PCM WAV'a çeviriyordu. `analyse_upload()`
   içinde çağrılıyor; `refresh_existing_viewer`/`reanalyse_existing_viewer`
   WAV'ı önbellekten okuyor, `_to_wav`'ı tekrar çağırmıyor — yani ffmpeg
   yalnız **ilk analizde** çalışıyordu.
2. **`_import_from_url(url)`** içindeki `yt_dlp` çağrısına `ffmpeg_location`
   olarak veriliyordu. Bu yol `--exclude-module yt_dlp` ile PyInstaller
   paketinden zaten çıkarılmıştı; App Store derlemesinde `yt_dlp` içe
   aktarılamaz, `_import_from_url` `ImportError` fırlatıp Türkçe bir hata
   mesajı döner. **Doğrulandı: linkten açma App Store paketinde koddan da
   erişilemez** — Yönerge 5.2.3 açısından ek bir işlem gerekmiyordu.

Motorun kendisi (C++ `pitch_track_cli` ve Python `extract_cpp_pitch`/`vamp`
yolları) yalnız WAV okur; ffmpeg'i hiçbir yerde doğrudan çağırmaz.

## Uygulanan değişiklik

- **`macos/KlariVision/Sources/KlariVisionApp/MediaToWAVConverter.swift`**
  (yeni dosya): `AVAssetReader` + `AVAssetReaderTrackOutput` ile kaynağın
  ilk ses parçasını 48 kHz mono 16-bit PCM'e çözüp `AVAudioFile` ile WAV
  yazan `MediaToWAVConverter.convert(source:destination:)`.
  `AVAssetReaderTrackOutput`'un kendi `outputSettings`'i örnekleme hızını ve
  kanal sayısını zaten hedefe düşürdüğü için ayrı bir yeniden örnekleme
  adımına gerek yok. Kaynak zaten `.wav`/`.wave` ise `prepareWAV(for:)`
  hiç çözmeden orijinal dosyayı döndürür.
- **`KlariVisionApp.swift`** (`analyseWithBundledEngine`) ve
  **`LivePitchAnalyzer.swift`** (`prepareOfflineReference`'ın paketlenmiş-motor
  dalı): motoru çağırmadan önce `MediaToWAVConverter.prepareWAV(for:)` ile
  WAV'ı hazırlayıp motora `--wav <path>` bayrağıyla veriyor; üretilen geçici
  WAV işlem bitince siliniyor (`cleanUpTemporaryWAV`).
- **`src/klarivision/engine_cli.py`**: yeni `--wav WAV` bayrağı,
  `analyse_upload`'a `precomputed_wav` olarak iletiliyor.
- **`src/klarivision/local_app.py`**:
  - `analyse_upload(..., precomputed_wav: Path | None = None)` — verilirse
    `_to_wav(precomputed_wav, wav)` çağrılır; `_to_wav` hedefin zaten WAV
    olduğunu görüp yalnız `shutil.copy2` yapar, ffmpeg'e hiç girmez.
  - `_to_wav`: kaynak zaten `.wav`/`.wave` ise doğrudan kopyalar;
    `imageio_ffmpeg` importu artık modül yüklenirken değil, yalnız gerçekten
    ffmpeg'e ihtiyaç duyulduğunda (geliştirici/CLI akışı, precomputed WAV
    verilmeden çağrıldığında) fonksiyon içinde yapılıyor. Böylece
    `imageio_ffmpeg`'in pakette bulunmadığı App Store derlemesinde
    `klarivision.local_app`'ı import etmek bile başarısız olmuyor.
  - `_import_from_url`: aynı gerekçeyle `imageio_ffmpeg` importu `yt_dlp`
    import'u başarılı olduktan sonra, fonksiyon içinde yapılıyor.
  - **`_persist_video_source` değişmedi** — hâlâ orijinal videoyu
    `data/imports/`'a `shutil.copy2` ile kopyalar; WAV artık `_to_wav`'dan
    değil Swift'in ürettiği dosyadan gelir.
- **`scripts/build_app_store.sh`**: PyInstaller adımından
  `--collect-all imageio_ffmpeg` çıkarıldı, `--exclude-module imageio_ffmpeg`
  eklendi. `yt_dlp` zaten dışlanmıştı. `scripts/build_beta_app.sh` ve
  Xcode'un "Embed bundled analysis engine" script fazı **bilerek
  değiştirilmedi** — beta paketi hâlâ ffmpeg taşıyor; yalnız App Store
  derlemesi (`build_app_store.sh`'ın ürettiği arşiv) ffmpeg'siz.
- **Geliştirici/CLI akışı bozulmadı**: `KlariVisionApp.swift`'in `#if DEBUG`
  arkasındaki yerel Python yolu (`analyseSelectedFileWithLocalPython`) ve
  `LivePitchAnalyzer.swift`'in paketlenmiş motor bulunamadığındaki `.venv`
  dalı hâlâ `analyse_upload`'ı `precomputed_wav` vermeden çağırıyor —
  dolayısıyla hâlâ ffmpeg'e düşüyor, tıpkı önceden olduğu gibi.

## Format kapsamı

`imageio_ffmpeg` mp4/mov/m4v/webm/mp3/m4a/aac/aiff/flac/wav/wave gibi geniş
bir kapsamı tek çözücüyle karşılıyordu. `AVAssetReader`, QuickTime/Core
Media'nın desteklediği kod çözücülerle sınırlı: mp4/mov/m4v/mp3/m4a/aac/
aiff/wav'ı native çözer, ama **webm (VP8/VP9/Opus) ve bazı eski/özel
codec'li avi/mkv dosyalarını çözemez**. Bu dosyalar hâlâ
`isSupportedMediaFile`'da (`KlariVisionApp.swift`) listeli; `AVAssetReader`
onlarla karşılaşırsa `MediaToWAVConversionError.noAudioTrack` ya da bir
`AVAssetReader` hatasıyla başarısız olur ve kullanıcı "Ses çözülemedi: …"
mesajını görür. **Açık karar noktası**: bu formatlar App Store sürümünde
`isSupportedMediaFile`'dan çıkarılıp desteklenmediği baştan mı
belirtilsin, yoksa mevcut hata mesajına mı güvenilsin?

## Doğrulama: örnek dosya karşılaştırması

`data/benchmarks/canli_pitch_referans_v1.wav`, ffmpeg ile AAC/m4a'ya
kodlanıp (128 kb/s) hem eski `_to_wav` (ffmpeg) hem de yeni
`MediaToWAVConverter` (küçük bir `swiftc` betiği ile ayrık çalıştırıldı; bu
dosya depoya eklenmedi) ile 48 kHz mono WAV'a geri çözüldü:

| | ffmpeg (eski) | AVFoundation (yeni) |
|---|---|---|
| Örnek sayısı | 1.142.784 | 1.142.400 |
| RMS | 4621.243 | 4622.020 |

Fark yalnız **384 örnek (~%0,034, ~8 ms)** — AAC kod çözücülerin encoder
gecikmesini/priming örneklerini nasıl işlediğine bağlı, iki taraf için de
normal bir sapma. Ortak önekte (`min(1.142.400, 1.142.784)` örnek)
örnek-başına ortalama mutlak fark **0,026** (int16 aralığı ±32767 üzerinden)
— pratikte hizalı ve neredeyse bit-birebir aynı. Bu, pitch analizi için
iki yolun da eşdeğer girdi ürettiğini gösteriyor; 8 ms'lik uç kayması
pYIN/C++ pencereleme payının çok altında.

## Doğrulama: testler

- `swift test` (macOS uygulaması): 49/49 geçti.
- `.venv/bin/python -m pytest tests -q`: 106 geçti, 5 atlandı (önceden de
  atlanan, bu değişiklikle ilgisiz testler), 0 başarısız.
- `tests/test_local_app.py`'ye iki yeni test eklendi:
  `test_to_wav_copies_a_wav_source_without_importing_ffmpeg` ve
  `test_analyse_upload_uses_precomputed_wav_instead_of_calling_to_wav` —
  ikincisi `imageio_ffmpeg.get_ffmpeg_exe`'yi çağrılırsa hata fırlatacak
  şekilde yamalıyor, precomputed WAV verildiğinde ffmpeg'e hiç
  girilmediğini doğruluyor.

## Açık karar noktaları

1. webm/avi/mkv desteği App Store sürümünde koddan mı çıkarılsın, yoksa
   mevcut "Ses çözülemedi" hata mesajına mı güvenilsin?
2. Beta paketi (`build_beta_app.sh`) de ffmpeg'siz hale getirilsin mi, yoksa
   yalnız App Store arşivi mi (şu an durum budur)?
