// KlariVision Android — Dinleme modunun kalıcı çift yönlü WebView köprüsü,
// Swift iPadStudyWebViewStore'dan port edildi. Yerel viewer/medya erişimini
// kurar, oynatma komutlarını JS'e yollar, JS'in gönderdiği oynatma anlık
// görüntülerini geri taşır.

package com.aykerme.klarivision.web

import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebView
import java.io.File

/**
 * `window.kvStudy`'e komut yollayan, `window.kvStudyBridge`'den anlık
 * görüntü alan çift yönlü köprü. `webView`'i `iPadStudyWebViewStore.webView`
 * gibi dışa açar — sahiplik burada, üst katman (P5a) yalnız yerleştirir.
 */
class StudyGraphBridge(
    context: Context,
    importsDir: File,
    private val onSnapshot: (PlaybackSnapshot) -> Unit = {}
) {
    /** Arayüz adı tam olarak `kvStudyBridge` olmalı — StudyViewer.html bunu arar. */
    private companion object {
        const val BRIDGE_INTERFACE_NAME = "kvStudyBridge"
    }

    val webView: WebView = WebView(context)

    private val assetLoader = ViewerAssets.buildAssetLoader(context, importsDir)
    private val queue = StudyCommandQueue()
    private var ready = false
    private var safeTopDp = 0f
    private var safeBottomDp = 0f
    private var handlerInstalled = false

    init {
        ViewerAssets.applyFullSizeLayout(webView)
        ViewerAssets.configureSecurity(webView)
        ViewerAssets.disableNativeGestures(webView)
        installBridgeInterface()
        webView.webViewClient = ViewerWebViewClient(assetLoader, importsDir) {
            ready = true
            sendSafeAreaInsets()
            flushIfReady()
        }
    }

    /** StudyViewer.html'i appassets üzerinden yükle. */
    fun load() {
        ready = false
        webView.loadUrl(ViewerAssets.STUDY_VIEWER_URL)
    }

    /** Sayfa hazır değilse kuyrukla, hazırsa hemen yolla. */
    fun enqueue(command: StudyCommand) {
        queue.enqueue(command)
        flushIfReady()
    }

    /** Oynatmayı durdur ve sayfayı boşa çıkar (çalışma kapatılırken). */
    fun close() {
        enqueue(StudyCommand.Pause)
        ready = false
        webView.loadUrl("about:blank")
    }

    /** Köprüyü tamamen söküp scriptmessage handler'ı kaldır (görünüm yok olurken). */
    fun tearDown() {
        ready = false
        evaluateRaw("window.kvStudy && window.kvStudy.receive({\"type\":\"pause\"});")
        if (handlerInstalled) {
            webView.removeJavascriptInterface(BRIDGE_INTERFACE_NAME)
            handlerInstalled = false
        }
    }

    private fun installBridgeInterface() {
        if (handlerInstalled) return
        webView.addJavascriptInterface(BridgeInterface(), BRIDGE_INTERFACE_NAME)
        handlerInstalled = true
    }

    private fun flushIfReady() {
        if (!ready) return
        queue.drainWhenReady().forEach(::send)
    }

    private fun send(command: StudyCommand) {
        evaluateRaw("window.kvStudy && window.kvStudy.receive(${command.toJsonString()});")
    }

    /**
     * Sistem çubuğu boşluklarını sayfaya CSS değişkeni olarak bildirir —
     * gerekçe için bkz. [LiveGraphBridge.setSafeAreaInsets].
     */
    fun setSafeAreaInsets(topDp: Float, bottomDp: Float) {
        safeTopDp = topDp
        safeBottomDp = bottomDp
        sendSafeAreaInsets()
    }

    private fun sendSafeAreaInsets() {
        if (!ready) return
        evaluateRaw(
            "document.documentElement.style.setProperty('--kv-inset-top','${safeTopDp}px');" +
                "document.documentElement.style.setProperty('--kv-inset-bottom','${safeBottomDp}px');",
        )
    }

    private fun evaluateRaw(script: String) {
        webView.evaluateJavascript(script, null)
    }

    /**
     * JS→Kotlin köprüsü. StudyViewer.html WebKit'in
     * `window.webkit.messageHandlers.studyPlayback` nesnesi yokken (Android'de
     * hiç yok) `window.kvStudyBridge.postMessage(JSON.stringify(snapshot))`
     * çağırır — bu yüzden burada String alınır, JSON nesnesi değil.
     */
    private inner class BridgeInterface {
        @JavascriptInterface
        fun postMessage(json: String) {
            PlaybackSnapshot.parse(json)?.let(onSnapshot)
        }
    }
}
