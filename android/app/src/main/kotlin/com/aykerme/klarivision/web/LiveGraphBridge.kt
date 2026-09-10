// KlariVision Android — canlı pitch karelerini window.kvLive'a taşıyan tek
// yönlü (Kotlin→JS) köprü, Swift iPadLiveWebViewStore'dan port edildi. Sayfa
// hazır olana dek kareler tamponlanır, sonra JSON-safe toplu yollanır;
// context/renk/running her yeniden yüklemede tekrar gönderilir.

package com.aykerme.klarivision.web

import android.content.Context
import android.os.Handler
import android.os.Looper
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

    /**
     * WebView'in TÜM metotları, onu yaratan thread'den (ana thread)
     * çağrılmak ZORUNDADIR; başka bir thread'den çağrılırsa WebView
     * `checkThread()` içinde ölümcül istisna atar ve uygulama ÇÖKER.
     *
     * Bu soyut bir tehlike değil, ölçülmüş bir çökmedir: `LiveAudioCapture.
     * stop()` bir coroutine worker'ında koşuyor, oradan `flushNow()` →
     * `LiveOrchestrator.onFrames` → [append] zinciri geliyordu ve Çalma
     * Modu'nu her durduruşta uygulama "A WebView method was called on
     * thread 'DefaultDispatcher-worker-N'" ile ölüyordu.
     *
     * Çözüm çağıranlara "ana thread'den çağır" demek DEĞİL — köprü
     * WebView'in sahibi olduğu için thread garantisini KENDİSİ verir:
     * aşağıdaki her genel metot gövdesi [runOnMain] ile ana Looper'a
     * taşınır. Koşullu değil, KOŞULSUZ post edilir; bir kısmı yerinde bir
     * kısmı ertelenmiş çalışsaydı sıra bozulabilir, ör. ana thread'den
     * gelen bir [reset] worker'dan post edilmiş bir [append]'i geçebilirdi.
     * Koşulsuz post, tüm çağrıların FIFO sırasını korur ve köprünün iç
     * durumunu (`pendingFrames`, `ready`, `lastContext`) tek bir thread'e
     * hapseder — bu yüzden ayrıca kilit gerekmez.
     */
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun runOnMain(block: () -> Unit) {
        mainHandler.post(block)
    }

    private val assetLoader = ViewerAssets.buildAssetLoader(context, importsDir)
    private var ready = false
    private var safeTopDp = 0f
    private var safeBottomDp = 0f
    private var isRunning = false
    private var lastContext: LiveContextPayload? = null
    private val pendingFrames = mutableListOf<PitchFrame>()

    init {
        ViewerAssets.applyFullSizeLayout(webView)
        ViewerAssets.configureSecurity(webView)
        ViewerAssets.attachConsoleBridge(webView)
        ViewerAssets.disableNativeGestures(webView)
        webView.webViewClient = ViewerWebViewClient(assetLoader, importsDir) {
            ready = true
            sendSafeAreaInsets()
            sendContext()
            sendRunning()
            flush()
        }
    }

    /** LiveViewer.html'i appassets üzerinden yükle. */
    fun load() = runOnMain {
        ready = false
        webView.loadUrl(ViewerAssets.LIVE_VIEWER_URL)
    }

    /** Yeni kareleri kuyrukla; sayfa hazırsa hemen yolla. */
    fun append(frames: List<PitchFrame>) {
        if (frames.isEmpty()) return
        runOnMain {
            pendingFrames.addAll(frames)
            if (ready) flush()
        }
    }

    fun setContext(payload: LiveContextPayload) = runOnMain {
        lastContext = payload
        sendContext()
    }

    /**
     * Grafiğin akış saatini başlatır/durdurur. Çalışırken pencere gerçek
     * zamanda kayar (sessizlik akışı kesmez); durunca olduğu yerde donar.
     */
    fun setRunning(running: Boolean) = runOnMain {
        isRunning = running
        sendRunning()
    }

    fun reset() = runOnMain {
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


    /**
     * Sistem çubuğu boşluklarını sayfaya CSS değişkeni olarak bildirir.
     *
     * `WKWebView` `env(safe-area-inset-*)`'i doğru doldurur; Android WebView
     * oraya yalnız EKRAN ÇENTİĞİNİ koyar, durum/gezinme çubuğunu koymaz.
     * Grafik kasten kenardan kenara çizildiği için bu bilgi olmadan sayfanın
     * üst etiketi durum çubuğunun altında kalıyor. Değer Compose tarafından
     * (`WindowInsets.safeDrawing`) ölçülüp buraya verilir; sayfa CSS'i
     * `env()` ile bu değişkenin BÜYÜĞÜNÜ alır, böylece iki platform da aynı
     * sayfayı bozmadan kullanır.
     */
    fun setSafeAreaInsets(topDp: Float, bottomDp: Float) = runOnMain {
        safeTopDp = topDp
        safeBottomDp = bottomDp
        sendSafeAreaInsets()
    }

    private fun sendSafeAreaInsets() {
        if (!ready) return
        evaluate(
            "document.documentElement.style.setProperty('--kv-inset-top','${safeTopDp}px');" +
                "document.documentElement.style.setProperty('--kv-inset-bottom','${safeBottomDp}px');",
        )
    }

    private fun evaluate(script: String) {
        webView.evaluateJavascript(script, null)
    }
}
