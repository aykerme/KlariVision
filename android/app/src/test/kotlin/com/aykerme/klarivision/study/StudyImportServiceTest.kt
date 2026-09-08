// KlariVision Android — StudyImportService için unit testler.
// ContentResolver/Context gerektirmeyen saf kopyalama fonksiyonuna ve MediaKind
// türetme mantığına odaklanır (JVM testi, Robolectric/enstrümantasyon yok).

package com.aykerme.klarivision.study

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream

class StudyImportServiceTest {
    private lateinit var tempDir: File

    @Before
    fun setUp() {
        tempDir = File.createTempFile("import_test_", "").parentFile
            ?.let { File(it, "klarivision_import_test_${System.currentTimeMillis()}_${System.nanoTime()}") }
            ?: throw IllegalStateException("Geçici dizin oluşturulamadı")
        tempDir.mkdirs()
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    // MARK: - Başarılı kopya

    @Test
    fun testSuccessfulCopyCreatesDestinationWithIdenticalContent() = runBlocking {
        val content = ByteArray(1024 * 200) { (it % 251).toByte() } // 200 KB, tek buffer'dan büyük
        val destination = File(tempDir, "dest.m4a")

        StudyImportService.copyStreamAtomically(ByteArrayInputStream(content), destination)

        assertTrue("Hedef dosya oluşmalı", destination.exists())
        assertArrayEquals("İçerik birebir aynı olmalı", content, destination.readBytes())
    }

    @Test
    fun testSuccessfulCopyLeavesNoTempFile() = runBlocking {
        val destination = File(tempDir, "dest.wav")
        StudyImportService.copyStreamAtomically(ByteArrayInputStream(byteArrayOf(1, 2, 3)), destination)

        val leftovers = tempDir.listFiles { f -> f.name.contains(".tmp-") } ?: emptyArray()
        assertTrue("Geçici dosya kalmamalı", leftovers.isEmpty())
    }

    @Test
    fun testEmptySourceProducesEmptyDestination() = runBlocking {
        val destination = File(tempDir, "empty.mp3")
        StudyImportService.copyStreamAtomically(ByteArrayInputStream(ByteArray(0)), destination)

        assertTrue(destination.exists())
        assertEquals(0L, destination.length())
    }

    // MARK: - Ortada kesilen kopya

    private class FailingInputStream(private val failAfterBytes: Int) : InputStream() {
        private var delivered = 0
        override fun read(): Int = throw UnsupportedOperationException("kullanılmıyor")
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (delivered >= failAfterBytes) throw IOException("kaynak akışı koptu")
            val toDeliver = minOf(len, failAfterBytes - delivered, 16)
            for (i in 0 until toDeliver) b[off + i] = 0x42
            delivered += toDeliver
            return toDeliver
        }
    }

    @Test
    fun testInterruptedCopyLeavesNoDestinationFile() {
        val destination = File(tempDir, "dest.mp4")

        assertThrows(ImportError.UnableToCopy::class.java) {
            runBlocking { StudyImportService.copyStreamAtomically(FailingInputStream(32), destination) }
        }

        assertFalse("Hedef dosya oluşmamalı", destination.exists())
    }

    @Test
    fun testInterruptedCopyLeavesNoTempFile() {
        val destination = File(tempDir, "dest.mp4")

        try {
            runBlocking { StudyImportService.copyStreamAtomically(FailingInputStream(32), destination) }
        } catch (e: ImportError) {
            // beklenen
        }

        val leftovers = tempDir.listFiles() ?: emptyArray()
        assertTrue("Hiçbir dosya (geçici dahil) kalmamalı", leftovers.isEmpty())
    }

    @Test
    fun testCancelledCopyPropagatesCancellationNotImportError() {
        val destination = File(tempDir, "dest.mov")

        val cancelling = object : InputStream() {
            override fun read(): Int = throw UnsupportedOperationException("kullanılmıyor")
            override fun read(b: ByteArray, off: Int, len: Int): Int = throw CancellationException("iptal")
        }

        assertThrows(CancellationException::class.java) {
            runBlocking { StudyImportService.copyStreamAtomically(cancelling, destination) }
        }
        assertFalse(destination.exists())
        assertTrue((tempDir.listFiles() ?: emptyArray()).isEmpty())
    }

    // MARK: - Uzantı/tür türetme (MediaKind)

    @Test
    fun testKnownAudioExtensionsMapToAudio() {
        listOf("mp3", "wav", "m4a", "aac", "flac", "ogg").forEach { ext ->
            assertEquals("$ext ses olmalı", MediaKind.AUDIO, MediaKind.fromExtension(ext))
        }
    }

    @Test
    fun testKnownVideoExtensionsMapToVideo() {
        listOf("mp4", "mov", "m4v", "mpeg4").forEach { ext ->
            assertEquals("$ext video olmalı", MediaKind.VIDEO, MediaKind.fromExtension(ext))
        }
    }

    @Test
    fun testUnknownExtensionReturnsNull() {
        assertNull(MediaKind.fromExtension("xyz"))
        assertNull(MediaKind.fromExtension(""))
    }

    @Test
    fun testMimeTypeDerivesMediaKind() {
        assertEquals(MediaKind.AUDIO, MediaKind.fromMimeType("audio/mpeg"))
        assertEquals(MediaKind.VIDEO, MediaKind.fromMimeType("video/mp4"))
        assertNull(MediaKind.fromMimeType("application/octet-stream"))
        assertNull(MediaKind.fromMimeType(null))
    }

    @Test
    fun testDefaultExtensionPerKind() {
        assertEquals("m4a", MediaKind.AUDIO.defaultExtension)
        assertEquals("mp4", MediaKind.VIDEO.defaultExtension)
    }

    @Test
    fun testMimeTypesArrayCoversAudioAndVideo() {
        assertArrayEquals(arrayOf("audio/*", "video/*"), StudyImportService.openDocumentMimeTypes)
    }
}
