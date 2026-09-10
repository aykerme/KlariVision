// KlariVision Android — canlı yolun kare bütçesini parçalarına ayıran
// ölçüm katmanı. VARSAYILAN OLARAK KAPALI: dış bir değerlendirme WebView +
// evaluateJavascript JSON köprüsünü (LiveGraphBridge) Android takılmasının
// (jank) kaynağı olarak işaret etti ve onu Jetpack Compose Canvas ile
// değiştirmeyi önerdi. Bu, grafiğin HTML'inin iPad ile byte-eşit paylaşılan
// kanonik bir varlık olduğu bu projede BÜYÜK ve GERİ DÖNÜŞÜ ZOR bir
// değişiklik (bkz. android/app/src/main/assets/viewer/README.md) — bu yüzden
// önce ÖLÇÜYORUZ: hangi aşama (JNI/motor mu, JSON serileştirme mi,
// evaluateJavascript mi) asıl maliyeti taşıyor, sökmeden önce bunu bilmeden
// karar verilmez.
//
// Bu dosya Android çalışma zamanına bağımlı DEĞİLDİR (yalnız `java.util.
// concurrent.atomic`) — JVM testiyle koşar. Android'e bağımlı kısım
// (Log.i, Choreographer) LiveProfilingLog.kt'dedir; bu ayrım proje genelinde
// sistematiktir (bkz. PcmConversion, StopGate, InputLatencyProbe).

package com.aykerme.klarivision.profiling

import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt

/**
 * Ölçümün açık/kapalı anahtarı. Kapalıyken çağıran taraflar (LiveAudioCapture,
 * LiveGraphBridge) yalnız bu `Boolean`'ı okur ve hiçbir tahsis/ölçüm
 * yapmaz — sıfıra yakın maliyet garantisi buradan gelir. Açmak için:
 * `LiveInstrumentation.enabled = true` (bkz. android/LIVE_PROFILING.md).
 */
object LiveInstrumentation {
    @Volatile
    var enabled: Boolean = false

    /** Her metrik için tutulan örnek sayısı — bellek sabit, döngü içinde tahsis YOK. */
    private const val RING_CAPACITY = 4096

    /** JNI + motor süresi (ns) — `LiveAudioCapture.runCaptureLoop` içindeki `processor.process()` çağrısı. */
    val jniEngineNanos = ProfileRing(RING_CAPACITY)

    /** JSON serileştirme süresi (ns) — `LiveFramePayload.toJsonString`. */
    val jsonSerializeNanos = ProfileRing(RING_CAPACITY)

    /** Üretilen JSON string'in UTF-8 bayt boyutu — köprünün taşıdığı gerçek yük. */
    val jsonByteSize = ProfileRing(RING_CAPACITY)

    /** `webView.evaluateJavascript` çağrısının ANA İŞ PARÇACIĞINDA geçirdiği süre (ns). */
    val evaluateNanos = ProfileRing(RING_CAPACITY)

    /** Ardışık `Choreographer` vsync'leri arasındaki gerçek aralık (ns) — kare düzenliliğinin doğrudan kanıtı. */
    val frameIntervalNanos = ProfileRing(RING_CAPACITY)

    /**
     * Kare bütçesini (16,7 ms ya da cihazın gerçek yenileme aralığını) aşan
     * ardışık vsync sayısının TOPLAMI. Ring değil basit sayaç — asıl soru
     * "kaç kare atlandı" toplamıdır, dağılımı değil (dağılım için
     * [frameIntervalNanos] zaten var).
     */
    val skippedFrames = AtomicLong(0L)

    /** Yeni bir ölçüm penceresi (ör. yeni bir yakalama oturumu) için tüm birikimi sıfırlar. */
    fun resetAll() {
        jniEngineNanos.clear()
        jsonSerializeNanos.clear()
        jsonByteSize.clear()
        evaluateNanos.clear()
        frameIntervalNanos.clear()
        skippedFrames.set(0L)
    }

    /**
     * İki ardışık `Choreographer.doFrame` çağrısı arasındaki [deltaNanos]
     * aralığının kaç kare bütçesi karşılığı geldiğini hesaplar ve İLK karenin
     * dışındakileri "atlanan" sayar (delta == beklenen aralıksa 0 döner).
     * Saf fonksiyon — Android'e bağımlı değil, bu yüzden JVM testiyle koşar;
     * gerçek `Choreographer` bağlanması [LiveProfilingLog]'dadır.
     */
    fun droppedFrames(deltaNanos: Long, expectedIntervalNanos: Long): Int {
        if (expectedIntervalNanos <= 0L || deltaNanos <= 0L) return 0
        val framesElapsed = (deltaNanos.toDouble() / expectedIntervalNanos).roundToInt()
        return (framesElapsed - 1).coerceAtLeast(0)
    }
}

/**
 * Tek bir metriğin p50/p95/max özeti — [ProfileRing.summary]'nin sonucu.
 * `count == 0` iken tüm alanlar 0'dır (henüz örnek toplanmamış).
 */
data class ProfileSummary(
    val count: Int,
    val p50: Long,
    val p95: Long,
    val max: Long,
)

/**
 * Önceden ayrılmış, sabit kapasiteli dairesel tampon — SICAK YOLDA
 * (`record`) HİÇ tahsis yapmaz, en eski örneğin üzerine yazar. Özet
 * ([summary]) yalnız loglama anında çağrılır ve orada bir kopya/sıralama
 * YAPILABİLİR — RealtimeFactorBenchmark'taki p50/p95/max deseniyle aynı
 * gerekçe: ölçümün kendisi ucuz olmalı, özetleme seyrek ve ucuz olmayabilir.
 *
 * Tek yazıcılı kullanım varsayılır (her metrik tek bir iş parçacığından
 * beslenir — bkz. LIVE_PROFILING.md); `summary()` başka bir iş parçacığından
 * çağrılırsa en fazla birkaç örnek tutarsız (yarı yazılmış) okunabilir, bu
 * yalnızca bir profilleme aracı için kabul edilebilir bir yaklaşıklıktır.
 */
class ProfileRing(private val capacity: Int) {
    private val values = LongArray(capacity)
    private var writeIndex = 0
    private var filled = 0

    fun record(value: Long) {
        values[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
        if (filled < capacity) filled++
    }

    fun clear() {
        writeIndex = 0
        filled = 0
    }

    fun summary(): ProfileSummary {
        if (filled == 0) return ProfileSummary(0, 0, 0, 0)
        val sorted = values.copyOf(filled)
        sorted.sort()
        fun pct(p: Double): Long = sorted[((sorted.size - 1) * p).roundToInt()]
        return ProfileSummary(count = filled, p50 = pct(0.50), p95 = pct(0.95), max = sorted.last())
    }
}
