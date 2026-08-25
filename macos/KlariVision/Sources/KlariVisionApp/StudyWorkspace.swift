// KlariVision macOS — Dinleme çalışma alanı ve Swift ↔ WebKit köprüsü.
// Akış: viewer + pitch JSON → yerel medya saati → senkron grafik ve kontroller.
// Snapshotlar yumuşatılır; WebView/medya kimliği güncellemelerde korunur.
// Sıra: layout → workspace → playback → graph → AppKit → LocalViewer köprüsü.

import AppKit
import Foundation
import SwiftUI
import WebKit

private struct ResponsiveWorkspaceLayout: Layout {
    var compact: Bool
    var spacing: CGFloat = 14

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let proposedWidth = proposal.width ?? 900
        if !compact {
            let left = subviews[0].sizeThatFits(ProposedViewSize(width: proposedWidth * 0.32, height: proposal.height))
            let right = subviews[1].sizeThatFits(ProposedViewSize(width: proposedWidth * 0.68, height: proposal.height))
            return CGSize(width: proposedWidth, height: max(left.height, right.height))
        }
        let first = subviews[0].sizeThatFits(ProposedViewSize(width: proposedWidth, height: 220))
        let second = subviews[1].sizeThatFits(ProposedViewSize(width: proposedWidth, height: 360))
        return CGSize(width: proposedWidth, height: max(594, first.height + spacing + second.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        if !compact {
            let mediaWidth = max(300, (bounds.width - spacing) * 0.32)
            let graphWidth = max(0, bounds.width - spacing - mediaWidth)
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: mediaWidth, height: bounds.height))
            subviews[1].place(at: CGPoint(x: bounds.minX + mediaWidth + spacing, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: graphWidth, height: bounds.height))
            return
        }

        // Keep both panels inside the available height; the old VStack let
        // their minimum heights overlap whenever the window became short.
        let mediaHeight = max(220, min(bounds.height * 0.42, bounds.height - 360 - spacing))
        let graphHeight = max(360, bounds.height - mediaHeight - spacing)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: mediaHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + mediaHeight + spacing), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: graphHeight))
    }
}
struct WorkspaceView: View {
    let viewer: URL
    @Bindable var library: RecentLibrary
    @Environment(\.appTheme) private var appTheme
    @State private var webView: WKWebView?
    @State private var isEditingStudy = false
    @State private var studySettings: StudySettingsDraft?
    @State private var pitchTrack: StudyPitchTrack?
    @State private var pitchTrackError: String?
    @State private var webViewReloadToken = 0
    @StateObject private var playback = StudyPlaybackState()
    @AppStorage(GraphAppearance.pitchColorKey) private var graphPitchHex = GraphAppearance.defaultPitchHex
    @AppStorage(GraphAppearance.noteGuideColorKey) private var graphNoteGuideHex = GraphAppearance.defaultNoteGuideHex

    var body: some View {
        VStack(spacing: 0) {
            if let item = library.item(for: viewer) {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.tint)
                    Text("Çalışma bağlamı")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(library.studySummary(for: item))
                        .font(.callout.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Seçili makam ve karar: \(library.studySummary(for: item))")
            }

            StudyPlaybackBar(playback: playback) { command in
                sendPlaybackCommand(command)
            }
            .overlay(alignment: .bottom) { Divider() }

            GeometryReader { geometry in
                ScrollView(.vertical) {
                    studyMedia
                    .frame(minHeight: max(geometry.size.height - 32, 594), alignment: .top)
                }
                .scrollIndicators(.automatic)
                .padding(16)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    closeWorkspaceAfterPausing()
                } label: {
                    Label("Çalışmalara Dön", systemImage: "chevron.left")
                }
                .help("Çalışmalar listesine dön")
            }

            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Label(
                        library.item(for: viewer).map { library.study(for: $0).title }
                            ?? viewer.deletingPathExtension().lastPathComponent,
                        systemImage: "waveform"
                    )
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)

