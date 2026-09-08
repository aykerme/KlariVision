package com.aykerme.klarivision.study

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class ResamplerTest {

    @Test
    fun `48 kHz source is returned unchanged (identity)`() {
        val source = floatArrayOf(0f, 1f, 2f, 3f)
        val result = Resampler.resampleLinear(source, sourceRateHz = 48_000.0)
        assertSame(source, result)
    }

    @Test
    fun `upsampling doubles the rate with linear interpolation`() {
        // 2 örnek, 1 Hz -> 2 Hz: çıktı uzunluğu 4, ara noktalar doğrusal
        // interpolasyonla; dizi sonunda kaynağın son örneği tekrar eder
        // (CLI'daki `hi = min(lo+1, size-1)` kırpmasıyla aynı davranış).
        val source = floatArrayOf(0f, 10f)
        val result = Resampler.resampleLinear(source, sourceRateHz = 1.0, targetRateHz = 2.0)
        assertEquals(4, result.size)
        assertEquals(0f, result[0], 1e-6f)
        assertEquals(5f, result[1], 1e-6f)
        assertEquals(10f, result[2], 1e-6f)
        assertEquals(10f, result[3], 1e-6f)
    }

    @Test
    fun `downsampling halves the rate`() {
        val source = floatArrayOf(0f, 1f, 2f, 3f, 4f, 5f)
        val result = Resampler.resampleLinear(source, sourceRateHz = 2.0, targetRateHz = 1.0)
        assertEquals(3, result.size)
        assertEquals(0f, result[0], 1e-6f)
        assertEquals(2f, result[1], 1e-6f)
        assertEquals(4f, result[2], 1e-6f)
    }

    @Test
    fun `empty input yields empty output`() {
        val result = Resampler.resampleLinear(floatArrayOf(), sourceRateHz = 44_100.0)
        assertEquals(0, result.size)
    }

    @Test
    fun `non-48kHz target still resamples (arbitrary rates supported)`() {
        val source = floatArrayOf(0f, 4f, 8f)
        val result = Resampler.resampleLinear(source, sourceRateHz = 3.0, targetRateHz = 6.0)
        assertEquals(6, result.size)
        assertEquals(0f, result[0], 1e-6f)
        assertEquals(8f, result[5], 1e-6f)
    }
}
