package com.aykerme.klarivision.study

import com.aykerme.klarivision.core.PitchFrame as CorePitchFrame
import java.nio.FloatBuffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `MediaCodec` gerçek cihaz/enstrümantasyon işidir — burada taklit
 * EDİLMEZ. Bunun yerine [AudioDecoder] arayüzü sahte bir uygulamayla
 * değiştirilir; [OfflinePitchAnalyzer]'ın kendisi (downmix/resample/ilerleme
 * sıralaması) böylece saf JVM testiyle koşar.
 */
private class FakeAudioDecoder(
    private val durationSeconds: Double,
    private val sampleRateHz: Int,
    private val channelCount: Int,
    private val chunks: List<FloatArray>,
) : AudioDecoder {
    override suspend fun probe(sourcePath: String): AudioSourceInfo =
        AudioSourceInfo(durationSeconds, sampleRateHz, channelCount)

    override suspend fun decode(sourcePath: String, onChunk: suspend (AudioChunk) -> Unit) {
        var framesEmitted = 0L
        for (chunk in chunks) {
            onChunk(
                AudioChunk(
                    interleavedSamples = chunk,
                    channelCount = channelCount,
                    sampleRateHz = sampleRateHz,
                    presentationTimeUs = (framesEmitted * 1_000_000L) / sampleRateHz,
                )
            )
            framesEmitted += chunk.size / channelCount
        }
    }
}

/** `OfflineTrackSession`'ın native olmayan sahte uygulaması. */
private class FakeEngineSession(private val frames: List<CorePitchFrame>) : OfflineEngineSession {
    var pushedSamples = 0
        private set
    var closed = false
        private set

    override fun push(samples: FloatBuffer, sampleRateHz: Double) {
        assertEquals(Resampler.TARGET_SAMPLE_RATE_HZ, sampleRateHz, 1e-9)
        pushedSamples += samples.remaining()
    }

    override fun finish(): Int = frames.size

    override fun frame(index: Int): CorePitchFrame = frames[index]

    override fun close() {
        closed = true
    }
}

class OfflinePitchAnalyzerTest {

    @Test
    fun `progress stages are emitted in canonical decode-pitch-write order`() = runTest {
        val decoder = FakeAudioDecoder(
            durationSeconds = 1.0,
            sampleRateHz = 48_000,
            channelCount = 1,
            chunks = listOf(FloatArray(24_000) { 0f }, FloatArray(24_000) { 0f }),
        )
        val session = FakeEngineSession(
            listOf(CorePitchFrame(0.0, 440.0, 0.9, true), CorePitchFrame(0.01, 442.0, 0.8, true))
        )
        val stages = mutableListOf<AnalysisStage>()

        OfflinePitchAnalyzer.analyze(
            sourcePath = "fake.wav",
            decoder = decoder,
            sessionFactory = { session },
            dispatcher = Dispatchers.Unconfined,
            onProgress = { stages.add(it.stage) },
        )

        assertTrue("decode aşaması bulunmalı", stages.contains(AnalysisStage.DECODE))
        val firstPitch = stages.indexOf(AnalysisStage.PITCH)
        val firstWrite = stages.indexOf(AnalysisStage.WRITE)
        assertTrue("pitch aşaması bulunmalı", firstPitch >= 0)
        assertTrue("write aşaması bulunmalı", firstWrite >= 0)
        assertTrue("decode pitch'ten önce olmalı", stages.indexOf(AnalysisStage.DECODE) < firstPitch)
        assertTrue("pitch write'tan önce olmalı", firstPitch < firstWrite)
        // Aşamalar geri sıçramaz: pitch başladıktan sonra bir daha decode görülmez.
        assertTrue(stages.subList(firstPitch, stages.size).none { it == AnalysisStage.DECODE })
    }

    @Test
    fun `pitch stage is reported as indeterminate (fraction is null)`() = runTest {
        val decoder = FakeAudioDecoder(1.0, 48_000, 1, listOf(FloatArray(48_000) { 0f }))
        val session = FakeEngineSession(emptyList())
        var sawPitchStage = false
        var pitchFraction: Double? = -1.0

        OfflinePitchAnalyzer.analyze(
            sourcePath = "fake.wav",
            decoder = decoder,
            sessionFactory = { session },
            dispatcher = Dispatchers.Unconfined,
            onProgress = {
                if (it.stage == AnalysisStage.PITCH) {
                    sawPitchStage = true
                    pitchFraction = it.fraction
                }
            },
        )

        assertTrue(sawPitchStage)
        assertNull(pitchFraction)
    }

    @Test
    fun `decode stage never exceeds 0_9`() = runTest {
        val decoder = FakeAudioDecoder(1.0, 48_000, 1, listOf(FloatArray(48_000) { 0f }))
        val session = FakeEngineSession(emptyList())
        val decodeFractions = mutableListOf<Double>()

        OfflinePitchAnalyzer.analyze(
            sourcePath = "fake.wav",
            decoder = decoder,
            sessionFactory = { session },
            dispatcher = Dispatchers.Unconfined,
            onProgress = { if (it.stage == AnalysisStage.DECODE) decodeFractions.add(it.fraction!!) },
        )

        assertTrue(decodeFractions.isNotEmpty())
        assertTrue(decodeFractions.all { it <= 0.9 + 1e-9 })
    }

    @Test
    fun `stereo source is downmixed and frames are mapped from core to study PitchFrame`() = runTest {
        // 1 saniyelik 48 kHz stereo -> 96000 interleaved örnek.
        val decoder = FakeAudioDecoder(1.0, 48_000, 2, listOf(FloatArray(96_000) { 0f }))
        val engineFrames = listOf(CorePitchFrame(0.5, 220.0, 0.7, true))
        val session = FakeEngineSession(engineFrames)

        val result = OfflinePitchAnalyzer.analyze(
            sourcePath = "fake.wav",
            decoder = decoder,
            sessionFactory = { session },
            dispatcher = Dispatchers.Unconfined,
        )

        assertEquals(1, result.frames.size)
        assertEquals(0.5, result.frames[0].time, 1e-9)
        assertEquals(220.0, result.frames[0].frequency, 1e-9)
        assertEquals(0.7, result.frames[0].confidence, 1e-9)
        assertTrue(result.frames[0].voiced)
        // Stereo 48 kHz -> mono 48 kHz downmix sonrası motora beslenen örnek
        // sayısı, girişteki kare (frame) sayısıyla eşleşmeli (96000/2 kanal).
        assertEquals(48_000, session.pushedSamples)
        assertTrue(session.closed)
    }

    @Test
    fun `empty engine output still closes the session and reports write completion`() = runTest {
        val decoder = FakeAudioDecoder(1.0, 48_000, 1, listOf(FloatArray(48_000) { 0f }))
        val session = FakeEngineSession(emptyList())
        var lastWriteFraction: Double? = null

        val result = OfflinePitchAnalyzer.analyze(
            sourcePath = "fake.wav",
            decoder = decoder,
            sessionFactory = { session },
            dispatcher = Dispatchers.Unconfined,
            onProgress = { if (it.stage == AnalysisStage.WRITE) lastWriteFraction = it.fraction },
        )

        assertTrue(result.frames.isEmpty())
        assertEquals(1.0, lastWriteFraction)
        assertTrue(session.closed)
    }
}
