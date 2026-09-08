// KlariVision Android — Dinleme (Study) modu durum orkestrasyonu, Swift
// iPadStudyState'ten (StudyState.swift) port edildi. Zincir: içe aktar →
// çöz/analiz et → viewer'a yükle → kütüphaneye ATOMİK kaydet. Herhangi bir
// adım (viewer yüklemesi dahil) başarısız olursa kütüphane KİRLENMEZ ve
// kaynak `retry()` ile yeniden denenebilir kalır. Bu katman pitch KARARI
// üretmez — yalnız `study/` ve `web/` katmanlarını sıralar.
//
// UI (P5a, ayrı ajan) yalnız `uiState`'i okur ve niyet metotlarını çağırır;
// oynatma durumu (`playback`) TEK YÖNLÜ sayfadan yansır — bu sınıf kendi
// oynatma saatini tutmaz (bkz. `onPlaybackSnapshot`).
//
// Kasıtlı olarak `android.content.Context` TUTMAZ: `Context` gerektiren
// gerçek adımlar (`StudyImportService.importFile`, görünen ad sorgusu)
// çağıran taraf (kompozisyon kökü, gerçek `Context`'in doğal olarak
// bulunduğu yer) tarafından küçük lambdalar olarak geçirilir. Bu hem daha
// güvenli bir yaşam döngüsüdür (orkestratör bir Activity/Context referansı
// TUTMAZ) hem de bu dosyayı `android.net.Uri`/`Context` STUB'larına hiç
// dokunmadan salt-JVM testlerle kapsanabilir kılar (bkz. `launchImport`).

package com.aykerme.klarivision.state

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.aykerme.klarivision.study.AnalysisProgress
import com.aykerme.klarivision.study.AnalysisStage
import com.aykerme.klarivision.study.ImportedFile
import com.aykerme.klarivision.study.OfflineAnalysisResult
import com.aykerme.klarivision.study.OfflinePitchAnalyzer
import com.aykerme.klarivision.study.Study
import com.aykerme.klarivision.study.StudyContext
import com.aykerme.klarivision.study.StudyImportService
import com.aykerme.klarivision.study.StudyLibraryStore
import com.aykerme.klarivision.music.Karar
import com.aykerme.klarivision.music.Makam
import com.aykerme.klarivision.music.ScaleDisplay
import com.aykerme.klarivision.web.GuidePayload
import com.aykerme.klarivision.web.StudyCommand
import com.aykerme.klarivision.web.StudyGraphBridge
import com.aykerme.klarivision.web.PlaybackSnapshot
import com.aykerme.klarivision.web.ViewerAssets
import java.io.File
import java.util.Collections
import java.util.IdentityHashMap
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Dinleme akışının durum makinesi aşamaları — UI bunlara göre ekran seçer. */
enum class StudyPhase { IDLE, IMPORTING, DECODING, ANALYZING, WRITING, READY, FAILED }

/**
 * Dinleme modu UI'sinin tek gerçek kaynağı.
 *
 * `progress == null`, aşamanın BELİRSİZ olduğu anlamına gelir — yalnız
 * [StudyPhase.ANALYZING] için geçerlidir ([OfflinePitchAnalyzer]'ın
 * `finish()` adımı bloklayıcıdır, ilerleme kancası yoktur).
 */
data class StudyUiState(
    val phase: StudyPhase = StudyPhase.IDLE,
    val studies: List<Study> = emptyList(),
    val current: Study? = null,
    val progress: Float? = null,
    val playback: PlaybackSnapshot? = null,
    val errorMessage: String? = null,
)

/**
 * Ekranın uykuya geçmemesi gereken aşamalar (bkz. görev notu "Boşta kalma
 * politikası"). UI bu değeri okuyup `Window.FLAG_KEEP_SCREEN_ON`'u (veya
 * Compose eşdeğerini) uygular — orkestratör bizzat pencereye dokunmaz.
 */
val StudyUiState.keepScreenOn: Boolean
    get() = phase == StudyPhase.IMPORTING || phase == StudyPhase.DECODING ||
        phase == StudyPhase.ANALYZING || phase == StudyPhase.WRITING

