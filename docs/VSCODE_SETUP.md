# VS Code ile KlariVision kodunu okuma

Bu ortam kod **okumak ve analiz etmek** için kurulmuştur. Derleme ve paketleme
sözleşmesi değişmedi: macOS/iPad uygulamalarının resmî üretim yolu hâlâ
`xcodebuild`'dir. VS Code burada üç dilin tanıma-gitme, çağıran-arama ve tip
bilgisini tek pencerede toplar.

## 1. Aç

```bash
open -a "Visual Studio Code" /Users/aydinkoyuncu/Documents/KlariVision/KlariVision.code-workspace
```

## 2. Eklentiler

Gerekli eklentilerin tümü kurulu. Listeyi görmek veya yeni bir makinede tekrar
kurmak için VS Code'un kendi CLI'ı kullanılabilir; `code` komutu PATH'te değilse
uygulama içindeki ikili doğrudan çağrılır:

```bash
"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" --list-extensions
```

`ms-vscode.cpptools` bilerek önerilmez; clangd ile çakışır ve
`.vscode/settings.json` içinde devre dışı bırakılmıştır.

## 3. Dil sunucularının durumu

| Alan | Sunucu | Durum | Nasıl çalışıyor |
| --- | --- | --- | --- |
| `core/` C++ | clangd (`/usr/bin/clangd`) | Tam | `core/compile_commands.json` — 22 çeviri birimi, `-std=c++20 -I core/include` + macOS SDK |
| `macos/KlariVision` Swift | SourceKit-LSP | Tam | `Package.swift` üzerinden; `swift.searchSubfoldersForPackages` açık |
| `src/klarivision`, `scripts/`, `tests/` | Pylance | Tam | `.venv/bin/python`, `python.analysis.extraPaths = src` |
| `ipad/` Swift | SourceKit-LSP | Kısmi | Yalnız `.xcodeproj` var, `Package.swift` yok |

`ipad/` dosyalarında sözdizimi renklendirmesi ve dosya içi gezinme çalışır;
projeler arası tanıma-gitme için tek seferlik köprü gerekir:

```bash
brew install xcode-build-server && xcode-build-server config -project ipad/KlariVisioniPadCoreSmoke.xcodeproj -scheme KlariVisioniPad
```

Aynı komut Tasks listesinde **"iPad SourceKit köprüsü kur (tek seferlik,
opsiyonel)"** olarak da vardır. Ürettiği `buildServer.json` yerel dosyadır ve
Git'e girmez.

## 4. Görevler

`Cmd+Shift+P` → **Tasks: Run Task**:

- `Doğrula: C++ çekirdek testleri` — `scripts/test_core.sh`
- `Doğrula: Python testleri` — `pytest -q` (varsayılan test görevi)
- `macOS: swift build` / `macOS: swift test` / `macOS: xcodebuild (imzasız)`
- `iPad: xcodebuild (simulator)`
- `C++: clangd indeksini yenile` — `core/` altına yeni `.cpp` eklendiğinde
- `C++: pitch_track_cli derle (debug)` — LLDB için sembollü ikili
- `Doküman: mimariyi tarayıcıda aç` — `docs/architecture.html`

Hata ayıklama (`F5`) yapılandırmaları: açık Python dosyası, açık dosyanın
pytest'i, `klarivision.cli`, `klarivision.local_app` ve C++ `pitch_track_cli`
(LLDB, derlemeyi kendi tetikler).

## 5. Okuma sırası

Ürün sözleşmesi için önce `AGENTS.md`, `docs/PROJECT_STATE.md` ve
`docs/architecture.html`. Sonra kod:

1. **Sinyal çekirdeği** — `core/include/klarivision/core/` başlıkları veri
   sözleşmesini tek sayfada verir; sonra `core/src/analysis_engine.cpp` (728
   satır, motor seçimi ve kare üretimi), ardından ilgilendiğiniz motor:
   `pitch_engine_v2.cpp`, `vpm_like.cpp`, `mpm.cpp`, `swipe_prime.cpp`.
2. **C ABI sınırı** — `core/include/klarivision/core/analysis_engine_c.h` ve
   `core/src/analysis_engine_c.cpp`; sözleşme metni
   `docs/PITCH_ENGINE_C_ABI_V1.md`. Swift tarafı buradan başlar.
3. **iPhone/iPad** — küçük ve okunaklı taraf: `PitchABIAdapter.swift` (C ABI
   köprüsü) → `LiveAnalyzer.swift` → `AppState.swift` /`StudyState.swift` →
   `Resources/LiveViewer.html` (grafiğin çizildiği yer).
4. **macOS** — `KlariVisionApp.swift` kabuk, `LivePitchAnalyzer.swift` (4239
   satır; Outline paneli ve sticky scroll ile okuyun), `LiveVisuals.swift`,
   `StudyWorkspace.swift`.
