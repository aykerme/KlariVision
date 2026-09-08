// KlariVision Android — canlı pitch karelerini window.kvLive'a taşıyan tek
// yönlü (Kotlin→JS) köprü, Swift iPadLiveWebViewStore'dan port edildi. Sayfa
// hazır olana dek kareler tamponlanır, sonra JSON-safe toplu yollanır;
// context/renk/running her yeniden yüklemede tekrar gönderilir.

package com.aykerme.klarivision.web

import android.content.Context
import android.webkit.WebView
import com.aykerme.klarivision.study.PitchFrame
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.io.File

/**
 * `window.kvLive`'a giden çağrının yükü — `{makam, karar, guides, follow,
 * pitchColor, guideColor, kararColor}`. `iPadLiveWebViewStore.sendContextIfReady`
 * ile birebir aynı alan adları.
 */
data class LiveContextPayload(
    val makam: String,
    val karar: String,
    val guides: List<GuidePayload>,
    val follow: Boolean,
    val pitchColor: String,
    val guideColor: String,
    val kararColor: String
) {
    fun toJsonObject(): JsonObject = buildJsonObject {
        put("makam", makam)
        put("karar", karar)
        putJsonArray("guides") {
            guides.forEach { guide ->
                addJsonObject {
                    put("name", guide.name)
                    put("hz", guide.hz)
                    put("karar", guide.karar)
                }
            }
        }
        put("follow", follow)
        put("pitchColor", pitchColor)
        put("guideColor", guideColor)
        put("kararColor", kararColor)
    }

    fun toJsonString(): String = toJsonObject().toString()
}

/**
 * `window.kvLive.append([{t,f,c,v}])` çerçeve listesi serileştirmesi —
 * `iPadLiveGraphPayload.make` ile birebir aynı kural: sonsuz olmayan zaman
 * zorunlu, unvoiced ya da sıfır/altı frekans `f=0`'a düşürülür, `v` yalnız
 * hem sesli hem de pozitif frekanslı karelerde `true`.
 */
object LiveFramePayload {
    fun toJsonArray(frames: List<PitchFrame>): JsonArray = buildJsonArray {
        frames.forEach { frame ->
            if (!frame.time.isFinite()) return@forEach
            val frequency = if (frame.frequency.isFinite() && frame.frequency > 0) frame.frequency else 0.0
            val confidence = if (frame.confidence.isFinite()) frame.confidence else 0.0
            addJsonObject {
                put("t", frame.time)
                put("f", frequency)
                put("c", confidence)
                put("v", frame.voiced && frequency > 0)
            }
        }
    }

    fun toJsonString(frames: List<PitchFrame>): String = toJsonArray(frames).toString()
}

/**
 * `window.kvLive` global'ine tek yönlü çağrılar yapan köprü. WKWebView
 * eşdeğeri (`WebView`) sahipliği burada; `store.webView`'i tıpkı
 * `iPadLiveWebViewStore` gibi dışa açar ki üst katman (P5a, Compose
 * `AndroidView`) onu doğrudan yerleştirebilsin.
 */
class LiveGraphBridge(context: Context, importsDir: File) {
    val webView: WebView = WebView(context)

    private val assetLoader = ViewerAssets.buildAssetLoader(context, importsDir)
    private var ready = false
    private var isRunning = false
    private var lastContext: LiveContextPayload? = null
    private val pendingFrames = mutableListOf<PitchFrame>()

    init {
        ViewerAssets.configureSecurity(webView)
        ViewerAssets.disableNativeGestures(webView)
        webView.webViewClient = ViewerWebViewClient(assetLoader) {
            ready = true
            sendContext()
            sendRunning()
            flush()
        }
    }

    /** LiveViewer.html'i appassets üzerinden yükle. */
    fun load() {
        ready = false
        webView.loadUrl(ViewerAssets.LIVE_VIEWER_URL)
    }

    /** Yeni kareleri kuyrukla; sayfa hazırsa hemen yolla. */
    fun append(frames: List<PitchFrame>) {
        if (frames.isEmpty()) return
        pendingFrames.addAll(frames)
        if (ready) flush()
    }

    fun setContext(payload: LiveContextPayload) {
        lastContext = payload
        sendContext()
    }

    /**
     * Grafiğin akış saatini başlatır/durdurur. Çalışırken pencere gerçek
     * zamanda kayar (sessizlik akışı kesmez); durunca olduğu yerde donar.
     */
    fun setRunning(running: Boolean) {
        isRunning = running
        sendRunning()
    }

    fun reset() {
        pendingFrames.clear()
        evaluate("window.kvLive && window.kvLive.reset();")
    }

    private fun flush() {
        if (pendingFrames.isEmpty()) return
        val batch = pendingFrames.toList()
        pendingFrames.clear()
        evaluate("window.kvLive && window.kvLive.append(${LiveFramePayload.toJsonString(batch)});")
    }

    private fun sendContext() {
        if (!ready) return
        val payload = lastContext ?: return
        evaluate("window.kvLive && window.kvLive.context(${payload.toJsonString()});")
    }

    private fun sendRunning() {
        if (!ready) return
        evaluate("window.kvLive && window.kvLive.setRunning($isRunning);")
    }

    private fun evaluate(script: String) {
        webView.evaluateJavascript(script, null)
    }
}