/**
 * Aynı kaynağın (dosya seçici URI'si veya tamamlanmış Çalma kaydı) ikinci
 * kez Çalışmalara eklenmesini engeller — Swift `iPadCompletedRecordingImportTracker`
 * karşılığı. Kimlik karşılaştırması REFERANS eşitliğiyle yapılır
 * ([IdentityHashMap] tabanlı): gerçek cihazda aynı `Uri` nesnesi (SAF
 * sonucundan veya `LiveOrchestrator`'ın tamamlanmış-kayıt URI'sinden) tek
 * sefer akar, bu yüzden referans eşitliği yeterli ve JVM testlerinde
 * `Uri.equals`/`hashCode`'a (Robolectric yok) hiç dokunmadan sahte anahtar
 * nesneleriyle test edilebilir.
 */
internal class DuplicateImportGuard {
    private val imported = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>())
    private val importing = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>())

    @Synchronized
    fun begin(key: Any): Boolean {
        if (imported.contains(key) || importing.contains(key)) return false
        importing.add(key)
        return true
    }

    @Synchronized
    fun finish(key: Any, succeeded: Boolean) {
        importing.remove(key)
        if (succeeded) imported.add(key)
    }

    @Synchronized
    fun contains(key: Any): Boolean = imported.contains(key)
}

/** Yeniden denenebilir, başarısız olmuş bir içe aktarmanın hatırlanan tarifi. */
private data class RetryableImport(
    val key: Any,
    val titleHint: String,
    val importer: suspend () -> ImportedFile,
)

/**
 * `StudyViewer.html`'e varsayılan pitch/kılavuz/karar renkleri — Swift
 * `iPadStudyState`'in özel alanlarıyla (`pitchColor`, `guideColor`,
 * `kararColor`) aynı varsayılanlar. Bu katmanın sabit sözleşmesinde bir
 * `configure(...)` girişi yok, bu yüzden burada sabitlenir.
 */
private const val DEFAULT_PITCH_COLOR = "#67d5ff"
private const val DEFAULT_GUIDE_COLOR = "#b7d8ff"
private const val DEFAULT_KARAR_COLOR = "#E75A5A"

/**
 * Dinleme (Study) modunun durum orkestratörü.
 *
 * Zincir: [importAndAnalyze] → `importFile` ([StudyImportService.importFile]
 * eşdeğeri) → mono indirgeme + 48 kHz analiz ([OfflinePitchAnalyzer.analyze])
 * → viewer'a yükle ([viewerLoad]) → [StudyLibraryStore.save] (atomik yazma
 * zaten `StudyLibraryStore` içinde: geçici dosyaya yaz, rename et). Viewer
 * yüklemesi dahil herhangi bir adım istisna fırlatırsa kütüphane değişmeden
 * kalır ve kaynak [retry] için saklanır.
 *
 * @param libraryStore Kalıcı kütüphane deposu (üretimde `StudyLibraryStore(context.filesDir)`).
 * @param importFile SAF `Uri`'sini uygulamanın kendi kopyasına indirir
 *   (üretimde `{ uri -> StudyImportService.importFile(context, uri) }`).
 * @param resolveTitle `Uri`'den insan-okunur başlık türetir (üretimde
 *   [studyTitleFromDisplayName] geçirilebilir); varsayılan her zaman
 *   "Yeni Çalışma" döner.
 * @param analyze Çözme + pitch analizi hattı (üretimde [OfflinePitchAnalyzer.analyze]).
 * @param viewerLoad Viewer'ı hazırlayıp `load`/`context` komutlarını
 *   kuyruklar (üretimde [defaultViewerLoad]); testler hata fırlatan sahte
 *   bir uygulama geçirerek "geç viewer hatası" atomikliğini doğrular.
 *
 * Birincil kurucu tüm bağımlılıkları açıkça alır (JVM testleri `Context`/
 * `Uri` STUB'larına hiç dokunmadan bunu kullanır). `constructor(context)`
 * ikincil kurucusu gerçek Android katmanlarını (`StudyImportService`,
 * `OfflinePitchAnalyzer`, ...) bağlayarak kompozisyon kökü (`MainActivity`)
 * için kısa yolu sağlar.
 */
