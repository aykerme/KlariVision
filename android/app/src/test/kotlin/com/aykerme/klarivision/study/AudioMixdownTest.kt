package com.aykerme.klarivision.study

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class AudioMixdownTest {

    @Test
    fun `mono passthrough returns same array`() {
        val samples = floatArrayOf(1f, 2f, 3f)
        val result = AudioMixdown.downmixToMono(samples, channelCount = 1)
        assertSame(samples, result)
    }

    @Test
    fun `stereo channels are averaged`() {
        // L, R, L, R -> (L+R)/2 çiftleri
        val interleaved = floatArrayOf(1f, 3f, -1f, 1f)
        val result = AudioMixdown.downmixToMono(interleaved, channelCount = 2)
        assertArrayEquals(floatArrayOf(2f, 0f), result, 1e-6f)
    }

    @Test
    fun `three channels are averaged`() {
        val interleaved = floatArrayOf(0f, 3f, 6f, 9f, 12f, 15f)
        val result = AudioMixdown.downmixToMono(interleaved, channelCount = 3)
        assertArrayEquals(floatArrayOf(3f, 12f), result, 1e-6f)
    }

    @Test
    fun `mismatched sample count throws`() {
        assertThrows(IllegalArgumentException::class.java) {
            AudioMixdown.downmixToMono(floatArrayOf(1f, 2f, 3f), channelCount = 2)
        }
    }

    @Test
    fun `non-positive channel count throws`() {
        assertThrows(IllegalArgumentException::class.java) {
            AudioMixdown.downmixToMono(floatArrayOf(1f, 2f), channelCount = 0)
        }
    }
}