                    if let item = library.item(for: viewer) {
                        Label(library.studySummary(for: item), systemImage: "music.note")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("Seçili makam ve karar: \(library.studySummary(for: item))")
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    library.reanalyse(viewer)
                } label: {
                    Label("Seçili motorla yeniden analiz et", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Ayarlar'daki çalışma motoruyla yeni pitch eğrisi oluştur")
                .disabled(library.isAnalysing)

                Button {
                    presentStudySettings()
                } label: {
                    Label("Ayarlar", systemImage: "slider.horizontal.3")
                }
                .help("Dinleme modu görünümünü ve makam aralıklarını ayarla")
                .disabled(webView == nil)

                Button {
                    isEditingStudy = true
                } label: {
                    Label("Çalışmayı Düzenle", systemImage: "pencil")
                }
                .help("Çalışma adı, makam ve karar bilgisini düzenle")
                .disabled(library.item(for: viewer) == nil)
            }
        }
        .sheet(isPresented: $isEditingStudy) {
            if let item = library.item(for: viewer) {
                StudyEditor(item: item, library: library) { makam, karar in
                    applyStudyContext(makam: makam, karar: karar)
                }
            }
        }
        .sheet(item: $studySettings) { draft in
            StudySettingsView(draft: draft) { updated in
                applyStudySettings(updated)
            }
        }
        .task(id: viewer) {
            loadPitchTrack()
        }
        .onChange(of: library.isAnalysing) { wasAnalysing, isAnalysing in
            if wasAnalysing && !isAnalysing {
                loadPitchTrack()
                // Refresh/reanalyse rewrite the same HTML file in place, so the
                // viewer URL never changes; bump a token to force the WebView
                // to reload even though `webView.url == viewer` still holds.
                webViewReloadToken += 1
            }
        }
        .onChange(of: playback.time) { _, time in
            updatePlaybackFrequency(at: time)
        }
        .onDisappear { sendPlaybackCommand("pause") }
    }

    private var studyMedia: some View {
        LocalViewer(
            viewer: viewer,
            readAccessRoot: library.viewerReadAccessRoot(for: viewer),
            study: library.item(for: viewer).map { library.study(for: $0) },
            playback: playback,
            appTheme: appTheme,
            graphAppearance: GraphAppearance(pitchHex: graphPitchHex, noteGuideHex: graphNoteGuideHex),
            reloadToken: webViewReloadToken,
            webView: $webView
        )
        .frame(minWidth: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyStudyContext(makam: String, karar: Int) {
        webView?.evaluateJavaScript("""
        (() => {
            const scale = document.getElementById('scale-mode');
            const tonic = document.getElementById('tonic');
            if (scale) { scale.value = '\(makam)'; scale.dispatchEvent(new Event('change')); }
            if (tonic) { tonic.value = '\(karar)'; tonic.dispatchEvent(new Event('change')); }
        })();
        """)
    }

    private func presentStudySettings() {
        webView?.evaluateJavaScript("window.klariVisionStudyViewer?.settingsSnapshot?.()") { result, _ in
            guard let values = result as? [String: Any],
                  let draft = StudySettingsDraft(values: values) else { return }
            DispatchQueue.main.async { studySettings = draft }
        }
    }

    private func applyStudySettings(_ settings: StudySettingsDraft) {
        guard let data = try? JSONEncoder().encode(settings),
              let payload = String(data: data, encoding: .utf8) else { return }
        graphPitchHex = settings.graphAppearance.pitchHex
        graphNoteGuideHex = settings.graphAppearance.noteGuideHex
        webView?.evaluateJavaScript("window.klariVisionStudyViewer?.applySettings?.(\(payload))")
    }

    private func sendPlaybackCommand(_ command: String) {
        let encoded = (try? JSONEncoder().encode(command))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        webView?.evaluateJavaScript("window.klariVisionStudyViewer?.command(\(encoded))")
    }

    /// WebKit teardown is asynchronous.  Closing the SwiftUI workspace first
    /// can orphan an audible media element, so wait until the page has paused
    /// its actual HTMLMediaElement before removing the view.
    private func closeWorkspaceAfterPausing() {
        guard let webView else {
            library.closeWorkspace()
            return
        }
        webView.evaluateJavaScript("""
        (() => {
            const media = window.klariVisionStudyViewer?.media || document.getElementById('media');
            media?.pause();
            return media?.paused ?? true;
        })();
        """) { _, _ in
            DispatchQueue.main.async { library.closeWorkspace() }
        }
    }

    private func seekPlayback(to seconds: Double) {
        let value = seconds.isFinite ? max(0, seconds) : 0
        webView?.evaluateJavaScript("""
        (() => {
            const viewer = window.klariVisionStudyViewer;
            if (!viewer) return;
            viewer.command?.({type:'seek',seconds:\(value)});
            if (viewer.media) viewer.media.currentTime = \(value);
        })();
        """)
    }

    private func loadPitchTrack() {
        do {
            pitchTrack = try StudyPitchTrack.load(viewer: viewer)
            pitchTrackError = nil
            updatePlaybackFrequency(at: playback.time)
        } catch {
            pitchTrack = nil
            pitchTrackError = "Pitch eğrisi okunamadı: \(error.localizedDescription)"
        }
    }

    private func updatePlaybackFrequency(at time: Double) {
        guard let points = pitchTrack?.points,
              let nearest = points.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(nearest.time - time) <= 0.15 else {
            playback.frequency = nil
            return
        }
        playback.frequency = nearest.frequency
    }
}

/// A monotonic presentation clock for the Study graph.  WebKit reports media
/// time in coarse snapshots; using that value as the drawing clock would move
/// the complete canvas backwards whenever a snapshot arrives a little late.
struct StudyPlaybackClock {
    private(set) var displayedTime = 0.0
    private var duration = 0.0
    private var isPlaying = false
    private var rate = 1.0
    private var lastUptime: TimeInterval?
    private var pendingCorrection = 0.0
    private var correctionTimeRemaining = 0.0

    private let correctionDuration = 0.18
    private let discontinuityThreshold = 0.20

    mutating func applySnapshot(
        time: Double,
        duration: Double,
        isPlaying: Bool,
        rate: Double,
        discontinuity: Bool,
        at uptime: TimeInterval
    ) {
        _ = advance(to: uptime)
        self.duration = max(0, duration.isFinite ? duration : self.duration)
        self.rate = max(0, rate.isFinite ? rate : self.rate)
        let target = min(self.duration, max(0, time.isFinite ? time : displayedTime))
        let difference = target - displayedTime
        let shouldJump = discontinuity || !isPlaying || difference < -discontinuityThreshold ||
            abs(difference) > discontinuityThreshold

        self.isPlaying = isPlaying
        if shouldJump {
            displayedTime = target
            pendingCorrection = 0
            correctionTimeRemaining = 0
        } else {
            // Spread normal WebKit clock drift across a few display frames.
            // Keeping the correction in time units lets this work equally at
            // 0.10× and 2.00× playback.
            pendingCorrection += difference
            correctionTimeRemaining = correctionDuration
        }
        lastUptime = uptime
    }

    mutating func advance(to uptime: TimeInterval) -> Double {
        guard uptime.isFinite else { return displayedTime }
        guard let lastUptime else {
            self.lastUptime = uptime
            return displayedTime
        }
        let elapsed = max(0, uptime - lastUptime)
        self.lastUptime = uptime
        guard isPlaying, elapsed > 0 else { return displayedTime }

        let forward = elapsed * rate
        var correction = 0.0
        if pendingCorrection != 0 {
            let portion = correctionTimeRemaining > 0 ? min(1, elapsed / correctionTimeRemaining) : 1
            let requested = pendingCorrection * portion
            // A late snapshot may ask for a small backwards correction. Let
            // it slow the clock, never reverse the graph during playback.
            correction = max(-forward * 0.85, requested)
            pendingCorrection -= correction
            correctionTimeRemaining = max(0, correctionTimeRemaining - elapsed)
            if abs(pendingCorrection) < 0.000_001 {
                pendingCorrection = 0
                correctionTimeRemaining = 0
            }
        }
        displayedTime = min(duration, max(0, displayedTime + forward + correction))
        return displayedTime
    }
}

private final class StudyPlaybackState: ObservableObject {
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var isReady = false
    @Published var isPlaying = false
    @Published var rate = 1.0
    @Published var loopEnabled = false
    @Published var loopA = 0.0
    @Published var loopB = 0.0
    @Published var followsCurve = false
    @Published var theme = "focus"
    @Published var frequency: Double?
    @Published var scale: LiveScale = .nihavent
    @Published var tonic = 9
    @Published var intervals: [Int] = LiveMakamIntervals.defaults[LiveScale.nihavent.rawValue] ?? [9, 4, 9, 9, 4, 9, 9]
    private var presentationClock = StudyPlaybackClock()

    func displayTime(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        presentationClock.advance(to: uptime)
    }

    func apply(_ body: Any) {
        guard let values = body as? [String: Any] else { return }
        let snapshotTime = (values["time"] as? NSNumber)?.doubleValue ?? time
        let snapshotDuration = (values["duration"] as? NSNumber)?.doubleValue ?? duration
        let snapshotIsPlaying = (values["isPlaying"] as? Bool) ?? isPlaying
        let snapshotRate = (values["rate"] as? NSNumber)?.doubleValue ?? rate
        let discontinuity = (values["discontinuity"] as? Bool) ?? false
        presentationClock.applySnapshot(
            time: snapshotTime,
            duration: snapshotDuration,
            isPlaying: snapshotIsPlaying,
            rate: snapshotRate,
            discontinuity: discontinuity,
            at: ProcessInfo.processInfo.systemUptime
        )
        time = snapshotTime
        duration = snapshotDuration
        isReady = ((values["ready"] as? Bool) ?? isReady) || duration > 0
        isPlaying = snapshotIsPlaying
        rate = snapshotRate
        loopEnabled = (values["loopEnabled"] as? Bool) ?? loopEnabled
        loopA = (values["loopA"] as? NSNumber)?.doubleValue ?? loopA
        loopB = (values["loopB"] as? NSNumber)?.doubleValue ?? loopB
        followsCurve = (values["followsCurve"] as? Bool) ?? followsCurve
        if let proposedTheme = values["theme"] as? String,
           ["focus", "studio", "classic"].contains(proposedTheme) {
            theme = proposedTheme
        }
        frequency = (values["frequency"] as? NSNumber).flatMap { value in
            value.doubleValue.isFinite && value.doubleValue > 0 ? value.doubleValue : nil
        }
        if let rawScale = values["scale"] as? String, let selected = LiveScale(rawValue: rawScale) {
            scale = selected
        }
        if let value = (values["tonic"] as? NSNumber)?.intValue, (0...11).contains(value) {
            tonic = value
        }
        if let proposed = values["intervals"] as? [NSNumber] {
            let parsed = proposed.map(\.intValue)
            if parsed.count == 7, parsed.allSatisfy({ (1...13).contains($0) }), parsed.reduce(0, +) == 53 {
                intervals = parsed
            }
        }
    }
}

private struct StudyPlaybackBar: View {
    @ObservedObject var playback: StudyPlaybackState
    let command: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { controls; tuner }
            VStack(alignment: .leading, spacing: 8) { controls; tuner }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ControlGroup {
                HoverTooltip(playback.isPlaying ? "Medya oynatmayı duraklat" : "Medyayı oynat") {
                    Button { command("toggle") } label: {
                        Label(playback.isPlaying ? "Duraklat" : "Oynat", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .disabled(!playback.isReady)
                }
                HoverTooltip("Başa dön") {
                    Button { command("reset") } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Oynatmayı başa al")
                    .accessibilityHint("Medyanın zamanını sıfıra getirir.")
                    .disabled(!playback.isReady)
                }
                Text(clock(playback.time) + " / " + clock(playback.duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 100)
            }

            ControlGroup("Oynatma Hızı") {
                HoverTooltip("Oynatma hızını azalt") {
                    Button { command("speedDown") } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Oynatma hızını azalt")
                        .disabled(!playback.isReady)
                }
                Text(String(format: "%.2f×", playback.rate).replacingOccurrences(of: ".", with: ","))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 50)
                HoverTooltip("Oynatma hızını artır") {
                    Button { command("speedUp") } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Oynatma hızını artır")
                        .disabled(!playback.isReady)
                }
            }

            ControlGroup {
                HoverTooltip("İmleçte A işaretini oluştur") {
                    Button("A") { command("setA") }.disabled(!playback.isReady)
                }
                HoverTooltip("İmleçte B işaretini oluştur") {
                    Button("B") { command("setB") }.disabled(!playback.isReady)
                }
                HoverTooltip("A ile B arasında döngü") {
                    Toggle("Loop", isOn: Binding(get: { playback.loopEnabled }, set: { _ in command("loop") }))
                        .toggleStyle(.button)
                        .disabled(!playback.isReady)
                }
            }

            ControlGroup {
                HoverTooltip("Pitch eğrisini dikeyde takip et") {
                    Toggle("Eğri Takibi", isOn: Binding(get: { playback.followsCurve }, set: { _ in command("follow") }))
                        .toggleStyle(.button)
                        .disabled(!playback.isReady)
                }
            }
        }
        .font(.callout.weight(.medium))
        .controlSize(.large)
    }

    private var tuner: some View {
        TunerPanel(frequency: playback.frequency, scale: playback.scale, tonic: playback.tonic, intervals: playback.intervals)
            .frame(width: 420)
    }

    private func clock(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

struct StudyGraphViewport {
    static func windowStart(currentTime: Double, duration: Double, visibleDuration: Double) -> Double {
        let visible = min(60, max(2, visibleDuration))
        let lower = -visible / 2
        let upper = max(lower, max(0, duration) - visible / 2)
        return min(upper, max(lower, currentTime - visible / 2))
    }

    static func zoomedDuration(_ duration: Double, deltaY: CGFloat) -> Double {
        min(60, max(2, duration * (deltaY > 0 ? 0.86 : 1.16)))
    }

    static func zoomedVerticalSpan(_ span: Double, deltaY: CGFloat) -> Double {
        min(4_800, max(200, span * (deltaY > 0 ? 0.86 : 1.16)))
    }

    static func followedCenter(current: Double, pitch: Double, span: Double) -> Double {
        let edge = span * 0.45
        let restingEdge = span * 0.35
        if pitch > current + edge { return pitch - restingEdge }
        if pitch < current - edge { return pitch + restingEdge }
        return current
    }
}

private struct StudyPitchGraphPanel: View {
    let points: [StudyPitchPoint]
    private let chartPoints: [PitchGraphPoint]
    private let pitchCentBounds: ClosedRange<Double>
    @ObservedObject var playback: StudyPlaybackState
    let appearance: GraphAppearance
    let theme: String
    let seek: (Double) -> Void
    let togglePlayback: () -> Void
    let toggleFollow: () -> Void
    let emptyMessage: String

    @State private var visibleDuration = 12.0
    @State private var verticalSpan = 2_400.0
    @State private var verticalCenter = 0.0
    @State private var verticalReady = false
    @State private var dragOriginTime: Double?

    init(
        points: [StudyPitchPoint],
        playback: StudyPlaybackState,
        appearance: GraphAppearance,
        theme: String,
        seek: @escaping (Double) -> Void,
        togglePlayback: @escaping () -> Void,
        toggleFollow: @escaping () -> Void,
        emptyMessage: String
    ) {
        self.points = points
        self.chartPoints = points.map { PitchGraphPoint(time: $0.time, frequency: $0.frequency) }
        let centValues = points.map { 1_200 * log2($0.frequency / 440) }
        let centLow = centValues.min() ?? -1_200
        let centHigh = centValues.max() ?? 1_200
        self.pitchCentBounds = centLow...max(centLow + 1, centHigh)
        self.playback = playback
        self.appearance = appearance
        self.theme = theme
        self.seek = seek
        self.togglePlayback = togglePlayback
        self.toggleFollow = toggleFollow
        self.emptyMessage = emptyMessage
    }

    private var scale: LiveScale { playback.scale }
    private func windowStart(for time: Double) -> Double {
        StudyGraphViewport.windowStart(
            currentTime: time,
            duration: max(playback.duration, points.last?.time ?? 0),
            visibleDuration: visibleDuration
        )
    }
    private var verticalBounds: ClosedRange<Double> {
        let low = pitchCentBounds.lowerBound - verticalSpan / 2
        let high = pitchCentBounds.upperBound + verticalSpan / 2
        return low...max(low + 1, high)
    }

    var body: some View {
        let displayedTime = playback.displayTime()
        let start = windowStart(for: displayedTime)
        VStack(spacing: 7) {
                HStack(spacing: 5) {
                    NativePitchGraphView(
                            points: chartPoints,
                            appearance: appearance,
                            theme: theme,
                            scale: scale,
                            tonic: playback.tonic,
                            makamIntervals: playback.intervals,
                            windowStart: start,
                            windowEnd: start + visibleDuration,
                            verticalCenter: verticalCenter,
                            verticalSpan: verticalSpan,
                            playheadTime: displayedTime,
                            loopA: playback.loopA,
                            loopB: playback.loopB,
                            loopEnabled: playback.loopEnabled,
                            timeTickStep: 1,
                            maximumContinuousJumpCents: nil,
                            includesGapAtLimit: true,
                            emptyMessage: emptyMessage,
                            presentationTime: { playback.displayTime() },
                            windowStartAtPresentationTime: { windowStart(for: $0) },
                            animates: playback.isPlaying,
                            fixedContentRange: 0...max(playback.duration, points.last?.time ?? 0),
                            onScroll: handleScroll,
                            onVerticalDrag: handleVerticalDrag,
                            onDragStarted: { dragOriginTime = displayedTime },
                            onHorizontalDrag: handleHorizontalDrag,
                            onDragEnded: { dragOriginTime = nil },
                            onClick: togglePlayback
                        )

                    StudyVerticalSlider(
                        value: Binding(
                            get: { verticalCenter },
                            set: { value in
                                if playback.followsCurve { sendFollowToggle() }
                                verticalCenter = value
                            }
                        ),
                        range: verticalBounds
                    )
                        .frame(width: 18)
                }

                Slider(
                    value: Binding(
                        get: { min(max(0, displayedTime), max(1, playback.duration)) },
                        set: { seek($0) }
                    ),
                    in: 0...max(1, playback.duration)
                )
                .controlSize(.small)
                .accessibilityLabel("Kayıtta gezin")

                Text("Tekerlek: zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır · sürükle: kayıtta gezin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .onAppear { initialiseVerticalCenterIfNeeded() }
        .onChange(of: points) { _, _ in initialiseVerticalCenterIfNeeded(force: true) }
        .onReceive(playback.$time) { _ in
            // Vertical follow-curve smoothing is applied inside PitchGraphNSView
            // via a CADisplayLink-driven transform (see LiveVisuals.swift), not
            // via SwiftUI animation: re-issuing `withAnimation` on every ~50ms
            // playback snapshot used to retrigger/interrupt the previous
            // animation and force a full layer rebuild on every interpolated
            // frame, causing visible stutter.
            updateVerticalFollow(at: playback.displayTime())
        }
        .onReceive(playback.$followsCurve) { follows in
            if follows { updateVerticalFollow(at: playback.displayTime()) }
        }
    }

    private func initialiseVerticalCenterIfNeeded(force: Bool = false) {
        guard force || !verticalReady else { return }
        let values = points.map { 1_200 * log2($0.frequency / 440) }.sorted()
        guard !values.isEmpty else { return }
        let middle = values.count / 2
        verticalCenter = values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
        verticalReady = true
        updateVerticalFollow(at: playback.displayTime())
    }

    private func updateVerticalFollow(at time: Double) {
        guard playback.followsCurve else { return }
        let values = points
            .filter { abs($0.time - time) <= 0.25 }
            .map { 1_200 * log2($0.frequency / 440) }
            .sorted()
        guard !values.isEmpty else { return }
        let middle = values.count / 2
        let pitch = values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
        verticalCenter = StudyGraphViewport.followedCenter(
            current: verticalCenter,
            pitch: pitch,
            span: verticalSpan
        )
    }

    private func handleScroll(_ event: LiveGraphScrollEvent) {
        if event.shiftPressed {
            let oldSpan = verticalSpan
            let nextSpan = StudyGraphViewport.zoomedVerticalSpan(oldSpan, deltaY: event.deltaY)
            let drawableHeight = max(1, event.size.height - 44)
            let ratioFromBottom = min(1, max(0, Double(event.location.y - 28) / drawableHeight))
            let anchor = verticalCenter - oldSpan / 2 + ratioFromBottom * oldSpan
            verticalCenter = anchor - (ratioFromBottom - 0.5) * nextSpan
            verticalSpan = nextSpan
            return
        }
        visibleDuration = StudyGraphViewport.zoomedDuration(visibleDuration, deltaY: event.deltaY)
    }

    private func handleVerticalDrag(_ event: LiveGraphVerticalDragEvent) {
        if playback.followsCurve { sendFollowToggle() }
        let drawableHeight = max(1, event.size.height - 44)
        verticalCenter += Double(event.deltaY / drawableHeight) * verticalSpan
    }

    private func handleHorizontalDrag(_ event: LiveGraphHorizontalDragEvent) {
        let origin = dragOriginTime ?? playback.time
        let drawableWidth = max(1, event.size.width - 104)
        seek(min(max(0, origin - Double(event.translationX / drawableWidth) * visibleDuration), playback.duration))
    }

    private func sendFollowToggle() {
        guard playback.followsCurve else { return }
        playback.followsCurve = false
        toggleFollow()
    }
}

private struct StudyVerticalSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 18, height: 200))
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("Grafiğin dikey merkezini değiştir")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = min(range.upperBound, max(range.lowerBound, value))
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @MainActor @objc func changed(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue }
    }
}

private struct HoverTooltip<Content: View>: View {
    let message: String
    let content: Content
    @State private var isHovering = false

    init(_ message: String, @ViewBuilder content: () -> Content) {
        self.message = message
        self.content = content()
    }

    var body: some View {
        content
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
            .help(message)
    }
}

private struct LocalViewer: NSViewRepresentable {
    let viewer: URL
    let readAccessRoot: URL
    let study: RecentLibrary.StudyMetadata?
    @ObservedObject var playback: StudyPlaybackState
    let appTheme: AppTheme
    let graphAppearance: GraphAppearance
    let reloadToken: Int
    @Binding var webView: WKWebView?

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: playback)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "studyPlayback")
        configuration.userContentController.add(context.coordinator, name: "graphAppearance")
        let hideStandaloneControls = """
        (() => {
            document.body.classList.add('native-shell');
            const newRecording = document.getElementById('new-recording');
            if (newRecording) newRecording.style.display = 'none';
            const makamSettings = document.getElementById('makam-settings-open');
            if (makamSettings) makamSettings.style.display = 'none';
            const layoutMode = document.getElementById('layout-mode');
            if (layoutMode) {
                layoutMode.value = 'side';
                layoutMode.dispatchEvent(new Event('change'));
            }
            document.querySelectorAll('.resize-handle').forEach((handle) => {
                handle.style.display = 'none';
            });
            const style = document.createElement('style');
            style.textContent = `
                body.native-shell main { max-width: none; height: 100vh; padding: 16px; }
                body.native-shell .workspace,
                body.native-shell .workspace.side {
                    grid-template-columns: minmax(300px, 0.78fr) minmax(560px, 1.72fr);
                    gap: 16px;
                    height: calc(100vh - 32px);
                    overflow: hidden;
                }
                body.native-shell .workspace.side .media,
                body.native-shell .workspace.side .panel {
                    width: 100%;
                    height: 100%;
                    min-height: 0;
                }
                body.native-shell .workspace.side .media {
                    padding: 0;
                    background: #101418;
                    border: 1px solid rgba(104, 123, 140, .35);
                    border-radius: 12px;
                    overflow: hidden;
                }
                body.native-shell .workspace.side .media video {
                    height: 100%;
                    border-radius: 11px;
                }
                body.native-shell .workspace.side .panel {
                    padding: 16px;
                    border-radius: 12px;
                    border-color: rgba(116, 135, 152, .30);
                    box-shadow: none;
                }
                body.native-shell .workspace.side .chart-scroll { min-height: 0; }
                body.native-shell .workspace.side canvas { border-radius: 9px; }
                body.native-shell .resize-handle,
                body.native-shell .layout-tools,
                body.native-shell .player-controls,
                body.native-shell .panel > .tools { display: none !important; }
                @media (max-width: 900px) {
                    body.native-shell .workspace,
                    body.native-shell .workspace.side {
                        grid-template-columns: 1fr;
                        grid-template-rows: minmax(260px, .72fr) minmax(360px, 1.28fr);
                        overflow: auto;
                    }
                }
            `;
            document.head.append(style);
            const transport = document.querySelector('.player-controls');
            const play = document.getElementById('play-toggle');
            const markA = document.getElementById('set-a');
            const markB = document.getElementById('set-b');
            const loop = document.getElementById('loop');
            const reset = document.getElementById('reset');
            if (transport && play && markA && markB && loop && reset) {
                const transportStyle = document.createElement('style');
                transportStyle.textContent = `
                    body.native-shell .player-controls {
                        width: 100%; min-height: 52px; gap: 5px; padding: 6px;
                        background: var(--control-background, rgba(246,247,249,.96));
                        border: 1px solid rgba(116,135,152,.27); border-radius: 11px;
                        box-shadow: none;
                    }
                    body.native-shell .player-controls #play-toggle {
                        min-width: 94px; height: 38px; padding: 0 13px;
                        background: #ffffff; border: 1px solid rgba(116,135,152,.25);
                        color: #202b36;
                    }
                    body.native-shell .player-controls .transport-jump,
                    body.native-shell .player-controls #reset {
                        width: 36px; min-width: 36px; height: 36px; padding: 0;
                        font-weight: 750; font-variant-numeric: tabular-nums;
                    }
                    body.native-shell .player-controls .transport-jump {
                        border: 1px solid transparent;
                        color: #405465;
                    }
                    body.native-shell .player-controls .transport-jump:hover,
                    body.native-shell .player-controls #reset:hover { background: #e9eef4; }
                    body.native-shell .player-controls .transport-time {
                        min-width: 92px; padding: 0 7px; color: #536272;
                        font-size: 13px; font-weight: 650;
                    }
                    body.native-shell .player-controls .loop-label {
                        margin-left: auto; font-size: 13px; color: #536272;
                    }
                    body.native-shell .player-controls #loop { margin-right: 2px; }
                `;
                document.head.append(transportStyle);
                markA.textContent = 'A';
                markA.title = 'İmleçte A işaretini oluştur';
                markB.textContent = 'B';
                markB.title = 'İmleçte B işaretini oluştur';
                reset.textContent = '↺';
                reset.title = 'Başa dön';
                reset.setAttribute('aria-label', 'Başa dön');
                transport.insertBefore(reset, markA);
                const loopLabel = transport.querySelector('.loop-label');
                if (loopLabel) loopLabel.textContent = '↻ Loop';
            }

            const settingsDialog = document.getElementById('makam-settings');
            if (settingsDialog) {
                settingsDialog.classList.add('native-settings');
                const settingsForm = settingsDialog.querySelector('.settings-form');
                const practiceSection = settingsForm?.querySelector('.settings-section:not(.settings-appearance)');
                const settingsDescription = settingsForm?.querySelector(':scope > p');
                if (settingsDescription) settingsDescription.textContent = 'Görünüm, çalışma bağlamı ve makam aralıklarını buradan düzenleyebilirsin.';
                const layoutSetting = document.getElementById('layout-mode')?.closest('label');
                if (layoutSetting) layoutSetting.hidden = true;

                const speedRow = document.getElementById('vertical-follow')?.closest('.settings-actions');
                if (speedRow && !speedRow.classList.contains('native-playback-section')) {
                    speedRow.classList.add('native-playback-section');
                    const title = document.createElement('h3');
                    title.textContent = 'Oynatma';
                    speedRow.prepend(title);
                }

                const makamLabel = document.getElementById('makam-settings-mode')?.closest('label');
                const makamGrid = document.getElementById('makam-settings-grid');
                const makamTotal = document.getElementById('makam-settings-total');
                const finalActions = document.getElementById('makam-settings-apply')?.closest('.settings-actions');
                if (settingsForm && makamLabel && makamGrid && makamTotal && finalActions && !document.getElementById('native-makam-section')) {
                    const makamSection = document.createElement('section');
                    makamSection.id = 'native-makam-section';
                    makamSection.className = 'settings-section native-makam-section';
                    makamSection.innerHTML = '<h3>Makam aralıkları</h3><p class="native-section-note">Yedi aralık toplamı bir oktavda 53 koma olmalıdır.</p>';
                    makamSection.append(makamLabel, makamGrid, makamTotal);
                    finalActions.before(makamSection);
                }

                const total = document.getElementById('makam-settings-total');
                if (total) {
                    const updateTotalStatus = () => {
                        const match = total.textContent.match(/(\\d+)\\s*\\/\\s*53/);
                        const value = match ? Number(match[1]) : 0;
                        total.classList.toggle('is-valid', value === 53);
                        total.classList.toggle('is-invalid', value !== 53);
                        total.setAttribute('aria-label', value === 53 ? '53 koma doğrulandı' : `Toplam ${value} koma; 53 olmalı`);
                    };
                    new MutationObserver(updateTotalStatus).observe(total, { childList: true, subtree: true, characterData: true });
                    updateTotalStatus();
                }

                const settingsStyle = document.createElement('style');
                settingsStyle.textContent = `
                    body.native-shell dialog.native-settings {
                        width: min(700px, calc(100vw - 56px)); padding: 0; overflow: hidden;
                        border: 1px solid rgba(116,135,152,.32); border-radius: 14px;
                        background: #f6f7f9; box-shadow: 0 24px 70px rgba(18,33,47,.32);
                    }
                    body.native-shell dialog.native-settings::backdrop { background: rgba(20,29,38,.38); }
                    body.native-shell dialog.native-settings .settings-form { padding: 24px; }
                    body.native-shell dialog.native-settings .settings-form > h2 {
                        font-size: 22px; letter-spacing: -.02em; margin: 0 0 5px; color: #1c2732;
                    }
                    body.native-shell dialog.native-settings .settings-form > p {
                        margin: 0 0 20px; color: #657382; font-size: 13px;
                    }
                    body.native-shell dialog.native-settings .settings-section,
                    body.native-shell dialog.native-settings .native-playback-section {
                        display: grid; gap: 11px; margin: 12px 0 0; padding: 16px;
                        border: 1px solid rgba(116,135,152,.20); border-radius: 11px;
                        background: rgba(255,255,255,.78);
                    }
                    body.native-shell dialog.native-settings .settings-section h3,
                    body.native-shell dialog.native-settings .native-playback-section h3 {
                        margin: 0; color: #273645; font-size: 13px; font-weight: 750;
                    }
                    body.native-shell dialog.native-settings .settings-row {
                        display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 11px;
                    }
                    body.native-shell dialog.native-settings label { color: #596979; font-size: 12px; font-weight: 650; }
                    body.native-shell dialog.native-settings label select,
                    body.native-shell dialog.native-settings label input[type=number] {
                        display: block; width: 100%; margin-top: 5px; color: #263544;
                        border: 1px solid rgba(116,135,152,.32); border-radius: 7px;
                        background: rgba(255,255,255,.95); min-height: 29px;
                    }
                    body.native-shell dialog.native-settings .native-playback-section {
                        grid-template-columns: auto 1fr; align-items: center;
                    }
                    body.native-shell dialog.native-settings .native-playback-section h3 { grid-column: 1 / -1; }
                    body.native-shell dialog.native-settings .native-playback-section label { white-space: nowrap; }
                    body.native-shell dialog.native-settings .speed-stepper { justify-content: flex-end; margin: 0; }
                    body.native-shell dialog.native-settings .speed-stepper button {
                        width: 28px; min-width: 28px; height: 28px; padding: 0; border-radius: 7px;
                    }
                    body.native-shell dialog.native-settings .native-makam-section > label { max-width: 185px; }
                    body.native-shell dialog.native-settings .native-section-note {
                        margin: -4px 0 2px; color: #718091; font-size: 12px;
                    }
                    body.native-shell dialog.native-settings .settings-grid {
                        margin: 3px 0 0; padding: 12px; border-radius: 8px; background: rgba(237,241,245,.82);
                    }
                    body.native-shell dialog.native-settings .settings-grid label { font-size: 11px; font-weight: 650; }
                    body.native-shell dialog.native-settings .settings-total {
                        justify-self: start; margin-top: 2px; padding: 5px 9px; border-radius: 999px;
                        font-size: 12px; font-weight: 750; color: #a24f42; background: #fbe9e6;
                    }
                    body.native-shell dialog.native-settings .settings-total.is-valid { color: #28734b; background: #e6f4ea; }
                    body.native-shell dialog.native-settings .settings-form > .settings-actions:last-child {
                        margin: 20px -24px -24px; padding: 14px 24px; min-height: 64px;
                        align-items: center; border-top: 1px solid rgba(116,135,152,.22); background: rgba(236,239,243,.85);
                    }
                    body.native-shell dialog.native-settings #makam-settings-reset { margin-right: auto; }
                    body.native-shell dialog.native-settings #makam-settings-apply {
                        color: #fff; border-color: #2472be; background: #287bc8; font-weight: 700;
                    }
                    body.native-shell.theme-studio dialog.native-settings {
                        background: #20262d; color: #ebf1f7; border-color: rgba(159,180,199,.25);
                    }
                    body.native-shell.theme-studio dialog.native-settings .settings-form > h2,
                    body.native-shell.theme-studio dialog.native-settings .settings-section h3,
                    body.native-shell.theme-studio dialog.native-settings .native-playback-section h3 { color: #f0f5fa; }
                    body.native-shell.theme-studio dialog.native-settings .settings-form > p,
                    body.native-shell.theme-studio dialog.native-settings label,
                    body.native-shell.theme-studio dialog.native-settings .native-section-note { color: #b8c5d0; }
                    body.native-shell.theme-studio dialog.native-settings .settings-section,
                    body.native-shell.theme-studio dialog.native-settings .native-playback-section { background: rgba(44,54,64,.92); border-color: rgba(159,180,199,.16); }
                    body.native-shell.theme-studio dialog.native-settings .settings-grid { background: rgba(20,27,34,.50); }
                    body.native-shell.theme-studio dialog.native-settings .settings-total { color: #ffc2b8; background: rgba(142,68,56,.26); }
                    body.native-shell.theme-studio dialog.native-settings .settings-total.is-valid { color: #a7ebc3; background: rgba(48,133,84,.28); }
                    body.native-shell.theme-studio dialog.native-settings label select,
                    body.native-shell.theme-studio dialog.native-settings label input[type=number] { color: #ecf4fb; background: #192129; border-color: rgba(159,180,199,.28); }
                    body.native-shell.theme-studio dialog.native-settings .settings-form > .settings-actions:last-child { background: rgba(25,32,39,.92); border-color: rgba(159,180,199,.16); }
                    @media (max-width: 600px) {
                        body.native-shell dialog.native-settings .settings-row { grid-template-columns: 1fr 1fr; }
                        body.native-shell dialog.native-settings .settings-grid { grid-template-columns: repeat(4, minmax(0, 1fr)); }
                    }
                `;
                document.head.append(settingsStyle);
            }

            const verticalFollow = document.getElementById('vertical-follow');
            const speedStepper = document.querySelector('.speed-stepper');
            if (transport && verticalFollow && !document.getElementById('native-vertical-follow')) {
                const followLabel = document.createElement('span');
                followLabel.className = 'follow-label';
                followLabel.textContent = 'Takip';
                const followButton = document.createElement('button');
                followButton.id = 'native-vertical-follow';
                followButton.type = 'button';
                followButton.title = 'Pitch eğrisini dikeyde takip et';
                const syncFollow = () => followButton.setAttribute('aria-pressed', String(verticalFollow.checked));
                followButton.onclick = () => {
                    verticalFollow.checked = !verticalFollow.checked;
                    verticalFollow.dispatchEvent(new Event('change', { bubbles: true }));
                    syncFollow();
                    window.dispatchEvent(new Event('resize'));
                };
                verticalFollow.addEventListener('change', syncFollow);
                syncFollow();
                if (speedStepper) {
                    speedStepper.classList.add('native-transport-speed');
                    speedStepper.title = 'Çalma hızı';
                    transport.append(speedStepper);
                }
                transport.append(followLabel, followButton);
                const playbackSection = verticalFollow.closest('.native-playback-section');
                if (playbackSection) playbackSection.style.display = 'none';

                const workspaceStyle = document.createElement('style');
                workspaceStyle.textContent = `
                    body.native-shell .player-controls .native-transport-speed {
                        display: flex; align-items: center; gap: 4px; margin: 0 5px 0 auto;
                        color: #536272; font-size: 12px;
                    }
                    body.native-shell .player-controls .native-transport-speed button {
                        width: 26px; min-width: 26px; height: 28px; padding: 0; border: 0;
                        border-radius: 7px; color: #405465; background: transparent;
                    }
                    body.native-shell .player-controls .native-transport-speed button:hover { background: #e9eef4; }
                    body.native-shell .player-controls .native-transport-speed span {
                        min-width: 40px; text-align: center; font-variant-numeric: tabular-nums; font-weight: 700;
                    }
                    body.native-shell .player-controls .follow-label { color: #536272; font-size: 13px; }
                    body.native-shell .player-controls #native-vertical-follow {
                        position: relative; width: 48px; min-width: 48px; height: 28px; padding: 0;
                        border: 0; border-radius: 999px; background: #c9d3dc; transition: background .16s;
                    }
                    body.native-shell .player-controls #native-vertical-follow::after {
                        content: ''; position: absolute; top: 4px; left: 4px; width: 20px; height: 20px;
                        border-radius: 50%; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.22); transition: transform .16s;
                    }
                    body.native-shell .player-controls #native-vertical-follow[aria-pressed="true"] { background: #4d9bed; }
                    body.native-shell .player-controls #native-vertical-follow[aria-pressed="true"]::after { transform: translateX(20px); }
                    body.native-shell.theme-studio .player-controls .native-transport-speed,
                    body.native-shell.theme-studio .player-controls .follow-label { color: #d4e1eb; }
                    @media (max-width: 1100px) {
                        body.native-shell .player-controls { flex-wrap: wrap; }
                        body.native-shell .player-controls .native-transport-speed { margin-left: auto; }
                    }
                `;
                document.head.append(workspaceStyle);
            }
        })();
        """
        let studyContext = study.map {
            """
            (() => {
                const scale = document.getElementById('scale-mode');
                const tonic = document.getElementById('tonic');
                if (scale) { scale.value = '\($0.makam)'; scale.dispatchEvent(new Event('change')); }
                if (tonic) { tonic.value = '\($0.karar)'; tonic.dispatchEvent(new Event('change')); }
            })();
            """
        } ?? ""
        let playbackBridge = """
        (() => {
            const bridge = window.webkit?.messageHandlers?.studyPlayback;
            let viewer = window.klariVisionStudyViewer;
            if (!viewer) {
                const media = document.getElementById('media');
                const scale = document.getElementById('scale-mode');
                const tonic = document.getElementById('tonic');
                const follow = document.getElementById('vertical-follow');
                const defaults = {
                    nihavent:[9,4,9,9,4,9,9], kurdi:[4,9,9,9,4,9,9],
                    ussak:[8,5,9,9,4,9,9], hicaz:[5,12,5,9,8,5,9],
                    kurdilihicazkar:[4,9,9,9,4,9,9], hicazkar:[5,12,5,9,5,12,5]
                };
                const storedIntervals = () => {
                    try { return JSON.parse(localStorage.getItem('klarivision-makam-intervals-v1')) || defaults; }
                    catch (_) { return defaults; }
                };
                const theme = () => document.body.classList.contains('theme-studio') ? 'studio'
                    : document.body.classList.contains('theme-classic') ? 'classic' : 'focus';
                const markerTime = (id, fallback) => {
                    const text = document.getElementById(id)?.title || document.getElementById(id)?.textContent || '';
                    const match = text.match(/([0-9]+(?:[.,][0-9]+)?)/);
                    return match ? Number(match[1].replace(',', '.')) : fallback;
                };
                const click = id => document.getElementById(id)?.click();
                viewer = {
                    media, scale, tonic, follow,
                    settingsSnapshot() {
                        let graphAppearance = {pitchHex:'\(graphAppearance.pitchHex)',noteGuideHex:'\(graphAppearance.noteGuideHex)'};
                        try { graphAppearance = JSON.parse(localStorage.getItem('klarivision-graph-appearance-v1')) || graphAppearance; } catch (_) {}
                        return {theme:theme(),scale:scale?.value || 'major',tonic:Number(tonic?.value)||0,countdown:Number(document.getElementById('countdown')?.value)||0,intervals:storedIntervals(),graphAppearance};
                    },
                    applySettings(value) {
                        if (!value || typeof value !== 'object') return false;
                        localStorage.setItem('klarivision-makam-intervals-v1', JSON.stringify(value.intervals || defaults));
                        if (scale) { scale.value=value.scale; scale.dispatchEvent(new Event('change')); }
                        if (tonic) { tonic.value=String(value.tonic); tonic.dispatchEvent(new Event('change')); }
                        const countdown=document.getElementById('countdown'); if (countdown) countdown.value=String(value.countdown || 0);
                        return true;
                    },
                    snapshot() {
                        const duration = Number.isFinite(media?.duration) ? media.duration : 0;
                        const loop = document.getElementById('loop');
                        return {time:Number(media?.currentTime)||0,duration,ready:(media?.readyState||0)>=1,isPlaying:media ? !media.paused : false,rate:Number(media?.playbackRate)||1,loopEnabled:loop?.getAttribute('aria-pressed')==='true',loopA:markerTime('set-a',0),loopB:markerTime('set-b',duration),theme:theme(),followsCurve:!!follow?.checked,frequency:null,scale:scale?.value||'major',tonic:Number(tonic?.value)||0,intervals:storedIntervals()[scale?.value]||null};
                    },
                    command(value) {
                        if (value && typeof value === 'object' && value.type === 'seek') { if (media) media.currentTime=Math.max(0,Math.min(Number(value.seconds)||0,Number(media.duration)||0)); return; }
                        if (value === 'toggle') { if (media?.paused) media.play().catch(()=>{}); else media?.pause(); return; }
                        if (value === 'pause' || value === 'stop') { media?.pause(); return; }
                        if (value === 'reset') { if (media) media.currentTime=0; return; }
                        if (value === 'setA') { click('set-a'); return; }
                        if (value === 'setB') { click('set-b'); return; }
                        if (value === 'loop') { click('loop'); return; }
                        if (value === 'speedDown' && media) { media.playbackRate=Math.max(.1,Math.round((media.playbackRate-.05)*20)/20); return; }
                        if (value === 'speedUp' && media) { media.playbackRate=Math.min(1,Math.round((media.playbackRate+.05)*20)/20); return; }
                        if (value === 'follow' && follow) { follow.checked=!follow.checked; follow.dispatchEvent(new Event('change',{bubbles:true})); }
                    }
                };
                window.klariVisionStudyViewer = viewer;
            }
            if (!bridge || !viewer) return;
            let lastSent = 0;
            const send = (force = false, discontinuity = false) => {
                const now = performance.now();
                if (!force && now - lastSent < 50) return;
                lastSent = now;
                const snapshot = viewer.snapshot();
                snapshot.discontinuity = discontinuity;
                bridge.postMessage(snapshot);
            };
            // Do not rely on a hidden HTML stepper for native-shell transport.
            // A number of saved viewers predate the public command API, and
            // their rate input can be visually hidden or stale after a loop.
            const inheritedCommand = viewer.command?.bind(viewer);
            viewer.command = (value) => {
                if (value === 'speedDown' || value === 'speedUp') {
                    const current = Number(viewer.media?.playbackRate) || 1;
                    const delta = value === 'speedDown' ? -0.05 : 0.05;
                    const rate = Math.max(0.10, Math.min(2, Math.round((current + delta) * 20) / 20));
                    if (viewer.media) {
                        viewer.media.defaultPlaybackRate = rate;
                        viewer.media.playbackRate = rate;
                    }
                    const input = document.getElementById('playback-rate');
                    if (input) {
                        input.value = rate.toFixed(2);
                        input.dispatchEvent(new Event('input', { bubbles: true }));
                    }
                    send(true);
                    return;
                }
                const isSeek = value && typeof value === 'object' && value.type === 'seek';
                const isReset = value === 'reset';
                inheritedCommand?.(value);
                // Existing viewers may only update their A/B DOM markers in a
                // click handler. Send again after that handler has completed.
                if (isSeek || isReset) {
                    // Wait for the media element to expose its new position;
                    // otherwise an old forced snapshot can briefly re-anchor
                    // the native graph before `seeked` arrives.
                    setTimeout(() => send(true, true), 0);
                } else if (value === 'setA' || value === 'setB' || value === 'loop') {
                    setTimeout(() => send(true), 0);
                } else {
                    send(true);
                }
            };
            let interval = setInterval(send, 50);
            window.klariVisionStudyPlaybackBridge = { send, dispose: () => clearInterval(interval) };
            let lastMediaTime = null;
            ['play', 'pause', 'seeking', 'seeked', 'timeupdate', 'loadedmetadata', 'canplay', 'ratechange', 'ended'].forEach((event) => viewer.media?.addEventListener(event, () => {
                const currentTime = Number(viewer.media?.currentTime) || 0;
                const loopJump = lastMediaTime !== null && currentTime + 0.10 < lastMediaTime;
                lastMediaTime = currentTime;
                const discontinuity = event === 'seeking' || event === 'seeked' || event === 'ended' || loopJump;
                send(event !== 'timeupdate' || discontinuity, discontinuity);
            }));
            ['change', 'input'].forEach((event) => {
                viewer.scale?.addEventListener(event, () => send(true));
                viewer.tonic?.addEventListener(event, () => send(true));
                viewer.follow?.addEventListener(event, () => send(true));
            });
            send(true);
        })();
        """
        let appearanceJSON = "{\"pitchHex\":\"\(graphAppearance.pitchHex)\",\"noteGuideHex\":\"\(graphAppearance.noteGuideHex)\"}"
        let graphAppearanceBridge = """
        (() => {
            window.klariVisionStudyViewer?.setGraphAppearance?.(\(appearanceJSON), { persist: false, notify: false });
            const body = document.body;
            body.classList.remove('theme-studio', 'theme-classic');
            if ('\(appTheme.rawValue)' === 'studio') body.classList.add('theme-studio');
            if ('\(appTheme.rawValue)' === 'classic') body.classList.add('theme-classic');
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideStandaloneControls + studyContext + playbackBridge + graphAppearanceBridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadFileURL(viewer, allowingReadAccessTo: readAccessRoot)
        context.coordinator.lastAppliedReloadToken = reloadToken
        DispatchQueue.main.async { self.webView = webView }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Refresh/reanalyse rewrite the saved HTML file in place at the same
        // path, so `webView.url == viewer` still holds afterwards. Without
        // also checking the reload token, the freshly written pitch curve on
        // disk would never actually get shown in the already-loaded page.
        let urlChanged = webView.url != viewer
        let reloadRequested = context.coordinator.lastAppliedReloadToken != reloadToken
        guard !urlChanged, !reloadRequested else {
            // A fresh page load resets JS-side theme/appearance state, so the
            // next successful update must re-apply rather than trust the
            // stale cache from the previous page.
            context.coordinator.lastAppliedGraphAppearance = nil
            context.coordinator.lastAppliedTheme = nil
            context.coordinator.lastAppliedReloadToken = reloadToken
            if urlChanged {
                webView.loadFileURL(viewer, allowingReadAccessTo: readAccessRoot)
            } else {
                webView.reloadFromOrigin()
            }
            return
        }
        // SwiftUI re-evaluates this representable on every `StudyPlaybackState`
        // publish (~20Hz during playback), but graph appearance and theme only
        // ever change on user action. Re-running `evaluateJavaScript` on every
        // such tick competes on the WKWebView's JS thread with its own
        // playback `setInterval`/`requestAnimationFrame` loop and visibly
        // contributes to graph stutter, so only push these when they actually
        // changed since the last apply.
        if context.coordinator.lastAppliedGraphAppearance != graphAppearance {
            applyGraphAppearance(to: webView)
            context.coordinator.lastAppliedGraphAppearance = graphAppearance
        }
        if context.coordinator.lastAppliedTheme != appTheme {
            applyTheme(to: webView)
            context.coordinator.lastAppliedTheme = appTheme
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.evaluateJavaScript("""
        (() => {
            window.klariVisionStudyViewer?.command?.('pause');
            if (window.klariVisionStudyPlaybackBridge?.dispose) window.klariVisionStudyPlaybackBridge.dispose();
        })();
        """)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "studyPlayback")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "graphAppearance")
        webView.stopLoading()
    }

    private func applyGraphAppearance(to webView: WKWebView) {
        let payload = "{\"pitchHex\":\"\(graphAppearance.pitchHex)\",\"noteGuideHex\":\"\(graphAppearance.noteGuideHex)\"}"
        webView.evaluateJavaScript("window.klariVisionStudyViewer?.setGraphAppearance?.(\(payload), { persist: false, notify: false });")
    }

    private func applyTheme(to webView: WKWebView) {
        let theme = appTheme.rawValue
        webView.evaluateJavaScript("""
        (() => {
            document.body.classList.remove('theme-studio', 'theme-classic');
            if ('\(theme)' === 'studio') document.body.classList.add('theme-studio');
            if ('\(theme)' === 'classic') document.body.classList.add('theme-classic');
        })();
        """)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let playback: StudyPlaybackState
        var lastAppliedGraphAppearance: GraphAppearance?
        var lastAppliedTheme: AppTheme?
        var lastAppliedReloadToken: Int?

        init(playback: StudyPlaybackState) {
            self.playback = playback
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "studyPlayback" {
                DispatchQueue.main.async { [playback] in playback.apply(message.body) }
                return
            }
            guard message.name == "graphAppearance",
                  let values = message.body as? [String: Any] else { return }
            let appearance = GraphAppearance(
                pitchHex: values["pitchHex"] as? String ?? GraphAppearance.defaultPitchHex,
                noteGuideHex: values["noteGuideHex"] as? String ?? GraphAppearance.defaultNoteGuideHex
            )
            appearance.save()
        }
    }
}
