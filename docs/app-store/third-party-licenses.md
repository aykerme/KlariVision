# KlariVision macOS — Üçüncü Taraf Lisansı Envanteri

> **Güncelleme (2026-09-13, birleştirme sonrası):**
> - **ffmpeg App Store paketinden çıktı.** Ses/video çözme AVFoundation'a geçti;
>   `scripts/build_app_store.sh` PyInstaller adımında `--exclude-module imageio_ffmpeg`
>   kullanıyor. Aşağıdaki "Uyumsuz" satırı yalnız beta paketi (`build_beta_app.sh`) için geçerli.
> - **Telif:** depo kodunun telifi tamamen geliştiricide; AGPL App Store dağıtımına engel değil.
> - **Açık iş:** BSD/MIT/PSF lisansları bildirimin dağıtılan kopyayla birlikte verilmesini
>   ister. Uygulamaya bir "Açık kaynak lisansları" metni (ör. Hakkında penceresi ya da
>   paket içinde `Acknowledgements.txt`) eklenmeli.
> - **`charset_normalizer` ve `cffi` paketten çıktı:** ikisi geliştirme ortamındaki fazladan
>   paketlerden sızıyordu, motor kullanmıyor. `build_app_store.sh` dışlıyor; App Store motor
>   paketinde yalnız Python runtime, numpy, openpyxl (+ et-xmlfile), setuptools ve C++ CLI var.

**Hukuki Uyarı:** Bu belge bilgilendirme amaçlıdır ve hukuki tavsiye değildir. App Store uyumluluğu ve lisans riskleri hakkında nihai karar Sahibi ve hukuki danışman tarafından alınmalıdır.

**Hazırlık Tarihi:** 2026-09-13  
**Sürüm:** KlariVision macOS 0.6.0 (build 7)  
**Paketleme Yöntemi:** PyInstaller 6.10+ `Contents/Resources/Engine/` → `KlariVisionEngine/_internal/`

---

## Özet

