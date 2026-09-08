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
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import java.io.File

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
    private val onReady: (WebView) -> Unit
) : WebViewClientCompat() {

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
        assetLoader.shouldInterceptRequest(request.url)

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
