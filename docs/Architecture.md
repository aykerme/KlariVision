# KlariVision mimarisi

Bu sayfa kısa metin özetidir. Katmanlar, platform karşılaştırması, dosya ve
canlı ses akışları ile yaşam döngüsü diyagramları için
[`architecture.html`](architecture.html) dosyasını açın.

## Katmanlar

1. **SwiftUI ürün kabuğu:** gezinme, seçimler, izinler, hata ve ilerleme
   durumları.
2. **Platform servisleri:** AVFoundation, dosya alma, yerel kayıt, medya
   oynatma ve kalıcı ayarlar.
3. **Pitch adaptörü:** 48 kHz mono Float32 PCM'i C ABI v1 oturumuna verir.
4. **C++ çekirdek:** tek motor `unified_v1` ile zaman, frekans, güven ve
   seslilik kareleri üretir (D-039; ABI kimlikleri 0–3 rezerve).
5. **Görselleştirme:** Swift'in hazırladığı veriyi kalıcı bir WKWebView canvas
   üzerinde çizer; makam/karar kılavuzları ölçümü değiştirmez.

## Temel sözleşmeler

- Canlı C ABI girişi: 48.000 Hz, mono Float32, 1.536 örnek pencere, 512 örnek
  hop.
- Her `process`/`finish` çağrısı çıktı vektörünü yeniler; tüketici sıfırıncı
  indisten tekrar okur.
- Kaynak zamanı, yayın gecikmesinden bağımsız korunur.
- macOS dosya analizi için Vamp pYIN kararlı referanstır; canlı motorlarla aynı
  şey olduğu varsayılmaz.
- Makam, karar ve yazılı nota kullanıcı seçimi/gösterim katmanıdır.
- Kullanıcı medyası uygulama alanına kopyalanır; ağ veya bulut akışı yoktur.

## Kaynak haritası

| Alan | macOS | iPhone/iPad |
| --- | --- | --- |
| Uygulama/state | `KlariVisionApp.swift`, `AppSettings.swift` | `KlariVisioniPadApp.swift`, `AppState.swift` |
| Dosya çalışması | `StudyModels.swift`, `StudyWorkspace.swift` | `StudyModels.swift`, `StudyState.swift`, `StudyWebView.swift` |
| Canlı analiz | `LivePitchAnalyzer.swift` | `LiveAnalyzer.swift`, `LiveModels.swift`, `PitchABIAdapter.swift` |
| Canlı görünüm | `PracticeViews.swift`, `LiveVisuals.swift` | `LiveWebView.swift`, `iPadCompactLiveWorkspace.swift` |
| Ortak çekirdek | `core/` ve C ABI köprüsü | `core/` ve `KlariVisionCore` statik hedefi |

## Değişiklik ilkesi

Pitch davranışı değişiyorsa tek bir kayıt üzerinde ayar yapılmaz. Sentetik
gerçek-değer, doğrudan dosya ve gerçek kayıt regresyonları birlikte ölçülür;
`TEST_BASELINE.md` ve ilgili rapor güncellenir. Kullanıcı verileri silinmez veya
Git'e eklenmez.
