package com.aykerme.klarivision.profiling

import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileRingTest {

    @Test
    fun `empty ring reports a zeroed summary`() {
        val ring = ProfileRing(4)
        val summary = ring.summary()
        assertEquals(0, summary.count)
        assertEquals(0L, summary.p50)
        assertEquals(0L, summary.p95)
        assertEquals(0L, summary.max)
    }

    @Test
    fun `summary reports p50 p95 and max over recorded samples`() {
        val ring = ProfileRing(16)
        // 1..10 ns — p50/p95/max'i elle doğrulanabilir küçük bir küme.
        (1..10).forEach { ring.record(it.toLong()) }
        val summary = ring.summary()
        assertEquals(10, summary.count)
        assertEquals(10L, summary.max)
        // sıralı [1..10], (count-1)*0.50 = 4,5 → round(4,5)=5 → indeks 5 → değer 6
        assertEquals(6L, summary.p50)
        // (count-1)*0.95 = 8,55 → round=9 → indeks 9 → değer 10
        assertEquals(10L, summary.p95)
    }

    @Test
    fun `ring overwrites the oldest sample once capacity is exceeded — no allocation growth`() {
        val ring = ProfileRing(3)
        ring.record(1L)
        ring.record(2L)
        ring.record(3L)
        // Kapasite 3'ü aştı — 1 örneği düşmeli, yalnız [2,3,4] kalmalı.
        ring.record(4L)
        val summary = ring.summary()
        assertEquals(3, summary.count)
        assertEquals(4L, summary.max)
    }

    @Test
    fun `clear resets the ring to empty`() {
        val ring = ProfileRing(4)
        ring.record(5L)
        ring.record(9L)
        ring.clear()
        assertEquals(0, ring.summary().count)
    }
}

class LiveInstrumentationDroppedFramesTest {

    private val budget60Hz = 16_666_667L

    @Test
    fun `an interval at exactly one frame budget drops nothing`() {
        assertEquals(0, LiveInstrumentation.droppedFrames(budget60Hz, budget60Hz))
    }

    @Test
    fun `an interval under budget drops nothing`() {
        assertEquals(0, LiveInstrumentation.droppedFrames(budget60Hz / 2, budget60Hz))
    }

    @Test
    fun `an interval spanning two budgets drops exactly one frame`() {
        assertEquals(1, LiveInstrumentation.droppedFrames(2 * budget60Hz, budget60Hz))
    }

    @Test
    fun `an interval spanning five budgets drops four frames`() {
        assertEquals(4, LiveInstrumentation.droppedFrames(5 * budget60Hz, budget60Hz))
    }

    @Test
    fun `a slightly overshot interval rounds to the nearest frame count`() {
        // 1,05 kare bütçesi — en yakın tam kareye yuvarlanır (1), 0 atlanan kare.
        assertEquals(0, LiveInstrumentation.droppedFrames((budget60Hz * 1.05).toLong(), budget60Hz))
    }

    @Test
    fun `a zero or negative expected interval never reports a drop`() {
        assertEquals(0, LiveInstrumentation.droppedFrames(budget60Hz, 0L))
        assertEquals(0, LiveInstrumentation.droppedFrames(budget60Hz, -1L))
    }

    @Test
    fun `a non-positive delta never reports a drop`() {
        assertEquals(0, LiveInstrumentation.droppedFrames(0L, budget60Hz))
        assertEquals(0, LiveInstrumentation.droppedFrames(-5L, budget60Hz))
    }
}

class LiveInstrumentationResetTest {

    @Test
    fun `resetAll clears every metric and the skipped-frame counter`() {
        LiveInstrumentation.jniEngineNanos.record(1L)
        LiveInstrumentation.jsonSerializeNanos.record(1L)
        LiveInstrumentation.jsonByteSize.record(1L)
        LiveInstrumentation.evaluateNanos.record(1L)
        LiveInstrumentation.frameIntervalNanos.record(1L)
        LiveInstrumentation.skippedFrames.addAndGet(3L)

        LiveInstrumentation.resetAll()

        assertEquals(0, LiveInstrumentation.jniEngineNanos.summary().count)
        assertEquals(0, LiveInstrumentation.jsonSerializeNanos.summary().count)
        assertEquals(0, LiveInstrumentation.jsonByteSize.summary().count)
        assertEquals(0, LiveInstrumentation.evaluateNanos.summary().count)
        assertEquals(0, LiveInstrumentation.frameIntervalNanos.summary().count)
        assertEquals(0L, LiveInstrumentation.skippedFrames.get())
    }
}