5. **Python** — referans/ölçüm katmanı: `src/klarivision/pitch/` (`yin.py`,
   `pyin.py`, `vamp_pyin.py`, `cpp_engine.py`), görselleştirme
   `frequency_viewer.py`, ölçüm ve turnuva `scripts/run_pitch_engine_tournament.py`.

Çapraz-dil doğruluğun nerede kilitlendiğini görmek için
`tests/test_vpm_swift_cpp_parity.py` ve `tests/test_v2_swift_python_parity.py`
okunmaya değer: aynı algoritmanın C++, Swift ve Python kopyalarını
karşılaştırırlar.

## 6. Gizlenen klasörler

`.venv/`, `.python/`, `.uv-cache/`, `build/`, `dist/`, `outputs/` ve
`__pycache__` Explorer'da gizlidir; arama ve dosya izleyici dışındadırlar
(`outputs/` altında 400'den fazla klasör var, indekslenmeleri editörü
yavaşlatır). Birini geçici olarak görmek için `.vscode/settings.json`
içindeki `files.exclude` satırını `false` yapın. `data/` görünürdür ama
aramaya girmez.

## 7. Source Insight düzeni

VS Code, Source Insight'ın dört penceresini yerleşik olarak karşılar. Eşleşme
şöyledir:

| Source Insight | VS Code karşılığı | Açılış |
| --- | --- | --- |
| Symbol Window (dosya) | Outline paneli | `Alt+O` |
| Project Symbol Window | Outline Map → **Workspace** görünümü | `Alt+M`, arama `Alt+L` |
| Context Window | Peek Definition | `Ctrl+Shift+=` veya `Alt+F12` |
| Relation Window | Call Hierarchy | `Ctrl+Shift+/` |
| Lookup References | References paneli | `Ctrl+/` |
| Browse Project Symbols | Sembol arama | `F7` |

Referanslar ve çağrı ağacı `references.preferredLocation: "view"` sayesinde
küçük bir peek kutusunda değil, alttaki panelde açılır — Source Insight'ta
olduğu gibi kalıcıdır, gezinirken kaybolmaz.

### Tuşlar

`~/Library/Application Support/Code/User/keybindings.json` içinde tanımlıdır ve
**tüm projelerde** geçerlidir. Geri almak için dosyayı silmek yeterli.

| Tuş | İş |
| --- | --- |
| `Ctrl+=` | Tanıma git |
| `Ctrl+Shift+=` | Tanımı yerinde göster (Context Window) |
| `Alt+,` / `Alt+.` | Geri / ileri |
| `Ctrl+/` | Referansları listele |
| `Ctrl+Shift+/` | Çağrı ağacı (Relation Window) |
| `Ctrl+Shift+T` | Tip hiyerarşisi |
| `F7` | Projede sembol ara |
| `Shift+F7` | Dosyada sembol ara |
| `Alt+O` | Outline paneline odaklan |
| `Alt+M` | Outline Map (proje sembol ağacı) |
| `Ctrl+F12` | Uygulamaya git (implementation) |
| `F4` / `Shift+F4` | Sonraki / önceki arama sonucu |

### Pencere yerleşimi (tek seferlik, elle)

VS Code görünüm yerleşimini ayar dosyasından okumaz; aşağıdaki üç adımı bir kez
yapmanız gerekir, sonra kalıcıdır.

1. `Cmd+Alt+B` ile sağdaki ikincil kenar çubuğunu açın.
2. Sol kenar çubuğundaki **Outline** başlığını tutup sağdaki çubuğa sürükleyin.
   Sol taraf SI'ın Project Window'u, sağ taraf Symbol Window'u olur.
3. Activity Bar'daki **Outline Map** simgesine tıklayın, **Workspace**
   görünümünü de sağ çubuğa sürükleyin. Bu, proje geneli sembol veritabanıdır.

Sonuç Source Insight'ın klasik yerleşimidir: solda dosya ağacı, ortada kaynak,
sağda semboller, altta referans/çağrı paneli.

### Renkler

Tema `Default Light Modern` olarak ayarlandı ve sembol türüne göre renklendirme
açıldı: fonksiyonlar koyu mor kalın, tipler teal, alanlar mor, parametreler
italik, makrolar kırmızı. Bu renkler yalnız bu temaya bağlıdır — başka bir tema
seçerseniz kendi renklerine döner. Renklendirme dil sunucusundan gelir, yani
C++, Swift ve Python'da aynı biçimde çalışır.

Bu görünüm ayarları `.vscode/settings.json` içinde, yani **yalnız bu projede**
geçerlidir. Tüm projelerde istersen ilgili blokları kullanıcı ayarlarına
(`Cmd+Shift+P` → *Preferences: Open User Settings (JSON)*) kopyala.
