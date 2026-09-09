package com.aykerme.klarivision.core

import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * `kv_pitch_engine_create(KV_ENGINE_UNIFIED_V1, KV_PROFILE_OFFLINE_TRACK)`
 * üzerine tüm-dosya (whole-file) çevrimdışı pitch oturumu — Dinleme/Study
 * yolu içindir. `ipad/.../PitchABIAdapter.swift`'teki
 * `iPadOfflineTrackSession`'ın Kotlin karşılığı; semantiği birebir korur.
 *
 * Bu sınıf pitch kararı üretmez: eşikleme/yumuşatma/oktav düzeltme/yeniden
 * örnekleme yoktur, yalnız C++ çekirdeğinin ürettiği kareleri ve
 * `kv_pitch_engine_last_error` metnini taşır.
 *
 * Çağrı deseni causal `LivePitchSession.process(...)`'ten kasıtlı olarak
 * farklıdır: `push` rastgele boyutlu PCM parçaları kabul eder (motor
 * içeride tamponlar — `PitchEngine::push`/`finish`, analysis_engine.hpp),
 * hiçbir analiz `finish()`'e kadar yapılmaz.
 *
 * Eşzamanlılık: aynı örneği iki thread'den aynı anda çağırmayın.
 *
 * `close()` idempotenttir; kapandıktan sonra herhangi bir kullanım
 * [IllegalStateException] fırlatır. Finalizer'a güvenilmez.
 */
class OfflineTrackSession private constructor() : AutoCloseable {

    companion object {
        /**
         * Yeni bir çevrimdışı oturum oluşturur. Motor her zaman
         * `KV_ENGINE_UNIFIED_V1`'dir — bu port başka motor seçtirmez.
         */
        fun create(): OfflineTrackSession = OfflineTrackSession()
    }

    @Volatile
    private var handle: Long = 0L
    private val closed = AtomicBoolean(false)

    init {
        val created = NativeBridge.nativeOfflineCreate(PitchEngine.UNIFIED_V1)
        if (created == 0L) {
            throw PitchAbiException.SessionCreationFailed("Pitch oturumu oluşturulamadı.")
        }
        handle = created
    }

    private fun openHandle(): Long {
        check(!closed.get() && handle != 0L) {
            "OfflineTrackSession kapatıldıktan sonra kullanılamaz."
        }
        return handle
    }

    /**
     * Mono Float32 PCM'in bir parçasını ekler. `samples` DOĞRUDAN (direct)
     * bir FloatBuffer olmalı, `buffer.position()`'dan itibaren kalan tüm
     * örnekler okunur. Parça sınırları herhangi bir pencere/hop boyutuna
     * hizalanmak zorunda değildir.
     *
     * Doğrudan olmayan bir buffer açık [PitchAbiException.InvalidArgument]
     * ile başarısız olur — sessiz kabul yoktur.
     */
    fun push(samples: FloatBuffer, sampleRateHz: Double) {
        val h = openHandle()
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
        val count = samples.remaining()
        require(count > 0) { "PCM verisi boş olamaz." }
        require(sampleRateHz.isFinite() && sampleRateHz > 0) {
            "Örnekleme hızı sonlu ve pozitif olmalı."
        }
        val ok = NativeBridge.nativeOfflinePush(h, samples, count, sampleRateHz)
        if (!ok) {
            throw PitchAbiException.OfflineProcessingFailed(readLastError(h))
        }
    }

    /**
     * Şimdiye kadar `push` edilen tüm PCM üzerinde tüm-dosya analizini
     * çalıştırır ve üretilen kare sayısını döner.
     *
     * TEK BLOKLAYICI ÇAĞRIDIR — ilerleme kancası (progress hook) yoktur.
     * `kv_pitch_engine_set_progress` bu P1a katmanında bilinçli olarak
     * bağlanmamıştır; tüm analiz süresi (tam bir kayıt için onlarca saniye
     * olabilir) bu tek çağrı içinde geçer. Çağıran taraf bunu bir arka plan
     * thread'inde çalıştırmalıdır. Idempotent değildir ve artımlı değildir.
     *
     * `finish()` 0 dönerse ve `kv_pitch_engine_last_error` boş DEĞİLSE bu
     * gerçek bir başarısızlıktır: hata metni AYNEN
     * [PitchAbiException.OfflineProcessingFailed] içinde fırlatılır.
     * Sessizce canlı (causal) yola düşülmez. `last_error` boşsa 0, gerçekten
     * sessiz/çok kısa bir kayıt anlamına gelebilir (iOS tarafındaki
     * `iPadOfflineTrackSession.finish` ile aynı ayrım) ve boş liste anlamına
     * gelecek şekilde 0 döner, hata fırlatılmaz.
     */
    fun finish(): Int {
        val h = openHandle()
        val count = NativeBridge.nativeOfflineFinish(h)
        if (count <= 0L) {
            val message = readLastError(h)
            if (message.isNotEmpty()) {
                throw PitchAbiException.OfflineProcessingFailed(message)
            }
            return 0
        }
        return count.toInt()
    }

    /** `finish()`'in ürettiği kare dizisinden `index`'teki kareyi okur. */
    fun frame(index: Int): PitchFrame {
        val h = openHandle()
        require(index >= 0) { "index negatif olamaz." }
        val raw = NativeBridge.nativeOfflineFrame(h, index.toLong())
            ?: throw PitchAbiException.OutputReadFailed("Pitch çekirdeği sonuç karesini okuyamadı.")
        return PitchFrame(raw[0], raw[1], raw[2], raw[3] != 0.0)
    }

    /** `kv_pitch_engine_last_error`'ın güncel metnini döner (boş olabilir). */
    fun lastError(): String = readLastError(openHandle())

    private fun readLastError(h: Long): String = NativeBridge.nativeOfflineLastError(h)

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            val h = handle
            handle = 0L
            if (h != 0L) {
                NativeBridge.nativeOfflineDestroy(h)
            }
        }
    }
}
