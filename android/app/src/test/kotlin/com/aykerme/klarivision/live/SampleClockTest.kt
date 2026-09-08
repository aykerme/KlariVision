package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Test

class SampleClockTest {

    @Test
    fun `starts at zero`() {
        val clock = SampleClock(48_000.0)
        assertEquals(0.0, clock.currentTimeSeconds(), 1e-12)
        assertEquals(0L, clock.samplesWritten)
    }

    @Test
    fun `advance returns time before the block and moves the counter forward`() {
        val clock = SampleClock(48_000.0)

        val t0 = clock.advance(480) // 10 ms @ 48 kHz
        assertEquals(0.0, t0, 1e-12)
        assertEquals(480L, clock.samplesWritten)

        val t1 = clock.advance(480)
        assertEquals(480.0 / 48_000.0, t1, 1e-12)
        assertEquals(960L, clock.samplesWritten)
    }

    @Test
    fun `currentTimeSeconds reflects accumulated samples`() {
        val clock = SampleClock(48_000.0)
        clock.advance(48_000)
        assertEquals(1.0, clock.currentTimeSeconds(), 1e-12)
    }

    @Test
    fun `alignTo jumps forward to a later hardware frame position`() {
        val clock = SampleClock(48_000.0)
        clock.advance(100)
        clock.alignTo(48_000)
        assertEquals(48_000L, clock.samplesWritten)
        assertEquals(1.0, clock.currentTimeSeconds(), 1e-12)
    }

    @Test
    fun `alignTo never moves the clock backwards`() {
        val clock = SampleClock(48_000.0)
        clock.advance(10_000)
        clock.alignTo(1_000) // donanım konumu bizim saydığımızdan geride
        assertEquals(10_000L, clock.samplesWritten)
    }

    @Test
    fun `reset returns the clock to zero`() {
        val clock = SampleClock(48_000.0)
        clock.advance(48_000)
        clock.reset()
        assertEquals(0.0, clock.currentTimeSeconds(), 1e-12)
        assertEquals(0L, clock.samplesWritten)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `negative sample count is rejected`() {
        SampleClock(48_000.0).advance(-1)
    }
}
