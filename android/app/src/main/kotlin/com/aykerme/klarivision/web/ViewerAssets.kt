// KlariVision Android — iki grafik görüntüleyicisinin ortak yükleme/güvenlik/
// jest kuralları. Canonik HTML kaynakları assets/viewer/ altında
// WebViewAssetLoader ile sunulur; kullanıcı medyası (filesDir/Imports) ayrı
// bir InternalStoragePathHandler ile aynı appassets alan adı altında açılır.
// Bu dosya `LiveGraphBridge` ve `StudyGraphBridge` tarafından paylaşılır.

package com.aykerme.klarivision.web

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebView
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import java.io.File
import java.io.FileInputStream

object ViewerAssets {
    private const val DOMAIN = "appassets.androidplatform.net"
    private const val ASSETS_PREFIX = "/assets/"
    private const val IMPORTS_PREFIX = "/imports/"

    const val LIVE_VIEWER_URL = "https://$DOMAIN$ASSETS_PREFIX" + "viewer/LiveViewer.html"
    const val STUDY_VIEWER_URL = "https://$DOMAIN$ASSETS_PREFIX" + "viewer/StudyViewer.html"

    /**
     * `assets/viewer` altındaki HTML sayfalarını ve `importsDir`
     * (filesDir/Imports) altındaki
     * kullanıcı medyasını aynı `appassets.androidplatform.net` alan adı
     * altında sunan yükleyici. Ağ erişimi yok; her iki yol da yerel.
     */
    fun buildAssetLoader(context: Context, importsDir: File): WebViewAssetLoader =
        WebViewAssetLoader.Builder()
            .setDomain(DOMAIN)
            .addPathHandler(ASSETS_PREFIX, WebViewAssetLoader.AssetsPathHandler(context))
            .addPathHandler(IMPORTS_PREFIX, WebViewAssetLoader.InternalStoragePathHandler(context, importsDir))
            .build()

    /** `importsDir` altındaki bir medya dosyasının appassets URL'i (`load` komutunun `url` alanı için). */
    fun importUrl(relativePath: String): String = "https://$DOMAIN$IMPORTS_PREFIX$relativePath"

    /** Yalnız kendi appassets alan adımıza giden istekleri yerel say. */
    fun isLocalUrl(url: Uri): Boolean = url.host == DOMAIN

