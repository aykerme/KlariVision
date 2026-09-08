// KlariVision Android — canlı mikrofon yakalama hattı (P3a).
// Swift kaynağı: `ipad/.../LiveAnalyzer.swift` (iPadLiveWorker + iPadLiveAnalyzer).
// Bu sınıf pitch KARARI üretmez: eşikleme, yumuşatma, oktav düzeltme YOKTUR —
// yalnız PCM'i hazırlar (mono + 48 kHz Float32), pencereler
// (PcmWindowAccumulator, LiveCoreProcessor ile — DEĞİŞTİRİLMEDİ) ve
// `LivePitchSession`'ın (android/core, DEĞİŞTİRİLMEDİ) ürettiği kareleri
// toplu olarak dışarı iletir. Compose UI burada YAZILMAZ — bu yalnız servis
// katmanıdır (ekran P5a'nın işidir).

package com.aykerme.klarivision.live

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.Window
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.aykerme.klarivision.core.LivePitchSession
import com.aykerme.klarivision.core.PitchFrame as CorePitchFrame
import com.aykerme.klarivision.study.AppDirectories
import com.aykerme.klarivision.study.Resampler
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Canlı mikrofon yakalama hattı: `AudioRecord` → (gerekirse 48 kHz'e yeniden
 * örnekleme) → `LiveCoreProcessor`/`LivePitchSession` → toplu kare yayını,
 * artı isteğe bağlı Float32 WAV kaydı.
 *
 * **Yaşam döngüsü**: dört bağımsız kaynak — ses odağı kaybı, rota değişimi
 * (`AudioManager.AudioDeviceCallback`), `Lifecycle` (onPause/onStop) ve
 * `AudioRecord` hataları — hepsi TEK, idempotent [stop] fonksiyonuna akar
 * ([StopGate] ile korunur). Her durdurmadan sonra YENİ bir `AudioRecord` ve
 * YENİ bir `LivePitchSession` kurulur ([start] her zaman sıfırdan inşa eder);
 * eski nesneler asla yeniden kullanılmaz — iOS tarafındaki
 * `engine = AVAudioEngine()` yeniden yaratmasıyla aynı gerekçe.
 *
 * Bu sınıfın kendisi Android çalışma zamanına bağımlı olduğu için JVM
 * testiyle koşamaz — saf/test edilebilir parçalar ayrı dosyalardadır:
 * [PcmConversion], [WavRecorder], [SampleClock], [StopGate], [MicSource].
 *
 * `window`, verilirse yakalama sürerken `FLAG_KEEP_SCREEN_ON` ile ekranı açık
 * tutmak için kullanılır (iOS `UIApplication.isIdleTimerDisabled` karşılığı).
 * Verilmezse (null) bu adım sessizce atlanır — ekran yönetimi çağıran tarafın
 * (P5a) sorumluluğundadır, bu yalnız isteğe bağlı bir kolaylıktır.
 */