class StudyOrchestrator(
    private val libraryStore: StudyLibraryStore,
    private val importFile: suspend (Uri) -> ImportedFile,
    private val resolveTitle: (Uri) -> String = { "Yeni Çalışma" },
    private val analyze: suspend (String, suspend (AnalysisProgress) -> Unit) -> OfflineAnalysisResult =
        { path, onProgress -> OfflinePitchAnalyzer.analyze(sourcePath = path, onProgress = onProgress) },
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    /**
     * Viewer'ı hazırlayıp `load`/`context` komutlarını kuyruklayan işlev.
     * [attachBridge] çağrılana kadar (henüz bir `StudyGraphBridge` yokken)
     * çağrılırsa fırlar — bu, "geç viewer hatası" atomikliğinin doğal bir
     * özel durumudur. `StudyGraphBridge`'i DOĞRUDAN bir kurucu parametresi
     * YAPMAMAK bilinçli bir tercihtir: `StudyGraphBridge`'in kendisi bir
     * Android `WebView` inşa eder ve JVM birim testlerinde (Robolectric yok)
     * asla oluşturulamaz — bu `(Study) -> Unit` seması testlerin gerçek bir
     * köprüye hiç dokunmadan atomiklik senaryolarını sahte bir uygulamayla
     * doğrulamasını sağlar.
     */
    internal var viewerLoad: (Study) -> Unit = { throw IllegalStateException("Görüntüleyici hazır değil.") },
) {
    /** Üretim kısa yolu: gerçek `study/` katmanlarını `context` ile bağlar. */
    constructor(context: Context) : this(
        libraryStore = StudyLibraryStore(context.filesDir),
        importFile = { uri -> StudyImportService.importFile(context, uri) },
        resolveTitle = { uri -> studyTitleFromDisplayName(context, uri) },
    )

    private val _uiState = MutableStateFlow(StudyUiState(studies = safeLoadLibrary()))
    val uiState: StateFlow<StudyUiState> = _uiState.asStateFlow()

    private var bridge: StudyGraphBridge? = null
    private val importGuard = DuplicateImportGuard()
    private var retryable: RetryableImport? = null

    /**
     * UI, `StudyGraphBridge`'i kurarken bunu `onSnapshot` olarak geçirmelidir:
     * `StudyGraphBridge(context, importsDir, onSnapshot = orchestrator.onPlaybackSnapshot)`.
     * Oynatma durumu yalnız buradan, sayfadan gelen anlık görüntüyle
     * güncellenir. Bilerek bir FONKSİYON DEĞERİ (property) — `StudyGraphBridge`'in
     * `onSnapshot: (PlaybackSnapshot) -> Unit` kurucu parametresine düz alan
     * erişimiyle (parantezsiz) doğrudan geçirilebilsin diye.
     */
    val onPlaybackSnapshot: (PlaybackSnapshot) -> Unit = { snapshot ->
        _uiState.update { it.copy(playback = snapshot) }
    }

    /** WebView'i barındıran köprüyü bağlar. UI, Compose `remember` ile sahipliği tutar. */
    fun attachBridge(bridge: StudyGraphBridge) {
        this.bridge = bridge
        viewerLoad = { study -> defaultViewerLoad(bridge, study) }
    }

    /** SAF ile seçilen bir kaynağı içe aktarır, analiz eder ve kütüphaneye ekler. */
    fun importAndAnalyze(uri: Uri) {
        launchImport(key = uri, titleHint = resolveTitle(uri)) { importFile(uri) }
    }

    /** Son başarısız içe aktarmayı aynı kaynaktan yeniden dener. */
    fun retry() {
        val pending = retryable ?: return
        launchImport(key = pending.key, titleHint = pending.titleHint, importer = pending.importer)
    }

    /**
     * Zincirin gerçek uygulaması. `key`, yinelenen içe aktarmaları
     * engellemek için kullanılır (bkz. [DuplicateImportGuard]) — üretimde
     * `Uri`'nin kendisi, testlerde sahte bir nesne/String olabilir. `internal`
     * görünürlük JVM testlerinin `android.net.Uri` inşa etmeden bu yolu
     * doğrudan egzersiz etmesini sağlar.
     */
    internal fun launchImport(key: Any, titleHint: String, importer: suspend () -> ImportedFile) {
        if (!importGuard.begin(key)) return
        scope.launch {
            _uiState.update { it.copy(phase = StudyPhase.IMPORTING, progress = null, errorMessage = null) }
            try {
                val imported = withContext(ioDispatcher) { importer() }
                val result = analyze(imported.file.absolutePath) { progress -> publishProgress(progress) }
                val study = Study(
                    sourceURL = imported.file.absolutePath,
                    title = titleHint,
                    duration = result.durationSeconds,
                    frames = result.frames,
                    context = StudyContext(),
                    pipelineRevision = OfflinePitchAnalyzer.PIPELINE_REVISION,
                )
                // Çalışmayı kaydetmeden önce viewer'ı hazırla. Bu geç adım
                // başarısız olursa `retry()` kalıcı bir kayıt bulmamalı ve
                // aynı kaynak için ikinci bir çalışma yaratmamalı — bkz.
                // StudyState.swift'teki aynı sıralama.
                viewerLoad(study)

                val updated = listOf(study) + _uiState.value.studies
                withContext(ioDispatcher) { libraryStore.save(updated) }

                _uiState.update {
                    it.copy(
                        phase = StudyPhase.READY,
                        studies = updated,
                        current = study,
                        progress = null,
                        errorMessage = null,
                    )
                }
                importGuard.finish(key, succeeded = true)
                retryable = null
            } catch (cancellation: CancellationException) {
                importGuard.finish(key, succeeded = false)
                throw cancellation
            } catch (error: Exception) {
                _uiState.update {
                    it.copy(
                        phase = StudyPhase.FAILED,
                        progress = null,
                        errorMessage = error.message ?: "Çalışma hazırlanamadı.",
                    )
                }
                importGuard.finish(key, succeeded = false)
                retryable = RetryableImport(key, titleHint, importer)
            }
        }
    }

    private fun publishProgress(progress: AnalysisProgress) {
        val phase = when (progress.stage) {
            AnalysisStage.DECODE -> StudyPhase.DECODING
            AnalysisStage.PITCH -> StudyPhase.ANALYZING
            AnalysisStage.WRITE -> StudyPhase.WRITING
        }
        _uiState.update { it.copy(phase = phase, progress = progress.fraction?.toFloat()) }
    }

    /** Kütüphaneden zaten kayıtlı bir çalışmayı açar. */
    fun openStudy(id: String) {
        val study = _uiState.value.studies.firstOrNull { it.id == id } ?: return
        pauseForLeavingWorkspace()
        try {
            viewerLoad(study)
            _uiState.update {
                it.copy(phase = StudyPhase.READY, current = study, progress = null, errorMessage = null, playback = null)
            }
        } catch (error: Exception) {
            _uiState.update { it.copy(phase = StudyPhase.FAILED, errorMessage = "Kaydedilmiş çalışma açılamadı.") }
        }
    }

    /** Bir çalışmayı kütüphaneden kaldırır (medya dosyasına dokunmaz). */
    fun removeStudy(id: String) {
        pauseForLeavingWorkspace()
        val state = _uiState.value
        val uuid = runCatching { UUID.fromString(id) }.getOrNull()
        try {
            val remaining = if (uuid != null) {
                libraryStore.removeSync(uuid, state.studies)
            } else {
                state.studies.filterNot { it.id == id }.also { libraryStore.save(it) }
            }
            val wasCurrent = state.current?.id == id
            _uiState.update {
                it.copy(
                    studies = remaining,
                    current = if (wasCurrent) null else it.current,
                    phase = if (wasCurrent) StudyPhase.IDLE else it.phase,
                    playback = if (wasCurrent) null else it.playback,
                )
            }
            if (wasCurrent) bridge?.close()
        } catch (error: Exception) {
            _uiState.update { it.copy(errorMessage = "Çalışma listeden kaldırılamadı.") }
        }
    }

    fun playPause() {
        bridge?.enqueue(StudyCommand.PlayPause)
    }

    fun pause() {
        bridge?.enqueue(StudyCommand.Pause)
    }

    fun seek(time: Double) {
        bridge?.enqueue(StudyCommand.Seek(time))
    }

    /** `rate`, macOS/iPad hız tablosuyla aynı 0.10–2.00/0.05 ızgarasına yuvarlanır. */
    fun setRate(rate: Double) {
        bridge?.enqueue(StudyCommand.Rate(PlaybackRateTable.snap(rate)))
    }

    fun markA() {
        bridge?.enqueue(StudyCommand.MarkA)
    }

    fun markB() {
        bridge?.enqueue(StudyCommand.MarkB)
    }

    fun toggleLoop() {
        bridge?.enqueue(StudyCommand.Loop)
    }

    fun toggleFollow() {
        bridge?.enqueue(StudyCommand.Follow)
    }

    /** `fullscreen == true` → video sahneyi doldurur, grafik köşe düğmesine küçülür. */
    fun setVideoFullscreen(fullscreen: Boolean) {
        bridge?.enqueue(StudyCommand.SetMode(isVideo = fullscreen))
    }

    /** Geçerli çalışmanın müzik bağlamını günceller ve kalıcı kaydeder. */
    fun applyMusicContext(makam: Makam, karar: Karar, scaleDisplay: ScaleDisplay) {
        val state = _uiState.value
        val current = state.current ?: return
        val updatedContext = StudyContext(
            makam = makam.displayName,
            karar = karar.displayName,
            followsCurve = current.context.followsCurve,
            scaleDisplay = scaleDisplay.displayName,
        )
        val updatedStudy = current.copy(context = updatedContext)
        val updatedStudies = state.studies.map { if (it.id == updatedStudy.id) updatedStudy else it }
        try {
            libraryStore.save(updatedStudies)
        } catch (_: Exception) {
            // Swift tarafıyla aynı tolerans: kalıcı yazım başarısız olsa da
            // bellekteki/sayfadaki bağlam güncellenmeye devam eder.
        }
        _uiState.update { it.copy(current = updatedStudy, studies = updatedStudies) }
        bridge?.enqueue(contextCommand(updatedContext))
    }

    private fun pauseForLeavingWorkspace() {
        bridge?.enqueue(StudyCommand.Pause)
    }

    private fun safeLoadLibrary(): List<Study> = try {
        libraryStore.load()
    } catch (_: Exception) {
        emptyList()
    }
}

