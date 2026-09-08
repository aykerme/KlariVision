package com.aykerme.klarivision.core

import java.nio.FloatBuffer

/**
 * `android/core/src/main/cpp/klarivision_jni.cpp`'nin tek Kotlin sınırı.
 * Burada TEK satır pitch mantığı yoktur — yalnız `analysis_engine_c.h`'nin
 * C ABI v1 yüzeyine 1:1 native bildirimler. Tüm doğrulama/dönüştürme
 * PitchContract / LivePitchSession / OfflineTrackSession içindedir.
 *
 * Dönüş sözleşmeleri:
 * - `DoubleArray?`: null == "C tarafı 0/NULL döndü ya da handle geçersiz".
 *   Sayısal alanlar (abiVersion, capabilities, sampleRateHz, windowSize,
 *   hopSize, voiced) `size_t`/`int`/`bool` olsa da tek bir dizi için double
 *   olarak taşınır; bu değerler double'ın 53 bitlik tam temsil aralığının
 *   çok altındadır, kayıp olmaz.
 * - Handle'lar `jlong` (native pointer). 0L == geçersiz/kapalı.
 * - Aynı handle'ı iki thread'den eşzamanlı çağırmayın; C++ tarafı da bu
 *   katman da kilit tutmaz (bkz. LivePitchSession/OfflineTrackSession KDoc).
 */
internal object NativeBridge {
    init {
        System.loadLibrary("klarivision_jni")
    }

    // --- Sözleşme ---------------------------------------------------------

    /** [abiVersion, capabilities, sampleRateHz, windowSize, hopSize, defaultMinimumRms] ya da null. */
    @JvmStatic external fun nativeGetContract(): DoubleArray?

    @JvmStatic external fun nativeUnifiedLagFrames(): Long

    // --- Canlı (causal) oturum: kv_production_pitch_session_* --------------

    /** Başarısızsa 0L döner. `engine` bu port için her zaman KV_ENGINE_UNIFIED_V1 (4). */
    @JvmStatic external fun nativeLiveCreate(engine: Int, minimumRms: Double): Long

    @JvmStatic external fun nativeLiveSetMinimumRms(handle: Long, minimumRms: Double): Boolean

    @JvmStatic external fun nativeLiveReset(handle: Long)

    /**
     * `buffer` DOĞRUDAN (direct) bir FloatBuffer olmalı; `sampleCount` kadar
     * örneği `buffer.position()`'dan itibaren okur. JNI tarafı
     * `GetDirectBufferAddress` kullanır — doğrudan olmayan buffer için bu
     * null adres döner ve bu fonksiyon false ile başarısız olur.
     */
    @JvmStatic external fun nativeLiveProcess(
        handle: Long,
        buffer: FloatBuffer,
        sampleCount: Int,
        sampleRateHz: Double,
        sourceTimeSeconds: Double,
    ): Boolean

    /** Kare sayısını döner (handle geçersizse 0). */
    @JvmStatic external fun nativeLiveFinish(handle: Long): Long

    @JvmStatic external fun nativeLiveOutputCount(handle: Long): Long

    /** [timeSeconds, frequencyHz, confidence, voiced(0/1)] ya da null. */
    @JvmStatic external fun nativeLiveOutputFrame(handle: Long, index: Long): DoubleArray?

    @JvmStatic external fun nativeLiveLastError(handle: Long): String

    @JvmStatic external fun nativeLiveDestroy(handle: Long)

    // --- Çevrimdışı (whole-file) oturum: kv_pitch_engine_* ------------------

    /** Başarısızsa 0L döner. `engine` bu port için her zaman KV_ENGINE_UNIFIED_V1 (4). */
    @JvmStatic external fun nativeOfflineCreate(engine: Int): Long

    /** `buffer` doğrudan olmalı; `sampleCount` örnek `buffer.position()`'dan okunur. */
    @JvmStatic external fun nativeOfflinePush(
        handle: Long,
        buffer: FloatBuffer,
        sampleCount: Int,
        sampleRateHz: Double,
    ): Boolean

    /** Tek bloklayıcı çağrı; ilerleme kancası yoktur. Kare sayısını döner. */
    @JvmStatic external fun nativeOfflineFinish(handle: Long): Long

    /** [timeSeconds, frequencyHz, confidence, voiced(0/1)] ya da null. */
    @JvmStatic external fun nativeOfflineFrame(handle: Long, index: Long): DoubleArray?

    @JvmStatic external fun nativeOfflineLastError(handle: Long): String

    @JvmStatic external fun nativeOfflineDestroy(handle: Long)
}
