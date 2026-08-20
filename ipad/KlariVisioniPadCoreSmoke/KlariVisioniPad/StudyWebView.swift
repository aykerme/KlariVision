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
        case let .context(context, pitchColor, guideColor):
            payload = ["type": "context", "makam": context.makam.rawValue, "karar": context.karar.rawValue, "guides": context.guideFrequencies(), "pitchColor": pitchColor, "guideColor": guideColor]
        case .playPause: payload = ["type": "playPause"]
        case .pause: payload = ["type": "pause"]
        case let .seek(time): payload = ["type": "seek", "time": time]
        case let .rate(rate): payload = ["type": "rate", "rate": rate]
        case .markA: payload = ["type": "markA"]
        case .markB: payload = ["type": "markB"]
        case .loop: payload = ["type": "loop"]
        case .follow: payload = ["type": "follow"]
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

    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
        store.enqueue(.context(study.context, pitchColor: "#67d5ff", guideColor: "#b7d8ff"))
    }
}
