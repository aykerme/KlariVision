package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PcmConversionTest {

    @Test
    fun `minimum short value maps to exactly negative one`() {
        val out = PcmConversion.int16ToFloat32(shortArrayOf(Short.MIN_VALUE))
        assertEquals(-1.0f, out[0], 0.0f)
    }

    @Test
    fun `zero maps to exactly zero`() {
        val out = PcmConversion.int16ToFloat32(shortArrayOf(0))
        assertEquals(0.0f, out[0], 0.0f)
    }

    @Test
    fun `maximum short value maps to just under positive one`() {
        val out = PcmConversion.int16ToFloat32(shortArrayOf(Short.MAX_VALUE))
        assertTrue(out[0] < 1.0f)
        assertEquals(32767f / 32768f, out[0], 1e-9f)
    }

    @Test
    fun `converts only the requested sample count`() {
        val input = shortArrayOf(Short.MIN_VALUE, Short.MAX_VALUE, 0, 100, -100)
        val output = FloatArray(input.size) { 42f }
        PcmConversion.int16ToFloat32(input, sampleCount = 2, output = output)

        assertEquals(-1.0f, output[0], 0.0f)
        assertEquals(32767f / 32768f, output[1], 1e-9f)
        // Talep edilmeyen konumlar dokunulmadan kalır (önceden ayrılmış tampon sözleşmesi).
        assertEquals(42f, output[2], 0.0f)
    }

    @Test
    fun `reuses a preallocated output buffer without allocating a new one`() {
        val output = FloatArray(3)
        val returned = PcmConversion.int16ToFloat32(shortArrayOf(1, 2, 3), output = output)
        assertTrue(returned === output)
    }

    @Test
    fun `default output buffer matches input size`() {
        val out = PcmConversion.int16ToFloat32(shortArrayOf(10, 20, 30))
        assertEquals(3, out.size)
    }
}