| Durum | Sayı |
|---|---|
| Uyumlu (App Store'da yayınlanabilir) | 6 |
| Risk (GPL binary, açık kaynak koşul) | 1 |
| Uyumsuz (GPL, App Store koşullarıyla çelişir) | 1 |
| Doğrulanamadı (dist-info metadata yok) | 2 |

---

## Bileşen Tablosu

| # | Bileşen | Sürüm | Lisans | Kaynak | App Store | Gerekçe / Risk |
|---|---------|-------|--------|--------|-----------|-----------------|
| 1 | Python (CPython runtime) | 3.12.x | PSF License | PyInstaller 6.10+ dağıtımı | ✅ Uyumlu | PSF License (Python Software Foundation) App Store'da kabul edilir; tek başına derleme |
| 2 | setuptools | (vendor, exact version unknown) | MIT | `_internal/setuptools/` | ✅ Uyumlu | MIT licensed, OSI approved; yalnız build-time gereksinim sonrası kaldırılabilir |
| 3 | NumPy | 2.4.6 | BSD-3-Clause + multi-license (MIT, Zlib, 0BSD, CC0) | `_internal/numpy-2.4.6.dist-info/METADATA` | ✅ Uyumlu | İç kaynaklar multiple permissive licenses; hepsi App Store friendly |
| 4 | openpyxl | 3.1.5 | MIT | `_internal/openpyxl-3.1.5.dist-info/LICENCE.rst` | ✅ Uyumlu | MIT license, OSI approved |
| 5 | imageio-ffmpeg (wrapper) | 0.6.0 | BSD-2-Clause | `_internal/imageio_ffmpeg-0.6.0.dist-info/LICENSE` | ⚠️ Risk | Wrapper BSD-2-Clause; *ancak* içerdiği ffmpeg binary GPL |
| 5b | **ffmpeg binary (gömülü)** | 7.1 aarch64 | GPL (v2 or v3) | `_internal/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1` | ❌ Uyumsuz | GPL derlemesi App Store Distribution Agreement (§5.2 "restrictions on code") ve SDK koşullarıyla **uyumsuz** |
| 6 | charset-normalizer | (unknown, paketlendi) | (unknown, metadata yok) | `_internal/charset_normalizer/` | ❓ Doğrulanamadı | dist-info metadata'sı paketlenmemiş; muhtemelen imageio-ffmpeg/yt-dlp bağımlılığı; OSS proje ama lisans eksik |
| 7 | cffi | (unknown, paketlendi) | (unknown, metadata yok) | `_internal/_cffi_backend.cpython-312-darwin.so` | ❓ Doğrulanamadı | dist-info metadata'sı paketlenmemiş; numpy/geliştirici araçları kullanır; MIT/Apache likely (open source) |

---

## Lisans Riski Analizi

### 1. **GPL ffmpeg Binary — Engelleyici Uyumsuzluk**

**Sorun:**  
- `imageio_ffmpeg` paketi, dağıtım paketinde **GPL v2 veya v3** ffmpeg ikilisini içerir
- macOS App Store Distribution Agreement §5.2: *"no Source Code (or any modified version thereof) shall be distributed except in object code form under a license that permits the end-user to use such object code"*
- GPL, kaynak kodu sunmadan kapalı uygulamada çalıştırılan binary'yi yasaklar

**Etki:**  
- Dosya analizi (`.mp3`, `.wav`, `.m4a`) ffmpeg'i kullanır
- ffmpeg olmadan ses dosyası deşifre edilemez

**Olası Çözümler (Aşama 1'de karar gerekli):**
1. ffmpeg'i **AVFoundation** (`AVAssetReader`) ile değiştir → Türkçe iOS/macOS frameworkü, proprietary ama mülkiyetinde
2. yt-dlp'yi kaldır (zaten App Store paketi filtrelendi)
3. Apple Silicon aarch64 binary'sine geç (GPL attribution gerektirebilir, ancak bağlı hala sorun)

---

### 2. **Repository Lisansı — AGPL-3.0-or-later**

**Durum:**  
- Temel kod AGPL-3.0; network service'te dağıtılacak değil (desktop app)
- **App Store dağıtımında sorun değil** çünkü binary kapalı, kaynak yüklenmez

**Not:**  
- Sahibi tüm telif haklarını mı kontrol ediyor? Öyleyse App Store kopyasını ayrı lisansla yapabilir (ticari lisans, proprietary)
- Üçüncü taraf koda bağımlıysa (scipy, librosa vb.) AGPL uyumluluğu kontrol edilmeli

---

### 3. **Eksik Metadata — Doğrulama Başarısız**

**charset-normalizer:**
- Paketlendi (PyInstaller bağımlılık analizi)
- dist-info'si PyInstaller'dan çıkarılmış
- Muhtemelen MIT/Apache (open source)
- **Doğrulama Gerekli:** PyInstaller cache'inden METADATA bulabilir

**cffi:**
- NumPy ve geliştirici araçları tarafından kullanılır
- Standalone binary (`_cffi_backend.cpython-312-darwin.so`)
- **Doğrulama Gerekli:** https://pypi.org/project/cffi/ → MIT licensed

---

## Öneriler

1. **Acil (Aşama 2):** ffmpeg yerine AVFoundation geçişinin teknik uygulanabilirliğini tamamıyla değerlendir (Aşama 1).
   
2. **Metadata Tamaç:** Build'den sonra PyInstaller temporary'sinden charset_normalizer ve cffi METADATA'sını çıkar; `build/` klasöründe kaydet.

3. **Attribution & Uyum Lisans Dosyası:**
   - Paketlenen tüm açık kaynak bileşenlerin attributions'ını `Contents/Resources/THIRD_PARTY_LICENSES.txt` veya in-app "Hakkında" sekmesine koy
   - ffmpeg GPL metni tam olarak (GPL seçilirse)
   - Veya ffmpeg'i kaldır (AVFoundation kullanan yol)

4. **App Store Açıklama:** Review notes'ta "ffmpeg veya AVFoundation kullanan ses deşifre yöntemi" açıkla; GPL'den kaçıyorsan "Apple native frameworks yalnız" notu ekle.

---

## Dosya Yolları (Referans)

- Temel metadata: `/Users/aydinkoyuncu/Documents/KlariVision/build/KlariVisionEngineDist/KlariVisionEngine/_internal/*.dist-info/`
- ffmpeg binary: `_internal/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1`
- Repo lisansı: `/Users/aydinkoyuncu/Documents/KlariVision/LICENSE`

---

**Son Güncelleme:** 2026-09-13
