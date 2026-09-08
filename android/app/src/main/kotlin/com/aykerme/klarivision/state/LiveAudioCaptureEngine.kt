// KlariVision Android — `live/LiveAudioCapture` (AudioRecord tabanlı gerçek
// mikrofon motoru) ile `state/LiveCaptureEngine` (orkestratörün beklediği
// sözleşme) arasındaki adaptör.
//
// İki taraf ayrı parçalar olarak yazıldığı için yüzeyleri birebir örtüşmüyor:
//  * `LiveAudioCapture.start` askıya alınmaz (suspend değil) ve hatayı istisna
//    yerine `phase = LivePhase.Failed(...)` olarak bildirir; sözleşme ise
//    istisna bekler.
//  * `LiveAudioCapture` eşiği dBFS olarak alıp içeride lineer RMS'e çevirir;
//    sözleşme doğrudan lineer RMS taşır.
//  * Kare tipleri farklı: çekirdek `core.PitchFrame`, orkestratör
//    `study.PitchFrame`.
// Bu dosya üç farkı da tek yerde kapatır; iki tarafın kendi kodu değişmez.

package com.aykerme.klarivision.state

import android.content.Context
import androidx.lifecycle.LifecycleOwner
import com.aykerme.klarivision.live.LiveAudioCapture
import com.aykerme.klarivision.live.LivePhase
import com.aykerme.klarivision.live.RecordingPhase
import com.aykerme.klarivision.study.PitchFrame
import kotlin.math.log10
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.aykerme.klarivision.core.PitchFrame as CorePitchFrame

/**
 * Gerçek mikrofon motorunu [LiveCaptureEngine] sözleşmesine bağlar.
 *
 * `LiveAudioCapture` bloklamayan ama askıya alınmayan bir API sunar ve kendi
 * yakalama iş parçacığını yönetir; burada yalnız çağrılar [Dispatchers.Default]
 * üzerine alınır ve dönüş durumu sözleşmenin beklediği biçime çevrilir.
 */
class LiveAudioCaptureEngine(
    private val capture: LiveAudioCapture,
) : LiveCaptureEngine {

    constructor(context: Context) : this(LiveAudioCapture(context.applicationContext))

    /** Yaşam döngüsü (onPause/onStop) durdurmaları için; UI katmanı çağırır. */
    fun attachLifecycle(owner: LifecycleOwner) = capture.attachLifecycle(owner)

    /** Ekran kapanırken bırakılır. */
    fun detachLifecycle() = capture.detachLifecycle()

    /** Yakalama sırasında seçilen mikrofon kaynağı (tanılama için). */
    val selectedSource get() = capture.selectedSource

    override suspend fun start(
        minimumRms: Double,
        onFrames: (List<PitchFrame>) -> Unit,
        onRecording: (RecordingPhase) -> Unit,
        onFailure: (String) -> Unit,
    ) {
        capture.onFrames = { coreFrames -> onFrames(coreFrames.map { it.toStudyFrame() }) }
        capture.onRecordingChanged = onRecording
        capture.onPhaseChanged = { phase ->
            // Başlatmadan sonra ortaya çıkan kesinti/hata (rota değişimi, ses
            // odağı kaybı, ölü AudioRecord) istisna olarak atılamaz — çağıran
            // çoktan dönmüştür. Sözleşmenin `onFailure` kanalı bunun içindir.
            when (phase) {
                is LivePhase.Failed -> onFailure(phase.message)
                is LivePhase.Interrupted -> onFailure(phase.message)
                else -> Unit
            }
        }

        withContext(Dispatchers.Default) { capture.start(signalGateDbFS = minimumRms.toDbFs()) }

        // `start` hatayı istisna yerine faz olarak bildirir; sözleşme istisna
        // bekliyor. İzin reddi ayrı bir tip olarak ayrılır ki orkestratör
        // kullanıcıdan izin isteyebilsin.
        when (val phase = capture.phase) {
            is LivePhase.Failed ->
                if (phase.message.isPermissionDenial()) {
                    throw SecurityException(phase.message)
                } else {
                    throw IllegalStateException(phase.message)
                }
            else -> Unit
        }
    }

    override suspend fun stop(): RecordingPhase = withContext(Dispatchers.Default) {
        capture.stop(reason = null)
        capture.recordingPhase
    }

    override suspend fun toggleRecording(): RecordingPhase =
        withContext(Dispatchers.Default) { capture.toggleRecording() }
}

/**
 * Lineer RMS eşiğini dBFS'e çevirir — `SettingsValidation.rmsForDbFs`'in
 * (`10^(dB/20)`) tam tersi, çünkü `LiveAudioCapture` dönüşümü kendi içinde
 * yapıyor ve eşiği dBFS olarak alıyor.
 */
private fun Double.toDbFs(): Double =
    if (this > 0.0) 20.0 * log10(this) else NEGATIVE_INFINITY_GATE

/** RMS sıfır/negatif ise pratikte "kapı kapalı değil" demektir. */
private const val NEGATIVE_INFINITY_GATE = -60.0

private fun CorePitchFrame.toStudyFrame() = PitchFrame(
    time = timeSeconds,
    frequency = frequencyHz,
    confidence = confidence,
    voiced = voiced,
)

private fun String.isPermissionDenial(): Boolean =
    contains("izin", ignoreCase = true) || contains("permission", ignoreCase = true)
