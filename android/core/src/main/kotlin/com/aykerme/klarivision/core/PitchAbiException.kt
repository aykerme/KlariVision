package com.aykerme.klarivision.core

/**
 * Bu paket (JNI + Kotlin sarmalayıcılar) pitch kararı üretmez: eşikleme,
 * yumuşatma, oktav düzeltme, yeniden örnekleme burada YOKTUR. Yalnız C++
 * çekirdeğinin (`analysis_engine_c.h`) ürettiği sonucu ve `last_error`
 * metnini olduğu gibi taşır. Hata mesajları kullanıcıya görünebileceği
 * için Türkçedir — iPadPitchABIError (PitchABIAdapter.swift) ile aynı ruhta.
 */
sealed class PitchAbiException(message: String) : Exception(message) {

    /** kv_pitch_contract_get_v1 başarısız oldu ya da sert doğrulamayı geçemedi. */
    class ContractMismatch(message: String) : PitchAbiException(message)

    /** kv_production_pitch_session_create / kv_pitch_engine_create NULL döndü. */
    class SessionCreationFailed(message: String) : PitchAbiException(message)

    /** process_frame / set_minimum_rms gibi bir çağrı 0 döndü. */
    class InvalidArgument(message: String) : PitchAbiException(message)

    /** kv_production_pitch_session_process_frame 0 döndü. */
    class ProcessingFailed(message: String) : PitchAbiException(message)

    /** *_output_frame / *_frame bir kareyi okuyamadı. */
    class OutputReadFailed(message: String) : PitchAbiException(message)

    /**
     * Çevrimdışı (whole-file) analiz başarısız oldu. `message`,
     * `kv_pitch_engine_last_error`'ın metnini AYNEN taşır — jenerik bir
     * dize değildir, çünkü canlı yola sessizce düşmek yasaktır (bkz.
     * OfflineTrackSession.finish KDoc'u).
     */
    class OfflineProcessingFailed(message: String) : PitchAbiException(
        "Yerel çevrimdışı pitch analizi başarısız oldu: $message"
    )
}
