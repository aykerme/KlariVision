package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Test

class LiveCoreProcessorTest {

    @Test
    fun `sink is invoked once per completed window with its source time`() {
        val received = mutableListOf<Double>()
        val sink = PitchWindowSink<Double> { _, sourceTime ->
            received.add(sourceTime)
            listOf(sourceTime)
        }
        val processor = LiveCoreProcessor(sink)

        // 1536 + 512 = 2048 örnek: ilk pencere 1536'da, hop (512) sonrası
        // kalan 1536 örnek de ikinci bir pencere tamamlar -> 2 çağrı.
        val samples = FloatArray(1536 + 512) { it.toFloat() }
        val frames = processor.process(samples)

        assertEquals(2, received.size)
        assertEquals((1536 / 2) / 48_000.0, received[0], 1e-12)
        assertEquals((512 + 1536 / 2) / 48_000.0, received[1], 1e-12)
        assertEquals(received, frames)
    }

    @Test
    fun `no sink calls when fewer than a full window is fed`() {
        val sink = PitchWindowSink<Unit> { _, _ -> listOf(Unit) }
        val processor = LiveCoreProcessor(sink)

        val frames = processor.process(FloatArray(100))

        assertEquals(0, frames.size)
    }

    @Test
    fun `reset discards pending partial window`() {
        var calls = 0
        val sink = PitchWindowSink<Unit> { _, _ -> calls++; listOf(Unit) }
        val processor = LiveCoreProcessor(sink)

        processor.process(FloatArray(1000))
        processor.reset()
        processor.process(FloatArray(1000))

        assertEquals(0, calls)
    }
}
