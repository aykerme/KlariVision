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
    private var pendingFrames: [iPadPitchFrame] = []
    private var context = iPadMusicContext()
    private var pitchColor = "#67d5ff"
    private var guideColor = "#b7d8ff"

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
    func setStyle(pitchColor: String, guideColor: String) { self.pitchColor = pitchColor; self.guideColor = guideColor; sendContextIfReady() }

    func reset() {
        pendingFrames.removeAll()
        webView.evaluateJavaScript("window.kvLive && window.kvLive.reset();")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        sendContextIfReady()
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
            "guides": context.guideFrequencies(), "follow": context.followsCurve,
            "pitchColor": pitchColor, "guideColor": guideColor,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.kvLive && window.kvLive.context(\(json));")
    }
}

struct iPadLiveWebView: UIViewRepresentable {
    @ObservedObject var store: iPadLiveWebViewStore
    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
