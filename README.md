# KlariVision

KlariVision, Türk müziği ve klarnet çalışması için yerel pitch analiz ve
görselleştirme uygulamasıdır. macOS ile iPhone/iPad uygulamaları aynı C++ pitch
sözleşmesini kullanır; ses ve çalışma kayıtları cihazdan çıkmaz.

## Uygulamalar

| Hedef | Kaynak | Arayüz | Analiz |
| --- | --- | --- | --- |
| macOS | `macos/KlariVision/` | SwiftUI + WebKit | Dosyada Vamp pYIN, canlıda C++ `unified_v1` |
| iPhone/iPad | `ipad/KlariVisioniPadCoreSmoke/` | SwiftUI + WebKit | C++ C ABI v1 |

Her iki uygulamada kullanıcı makamı ve karar perdesini seçer. Pitch motoru
seçilebilir değildir: tek motor `unified_v1` çalışır (D-039).
Nota adı/transpozisyon yalnız gösterimi değiştirir; ölçülen fiziksel frekansı
değiştirmez. Otomatik makam ve süsleme tespiti ana ürün kapsamında değildir.

## İlk kez geliştirecekler için

1. Görsel sistem ve veri akışı için [`docs/architecture.html`](docs/architecture.html)
   dosyasını tarayıcıda açın.
2. Güncel durum için [`docs/PROJECT_STATE.md`](docs/PROJECT_STATE.md), yalnız
   sıradaki iş için [`docs/CODEX_HANDOFF.md`](docs/CODEX_HANDOFF.md) okuyun.
3. Kalıcı ürün kararları için [`docs/DECISIONS.md`](docs/DECISIONS.md), C ABI
   ayrıntısı için [`docs/PITCH_ENGINE_C_ABI_V1.md`](docs/PITCH_ENGINE_C_ABI_V1.md)
   kullanın.
4. Platform kurulum ve çalıştırma adımlarını
   [`macos/KlariVision/README.md`](macos/KlariVision/README.md) ve
   [`ipad/README.md`](ipad/README.md) içinde izleyin.

## Doğrulama

```bash
zsh scripts/test_core.sh
.venv/bin/python -B -m pytest -q
cd macos/KlariVision && swift test
xcodebuild -project ipad/KlariVisioniPadCoreSmoke.xcodeproj \
  -scheme KlariVisioniPad -sdk iphonesimulator build-for-testing
```

macOS paketini üretmek için:

```bash
zsh scripts/build_beta_app.sh
```

`data/audio/`, `data/video/`, `data/annotations/`, `outputs/` ve `dist/`
kullanıcı/yerel çıktı alanlarıdır; kaynak kontrolüne eklenmez.

Sentetik WAV turnuva corpus'u da yerel doğrulama girdisidir. Bu corpus yoksa
fixture'a bağlı iki Python entegrasyon testi açık gerekçeyle atlanır; birim
testleri ve uygulama kaynakları bundan etkilenmez. Corpus'u olan geliştirme
ortamında aynı komut tüm turnuva denetimlerini de çalıştırır.

## Belge düzeni

- `docs/architecture.html`: güncel, grafikli sistem açıklaması
- `docs/VSCODE_SETUP.md`: VS Code ile kod okuma ortamı ve okuma sırası
- `docs/PROJECT_STATE.md`: doğrulanmış güncel ürün durumu
- `docs/CODEX_HANDOFF.md`: son çalışma ve sıradaki tek somut iş
- `docs/DECISIONS.md`: kalıcı karar günlüğü
- `docs/TEST_BASELINE.md`: sayısal regresyon tabanı
- `docs/*ACCEPTANCE*.md`: fiziksel ve otomatik kabul kanıtları
- `docs/MeetingNotes.md`, `docs/PRD.md`, `docs/RoadMap.md`: tarihsel başlangıç
  kayıtları; güncel durum kaynağı değildir
