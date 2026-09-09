// KlariVision Android — StudyOrchestrator için JVM birim testleri. Android
// Context/Uri STUB'larına (Robolectric yok) hiç dokunmaz: `Uri`, `Context`
// gerektiren bağımlılıklar (importFile/resolveTitle/viewerLoad) sahte
// uygulamalarla geçirilir, `internal launchImport(key, ...)` ile gerçek
// zincir `android.net.Uri` inşa etmeden egzersiz edilir (bkz.
// `state/StudyOrchestrator.kt`'nin baş yorumu).

package com.aykerme.klarivision.state

import com.aykerme.klarivision.study.AnalysisProgress
import com.aykerme.klarivision.study.AnalysisStage
import com.aykerme.klarivision.study.ImportedFile
import com.aykerme.klarivision.study.MediaKind
import com.aykerme.klarivision.study.OfflineAnalysisResult
import com.aykerme.klarivision.study.PitchFrame
import com.aykerme.klarivision.study.Study
import com.aykerme.klarivision.study.StudyLibraryStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

class StudyOrchestratorTest {

    private lateinit var tempDir: File
    private lateinit var libraryStore: StudyLibraryStore

    @Before
    fun setUp() {
        tempDir = File.createTempFile("study_orch_", "").parentFile
            ?.let { File(it, "kv_study_orch_test_${System.currentTimeMillis()}_${System.nanoTime()}") }
            ?: throw IllegalStateException("Geçici dizin oluşturulamadı")
        tempDir.mkdirs()
        libraryStore = StudyLibraryStore(File(tempDir, "root").apply { mkdirs() })
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    /**
     * Tüm bağımlılıkları sahte uygulamalarla kuran bir orkestratör.
     * `Dispatchers.Unconfined` hem `scope` hem `ioDispatcher` için kullanılır
     * ki `launchImport` çağrısı gerçek asenkron bir boşluk olmadan senkron
     * biter — testler `runBlocking`/`advanceUntilIdle` olmadan doğrudan
     * son (veya ara) durumu okuyabilir.
     */
    private fun orchestrator(
        importer: suspend () -> ImportedFile = { fakeImportedFile() },
        analyze: suspend (String, suspend (AnalysisProgress) -> Unit) -> OfflineAnalysisResult = ::successfulAnalyze,
        viewerLoad: (Study) -> Unit = {},
    ): StudyOrchestrator {
        val orch = StudyOrchestrator(
            libraryStore = libraryStore,
            importFile = { _ -> importer() },
            analyze = analyze,
            ioDispatcher = Dispatchers.Unconfined,
            scope = CoroutineScope(Dispatchers.Unconfined),
        )
        orch.viewerLoad = viewerLoad
        return orch
    }

    private fun fakeImportedFile(name: String = "clip.wav"): ImportedFile {
        val file = File(tempDir, name).apply { writeBytes(ByteArray(4)) }
        return ImportedFile(file = file, mediaKind = MediaKind.AUDIO)
    }

    private suspend fun successfulAnalyze(
        @Suppress("UNUSED_PARAMETER") path: String,
        onProgress: suspend (AnalysisProgress) -> Unit,
    ): OfflineAnalysisResult {
        onProgress(AnalysisProgress(AnalysisStage.DECODE, 0.5))
        onProgress(AnalysisProgress(AnalysisStage.PITCH, null))
        onProgress(AnalysisProgress(AnalysisStage.WRITE, 1.0))
        return OfflineAnalysisResult(
            frames = listOf(PitchFrame(time = 0.0, frequency = 440.0, confidence = 1.0, voiced = true)),
            durationSeconds = 1.0,
        )
    }

    // MARK: - Başarılı zincir

    @Test
    fun `successful chain visits phases in order and ends READY`() {
        val visited = mutableListOf<StudyPhase>()
        lateinit var orch: StudyOrchestrator
        orch = orchestrator(
            analyze = { path, onProgress ->
                // IMPORTING zaten launchImport başında yayınlandı.
                visited.add(orch.uiState.value.phase)
                onProgress(AnalysisProgress(AnalysisStage.DECODE, 0.5))
                visited.add(orch.uiState.value.phase)
                onProgress(AnalysisProgress(AnalysisStage.PITCH, null))
                visited.add(orch.uiState.value.phase)
                onProgress(AnalysisProgress(AnalysisStage.WRITE, 1.0))
                visited.add(orch.uiState.value.phase)
                OfflineAnalysisResult(
                    frames = listOf(PitchFrame(0.0, 440.0, 1.0, true)),
                    durationSeconds = 1.0,
                )
            },
        )

        orch.launchImport(key = "rec-1", titleHint = "Kayıt 1") { fakeImportedFile() }

        assertEquals(
            listOf(StudyPhase.IMPORTING, StudyPhase.DECODING, StudyPhase.ANALYZING, StudyPhase.WRITING),
            visited,
        )
        assertEquals(StudyPhase.READY, orch.uiState.value.phase)
        assertEquals(1, orch.uiState.value.studies.size)
        assertEquals("Kayıt 1", orch.uiState.value.current?.title)
        assertEquals(1, libraryStore.load().size)
    }

    @Test
    fun `ANALYZING stage reports null progress`() {
        var progressDuringAnalyzing: Float? = -1f
        lateinit var orch: StudyOrchestrator
        orch = orchestrator(
            analyze = { _, onProgress ->
                onProgress(AnalysisProgress(AnalysisStage.DECODE, 0.5))
                onProgress(AnalysisProgress(AnalysisStage.PITCH, null))
                progressDuringAnalyzing = orch.uiState.value.progress
                onProgress(AnalysisProgress(AnalysisStage.WRITE, 1.0))
                OfflineAnalysisResult(emptyList(), 1.0)
            },
        )

        orch.launchImport(key = "rec-progress", titleHint = "Kayıt") { fakeImportedFile() }

        assertNull(progressDuringAnalyzing)
    }

    // MARK: - Çözümleme hatası

    @Test
    fun `decode failure leaves library empty and sets FAILED`() {
        val orch = orchestrator(
            analyze = { _, _ -> throw RuntimeException("Ses çözülemedi.") },
        )

        orch.launchImport(key = "rec-fail", titleHint = "Kayıt") { fakeImportedFile() }

        assertEquals(StudyPhase.FAILED, orch.uiState.value.phase)
        assertEquals("Ses çözülemedi.", orch.uiState.value.errorMessage)
        assertTrue(orch.uiState.value.studies.isEmpty())
        assertTrue(libraryStore.load().isEmpty())
    }

    @Test
    fun `retry re-runs the same failed import`() {
        var attempts = 0
        val orch = orchestrator(
            analyze = { path, onProgress ->
                attempts += 1
                if (attempts == 1) {
                    throw RuntimeException("Ses çözülemedi.")
                }
                successfulAnalyze(path, onProgress)
            },
        )

        orch.launchImport(key = "rec-retry", titleHint = "Kayıt") { fakeImportedFile() }
        assertEquals(StudyPhase.FAILED, orch.uiState.value.phase)
        assertTrue(libraryStore.load().isEmpty())

        orch.retry()

        assertEquals(StudyPhase.READY, orch.uiState.value.phase)
        assertEquals(2, attempts)
        assertEquals(1, libraryStore.load().size)
    }

    // MARK: - Geç viewer hatası atomikliği

    @Test
    fun `viewer load failure does not save the study`() {
        val orch = orchestrator(
            viewerLoad = { throw IllegalStateException("Viewer yüklenemedi.") },
        )

        orch.launchImport(key = "rec-viewer-fail", titleHint = "Kayıt") { fakeImportedFile() }

        assertEquals(StudyPhase.FAILED, orch.uiState.value.phase)
        assertTrue("Kütüphane boş kalmalı", orch.uiState.value.studies.isEmpty())
        assertTrue("Diskte de hiçbir çalışma olmamalı", libraryStore.load().isEmpty())
        assertNull("current atanmamalı", orch.uiState.value.current)
    }

    // MARK: - Snapshot yansıtma

    @Test
    fun `incoming playback snapshot is reflected into uiState`() {
        val orch = orchestrator()
        val snapshot = com.aykerme.klarivision.web.PlaybackSnapshot(
            time = 12.5,
            duration = 90.0,
            isPlaying = true,
            rate = 1.25,
        )

        orch.onPlaybackSnapshot(snapshot)

        assertEquals(snapshot, orch.uiState.value.playback)
    }

    // MARK: - Yinelenen kayıt

    @Test
    fun `duplicate import key is ignored after success`() {
        var importCount = 0
        val orch = orchestrator()
        val key = "same-recording"

        orch.launchImport(key = key, titleHint = "Kayıt") {
            importCount += 1
            fakeImportedFile("first.wav")
        }
        assertEquals(StudyPhase.READY, orch.uiState.value.phase)
        assertEquals(1, orch.uiState.value.studies.size)

        // Aynı anahtarla ikinci deneme: importer'a hiç ulaşılmamalı, ikinci
        // bir çalışma eklenmemeli.
        orch.launchImport(key = key, titleHint = "Kayıt (tekrar)") {
            importCount += 1
            fakeImportedFile("second.wav")
        }

        assertEquals(1, importCount)
        assertEquals(1, orch.uiState.value.studies.size)
        assertEquals(1, libraryStore.load().size)
    }

    @Test
    fun `distinct keys are not treated as duplicates`() {
        val orch = orchestrator()

        orch.launchImport(key = "key-a", titleHint = "A") { fakeImportedFile("a.wav") }
        orch.launchImport(key = "key-b", titleHint = "B") { fakeImportedFile("b.wav") }

        assertEquals(2, orch.uiState.value.studies.size)
        assertEquals(2, libraryStore.load().size)
    }
}