class LiveAudioCapture(
    private val appContext: Context,
    private val window: Window? = null,
) {
    // --- Dışarı açık, gözlemlenebilir durum ---------------------------------

    @Volatile
    var phase: LivePhase = LivePhase.Idle
        private set

    @Volatile
    var recordingPhase: RecordingPhase = RecordingPhase.Idle
        private set

    /** Fiilen açılan mikrofon kaynağı (bkz. [MicSource.PREFERENCE_ORDER]) — yalnız yakalama sürerken null değildir. */
    @Volatile
    var selectedSource: MicSource? = null
        private set

    var onFrames: ((List<CorePitchFrame>) -> Unit)? = null
    var onPhaseChanged: ((LivePhase) -> Unit)? = null
    var onRecordingChanged: ((RecordingPhase) -> Unit)? = null

    // --- İç durum (yalnız start/stop/toggleRecording'den, çağıran taraf senkronize etmeli) ---

    private val lifecycle = LiveLifecycle()
    private val stopGate = StopGate()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sampleClock = SampleClock(TARGET_SAMPLE_RATE_HZ.toDouble())
    private val hardwareTimestamp = AudioTimestamp()

    private val shouldRun = AtomicBoolean(false)
    private var audioRecord: AudioRecord? = null
    private var session: LivePitchSession? = null
    private var processor: LiveCoreProcessor<CorePitchFrame>? = null
    private var currentFormat: LiveCaptureFormat? = null

    private var wavRecorder: WavRecorder? = null
    private var recordingPath: File? = null

    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null
    private var deviceCallback: AudioDeviceCallback? = null

    private var lifecycleOwner: LifecycleOwner? = null
    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onPause(owner: LifecycleOwner) {
            stop(BACKGROUND_STOP_MESSAGE)
        }

        override fun onStop(owner: LifecycleOwner) {
            stop(BACKGROUND_STOP_MESSAGE)
        }
    }

    private val batch = ArrayList<CorePitchFrame>()
    private val batchLock = Any()
    private val flushScheduled = AtomicBoolean(false)

    // --- Yaşam döngüsü bağlama -----------------------------------------------

    /** UI sahibinin `Lifecycle`'ına bağlanır — onPause/onStop tek [stop] yoluna akar. */
    fun attachLifecycle(owner: LifecycleOwner) {
        detachLifecycle()
        lifecycleOwner = owner
        owner.lifecycle.addObserver(lifecycleObserver)
    }

    fun detachLifecycle() {
        lifecycleOwner?.lifecycle?.removeObserver(lifecycleObserver)
        lifecycleOwner = null
    }

    // --- Başlatma --------------------------------------------------------------

    /**
     * Yakalamayı başlatır: izin kontrolü → mikrofon kaynağı/kodlama/hız
     * seçimi (bkz. [openBestAudioRecord]) → yeni [LivePitchSession] → ses
     * odağı → `AudioRecord.startRecording()` → adanmış yakalama thread'i.
     *
     * `signalGateDbFS`'ten `minimumRms`, ayar katmanının KENDİ
     * `rmsForDbFs` fonksiyonuyla hesaplanır (burada yeniden hesaplanmaz).
     * Herhangi bir adım başarısız olursa [phase] `Failed(mesaj)`'a geçer ve
     * önceden açılmış olabilecek her kaynak (AudioRecord/session/odak)
     * hemen serbest bırakılır — yarım bir durum bırakılmaz.
     */
    @Synchronized
    fun start(signalGateDbFS: Double = SettingsKeys.LIVE_SIGNAL_GATE_DBFS_DEFAULT) {
        if (stopGate.isStopping()) {
            updatePhase(LivePhase.Failed(LiveCaptureError.AlreadyStopping().message.orEmpty()))
            return
        }
        if (shouldRun.get()) return // zaten çalışıyor

        lifecycle.requestStart()
        updatePhase(lifecycle.phase)

        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            failStart(LiveCaptureError.PermissionDenied().message.orEmpty())
            return
        }

        val opened = try {
            openBestAudioRecord()
        } catch (e: SecurityException) {
            null
        }
        if (opened == null) {
            failStart(LiveCaptureError.NoUsableSource().message.orEmpty())
            return
        }
        val (record, format) = opened

        val minimumRms = SettingsValidation.rmsForDbFs(signalGateDbFS)
        val newSession = try {
            LivePitchSession.create(minimumRms)
        } catch (e: Exception) {
            record.release()
            failStart(LiveCaptureError.EngineFailed(e.message ?: "bilinmeyen hata").message.orEmpty())
            return
        }

        if (!requestAudioFocus()) {
            record.release()
            newSession.close()
            failStart("Ses odağı alınamadı.")
            return
        }

        try {
            record.startRecording()
        } catch (e: Exception) {
            record.release()
            newSession.close()
            abandonAudioFocus()
            failStart(LiveCaptureError.RecordStartFailed(e.message ?: "bilinmeyen hata").message.orEmpty())
            return
        }

        audioRecord = record
        session = newSession
        processor = LiveCoreProcessor(SessionWindowSink(newSession))
        currentFormat = format
        selectedSource = format.micSource
        sampleClock.reset()

        registerDeviceCallback()
        setKeepScreenOn(true)

        lifecycle.started()
        updatePhase(lifecycle.phase)

        startCaptureThread(record, format)
    }

    private fun failStart(message: String) {
        lifecycle.failed(message)
        updatePhase(lifecycle.phase)
    }

    // --- Durdurma (tek, idempotent giriş noktası) -------------------------------

    /**
     * Yakalamayı durdurur. `reason == null` ise kullanıcı tarafından
     * başlatılmış bir durdurma (faz `Idle`'a geçer); değilse bir kesinti
     * (faz `Interrupted(reason)`'a geçer) — bkz. [LiveLifecycle.stopped].
     *
     * İdempotenttir: eşzamanlı birden çok kaynaktan (ör. hem ses odağı kaybı
     * hem `Lifecycle.onPause` aynı anda) çağrılsa bile yalnız BİRİ gerçek
     * durdurma işini yapar ([StopGate]). Zaten durmuş durumdan tekrar
     * çağrılması güvenlidir, hiçbir şey yapmaz.
     */
    fun stop(reason: String?) {
        if (!stopGate.begin(reason)) return
        try {
            performStop(reason)
        } finally {
            stopGate.complete()
        }
    }

    private fun performStop(reason: String?) {
        shouldRun.set(false)

        val record = audioRecord
        audioRecord = null
        if (record != null) {
            // AudioRecord.release(), yakalama thread'i o an bloklayıcı bir
            // read() içindeyken de güvenlidir — thread bir sonraki
            // iterasyonda hata koduyla (ya da `shouldRun` bayrağıyla) kendi
            // kendine sessizce sona erer; burada JOIN BEKLENMEZ (iOS'taki
            // `engine.stop(); engine.reset()`'in anlık, beklemesiz teardown'ı
            // ile aynı gerekçe — tap kuyruğunun boşalmasını beklemez).
            try { record.stop() } catch (_: Exception) { /* zaten durmuş olabilir */ }
            try { record.release() } catch (_: Exception) { /* zaten serbest olabilir */ }
        }

        val activeSession = session
        session = null
        processor = null
        currentFormat = null
        if (activeSession != null) {
            // `unified_v1`'in kendi karar gecikmesi (hop cinsinden) nedeniyle
            // kuyrukta bekleyen son kareler `finish()` ile alınır — iOS
            // tarafındaki `processor.finishAndDestroy()` adımıyla aynı amaç.
            val remaining = try { activeSession.finish() } catch (_: Exception) { emptyList() }
            if (remaining.isNotEmpty()) enqueueFrames(remaining)
            try { activeSession.close() } catch (_: Exception) { /* idempotent zaten */ }
        }

        val recorder = wavRecorder
        wavRecorder = null
        if (recorder != null) {
            val finishedPhase = try {
                recorder.finish()
                RecordingPhase.Completed(recordingPath?.absolutePath.orEmpty())
            } catch (e: Exception) {
                RecordingPhase.Failed("WAV kaydı tamamlanamadı.")
            }
            updateRecording(finishedPhase)
        }

        unregisterDeviceCallback()
        abandonAudioFocus()
        setKeepScreenOn(false)
        flushNow()

        selectedSource = null
        lifecycle.stopped(reason)
        updatePhase(lifecycle.phase)
    }

    // --- Kayıt (WAV) --------------------------------------------------------

    /**
     * Kayıt açıksa kapatıp [RecordingPhase.Completed]/[RecordingPhase.Failed]
     * döner; kapalıysa ve yakalama sürüyorsa yeni bir WAV başlatır. Yakalama
     * sürmüyorsa hiçbir şey yapmaz (iOS'taki `guard engine.isRunning` ile
     * aynı davranış).
     */
    @Synchronized
    fun toggleRecording(): RecordingPhase {
        val activeRecorder = wavRecorder
        if (activeRecorder != null) {
            return finalizeRecording(activeRecorder)
        }
        if (audioRecord == null || !shouldRun.get()) return recordingPhase

        return try {
            val directory = AppDirectories.recordings(appContext)
            val target = File(directory, "KlariVision-${UUID.randomUUID()}.wav")
            val recorder = WavRecorder.create(target, sampleRateHz = TARGET_SAMPLE_RATE_HZ, channelCount = 1)
            wavRecorder = recorder
            recordingPath = target
            updateRecording(RecordingPhase.Active)
            RecordingPhase.Active
        } catch (e: Exception) {
            val failed = RecordingPhase.Failed("WAV kaydı başlatılamadı.")
            updateRecording(failed)
            failed
        }
    }

    private fun finalizeRecording(recorder: WavRecorder): RecordingPhase {
        wavRecorder = null
        val finishedPhase = try {
            recorder.finish()
            RecordingPhase.Completed(recordingPath?.absolutePath.orEmpty())
        } catch (e: Exception) {
            RecordingPhase.Failed("WAV kaydı tamamlanamadı.")
        }
        updateRecording(finishedPhase)
        return finishedPhase
    }

    private fun writeRecordingIfActive(samples: FloatArray) {
        val recorder = wavRecorder ?: return
        try {
            recorder.writeSamples(samples, samples.size)
        } catch (e: Exception) {
            wavRecorder = null
            updateRecording(RecordingPhase.Failed("WAV kaydı yazılamadı."))
        }
    }

    // --- Yakalama thread'i --------------------------------------------------

    private fun startCaptureThread(record: AudioRecord, format: LiveCaptureFormat) {
        shouldRun.set(true)
        val thread = Thread({ runCaptureLoop(record, format) }, "klarivision-live-capture")
        thread.isDaemon = true
        thread.start()
    }

    /**
     * Adanmış, yüksek öncelikli okuma döngüsü. Tahsis yapmaz: `shortBuf`/
     * `floatBuf` döngü DIŞINDA bir kez ayrılır ve tekrar tekrar doldurulur.
     * Yalnız kırpma (`copyOf`) — `read()` istenen tam boyuttan AZ döndüğünde
     * (ör. son parça) — ve yeniden örnekleme (cihaz 48 kHz vermediğinde,
     * nadir) yollarında tahsis olabilir; steady-state'te (tam boyutlu okuma,
     * cihaz zaten 48 kHz) HİÇ tahsis yoktur.
     */
    private fun runCaptureLoop(record: AudioRecord, format: LiveCaptureFormat) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

        val shortBuf = if (format.encoding == AudioFormat.ENCODING_PCM_16BIT) {
            ShortArray(READ_CHUNK_FRAMES)
        } else null
        val floatBuf = FloatArray(READ_CHUNK_FRAMES)

        while (shouldRun.get()) {
            val read = try {
                if (shortBuf != null) {
                    val n = record.read(shortBuf, 0, READ_CHUNK_FRAMES)
                    if (n > 0) PcmConversion.int16ToFloat32(shortBuf, n, floatBuf)
                    n
                } else {
                    record.read(floatBuf, 0, READ_CHUNK_FRAMES, AudioRecord.READ_BLOCKING)
                }
            } catch (e: IllegalStateException) {
                // record.release() az önce başka bir thread'den çağrılmış
                // olabilir (bkz. performStop KDoc'u) — sessizce çık.
                return
            }

            if (read < 0) {
                handleReadError(read)
                return
            }
            if (read == 0) continue

            val trimmed = if (read == floatBuf.size) floatBuf else floatBuf.copyOf(read)
            val samples = if (format.needsResample) {
                Resampler.resampleLinear(trimmed, format.deviceSampleRateHz.toDouble())
            } else {
                trimmed
            }

            sampleClock.advance(samples.size)
            alignWithHardwareTimestamp(record, format)
            writeRecordingIfActive(samples)

            val frames = try {
                processor?.process(samples)
            } catch (e: Exception) {
                stop(LiveCaptureError.EngineFailed(e.message ?: "bilinmeyen hata").message)
                return
            }
            if (!frames.isNullOrEmpty()) enqueueFrames(frames)
        }
    }

    private fun handleReadError(code: Int) {
        val message = when (code) {
            AudioRecord.ERROR_INVALID_OPERATION, AudioRecord.ERROR_DEAD_OBJECT ->
                "Ses hizmeti sıfırlandı. Yeniden başlatmak için Başlat'a dokunun."
            else -> "Mikrofon verisi okunamadı."
        }
        stop(message)
    }

    /**
     * Yalnız cihaz zaten 48 kHz veriyorsa (yeniden örnekleme YOK) anlamlıdır
     * — donanım çerçeve konumu cihazın KENDİ hızındadır, yeniden
     * örneklenmiş sayaçla karıştırılamaz. `getTimestamp` desteklenmeyen
     * cihazlarda sessizce yok sayılır; kaynak zamanı zaten kendi örnek
     * sayacımızdan doğru şekilde türer (UI saatine hiç ihtiyaç yoktur).
     */
    private fun alignWithHardwareTimestamp(record: AudioRecord, format: LiveCaptureFormat) {
        if (format.needsResample) return
        try {
            if (record.getTimestamp(hardwareTimestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                sampleClock.alignTo(hardwareTimestamp.framePosition)
            }
        } catch (_: Exception) {
            // Desteklenmiyor — yoksay.
        }
    }

    // --- Mikrofon kaynağı / kodlama / hız seçimi -----------------------------

    /**
     * Sırayla dener: her [MicSource] için önce `ENCODING_PCM_FLOAT` @ 48 kHz
     * ([TARGET_SAMPLE_RATE_HZ]); olmazsa Float32'yi bilinen yaygın hızlarda
     * ([FALLBACK_SAMPLE_RATES_HZ]); Float32 HİÇ yoksa `ENCODING_PCM_16BIT`'e
     * (bu geri düşüş yolu BAŞTAN yazılmıştır, sonradan eklenmemiştir) aynı
     * hız sırasıyla düşer. İlk açılabilen kombinasyon kullanılır.
     */
    private fun openBestAudioRecord(): Pair<AudioRecord, LiveCaptureFormat>? {
        for (source in MicSource.PREFERENCE_ORDER) {
            openAudioRecord(source, AudioFormat.ENCODING_PCM_FLOAT, TARGET_SAMPLE_RATE_HZ)?.let {
                return it to LiveCaptureFormat(source, AudioFormat.ENCODING_PCM_FLOAT, TARGET_SAMPLE_RATE_HZ, needsResample = false)
            }
            for (rate in FALLBACK_SAMPLE_RATES_HZ) {
                openAudioRecord(source, AudioFormat.ENCODING_PCM_FLOAT, rate)?.let {
                    return it to LiveCaptureFormat(source, AudioFormat.ENCODING_PCM_FLOAT, rate, needsResample = true)
                }
            }
            openAudioRecord(source, AudioFormat.ENCODING_PCM_16BIT, TARGET_SAMPLE_RATE_HZ)?.let {
                return it to LiveCaptureFormat(source, AudioFormat.ENCODING_PCM_16BIT, TARGET_SAMPLE_RATE_HZ, needsResample = false)
            }
            for (rate in FALLBACK_SAMPLE_RATES_HZ) {
                openAudioRecord(source, AudioFormat.ENCODING_PCM_16BIT, rate)?.let {
                    return it to LiveCaptureFormat(source, AudioFormat.ENCODING_PCM_16BIT, rate, needsResample = true)
                }
            }
        }
        return null
    }

    private fun openAudioRecord(source: MicSource, encoding: Int, sampleRateHz: Int): AudioRecord? {
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val minBufferBytes = AudioRecord.getMinBufferSize(sampleRateHz, channelConfig, encoding)
        if (minBufferBytes <= 0) return null // ERROR / ERROR_BAD_VALUE
        val bytesPerFrame = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
        val bufferSizeBytes = maxOf(minBufferBytes * 2, READ_CHUNK_FRAMES * bytesPerFrame * 4)
        return try {
            val record = AudioRecord(source.audioSource, sampleRateHz, channelConfig, encoding, bufferSizeBytes)
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                null
            } else {
                record
            }
        } catch (e: Exception) {
            null
        }
    }

    // --- Ses odağı (telefon/asistan kesintisi) -------------------------------

    private fun requestAudioFocus(): Boolean {
        val am = audioManagerOrNull() ?: return false
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
                -> stop("Ses kesintiye uğradı. Yeniden başlatmak için Başlat'a dokunun.")
            }
        }
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener(listener, mainHandler)
            .build()
        return if (am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            focusRequest = request
            true
        } else {
            false
        }
    }

    private fun abandonAudioFocus() {
        val am = audioManagerOrNull()
        val request = focusRequest
        focusRequest = null
        if (am != null && request != null) {
            try { am.abandonAudioFocusRequest(request) } catch (_: Exception) { /* zaten bırakılmış olabilir */ }
        }
    }

    // --- Rota değişimi: AudioManager.AudioDeviceCallback ---------------------

    /**
     * Kararı YALNIZ mevcut, saf [RouteChangePolicy.action] fonksiyonu verir
     * — burada hiçbir eşik/heuristik tekrarlanmaz. Android'de "kategori
     * değişimi" kavramı olmadığından `expectedOwnCategoryChange` her zaman
     * `false` geçilir; yalnız GİRİŞ kaynağı (`isSource`) ekleme/çıkarma
     * olayları dikkate alınır.
     */
    private fun registerDeviceCallback() {
        val am = audioManagerOrNull() ?: return
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<AudioDeviceInfo>) {
                if (addedDevices.none { it.isSource }) return
                applyRouteChange(RouteChangePolicy.REASON_NEW_DEVICE_AVAILABLE)
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<AudioDeviceInfo>) {
                if (removedDevices.none { it.isSource }) return
                applyRouteChange(RouteChangePolicy.REASON_OLD_DEVICE_UNAVAILABLE)
            }
        }
        am.registerAudioDeviceCallback(callback, mainHandler)
        deviceCallback = callback
    }

    private fun applyRouteChange(reasonRawValue: Int) {
        val action = RouteChangePolicy.action(reasonRawValue, expectedOwnCategoryChange = false)
        if (action is RouteChangeAction.Stop) stop(action.message)
    }

    private fun unregisterDeviceCallback() {
        val am = audioManagerOrNull()
        val callback = deviceCallback
        deviceCallback = null
        if (am != null && callback != null) {
            try { am.unregisterAudioDeviceCallback(callback) } catch (_: Exception) { /* zaten kayıtsız olabilir */ }
        }
    }

    private fun audioManagerOrNull(): AudioManager? {
        val cached = audioManager
        if (cached != null) return cached
        val resolved = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        audioManager = resolved
        return resolved
    }

    // --- Ekranı açık tutma ----------------------------------------------------

    private fun setKeepScreenOn(enabled: Boolean) {
        val w = window ?: return
        mainHandler.post {
            if (enabled) {
                w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    // --- Kare toplu yayını (~33 ms, iOS'taki 30 Hz yayım hızı) -----------------

    private fun enqueueFrames(frames: List<CorePitchFrame>) {
        if (frames.isEmpty()) return
        synchronized(batchLock) { batch.addAll(frames) }
        if (flushScheduled.compareAndSet(false, true)) {
            mainHandler.postDelayed({ flushNow() }, FLUSH_INTERVAL_MS)
        }
    }

    private fun flushNow() {
        flushScheduled.set(false)
        val output: List<CorePitchFrame>
        synchronized(batchLock) {
            if (batch.isEmpty()) return
            output = ArrayList(batch)
            batch.clear()
        }
        onFrames?.invoke(output)
    }

    // --- Durum yayını (her zaman ana thread'e postalanır) ----------------------

    private fun updatePhase(newPhase: LivePhase) {
        phase = newPhase
        mainHandler.post { onPhaseChanged?.invoke(newPhase) }
    }

    private fun updateRecording(newPhase: RecordingPhase) {
        recordingPhase = newPhase
        mainHandler.post { onRecordingChanged?.invoke(newPhase) }
    }

    companion object {
        const val TARGET_SAMPLE_RATE_HZ = 48_000
        private val FALLBACK_SAMPLE_RATES_HZ = listOf(44_100, 32_000, 22_050, 16_000, 11_025, 8_000)

        /** Tek okuma çağrısı başına çerçeve sayısı (10 ms @ 48 kHz). */
        private const val READ_CHUNK_FRAMES = 480

        /** UI'ye toplu kare itme aralığı — iOS'taki 30 Hz (33 ms) yayım hızıyla aynı. */
        private const val FLUSH_INTERVAL_MS = 33L

        private const val BACKGROUND_STOP_MESSAGE = "Uygulama arka plana geçti. Mikrofon güvenle durduruldu."
    }
}

/**
 * `LiveCoreProcessor`'ın beklediği [PitchWindowSink]'i gerçek
 * [LivePitchSession]'a bağlar: her 1536 örneklik pencereyi ÖNCEDEN AYRILMIŞ
 * tek bir doğrudan (direct) `FloatBuffer`'a kopyalar ve session'ın
 * `process`'ine verir — pencere başına yeni buffer TAHSİS EDİLMEZ.
 */
private class SessionWindowSink(
    private val session: LivePitchSession,
) : PitchWindowSink<CorePitchFrame> {
    private val windowBuffer: FloatBuffer = ByteBuffer
        .allocateDirect(PcmWindowAccumulator.WINDOW_SIZE * Float.SIZE_BYTES)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()

    override fun process(window: FloatArray, sourceTime: Double): List<CorePitchFrame> {
        windowBuffer.clear()
        windowBuffer.put(window)
        windowBuffer.flip()
        return session.process(windowBuffer, sourceTime)
    }
}
