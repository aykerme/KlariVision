# KlariVision iPhone + iPad

`KlariVisioniPadCoreSmoke.xcodeproj`, iOS/iPadOS 17+ için tek evrensel SwiftUI
uygulamasıdır. Compact genişlikte üç tab, regular genişlikte sidebar kullanır;
bundle kimliği, UserDefaults anahtarları ve `Studies-v1.json` iki cihaz
ailesinde ortaktır.

## Çalıştırma

Xcode'da projeyi açın, `KlariVisioniPad` şemasını ve bir iPhone/iPad hedefini
seçip çalıştırın. Mikrofon akışı gerçek cihazda doğrulanmalıdır.

Komut satırı derleme kapısı:

```bash
xcodebuild \
  -project KlariVisioniPadCoreSmoke.xcodeproj \
  -scheme KlariVisioniPad \
  -sdk iphonesimulator \
  -derivedDataPath /private/tmp/KlariVisionMobileDerivedData \
  build-for-testing
```

## Kod okuma sırası

1. `AppState.swift` — gezinme, tercihler ve müzik bağlamı
2. `KlariVisioniPadApp.swift` — responsive kabuk ve ekran bileşimi
3. `StudyModels.swift` + `StudyState.swift` — import, analiz ve kütüphane
4. `PitchABIAdapter.swift` — C ABI v1'in tek Swift sınırı
5. `LiveModels.swift` + `LiveAnalyzer.swift` — mikrofon yaşam döngüsü
6. `StudyWebView.swift` + `LiveWebView.swift` — kalıcı canvas köprüleri

C ABI smoke testi sözleşme, üç motor ve create/process/finish/destroy yaşam
döngüsünü doğrular. Fiziksel VoiceOver kabul turu henüz “NOT RUN” durumundadır;
TestFlight/App Store hazırlığı öncesinde tamamlanmalıdır.

Sistem diyagramları: [`../docs/architecture.html`](../docs/architecture.html).
