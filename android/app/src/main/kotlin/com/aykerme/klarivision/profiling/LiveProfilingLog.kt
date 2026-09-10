// KlariVision Android — LiveInstrumentation'ın Android'e bağımlı yarısı:
// Logcat çıktısı ve `Choreographer` ile atlanan kare sayımı. Saf hesaplama
// (ring tampon, p50/p95/max, "kaç kare atlandı" aritmetiği) LiveInstrumentation.kt'de
// yaşar ve JVM testiyle koşar — burası yalnız Android API'lerine bağlanır.

package com.aykerme.klarivision.profiling

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Choreographer
import android.view.Display

/**
 * `LiveInstrumentation` birikimini `Log.i(KlariVisionLiveProf, ...)` ile
 * yazar — `RealtimeFactorBenchmark`'ın (`KlariVisionRTF` etiketi) üslubuyla
 * aynı: p50/p95/max, tek satırda bir metrik, sayılar loglarda ("asıl çıktı
 * loglanan p50/p95/max değerleridir"). `adb logcat -s KlariVisionLiveProf:I`
 * ile okunur (bkz. android/LIVE_PROFILING.md).
 */
object LiveProfilingLog {
    const val TAG = "KlariVisionLiveProf"

    /** Ölçüm kapalıyken sessizce çıkar — hiçbir Log çağrısı, hiçbir string oluşturma yapılmaz. */
    fun logSummary(sessionLabel: String) {
        if (!LiveInstrumentation.enabled) return

        val jni = LiveInstrumentation.jniEngineNanos.summary()
        val json = LiveInstrumentation.jsonSerializeNanos.summary()
        val bytes = LiveInstrumentation.jsonByteSize.summary()
        val evalSummary = LiveInstrumentation.evaluateNanos.summary()
        val frame = LiveInstrumentation.frameIntervalNanos.summary()
        val skipped = LiveInstrumentation.skippedFrames.get()

        fun ms(nanos: Long) = "%.3f".format(nanos / 1e6)

        Log.i(TAG, "--- canlı yol kare bütçesi ($sessionLabel) ---")
        Log.i(
            TAG,
            "JNI+motor          p50=${ms(jni.p50)}ms p95=${ms(jni.p95)}ms max=${ms(jni.max)}ms (n=${jni.count})",
        )
        Log.i(
            TAG,
            "JSON serileştirme  p50=${ms(json.p50)}ms p95=${ms(json.p95)}ms max=${ms(json.max)}ms (n=${json.count})",
        )
        Log.i(
            TAG,
            "JSON bayt boyutu   p50=${bytes.p50}B p95=${bytes.p95}B max=${bytes.max}B (n=${bytes.count})",
        )
        Log.i(
            TAG,
            "evaluateJavascript p50=${ms(evalSummary.p50)}ms p95=${ms(evalSummary.p95)}ms " +
                "max=${ms(evalSummary.max)}ms (n=${evalSummary.count})",
        )
        Log.i(
            TAG,
            "kare aralığı       p50=${ms(frame.p50)}ms p95=${ms(frame.p95)}ms max=${ms(frame.max)}ms (n=${frame.count})",
        )
        Log.i(TAG, "atlanan kare sayısı (>bütçe): $skipped")
    }
}

/**
 * Ardışık `Choreographer` vsync'leri arasındaki aralığı ölçer ve bütçeyi
 * aşanları [LiveInstrumentation.skippedFrames]'e ekler. Yalnız [start] ile
 * [stop] arasında etkindir (ör. canlı grafik akarken) — durduğunda kendi
 * kendine callback zincirini bırakır, sızıntı yapmaz.
 *
 * Beklenen aralık, mümkünse `Display.getRefreshRate()`'ten türetilir
 * (değişken yenileme hızlı cihazlarda 16,7 ms sabitine güvenmek yanıltıcı
 * olur); alınamıyorsa 16,7 ms'ye (60 Hz) düşer.
 */
class FrameDropWatcher(display: Display? = null) : Choreographer.FrameCallback {
    private val expectedIntervalNanos: Long = run {
        val refreshHz = display?.refreshRate?.takeIf { it > 0f }
        if (refreshHz != null) (1_000_000_000.0 / refreshHz).toLong() else DEFAULT_INTERVAL_NANOS
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var lastFrameNanos: Long = 0L
    @Volatile
    private var active = false

    /**
     * Herhangi bir thread'den güvenle çağrılır. `Choreographer.getInstance()`
     * çağıranın thread'inde bir `Looper` ARAR ve yoksa "The current thread
     * must have a looper!" ile patlar; [LiveAudioCapture.start] ise ana
     * thread'de KOŞMAZ (ölçülmüş: bu tam olarak Çalma Modu'nu açılmaz hale
     * getiren hataydı). Bu yüzden Choreographer'a erişim her zaman ana
     * Looper'a taşınır — böylece [doFrame] de daima ana thread'de koşar ve
     * içindeki yeniden kuyruklama güvenli olur.
     */
    fun start() {
        if (active) return
        active = true
        lastFrameNanos = 0L
        mainHandler.post { if (active) Choreographer.getInstance().postFrameCallback(this) }
    }

    /** İdempotent: zaten durmuşsa hiçbir şey yapmaz. Kuyruklanmış son callback [doFrame] içinde kendini keser. */
    fun stop() {
        active = false
    }

    override fun doFrame(frameTimeNanos: Long) {
        if (!active) return
        if (lastFrameNanos != 0L) {
            val delta = frameTimeNanos - lastFrameNanos
            LiveInstrumentation.frameIntervalNanos.record(delta)
            val dropped = LiveInstrumentation.droppedFrames(delta, expectedIntervalNanos)
            if (dropped > 0) LiveInstrumentation.skippedFrames.addAndGet(dropped.toLong())
        }
        lastFrameNanos = frameTimeNanos
        // Kendini yeniden kuyruklamadan önce `active` kontrol edilir ki
        // `stop()` sonrası kuyrukta kalan tek bir callback sessizce ölsün.
        if (active) Choreographer.getInstance().postFrameCallback(this)
    }

    private companion object {
        const val DEFAULT_INTERVAL_NANOS = 16_666_667L // 60 Hz, cihazın gerçek hızı okunamazsa
    }
}
