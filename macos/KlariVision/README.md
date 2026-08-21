# KlariVision macOS

SwiftUI ürün kabuğu; yerel dosya analizi, medya oynatma, A/B döngüsü ve canlı
mikrofon çalışmasını aynı uygulamada sunar. Grafikler kalıcı WKWebView canvas,
yerel kontroller SwiftUI kullanır.

## Çalıştırma

Xcode'da `Package.swift` dosyasını açıp `KlariVisionApp` executable hedefini
çalıştırın. Komut satırı doğrulaması:

```bash
swift test
xcodebuild \
  -project KlariVision.xcodeproj \
  -scheme KlariVision \
  -configuration Debug \
  -derivedDataPath /private/tmp/KlariVisionDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Uygulamanın dosya analizi betikleri ve Vamp eklentileri depo kökündeki yerel
Python ortamını kullanır. Dağıtılabilir beta paketini depo kökünde
`zsh scripts/build_beta_app.sh` üretir.

## Kod okuma sırası

1. `AppSettings.swift` — tema, motor ve grafik tercihleri
2. `KlariVisionApp.swift` — uygulama state'i, dosya alma ve ana gezinme
3. `StudyModels.swift` + `StudyWorkspace.swift` — dosya çalışması
4. `LivePitchAnalyzer.swift` — ses girişi ve pitch oturumu
5. `PracticeViews.swift` + `LiveVisuals.swift` — canlı çalışma görünümü

Sistem diyagramları: [`../../docs/architecture.html`](../../docs/architecture.html).
