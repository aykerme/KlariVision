package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PcmWindowAccumulatorTest {

    private fun samplesOf(count: Int, start: Int = 0): FloatArray =
        FloatArray(count) { (start + it).toFloat() }

    @Test
    fun `partial feed produces no window`() {
        val acc = PcmWindowAccumulator()
        acc.append(samplesOf(1000))
        val windows = acc.drainWindows()
        assertTrue(windows.isEmpty())
        assertEquals(1000, acc.pendingSampleCount)
        assertEquals(0, acc.samplesConsumed)
    }

    @Test
    fun `exact window size produces exactly one window`() {
        val acc = PcmWindowAccumulator()
        acc.append(samplesOf(1536))
        val windows = acc.drainWindows()
        assertEquals(1, windows.size)
        assertEquals(1536, windows[0].samples.size)
        // pencere içeriği baştan sona 0..1535 olmalı
        assertEquals(0f, windows[0].samples.first())
        assertEquals(1535f, windows[0].samples.last())
    }

    @Test
    fun `consecutive windows advance by hop size`() {
        val acc = PcmWindowAccumulator()
        // 1536 + 512*2 = 2560 örnek -> 3 pencere üretmeli (1536, 2048, 2560 eşiklerinde)
        acc.append(samplesOf(1536 + 512 * 2))
        val windows = acc.drainWindows()
        assertEquals(3, windows.size)
        // Ardışık pencerelerin merkezleri tam olarak hop kadar (512) ilerlemeli.
        assertEquals(512, windows[1].centerSample - windows[0].centerSample)
        assertEquals(512, windows[2].centerSample - windows[1].centerSample)
        // İlk pencerenin ilk örneği ile ikinci pencerenin ilk örneği arasında
        // tam olarak hop (512) örnek fark olmalı.
        assertEquals(windows[0].samples[512], windows[1].samples[0])
    }

    @Test
    fun `center time is derived from window center not window start`() {
        val acc = PcmWindowAccumulator()
        acc.append(samplesOf(1536))
        val windows = acc.drainWindows()
        // centerSample = 0 + 1536/2 = 768 -> sourceTime = 768/48000
        val expectedCenterSample = 1536 / 2
        assertEquals(expectedCenterSample, windows[0].centerSample)
        val expectedSourceTime = expectedCenterSample / 48_000.0
        assertEquals(expectedSourceTime, windows[0].sourceTime, 1e-12)

        // İkinci pencere için: samplesConsumed artık 512 olduğundan
        // centerSample = 512 + 768 = 1280, pencerenin BAŞLANGICI değil.
        acc.append(samplesOf(512, start = 1536))
        val secondBatch = acc.drainWindows()
        assertEquals(1, secondBatch.size)
        assertEquals(512 + 1536 / 2, secondBatch[0].centerSample)
        assertEquals((512 + 1536 / 2) / 48_000.0, secondBatch[0].sourceTime, 1e-12)
    }

    @Test
    fun `reset clears buffer and consumed counter`() {
        val acc = PcmWindowAccumulator()
        acc.append(samplesOf(2000))
        acc.drainWindows()
        assertTrue(acc.samplesConsumed > 0)

        acc.reset()

        assertEquals(0, acc.samplesConsumed)
        assertEquals(0, acc.pendingSampleCount)
        assertTrue(acc.drainWindows().isEmpty())
    }
}
