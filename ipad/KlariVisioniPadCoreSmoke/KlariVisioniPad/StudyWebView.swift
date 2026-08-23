// KlariVision iPhone/iPad — çalışmanın kalıcı WKWebView köprüsü.
// Yerel viewer/medya erişimini kurar, payloadı JavaScript'e yollar ve oynatma
// komut/snapshotlarını iki yönlü taşır. UIViewRepresentable güncellemede yeni
// WebView oluşturmaz.

import Foundation
import SwiftUI
import WebKit

@MainActor
final class iPadStudyWebViewStore: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    /// Stable identity used by compact layout tests. Resize/orientation updates must
    /// keep this exact WKWebView instance alive so media state is not lost.
    var webViewIdentity: ObjectIdentifier { ObjectIdentifier(webView) }
    private var queue = iPadStudyCommandQueue()
    private var ready = false
    private var handlerInstalled = true
    var onSnapshot: (([String: Any]) -> Void)?

    override init() {
        let content = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        content.add(self, name: "studyPlayback")
        webView.navigationDelegate = self
    }

    func enqueue(_ command: iPadStudyCommand) {
        queue.append(command)
        flushIfReady()
    }

    func close() {
        enqueue(.pause)
        ready = false
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    func loadViewer(_ viewerURL: URL, allowingReadAccessTo root: URL) {
        installHandlerIfNeeded()
        ready = false
        webView.loadFileURL(viewerURL, allowingReadAccessTo: root)
    }

    func tearDownView() {
        ready = false
        webView.evaluateJavaScript("window.kvStudy?.receive({type:'pause'});")
        guard handlerInstalled else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "studyPlayback")
        handlerInstalled = false
        webView.navigationDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        flushIfReady()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "studyPlayback", let values = message.body as? [String: Any] else { return }
        onSnapshot?(values)
    }

    private func flushIfReady() {
        guard ready else { return }
        for command in queue.drainWhenReady() { send(command) }
    }

    private func send(_ command: iPadStudyCommand) {
        let payload: [String: Any]
        switch command {
        case let .load(url, frames):
            payload = ["type": "load", "url": url.absoluteString, "frames": frames.map { ["t": $0.time, "f": $0.frequency, "c": $0.confidence, "v": $0.voiced] }]
        case let .context(context, pitchColor, guideColor, komaOverride):
            payload = ["type": "context", "makam": context.makam.rawValue, "karar": context.karar.rawValue, "guides": context.guideNotes(commas: komaOverride).map { ["name": $0.name, "hz": $0.hz] }, "pitchColor": pitchColor, "guideColor": guideColor]
        case .playPause: payload = ["type": "playPause"]
        case .pause: payload = ["type": "pause"]
        case let .seek(time): payload = ["type": "seek", "time": time]
        case let .rate(rate): payload = ["type": "rate", "rate": rate]
        case .markA: payload = ["type": "markA"]
        case .markB: payload = ["type": "markB"]
        case .loop: payload = ["type": "loop"]
        case .follow: payload = ["type": "follow"]
        case let .setVideoFullscreen(isVideo): payload = ["type": "setMode", "mode": isVideo ? "video" : "graph"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.kvStudy && window.kvStudy.receive(\(json));")
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        webView.configuration.userContentController.add(self, name: "studyPlayback")
        webView.navigationDelegate = self
        handlerInstalled = true
    }
}

struct iPadStudyWebView: UIViewRepresentable {
    @ObservedObject var store: iPadStudyWebViewStore
    /// Whether the graph (not the video) currently fills the stage. Pinch
    /// handling for the graph is entirely in-page JS (see the `touchstart`/
    /// `touchmove` handlers in StudyViewer.html — the same synchronous,
    /// no-native-gesture approach the macOS viewer already uses for its
    /// wheel-driven zoom), so all this does is keep the WebView's own
    /// pinch-zoom/pan out of the way while the graph is showing; the video
    /// pane keeps the WebView's stock behavior unchanged.
    var isGraphMode: Bool = true

    func makeUIView(context: Context) -> WKWebView {
        let webView = store.webView
        applyMode(to: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        applyMode(to: uiView)
    }

    private func applyMode(to webView: WKWebView) {
        // An earlier attempt drove graph zoom through a native
        // UIPinchGestureRecognizer added alongside WKWebView's own. Even with
        // panning disabled, the playhead still drifted during zoom — the
        // Swift → JS command round trip (evaluateJavaScript, one per pinch
        // tick) could land a tick or more behind the live touch, so the
        // window briefly redrew against a stale zoom level. The graph now
        // reads raw touches straight from JS (synchronous with its own
        // requestAnimationFrame draw loop), so there's no cross-process
        // handoff left to lag — matching how the macOS viewer's wheel-driven
        // zoom has always worked. This just has to keep WKWebView's own
        // pinch-zoom/pan (which scales the whole page, axis-blind) from
        // fighting that JS handling while the graph is showing.
        webView.scrollView.pinchGestureRecognizer?.isEnabled = !isGraphMode
        webView.scrollView.isScrollEnabled = !isGraphMode
        webView.scrollView.bouncesZoom = !isGraphMode
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { }
}

@MainActor
enum iPadStudyViewerResource {
    static func load(into store: iPadStudyWebViewStore, study: iPadStudy) throws {
        let manager = FileManager.default
        let root = try iPadStudyImportService.importsDirectory(fileManager: manager).deletingLastPathComponent()
        let viewerDirectory = root.appendingPathComponent("Viewer", isDirectory: true)
        try manager.createDirectory(at: viewerDirectory, withIntermediateDirectories: true)
        let destination = viewerDirectory.appendingPathComponent("StudyViewer.html")
        guard let source = Bundle.main.url(forResource: "StudyViewer", withExtension: "html") else {
            throw iPadStudyImportError.unableToCopy
        }
        if !manager.fileExists(atPath: destination.path) ||
            (try? Data(contentsOf: source)) != (try? Data(contentsOf: destination)) {
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: source, to: destination)
        }
        store.loadViewer(destination, allowingReadAccessTo: root)
        store.enqueue(.load(study.sourceURL, study.frames))
        // Default, un-overridden intervals — the caller (`iPadStudyState`)
        // immediately follows this with its own context command carrying the
        // real makam-interval overrides, so this one is just a same-frame
        // placeholder until that lands.
        store.enqueue(.context(study.context, pitchColor: "#67d5ff", guideColor: "#b7d8ff", komaOverride: study.context.makam.guideCommas))
    }
}
