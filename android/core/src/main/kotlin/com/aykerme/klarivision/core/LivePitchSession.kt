package com.aykerme.klarivision.core

import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `kv_production_pitch_session_*` üzerine causal (canlı) pitch oturumu —
 * Çalma/live yolu içindir. `ipad/.../PitchABIAdapter.swift`'teki
 * `iPadProductionPitchSession`'ın Kotlin karşılığı; semantiği birebir korur.
 *
 * Bu sınıf pitch kararı üretmez: eşikleme/yumuşatma/oktav düzeltme/yeniden
 * örnekleme yoktur, yalnız C++ çekirdeğinin ürettiği kareleri taşır.
 *
 * KRİTİK SEMANTİK: C ABI çıktı vektörünü her `process`/`finish` çağrısında
 * BAŞTAN YAZAR. Bu yüzden her çağrının döndürdüğü liste `0 until
 * outputCount()` aralığından TAZE okunur; global bir imleç yoktur. Önceki
 * çağrının sonuçlarını saklamak isteyen çağıran taraf kendi listesini
 * biriktirmelidir (bkz. drainCurrentOutputs).
 *
 * Eşzamanlılık: aynı örneği (instance/handle) iki thread'den aynı anda
 * çağırmayın. Ne bu sınıf ne de C++ tarafı kilit tutar.
 *
 * `close()` idempotenttir; kapandıktan sonra herhangi bir kullanım
 * [IllegalStateException] fırlatır. Finalizer'a güvenilmez — çağıran taraf
 * `close()`'u (tercihen `use { }` ile) mutlaka çağırmalıdır.
 */
class LivePitchSession private constructor(minimumRms: Double) : AutoCloseable {

    companion object {
        private val REQUIRED_WINDOW_SIZE = PitchContract.EXPECTED_WINDOW_SIZE
        private val REQUIRED_SAMPLE_RATE_HZ = PitchContract.EXPECTED_SAMPLE_RATE_HZ.toDouble()

        /**
         * Yeni bir causal oturum oluşturur. Önce sözleşmeyi doğrular (bkz.
         * [PitchContract.load]); `minimumRms` verilmezse sözleşmenin
         * varsayılanı (`defaultMinimumRms`) kullanılır. Motor her zaman
         * `KV_ENGINE_UNIFIED_V1`'dir — bu port başka motor seçtirmez.
         */
        fun create(minimumRms: Double? = null): LivePitchSession {
            val contract = PitchContract.load()
            val rms = minimumRms ?: contract.defaultMinimumRms
            require(rms.isFinite() && rms >= 0) {
                "minimumRms sonlu ve negatif olmayan bir sayı olmalı."
            }
            return LivePitchSession(rms)
        }
    }

    @Volatile
    private var handle: Long = 0L
    private val closed = AtomicBoolean(false)

    init {
        val created = NativeBridge.nativeLiveCreate(PitchEngine.UNIFIED_V1, minimumRms)
        if (created == 0L) {
            throw PitchAbiException.SessionCreationFailed("Pitch oturumu oluşturulamadı.")
        }
        handle = created
    }

    private fun openHandle(): Long {
        check(!closed.get() && handle != 0L) {
            "LivePitchSession kapatıldıktan sonra kullanılamaz."
        }
        return handle
    }

    fun setMinimumRms(value: Double) {
        require(value.isFinite() && value >= 0) {
            "minimumRms sonlu ve negatif olmayan bir sayı olmalı."
        }
        val h = openHandle()
        if (!NativeBridge.nativeLiveSetMinimumRms(h, value)) {
            throw PitchAbiException.InvalidArgument("Minimum RMS eşiği ayarlanamadı.")
        }
    }

    fun reset() {
        NativeBridge.nativeLiveReset(openHandle())
    }

    /**
     * Bir analiz penceresini işler: `samples`, `EXPECTED_WINDOW_SIZE` (1536)
     * örnek mono Float32 PCM içeren DOĞRUDAN (direct) bir FloatBuffer
     * olmalı, `buffer.position()`'dan itibaren okunur. Örnekleme hızı her
     * zaman 48 kHz'dir (Swift tarafındaki gibi sabit geçilir, çağırana
     * parametre olarak açılmaz).
     *
     * Doğrudan olmayan bir buffer ya da 1536'dan farklı bir örnek sayısı
     * sessizce kabul edilmez — açık [PitchAbiException.InvalidArgument]
     * fırlatılır.
     *
     * Dönen liste, çıktı vektörünün BU çağrıdaki halidir (yukarıdaki
     * "kritik semantik" notuna bakın).
     */
    fun process(samples: FloatBuffer, sourceTimeSeconds: Double): List<PitchFrame> {
        val h = openHandle()
        validateWindow(samples)
        val ok = NativeBridge.nativeLiveProcess(
            h,
            samples,
            REQUIRED_WINDOW_SIZE,
            REQUIRED_SAMPLE_RATE_HZ,
            sourceTimeSeconds,
        )
        if (!ok) {
            throw PitchAbiException.ProcessingFailed("Pitch çekirdeği ses penceresini işleyemedi.")
        }
        return drainCurrentOutputs(h)
    }

    /** Oturumu sonlandırır ve son çıktı vektörünü döner (bkz. kritik semantik notu). */
    fun finish(): List<PitchFrame> {
        val h = openHandle()
        NativeBridge.nativeLiveFinish(h)
        return drainCurrentOutputs(h)
    }

    private fun validateWindow(samples: FloatBuffer) {
        if (!samples.isDirect) {
            throw PitchAbiException.InvalidArgument(
                "PCM verisi doğrudan (direct) bir buffer olmalı."
            )
        }
        if (samples.order() != java.nio.ByteOrder.nativeOrder()) {
            // docs/ANDROID_FEASIBILITY.md: yanlış byte sırası AÇIK hatadır.
            // ByteBuffer.allocateDirect varsayılanı BIG_ENDIAN'dır; native taraf
            // ham little-endian float okur, dolayısıyla sessiz kabul edilirse
            // byte'ları ters çevrilmiş çöp veri makul görünen bir pitch üretir.
            throw PitchAbiException.InvalidArgument(
                "PCM tamponu yerel byte sırasında olmalı (ByteOrder.nativeOrder())."
            )
        }
        val remaining = samples.remaining()
        if (remaining != REQUIRED_WINDOW_SIZE) {
            throw PitchAbiException.InvalidArgument(
                "Pencere tam olarak $REQUIRED_WINDOW_SIZE örnek içermeli, $remaining bulundu."
            )
        }
    }

    private fun drainCurrentOutputs(h: Long): List<PitchFrame> {
        val count = NativeBridge.nativeLiveOutputCount(h)
        if (count <= 0L) return emptyList()
        val frames = ArrayList<PitchFrame>(count.toInt())
        for (index in 0 until count) {
            val raw = NativeBridge.nativeLiveOutputFrame(h, index)
                ?: throw PitchAbiException.OutputReadFailed("Pitch çekirdeği sonuç karesini okuyamadı.")
            frames.add(PitchFrame(raw[0], raw[1], raw[2], raw[3] != 0.0))
        }
        return frames
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            val h = handle
            handle = 0L
            if (h != 0L) {
                NativeBridge.nativeLiveDestroy(h)
            }
        }
    }
}
