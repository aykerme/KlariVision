// KlariVision Android — Imports/ medya aralık yanıtı testleri.
// WebView, shouldInterceptRequest'ten dönen akışa Range başlığını kendisi
// uygular (baştan `start` bayt atlar). Bu testler akışın o atlamayla birlikte
// tam olarak istenen baytları verdiğini doğrular.

package com.aykerme.klarivision.web

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

class ViewerAssetsRangeTest {
    private val file = ByteArray(10_000) { (it * 31 % 251).toByte() }

    @Test
    fun parsesOpenEndedRange() {
        assertEquals(ViewerAssets.ByteRange(131_072, 5_496_856), ViewerAssets.parseByteRange("bytes=131072-", 5_496_857))
    }

    @Test
    fun clampsEndToFileLength() {
        assertEquals(ViewerAssets.ByteRange(100, 9_999), ViewerAssets.parseByteRange("bytes=100-50000", 10_000))
    }

    @Test
    fun rejectsUnsatisfiableRange() {
        assertNull(ViewerAssets.parseByteRange("bytes=10000-", 10_000))
        assertNull(ViewerAssets.parseByteRange("bytes=500-100", 10_000))
    }

    @Test
    fun streamYieldsRequestedBytesAfterWebViewSkip() {
        for (header in listOf("bytes=0-", "bytes=131-", "bytes=4000-4999", "bytes=9990-")) {
            val range = ViewerAssets.parseByteRange(header, file.size.toLong())!!
            val stream = ViewerAssets.rangedStream(ByteArrayInputStream(file), range)

            val served = readLikeWebView(stream, range.start)

            assertArrayEquals(header, file.copyOfRange(range.start.toInt(), range.end.toInt() + 1), served)
            assertEquals(header, range.count, served.size.toLong())
        }
    }

    /** WebView'in yaptığı gibi: `start` bayt atla, sonra akışın sonuna kadar oku. */
    private fun readLikeWebView(stream: InputStream, start: Long): ByteArray {
        var skipped = 0L
        while (skipped < start) {
            val step = stream.skip(start - skipped)
            if (step <= 0) break
            skipped += step
        }
        return stream.readBytes()
    }
}
