// KlariVision iPhone — compact genişlikte Dinleme ve kütüphane alanı.
// Aynı StudyState ve kalıcı WKWebView regular iPad düzeniyle paylaşılır.
// Yalnız küçük ekran yerleşimi ve kontroller burada tanımlanır.

import SwiftUI

/// Compact listening route.  The state and its WebView are owned by the root,
/// so this view can be recreated during size-class changes without losing
/// playback or analysis state.
struct iPadCompactStudyWorkspace: View {
    @Bindable var study: iPadStudyState
    let close: () -> Void
    let retryCompletedRecording: () -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                Group {
                    switch study.phase {
                    case .ready:
                        iPadStudyWebView(store: study.webView)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 8)
                    case .importing:
                        progressView(title: "Dosya hazırlanıyor", detail: "Dosya yerel çalışma alanına kopyalanıyor.", progress: nil)
                    case let .analyzing(progress):
                        progressView(title: "Yerel pitch analizi yapılıyor", detail: "Ses kareleri seçtiğiniz motorla işleniyor.", progress: progress)
                    case let .failed(message):
                        VStack(spacing: 16) {
                            ContentUnavailableView("Çalışma Açılamadı", systemImage: "exclamationmark.triangle", description: Text(message))
                            if study.canRetryCompletedRecording {
                                Button("Çalışmalara Eklemeyi Yeniden Dene", action: retryCompletedRecording).buttonStyle(.borderedProminent)
                            }
                        }
                    case .idle:
                        ContentUnavailableView("Çalışma seçilmedi", systemImage: "waveform", description: Text("Kütüphaneden bir çalışma açın."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if study.phase == .ready { compactControls(compact: proxy.size.width < 430) }
                }
            }
            .navigationTitle(study.currentStudy?.title ?? "Dinleme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Kapat") {
                        study.close()
                        close()
                    }
                    .accessibilityHint("Oynatmayı durdurur ve çalışmayı kapatır")
                }
            }
        }
    }

    private func progressView(title: String, detail: String, progress: Double?) -> some View {
        VStack(spacing: 16) {
            if let progress { ProgressView(value: progress).frame(maxWidth: 260) }
            else { ProgressView() }
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let progress { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
        }.padding(24)
    }

    @ViewBuilder private func compactControls(compact: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(formatTime(study.playbackTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { study.playbackTime }, set: { study.command(.seek($0)) }), in: 0...max(study.duration, 0.01))
                    .accessibilityLabel("Konum")
                Text(formatTime(study.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if compact {
                HStack(spacing: 8) {
                    playbackButton(study.isPlaying ? "Duraklat" : "Oynat", systemImage: study.isPlaying ? "pause.fill" : "play.fill") { study.command(.playPause) }
                    markerButton("A", label: "A noktasını işaretle") { study.command(.markA) }
                    markerButton("B", label: "B noktasını işaretle") { study.command(.markB) }
                    settingsMenu
                }
            } else {
                HStack(spacing: 10) {
                    playbackButton(study.isPlaying ? "Duraklat" : "Oynat", systemImage: study.isPlaying ? "pause.fill" : "play.fill") { study.command(.playPause) }
                    markerButton("A", label: "A noktasını işaretle") { study.command(.markA) }
                    markerButton("B", label: "B noktasını işaretle") { study.command(.markB) }
                    settingsMenu
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Döngü", isOn: Binding(get: { study.looping }, set: { _ in study.command(.loop) }))
            Toggle("Eğriyi takip et", isOn: Binding(get: { study.followsCurve }, set: { _ in study.command(.follow) }))
            Picker("Hız", selection: Binding(get: { study.rate }, set: { study.command(.rate($0)) })) {
                ForEach(iPadStudyPlaybackRate.values.filter { $0 >= 0.10 && $0 <= 2.00 }, id: \.self) { rate in Text(iPadStudyPlaybackRate.label(for: rate)).tag(rate) }
            }
            Picker("Makam", selection: Binding(get: { study.currentStudy?.context.makam ?? .nihavend }, set: { study.updateContext(makam: $0) })) { ForEach(iPadMakam.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Karar", selection: Binding(get: { study.currentStudy?.context.karar ?? .rast }, set: { study.updateContext(karar: $0) })) { ForEach(iPadKarar.allCases) { Text($0.rawValue).tag($0) } }
        } label: { Label("Ayarlar", systemImage: "slider.horizontal.3") }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Çalışma ayarları")
    }

    private func playbackButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage).labelStyle(.titleAndIcon) }
            .buttonStyle(.borderedProminent).controlSize(.large).frame(minHeight: 44)
    }

    private func markerButton(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.large).frame(minWidth: 44, minHeight: 44).accessibilityLabel(label)
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

struct iPadCompactLibraryView: View {
    @Bindable var study: iPadStudyState
    let open: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if study.studies.isEmpty {
                    ContentUnavailableView("Kayıt Bulunmadı", systemImage: "waveform.slash", description: Text("Ana Sayfa'dan yerel bir ses veya video dosyası seçin."))
                } else {
                    List(study.studies) { item in
                        Button { study.open(item); open() } label: {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text("\(item.context.makam.rawValue) · \(item.context.karar.rawValue)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Çalışmalar")
        }
    }
}
