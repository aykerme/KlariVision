package com.aykerme.klarivision.live

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WavRecorderTest {

    private fun tempWav(): File = File.createTempFile("wav-recorder-test", ".wav").apply { deleteOnExit() }

    private fun ascii(bytes: ByteArray, offset: Int, length: Int): String =
        String(bytes, offset, length, Charsets.US_ASCII)

    @Test
    fun `header stub is written immediately on create with zero-length data`() {
        val file = tempWav()
        val recorder = WavRecorder.create(file, sampleRateHz = 48_000, channelCount = 1)
        recorder.close()

        val bytes = file.readBytes()
        assertEquals(WavRecorder.HEADER_SIZE_BYTES, bytes.size)
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

        assertEquals("RIFF", ascii(bytes, 0, 4))
        assertEquals("WAVE", ascii(bytes, 8, 4))
        assertEquals("fmt ", ascii(bytes, 12, 4))
        assertEquals("fact", ascii(bytes, 36, 4))
        assertEquals("data", ascii(bytes, 48, 4))

        buf.position(52)
        assertEquals(0, buf.int) // data chunk size, henüz örnek yazılmadı
    }

    @Test
    fun `fmt chunk describes 48kHz mono float32 (format code 3)`() {
        val file = tempWav()
        val recorder = WavRecorder.create(file, sampleRateHz = 48_000, channelCount = 1)
        recorder.close()

        val buf = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        buf.position(16)
        assertEquals(16, buf.int) // fmt chunk data boyutu
        assertEquals(3, buf.short.toInt()) // format kodu: 3 = IEEE float
        assertEquals(1, buf.short.toInt()) // kanal sayısı: mono
        assertEquals(48_000, buf.int) // örnekleme hızı
        assertEquals(48_000 * 1 * 4, buf.int) // byte rate = sampleRate * channels * bytesPerSample
        assertEquals(4, buf.short.toInt()) // block align = channels * bytesPerSample
        assertEquals(32, buf.short.toInt()) // bits per sample
    }

    @Test
    fun `finish updates riff, fact and data length fields to the real written size`() {
        val file = tempWav()
        val recorder = WavRecorder.create(file, sampleRateHz = 48_000, channelCount = 1)

        val samples = floatArrayOf(0.1f, -0.2f, 0.3f, -1.0f, 1.0f)
        recorder.writeSamples(samples)
        val total = recorder.finish()

        assertEquals(5L, total)

        val bytes = file.readBytes()
        assertEquals(WavRecorder.HEADER_SIZE_BYTES + samples.size * 4, bytes.size)

        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buf.position(4)
        val expectedDataSize = samples.size * 4
        val expectedRiffSize = 4 + (8 + 16) + (8 + 4) + (8 + expectedDataSize)
        assertEquals(expectedRiffSize, buf.int)

        buf.position(44) // fact chunk verisi: dwSampleLength
        assertEquals(samples.size, buf.int)

        buf.position(52) // data chunk boyutu
        assertEquals(expectedDataSize, buf.int)

        // Örneklerin kendisi doğru sırada ve little-endian yazılmış mı?
        buf.position(WavRecorder.HEADER_SIZE_BYTES)
        for (expected in samples) {
            assertEquals(expected, buf.float, 1e-6f)
        }
    }

    @Test
    fun `finish is idempotent and returns the same total on repeated calls`() {
        val file = tempWav()
        val recorder = WavRecorder.create(file)
        recorder.writeSamples(floatArrayOf(1f, 2f, 3f))

        val first = recorder.finish()
        val second = recorder.finish()

        assertEquals(first, second)
        assertEquals(3L, first)
    }

    @Test
    fun `writeSamples honors the explicit count and ignores the rest of the array`() {
        val file = tempWav()
        val recorder = WavRecorder.create(file)
        val buffer = floatArrayOf(1f, 2f, 3f, 999f, 999f)

        recorder.writeSamples(buffer, count = 3)
        val total = recorder.finish()

        assertEquals(3L, total)
        assertEquals(WavRecorder.HEADER_SIZE_BYTES + 3 * 4, file.length().toInt())
    }

    @Test(expected = IllegalStateException::class)
    fun `writing after finish throws`() {
        val file = tempWav()
        val recorder = WavRecorder.create(file)
        recorder.finish()
        recorder.writeSamples(floatArrayOf(1f))
    }

    @Test
    fun `writing across multiple calls accumulates the sample count`() {
        val file = tempWav()
        val recorder = WavRecorder.create(file)
        recorder.writeSamples(floatArrayOf(1f, 2f))
        recorder.writeSamples(floatArrayOf(3f, 4f, 5f))
        val total = recorder.finish()

        assertEquals(5L, total)
        assertTrue(file.length() == (WavRecorder.HEADER_SIZE_BYTES + 5 * 4).toLong())
    }
}
