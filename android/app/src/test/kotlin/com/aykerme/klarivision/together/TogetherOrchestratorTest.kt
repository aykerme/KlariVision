// KlariVision Android — "Birlikte Çal" orkestratörünün gönderme kuralları.
//
// Bu testler macOS `TogetherSession.handle(...)`'daki kuralları sabitler.
// Kurallar ince ve sessizce bozulabilir cinsten: hepsi de bozulduğunda
// çökmez, yalnız yanlış çizer.

package com.aykerme.klarivision.together

import com.aykerme.klarivision.live.RecordingPhase
import com.aykerme.klarivision.state.LiveCaptureEngine
import com.aykerme.klarivision.study.PitchFrame
import com.aykerme.klarivision.web.PlaybackSnapshot
import com.aykerme.klarivision.web.StudyCommand
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TogetherOrchestratorTest {

    /** Kare akışını testin elinde tutan sahte yakalama motoru. */
    private class FakeCapture : LiveCaptureEngine {
        var frameSink: ((List<PitchFrame>) -> Unit)? = null
        var stopCount = 0
        override suspend fun start(
            minimumRms: Double,
            onFrames: (List<PitchFrame>) -> Unit,
            onRecording: (RecordingPhase) -> Unit,
            onFailure: (String) -> Unit,
        ) { frameSink = onFrames }
        override suspend fun stop(): RecordingPhase { stopCount++; return RecordingPhase.Idle }
        override suspend fun toggleRecording(): RecordingPhase = RecordingPhase.Idle
    }

    private class Harness {
        val capture = FakeCapture()
        val commands = mutableListOf<StudyCommand>()
        var wallClock = 1_000.0
        val orchestrator = TogetherOrchestrator(
            capture = capture,
            sendCommand = { commands += it },
            hasRecordAudioPermission = { true },
            measureLatency = { InputLatencyEstimate(0.0, InputLatencySource.FALLBACK_DEFAULT) },
            micAlignmentMs = { 0.0 },
            wallClockSeconds = { wallClock },
            scope = CoroutineScope(UnconfinedTestDispatcher()),
            log = {},
        )
        val appended: List<StudyCommand.MicAppend>
            get() = commands.filterIsInstance<StudyCommand.MicAppend>()

        fun play(time: Double, rate: Double = 1.0) =
            orchestrator.onPlaybackSnapshot(snapshot(time, true, rate))
        fun pause(time: Double) = orchestrator.onPlaybackSnapshot(snapshot(time, false, 1.0))
        private fun snapshot(time: Double, playing: Boolean, rate: Double) =
            PlaybackSnapshot(time = time, duration = 100.0, isPlaying = playing, rate = rate)

        fun push(vararg frames: PitchFrame) = capture.frameSink?.invoke(frames.toList())
    }

    private fun frame(time: Double, hz: Double = 440.0, conf: Double = 0.9, voiced: Boolean = true) =
        PitchFrame(time = time, frequency = hz, confidence = conf, voiced = voiced)

    @Test
    fun duraklatilmiskenNoktaUretilmezAmaImlecIlerler() = runTest {
        val h = Harness()
        h.orchestrator.start()
        h.pause(10.0)

        // Duraklamada gelen kareler çizilmemeli.
        h.push(frame(1.0), frame(2.0))
        assertTrue("Duraklatılmışken nokta gönderilmemeli", h.appended.isEmpty())

        // Oynatma dönünce, duraklamada biriken kareler TOPTAN gelmemeli:
        // imleç ilerlediği için yalnız yeni kare (3.0) işlenir.
        h.play(10.0)
        h.push(frame(1.0), frame(2.0), frame(3.0))
        val points = h.appended.flatMap { it.points }
        assertEquals("Yalnız imleçten sonraki kare işlenmeli", 1, points.size)
    }

    @Test
    fun kumulatifAkistaYalnizYeniKarelerAlinir() = runTest {
        val h = Harness()
        h.orchestrator.start()
        h.play(10.0)

        h.push(frame(1.0), frame(2.0))
        val first = h.appended.flatMap { it.points }.size
        h.push(frame(1.0), frame(2.0), frame(3.0))   // kümülatif tekrar
        val total = h.appended.flatMap { it.points }.size

        assertEquals("İlk turda iki kare", 2, first)
        assertEquals("İkinci turda yalnız bir yeni kare eklenmeli", 3, total)
    }

    @Test
    fun elemeEsikleriDinlemeTarafiylaAyni() = runTest {
        val h = Harness()
        h.orchestrator.start()
        h.play(10.0)

        h.push(
            frame(1.0, hz = 79.0),                    // eşiğin altında
            frame(2.0, hz = 80.0),                    // tam eşik — geçer
            frame(3.0, hz = 440.0, conf = 0.19),      // güven eşiğinin altında
            frame(4.0, hz = 440.0, conf = 0.20),      // tam eşik — geçer
            frame(5.0, hz = Double.NaN),              // sonlu değil
            frame(6.0, hz = Double.POSITIVE_INFINITY) // sonlu değil
        )
        assertEquals("Yalnız iki kare eşikleri geçmeli", 2, h.appended.flatMap { it.points }.size)
    }

    @Test
    fun toplugonderimdeHerKareKendiZamaniniAlir() = runTest {
        val h = Harness()
        h.orchestrator.start()
        h.play(50.0)
        h.wallClock = 1_010.0

        // İki kare, aralarında 1 saniye. Partiye tek damga vurulsaydı ikisi
        // aynı mediaTime'ı alırdı.
        h.push(frame(1.0), frame(2.0))
        val points = h.appended.flatMap { it.points }
        assertEquals(2, points.size)
        assertTrue(
            "İki kare farklı medya zamanı almalı (partiye tek damga vurulmamalı)",
            points[1].time != points[0].time,
        )
        assertEquals(
            "Kareler arası fark, kaynak zamanları arasındaki farkı korumalı",
            1.0, points[1].time - points[0].time, 1e-9,
        )
    }

    @Test
    fun negatifMediaTimeAtilir() = runTest {
        val h = Harness()
        h.orchestrator.start()
        // Saat neredeyse sıfırda; kare çok eskiye düşer → negatif mediaTime.
        h.play(0.0)
        h.wallClock = 1_100.0
        h.push(frame(1.0))
        assertTrue("Negatif medya zamanı gönderilmemeli", h.appended.flatMap { it.points }.isEmpty())
    }

    @Test
    fun geriyeSicramaMicTruncateGonderir() = runTest {
        val h = Harness()
        h.orchestrator.start()
        h.play(30.0)
        h.play(10.0)   // loop B→A dönüşü ya da geriye arama

        val truncate = h.commands.filterIsInstance<StudyCommand.MicTruncate>()
        assertEquals("Geriye sıçramada tam bir micTruncate gönderilmeli", 1, truncate.size)
        assertEquals(10.0, truncate.first().time, 1e-9)
    }

    @Test
    fun teardownIdempotent() = runTest {
        val h = Harness()
        h.orchestrator.start()
        h.orchestrator.stop()
        h.orchestrator.stop()
        assertEquals("İkinci stop mikrofonu tekrar kapatmamalı", 1, h.capture.stopCount)
    }

    @Test
    fun modAcilisindaKatmanTemizlenirVeRenkGonderilir() = runTest {
        val h = Harness()
        h.orchestrator.start()
        assertTrue("Açılışta micClear gönderilmeli", h.commands.any { it is StudyCommand.MicClear })
        assertTrue("Açılışta setMicColor gönderilmeli", h.commands.any { it is StudyCommand.SetMicColor })
    }

    @Test
    fun izinYoksaModAcilmaz() = runTest {
        val capture = FakeCapture()
        val commands = mutableListOf<StudyCommand>()
        val orchestrator = TogetherOrchestrator(
            capture = capture,
            sendCommand = { commands += it },
            hasRecordAudioPermission = { false },
            measureLatency = { InputLatencyEstimate(0.0, InputLatencySource.FALLBACK_DEFAULT) },
            scope = CoroutineScope(UnconfinedTestDispatcher()),
            log = {},
        )
        orchestrator.start()
        assertTrue("İzin yokken mod açılmamalı", !orchestrator.uiState.value.isRunning)
        assertTrue("İzin gereği bildirilmeli", orchestrator.uiState.value.permissionRequired)
        assertTrue("İzin yokken viewer'a komut gitmemeli", commands.isEmpty())
    }
}
