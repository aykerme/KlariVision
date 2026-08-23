// KlariVision iPhone — compact genişlikte Dinleme ve kütüphane alanı.
// Aynı StudyState ve kalıcı WKWebView regular iPad düzeniyle paylaşılır.
// Yalnız küçük ekran yerleşimi ve kontroller burada tanımlanır.

import SwiftUI

/// Compact listening route.  The state and its WebView are owned by the root,
/// so this view can be recreated during size-class changes without losing
/// playback or analysis state.
struct iPadCompactStudyWorkspace: View {
    @Bindable var study: iPadStudyState
    let intervals: iPadMakamIntervalsStore
    let close: () -> Void
    let retryCompletedRecording: () -> Void
    @State private var isPresentingSettings = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                Group {
                    switch study.phase {
                    case .ready:
                        // The graph/video toggle inside StudyViewer.html always fills the
                        // whole stage with one of the two, so the WebView can extend past
                        // the bottom safe area; playback controls float on top instead of
                        // claiming a fixed strip of screen. The top safe area is left alone
                        // so the WebView's content area starts below the navigation bar —
                        // ignoring it too would let the mini graph/video corner button land
                        // underneath the nav bar's title/close button.
                        ZStack(alignment: .bottom) {
                            iPadStudyWebView(store: study.webView, isGraphMode: study.isGraphMode)
                                .ignoresSafeArea(edges: .bottom)
                            compactControls(compact: proxy.size.width < 430)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                        .overlay(alignment: .topTrailing) {
                            // Native, not HTML: WKWebView scales page content (including
                            // `position:fixed` elements) together during pinch-zoom, so an
                            // in-page toggle button would zoom/pan out of reach along with
                            // the graph or video. This one lives outside the WebView, so it
                            // stays put and tappable at any zoom level.
                            if study.hasVideo { videoFullscreenToggle }
                        }
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

    /// Shows the icon of the side tapping it would switch to (a video icon
    /// while the graph is fullscreen, a waveform icon while the video is).
    private var videoFullscreenToggle: some View {
        Button {
            study.toggleVideoFullscreen()
        } label: {
            Image(systemName: study.isVideoFullscreen ? "waveform" : "play.rectangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
        }
        .padding(.top, 16)
        .padding(.trailing, 16)
        .accessibilityLabel(study.isVideoFullscreen ? "Grafiği tam ekran yap" : "Videoyu tam ekran yap")
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
            // No position slider: the graph itself scrubs (one-finger horizontal
            // drag in StudyViewer.html), which keeps the white playhead centered.
            iPadStudyPositionReadout(time: study.playbackTime, duration: study.duration) { study.command(.seek($0)) }
            HStack(spacing: compact ? 8 : 10) {
                playbackButton(study.isPlaying ? "Duraklat" : "Oynat", systemImage: study.isPlaying ? "pause.fill" : "play.fill") { study.command(.playPause) }
                Spacer(minLength: 8)
                markerButton("A", label: "A noktasını işaretle") { study.command(.markA) }
                markerButton("B", label: "B noktasını işaretle") { study.command(.markB) }
                loopButton
                Spacer(minLength: 8)
                settingsButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $isPresentingSettings) {
            iPadStudySettingsSheet(study: study, intervals: intervals)
        }
    }

    /// Opens the shared settings sheet.  It sits in the exact slot the old
    /// inline `Menu` occupied, so the control bar's layout is unchanged.
    private var settingsButton: some View {
        iPadWorkspaceSettingsButton(label: "Çalışma ayarları") { isPresentingSettings = true }
    }

    /// Toggles A–B looping.  Filled while looping is on, so the bar shows the
    /// state that used to live behind the settings menu's "Döngü" switch.
    @ViewBuilder private var loopButton: some View {
        let label = Label("Döngü", systemImage: "repeat").labelStyle(.iconOnly)
        let action = { study.command(.loop) }
        if study.looping {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Döngü").accessibilityValue("Açık")
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered).controlSize(.large).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Döngü").accessibilityValue("Kapalı")
        }
    }

    private func playbackButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage).labelStyle(.iconOnly) }
            .buttonStyle(.borderedProminent).controlSize(.large).frame(minWidth: 44, minHeight: 44)
    }

    private func markerButton(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered).controlSize(.large).frame(minWidth: 44, minHeight: 44).accessibilityLabel(label)
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
