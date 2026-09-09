package com.aykerme.klarivision.live

import android.media.AudioFormat
import android.media.MediaRecorder

/**
 * Mikrofon kaynağı önceliği: `UNPROCESSED` > `VOICE_RECOGNITION` > `MIC`.
 *
 * iOS tarafı `AVAudioSession`'ı `.measurement` moduna alarak donanım/OS
 * seviyesindeki sinyal işlemeyi (AGC, gürültü bastırma, yankı iptali) kapatır
 * (bkz. `iPadLiveAnalyzer.start`, LiveAnalyzer.swift). Android'de doğrudan
 * eşleniği yoktur; en yakını `MediaRecorder.AudioSource.UNPROCESSED`'dır —
 * ama her cihaz desteklemez. Desteklenmediğinde daha az işlenmiş bir
 * alternatif olan `VOICE_RECOGNITION` denenir, o da yoksa düz `MIC`'e
 * düşülür. Sıra SÖZLEŞMEdir — değiştirilmesi bu gerekçeyi bozar.
 */
enum class MicSource(val audioSource: Int, val label: String) {
    UNPROCESSED(MediaRecorder.AudioSource.UNPROCESSED, "unprocessed"),
    VOICE_RECOGNITION(MediaRecorder.AudioSource.VOICE_RECOGNITION, "voice_recognition"),
    MIC(MediaRecorder.AudioSource.MIC, "mic"),
    ;

    companion object {
        /** Deneme sırası. */
        val PREFERENCE_ORDER: List<MicSource> = listOf(UNPROCESSED, VOICE_RECOGNITION, MIC)
    }
}

/**
 * `AudioRecord`'un fiilen açılabildiği format: hangi mikrofon kaynağı, hangi
 * kodlama (`ENCODING_PCM_FLOAT` tercih edilir, desteklenmiyorsa
 * `ENCODING_PCM_16BIT`) ve hangi örnekleme hızıyla.
 *
 * `deviceSampleRateHz`, 48 kHz'den farklıysa [needsResample] `true`'dur —
 * bu durumda yakalama döngüsü her bloğu motora vermeden önce
 * `Resampler.resampleLinear` ile 48 kHz'e çevirir (bkz. `LiveAudioCapture`).
 * C ABI'ye giren PCM HER ZAMAN 48 kHz'dir; bu alan yalnız CİHAZDAN alınan
 * ham hızı bildirir.
 */
data class LiveCaptureFormat(
    val micSource: MicSource,
    val encoding: Int,
    val deviceSampleRateHz: Int,
    val needsResample: Boolean,
) {
    val isFloatEncoding: Boolean get() = encoding == AudioFormat.ENCODING_PCM_FLOAT
}

/**
 * Canlı yakalama hattının kullanıcıya görünebilir hataları. Türkçedir —
 * `iPadLiveError` (LiveAnalyzer.swift) ile aynı ruhta.
 */
sealed class LiveCaptureError(message: String) : Exception(message) {
    class PermissionDenied :
        LiveCaptureError("Mikrofon izni verilmedi. Ayarlar'dan izin verip yeniden başlatın.")

    class NoUsableSource :
        LiveCaptureError("Kullanılabilir bir mikrofon girişi bulunamadı.")

    class RecordInitFailed :
        LiveCaptureError("Mikrofon açılamadı.")

    class RecordStartFailed(detail: String) :
        LiveCaptureError("Mikrofon başlatılamadı: $detail")

    class EngineFailed(detail: String) :
        LiveCaptureError("Canlı pitch çekirdeği başlatılamadı: $detail")

    class RecordingWriteFailed(detail: String) :
        LiveCaptureError("WAV kaydı yazılamadı: $detail")

    class AlreadyStopping :
        LiveCaptureError("Ses oturumu kapanıyor. Kapanma tamamlanınca Başlat'a yeniden dokunun.")
}
