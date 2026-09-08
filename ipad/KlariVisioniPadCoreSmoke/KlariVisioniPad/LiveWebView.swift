// KlariVision iPhone/iPad — canlı pitch karelerini JavaScript canvas'a taşır.
// Store tek WKWebView sahibidir; sayfa hazır olana dek kareleri tamponlar ve
// sonra JSON-safe toplu yollar. Makam/karar/renk bağlamı ölçümü değiştirmez.

import Foundation
import OSLog
import SwiftUI
import WebKit

enum iPadLiveGraphPayload {
    static func make(from frames: [iPadPitchFrame]) -> [[String: Any]] {
        frames.compactMap { frame in
            guard frame.time.isFinite else { return nil }
            let frequency = frame.frequency.isFinite && frame.frequency > 0 ? frame.frequency : 0
            let confidence = frame.confidence.isFinite ? frame.confidence : 0
            return [
                "t": frame.time,
                "f": frequency,
                "c": confidence,
                "v": frame.voiced && frequency > 0,
            ]
        }
    }
}

@MainActor
final class iPadLiveWebViewStore: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    /// Stable identity used to prove layout changes keep the same live canvas.
    var webViewIdentity: ObjectIdentifier { ObjectIdentifier(webView) }
    private var ready = false
    private var hasLoaded = false
    /// Whether capture is live. The page's clock only advances while this is
    /// true, so it is remembered here and re-sent whenever the page reloads.
    private var isRunning = false
    private var pendingFrames: [iPadPitchFrame] = []
    private var context = iPadMusicContext()
    private var pitchColor = "#67d5ff"
    private var guideColor = "#b7d8ff"
    private var kararColor = "#E75A5A"
    private var makamIntervals = iPadMakamIntervalsStore()

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func load() throws {
        guard !hasLoaded else { return }
        let root = try iPadStudyImportService.importsDirectory().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Viewer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("LiveViewer.html")
        guard let source = Bundle.main.url(forResource: "LiveViewer", withExtension: "html") else {
            throw iPadStudyImportError.unableToCopy
        }
        if !FileManager.default.fileExists(atPath: destination.path) ||
            (try? Data(contentsOf: source)) != (try? Data(contentsOf: destination)) {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        ready = false
        hasLoaded = true
        webView.loadFileURL(destination, allowingReadAccessTo: root)
    }

    func append(_ frames: [iPadPitchFrame], context: iPadMusicContext) {
        self.context = context
        pendingFrames.append(contentsOf: frames)
        guard ready else { return }
        flush()
    }

    func setContext(_ context: iPadMusicContext) { self.context = context; sendContextIfReady() }
    func setStyle(pitchColor: String, guideColor: String, kararColor: String, makamIntervals: iPadMakamIntervalsStore? = nil) {
        self.pitchColor = pitchColor
        self.guideColor = guideColor
        self.kararColor = kararColor
        if let makamIntervals { self.makamIntervals = makamIntervals }
        sendContextIfReady()
    }

    func reset() {
        pendingFrames.removeAll()
        webView.evaluateJavaScript("window.kvLive && window.kvLive.reset();")
    }

    /// Starts/stops the graph's own stream clock.  While running, the window
    /// scrolls on wall time instead of waiting for the next voiced frame, so
    /// silences keep flowing; while stopped it freezes where it is.
    func setRunning(_ running: Bool) {
        isRunning = running
        sendRunningIfReady()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        sendContextIfReady()
        sendRunningIfReady()
        flush()
    }

    private func flush() {
        guard !pendingFrames.isEmpty else { return }
        let batch = pendingFrames; pendingFrames.removeAll()
        let payload = iPadLiveGraphPayload.make(from: batch)
        guard !payload.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            iPadLiveDiagnostics.logger.error("Live graph payload could not be serialized; inputFrames=\(batch.count, privacy: .public)")
            return
        }
        webView.evaluateJavaScript("window.kvLive && window.kvLive.append(\(json));") { _, error in
            if let error {
                iPadLiveDiagnostics.logger.error("Live graph JavaScript append failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func sendContextIfReady() {
        guard ready else { return }
        let payload: [String: Any] = [
            "makam": context.makam.rawValue, "karar": context.karar.rawValue,
            "guides": context.guideNotes(commas: makamIntervals.commas(for: context.makam)).map { ["name": $0.name, "hz": $0.hz, "karar": $0.isKarar] }, "follow": context.followsCurve,
            "pitchColor": pitchColor, "guideColor": guideColor, "kararColor": kararColor,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.kvLive && window.kvLive.context(\(json));")
    }

    private func sendRunningIfReady() {
        guard ready else { return }
        webView.evaluateJavaScript("window.kvLive && window.kvLive.setRunning(\(isRunning));")
    }
}

struct iPadLiveWebView: UIViewRepresentable {
    @ObservedObject var store: iPadLiveWebViewStore

    func makeUIView(context: Context) -> WKWebView {
        let webView = store.webView
        disableWebViewGestures(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        disableWebViewGestures(uiView)
    }

    /// The graph reads raw touches itself (see the `touchstart`/`touchmove`
    /// handlers in LiveViewer.html — the same in-page, no-native-gesture
    /// approach StudyViewer.html and the macOS viewer's wheel zoom use), so
    /// WKWebView's own pinch-zoom/pan must stay out of the way: it scales the
    /// whole page, which moves the perde labels off their lines and rescales
    /// every stroke. Unlike the study viewer there is no video pane here, so
    /// the graph always owns the surface and this is unconditional.
    private func disableWebViewGestures(_ webView: WKWebView) {
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bouncesZoom = false
    }
}