    /**
     * Swift tarafının `allowFileAccess`/`allowUniversalAccessFromFileURLs`
     * kapalı WKWebView yapılandırmasının Android karşılığı: JavaScript yalnız
     * bu yerel içerik için açık, dosya sistemine ham erişim kapalı, oynatma
     * native transport düğmelerinden tetiklendiği için kullanıcı jesti
     * şartı da kapalı.
     */
    /**
     * Sayfanın `console` çıktısını logcat'e aktarır (`KlariVisionViewer`).
     * Grafik bir WebView içinde çizildiği için, sayfa betiği sessizce
     * öldüğünde dışarıdan tek belirti "boş grafik" oluyor; bu köprü olmadan
     * neden görünmüyor.
     */
    fun attachConsoleBridge(webView: WebView) {
        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                Log.i("KlariVisionViewer", "${message.sourceId()}:${message.lineNumber()} ${message.message()}")
                return true
            }
        }
    }

    /**
     * WebView'e AÇIK tam-boyut `LayoutParams` verir.
     *
     * Bu şart: `AndroidView` içine `LayoutParams`'sız eklenen bir View
     * varsayılan olarak `WRAP_CONTENT` alır, WebView de yükseklikte sınırsız
     * ölçülür. O durumda sayfanın ilk kapsayıcı bloğu SIFIR yükseklik alır ve
     * `html, body { height: 100% }` sıfıra çözülür — grafik canvas'ı birkaç
     * on piksele sıkışıp ekran boş görünür. `window.innerHeight` doğru değeri
     * bildirdiği için hata sayfa tarafından fark edilmez.
     *
     * Cihazda ölçüldü (SM-A736B): düzeltmeden önce `htmlH=0px`, `bodyH=0px`,
     * `canvasH=83px`; görüntü alanı ise 384x853 CSS px idi.
     * WKWebView bu davranışı göstermez, bu yüzden aynı sayfa iOS'ta sorunsuzdu.
     */
    fun applyFullSizeLayout(webView: WebView) {
        webView.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
    }

    /**
     * `Imports/` altındaki medyayı **HTTP aralık (Range) desteğiyle** sunar.
     *
     * Gerekçe: `WebViewAssetLoader.InternalStoragePathHandler` dosyayı düz bir
     * akış olarak döner — `Accept-Ranges`, `Content-Length` ve 206 yanıtı
     * yoktur. HTML5 `<audio>`/`<video>` bu durumda süreyi baştan öğrenemez;
     * süre çalarken büyür, arama (seek) çalışmaz. Cihazda gözlendi: 5 dakikalık
     * bir eser önce "5 sn" görünüyor, oynatma ilerledikçe süre artıyordu.
     *
     * `null` dönerse çağıran normal varlık yükleyiciye düşer.
     */
    fun interceptMediaRange(request: WebResourceRequest, importsDir: File): WebResourceResponse? {
        val url = request.url
        if (url.host != DOMAIN) return null
        val path = url.path ?: return null
        if (!path.startsWith(IMPORTS_PREFIX)) return null

        val name = path.removePrefix(IMPORTS_PREFIX)
        // Dizin dışına çıkma girişimlerini reddet.
        val file = File(importsDir, name).canonicalFile
        if (!file.path.startsWith(importsDir.canonicalFile.path) || !file.isFile) return null

        val length = file.length()
        val mime = guessMediaMime(file.name)
        val rangeHeader = request.requestHeaders["Range"] ?: request.requestHeaders["range"]

        if (rangeHeader == null) {
            val headers = mapOf(
                "Accept-Ranges" to "bytes",
                "Content-Length" to length.toString(),
            )
            return WebResourceResponse(mime, null, 200, "OK", headers, FileInputStream(file))
        }

        val match = Regex("bytes=(\\d*)-(\\d*)").find(rangeHeader) ?: return null
        val startText = match.groupValues[1]
        val endText = match.groupValues[2]
        val start = if (startText.isNotEmpty()) startText.toLong() else 0L
        val end = if (endText.isNotEmpty()) minOf(endText.toLong(), length - 1) else length - 1
        if (start > end || start >= length) return null

        val stream = FileInputStream(file)
        stream.skip(start)
        val count = end - start + 1
        val headers = mapOf(
            "Accept-Ranges" to "bytes",
            "Content-Length" to count.toString(),
            "Content-Range" to "bytes $start-$end/$length",
        )
        return WebResourceResponse(
            mime,
            null,
            206,
            "Partial Content",
            headers,
            LimitedInputStream(stream, count),
        )
    }

    private fun guessMediaMime(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "mp4", "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "m4a" -> "audio/mp4"
        "mp3" -> "audio/mpeg"
        "wav" -> "audio/wav"
        "aac" -> "audio/aac"
        "ogg" -> "audio/ogg"
        "flac" -> "audio/flac"
        else -> "application/octet-stream"
    }

    @SuppressLint("SetJavaScriptEnabled")
    fun configureSecurity(webView: WebView) {
        webView.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
            mediaPlaybackRequiresUserGesture = false
            domStorageEnabled = false
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
        }
    }

    /**
     * Native pan/zoom/scrub'ı devre dışı bırak. iOS tarafında pinch'i native
     * `UIPinchGestureRecognizer`'a yönlendirmek her `evaluateJavaScript`
     * turunda bir kare gecikme yaratmıştı (bkz. `iPadStudyWebView.applyMode`
     * yorumu) — sayfa artık pan/zoom/scrub'ı tamamen kendi `touch*`
     * dinleyicileriyle, senkron biçimde yapıyor. Android eşdeğeri WebView'in
     * kendi çok-dokunuşlu yakınlaştırma/kaydırma motorudur: aynı hataya
     * düşmemek için zoom native olarak tamamen kapatılır (yukarıda,
     * `configureSecurity`) ve kalan native kaydırma/fling tepkisi burada View
     * seviyesinde yutulur — dokunuş olayları yine de normal View dispatch
     * akışından geçip sayfanın `touchstart`/`touchmove` dinleyicilerine ulaşır,
     * yalnız WebView'in kendi scroll/fling davranışı üretilmez.
     */
    @SuppressLint("ClickableViewAccessibility")
    fun disableNativeGestures(webView: WebView) {
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false
        webView.overScrollMode = View.OVER_SCROLL_NEVER
        webView.isNestedScrollingEnabled = false
        webView.setOnTouchListener { view, _ ->
            view.parent?.requestDisallowInterceptTouchEvent(true)
            false
        }
    }
}

/**
 * `appassets.androidplatform.net` dışına giden her gezinmeyi reddeden ortak
 * `WebViewClient`. `onReady` sayfa `onPageFinished` olduğunda çağrılır —
 * bridge'ler bunu kuyruk boşaltma/ context-renk-running yeniden gönderme
 * için kullanır.
 */
class ViewerWebViewClient(
    private val assetLoader: WebViewAssetLoader,
    private val importsDir: File,
    private val onReady: (WebView) -> Unit
) : WebViewClientCompat() {

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
        // Medya önce aralık destekli yoldan geçer; değilse normal varlık yükleyici.
        ViewerAssets.interceptMediaRange(request, importsDir)
            ?: assetLoader.shouldInterceptRequest(request.url)

    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        // Yalnız appassets üzerindeki yerel içeriğe izin ver; dış gezinme
        // reddedilir. Ağ erişimi yoktur.
        return !ViewerAssets.isLocalUrl(request.url)
    }

    override fun onPageFinished(view: WebView, url: String?) {
        super.onPageFinished(view, url)
        onReady(view)
    }
}

/** Alt akıştan en fazla [remaining] bayt okutan sarmalayıcı — 206 yanıtları için. */
private class LimitedInputStream(
    private val source: java.io.InputStream,
    private var remaining: Long,
) : java.io.InputStream() {
    override fun read(): Int {
        if (remaining <= 0) return -1
        val value = source.read()
        if (value >= 0) remaining--
        return value
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (remaining <= 0) return -1
        val count = source.read(buffer, offset, minOf(length.toLong(), remaining).toInt())
        if (count > 0) remaining -= count
        return count
    }

    override fun available(): Int = minOf(source.available().toLong(), remaining).toInt()
    override fun close() = source.close()
}