/** `rate`/index eşlemesi 0.10× → 2.00×, 0.05× adımlarla (macOS/iPad viewer sözleşmesi). */
internal object PlaybackRateTable {
    private val values: List<Double> = (2..40).map { it / 20.0 }

    fun snap(rate: Double): Double {
        val first = values.first()
        val last = values.last()
        val clamped = rate.coerceIn(first, last)
        return values.minByOrNull { kotlin.math.abs(it - clamped) } ?: first
    }
}

private fun contextCommand(context: StudyContext): StudyCommand.Context {
    val musicContext = context.toMusicContext()
    return StudyCommand.Context(
        makam = context.makam,
        karar = context.karar,
        guides = musicContext.guideNotes().map { GuidePayload(name = it.name, hz = it.hz, karar = it.isKarar) },
        pitchColor = DEFAULT_PITCH_COLOR,
        guideColor = DEFAULT_GUIDE_COLOR,
        kararColor = DEFAULT_KARAR_COLOR,
    )
}

/**
 * `StudyGraphBridge`'i yükler, PCM kaynağını (appassets URL'i olarak) ve
 * kareleri `load` komutuyla, ardından mevcut bağlamı `context` komutuyla
 * gönderir. Bridge'in kendisi (`bridge.load()`/`enqueue`) istisna
 * fırlatmaz (Android tarafında dosya kopyası yok — `assets/viewer/` APK
 * içinde gömülü), ama bu fonksiyon [StudyOrchestrator]'ın "geç viewer hatası"
 * seması için kasıtlı olarak `throws`-şekilli bırakılmıştır: testler bunun
 * yerine hata fırlatan sahte bir uygulama geçirebilir.
 */
private fun defaultViewerLoad(bridge: StudyGraphBridge, study: Study) {
    bridge.load()
    val relativeName = File(study.sourceURL).name
    bridge.enqueue(StudyCommand.Load(url = ViewerAssets.importUrl(relativeName), frames = study.frames))
    bridge.enqueue(contextCommand(study.context))
}

/**
 * [StudyOrchestrator]'ın `resolveTitle`'ı için hazır üretim uygulaması: SAF'ın
 * verdiği görünen adı sorup uzantısını atar — Swift'in
 * `source.deletingPathExtension().lastPathComponent`ının Android karşılığı.
 * Sorgu başarısız olursa Türkçe bir yer tutucuya düşer; hiçbir zaman fırlatmaz.
 * `Context` gerektirdiği için orkestratörün kendisi değil, kompozisyon kökü
 * bunu `resolveTitle = { uri -> studyTitleFromDisplayName(context, uri) }`
 * şeklinde geçirir.
 */
fun studyTitleFromDisplayName(context: Context, uri: Uri): String {
    val name = try {
        context.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
    } catch (_: Exception) {
        null
    }
    val base = name?.substringBeforeLast('.')?.trim().orEmpty()
    return base.ifEmpty { "Yeni Çalışma" }
}
