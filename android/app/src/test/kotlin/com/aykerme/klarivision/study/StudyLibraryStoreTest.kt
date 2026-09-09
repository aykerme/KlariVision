// KlariVision Android — çalışma kütüphanesi kalıcılık testleri.

package com.aykerme.klarivision.study

import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.util.UUID
import kotlin.math.absoluteValue

/**
 * StudyLibraryStore için unit testler. Geçici dizin kullan.
 */
class StudyLibraryStoreTest {
    private lateinit var tempDir: File
    private lateinit var store: StudyLibraryStore

    @Before
    fun setUp() {
        // JUnit temp dizini kullan
        tempDir = File.createTempFile("test_study_", "").parentFile
            ?.let { File(it, "klarivision_test_${System.currentTimeMillis()}") }
            ?: throw IllegalStateException("Geçici dizin oluşturulamadı")
        tempDir.mkdirs()
        store = StudyLibraryStore(tempDir)
    }

    @After
    fun tearDown() {
        // Geçici dizini temizle
        tempDir.deleteRecursively()
    }

    @Test
    fun testRoundTripPreservesAllFields() {
        // Arrange: Tüm alanlarla bir çalışma oluştur
        val studyId = UUID.randomUUID().toString()
        val frames = listOf(
            PitchFrame(time = 0.0, frequency = 440.0, confidence = 0.95, voiced = true),
            PitchFrame(time = 0.023, frequency = 445.0, confidence = 0.92, voiced = true),
            PitchFrame(time = 0.046, frequency = 442.0, confidence = 0.88, voiced = false)
        )
        val context = StudyContext(
            makam = "Nihavend",
            karar = "Re",
            followsCurve = true,
            scaleDisplay = "Makam"
        )
        val originalStudy = Study(
            id = studyId,
            sourceURL = "/data/study_abc.mp3",
            title = "Test Çalışması",
            duration = 5.5,
            frames = frames,
            engine = "unified_v1",
            context = context,
            analyzedAt = "2024-01-15T10:30:00Z",
            pipelineRevision = "offline-unified-path-r2"
        )

        // Act: Kaydet ve oku
        store.save(listOf(originalStudy))
        val loaded = store.load()

        // Assert: Tüm alanlar korunuyor
        assertEquals("Bir çalışma yüklenmeli", 1, loaded.size)
        val loadedStudy = loaded[0]
        assertEquals("ID korunmalı", studyId, loadedStudy.id)
        assertEquals("Başlık korunmalı", "Test Çalışması", loadedStudy.title)
        assertEquals("sourceURL korunmalı", "/data/study_abc.mp3", loadedStudy.sourceURL)
        assertEquals("Süre korunmalı", 5.5, loadedStudy.duration, 0.001)
        assertEquals("Engine korunmalı", "unified_v1", loadedStudy.engine)
        assertEquals("Tarih korunmalı", "2024-01-15T10:30:00Z", loadedStudy.analyzedAt)
        assertEquals("Pipeline revision korunmalı", "offline-unified-path-r2", loadedStudy.pipelineRevision)

        // Çerçeveler
        assertEquals("Çerçeve sayısı korunmalı", 3, loadedStudy.frames.size)
        assertEquals("İlk çerçeve zamanı", 0.0, loadedStudy.frames[0].time, 0.001)
        assertEquals("İlk çerçeve frekansı", 440.0, loadedStudy.frames[0].frequency, 0.001)
        assertEquals("İlk çerçeve güveni", 0.95, loadedStudy.frames[0].confidence, 0.001)
        assertTrue("İlk çerçeve sesli", loadedStudy.frames[0].voiced)

        // Bağlam
        assertEquals("Makam korunmalı", "Nihavend", loadedStudy.context.makam)
        assertEquals("Karar korunmalı", "Re", loadedStudy.context.karar)
        assertTrue("followsCurve korunmalı", loadedStudy.context.followsCurve)
        assertEquals("ScaleDisplay korunmalı", "Makam", loadedStudy.context.scaleDisplay)
    }

    @Test
    fun testBadKararValueDefaultsToRe() {
        // Arrange: Bilinmeyen karar değeri ("Rast" — eski isim) ile JSON oluştur
        val badJsonFile = File(tempDir, "Studies-v1.json")
        val badJson = """
            [
              {
                "id": "550e8400-e29b-41d4-a716-446655440000",
                "sourceURL": "/data/test.mp3",
                "title": "Old Study",
                "duration": 3.5,
                "frames": [
                  {"time": 0.0, "frequency": 440.0, "confidence": 0.9, "voiced": true}
                ],
                "engine": "unified_v1",
                "context": {
                  "makam": "Nihavend",
                  "karar": "Rast",
                  "followsCurve": true,
                  "scaleDisplay": "Makam"
                },
                "analyzedAt": "2024-01-01T00:00:00Z",
                "pipelineRevision": "offline-unified-path-r1"
              }
            ]
        """.trimIndent()
        badJsonFile.writeText(badJson)

        // Act: Yükle
        val loaded = store.load()

        // Assert: Karar "Re"ye düşmüş, diğer çalışmalar sağlam
        assertEquals("Bir çalışma yüklenmeli", 1, loaded.size)
        assertEquals("Karar 'Re'ye düşmeli", "Re", loaded[0].context.karar)
        assertEquals("Makam korunmalı", "Nihavend", loaded[0].context.makam)
    }

    @Test
    fun testAtomicWriteNoTempFilesLeft() {
        // Arrange
        val study = Study(
            id = UUID.randomUUID().toString(),
            sourceURL = "/data/test.mp3",
            title = "Test",
            duration = 1.0,
            frames = emptyList(),
            context = StudyContext(),
            analyzedAt = "2024-01-01T00:00:00Z"
        )

        // Act: Kaydet
        store.save(listOf(study))

        // Assert: Temp dosya olmamalı
        val tempFile = File(tempDir, "Studies-v1.json.tmp")
        assertFalse("Temp dosya bırakılmamalı", tempFile.exists())

        // Assert: Asıl dosya var
        val mainFile = File(tempDir, "Studies-v1.json")
        assertTrue("Main dosya var olmalı", mainFile.exists())
    }

    @Test
    fun testEmptyFileReturnsEmptyList() {
        // Arrange: Hiçbir şey yapma (dosya yok)

        // Act: Yükle
        val loaded = store.load()

        // Assert: Boş liste, istisna yok
        assertEquals("Boş liste döndürülmeli", 0, loaded.size)
    }

    @Test
    fun testNonExistentFileReturnsEmptyList() {
        // Arrange: Dosya silinmiş
        val studiesFile = File(tempDir, "Studies-v1.json")
        if (studiesFile.exists()) {
            studiesFile.delete()
        }

        // Act: Yükle
        val loaded = store.load()

        // Assert: Boş liste, istisna yok
        assertEquals("Boş liste döndürülmeli", 0, loaded.size)
    }

    @Test
    fun testRemoveStudyAndSave() {
        // Arrange: İki çalışma oluştur
        val study1Id = UUID.randomUUID().toString()
        val study2Id = UUID.randomUUID().toString()
        val studies = listOf(
            Study(
                id = study1Id,
                sourceURL = "/data/test1.mp3",
                title = "Test 1",
                duration = 1.0,
                frames = emptyList(),
                context = StudyContext(),
                analyzedAt = "2024-01-01T00:00:00Z"
            ),
            Study(
                id = study2Id,
                sourceURL = "/data/test2.mp3",
                title = "Test 2",
                duration = 2.0,
                frames = emptyList(),
                context = StudyContext(),
                analyzedAt = "2024-01-02T00:00:00Z"
            )
        )
        store.save(studies)

        // Act: Birincisini sil
        val result = store.removeSync(UUID.fromString(study1Id), studies)

        // Assert: Sadece ikincisi kaldı
        assertEquals("Bir çalışma kalmalı", 1, result.size)
        assertEquals("İkinci çalışma kalmalı", study2Id, result[0].id)

        // Assert: Dosya güncellenmiş
        val reloaded = store.load()
        assertEquals("Bir çalışma yüklenmeli", 1, reloaded.size)
        assertEquals("İkinci çalışma kalmalı", study2Id, reloaded[0].id)
    }

    @Test
    fun testMultipleStudiesPreserveOrder() {
        // Arrange
        val studies = (1..5).map { i ->
            Study(
                id = UUID.randomUUID().toString(),
                sourceURL = "/data/test_$i.mp3",
                title = "Test $i",
                duration = i.toDouble(),
                frames = emptyList(),
                context = StudyContext(),
                analyzedAt = "2024-01-0${i}T00:00:00Z"
            )
        }

        // Act
        store.save(studies)
        val loaded = store.load()

        // Assert
        assertEquals("Tüm çalışmalar yüklenmeli", 5, loaded.size)
        for (i in 0 until 5) {
            assertEquals("Sıra korunmalı (çalışma $i)", "Test ${i + 1}", loaded[i].title)
        }
    }

    @Test
    fun testVideoSourceDetection() {
        // Arrange
        val videoStudy = Study(
            id = UUID.randomUUID().toString(),
            sourceURL = "/data/test.mp4",
            title = "Video",
            duration = 1.0,
            frames = emptyList(),
            context = StudyContext(),
            analyzedAt = "2024-01-01T00:00:00Z"
        )
        val audioStudy = Study(
            id = UUID.randomUUID().toString(),
            sourceURL = "/data/test.mp3",
            title = "Audio",
            duration = 1.0,
            frames = emptyList(),
            context = StudyContext(),
            analyzedAt = "2024-01-01T00:00:00Z"
        )

        // Act & Assert
        assertTrue("MP4 video olmalı", videoStudy.isVideoSource)
        assertFalse("MP3 video olmamalı", audioStudy.isVideoSource)
    }

    @Test
    fun testDefaultPipelineRevision() {
        // Arrange
        val study = Study(
            id = UUID.randomUUID().toString(),
            sourceURL = "/data/test.mp3",
            title = "Test",
            duration = 1.0,
            frames = emptyList(),
            context = StudyContext()
            // pipelineRevision belirtilmedi
        )

        // Act
        store.save(listOf(study))
        val loaded = store.load()

        // Assert
        assertEquals("Varsayılan pipeline revision", "offline-unified-path-r2", loaded[0].pipelineRevision)
    }

    @Test
    fun testContextFieldDefaults() {
        // Arrange
        val context = StudyContext() // Tüm varsayılanlar

        // Act & Assert
        assertEquals("Varsayılan makam", "Nihavend", context.makam)
        assertEquals("Varsayılan karar", "Re", context.karar)
        assertTrue("Varsayılan followsCurve", context.followsCurve)
        assertEquals("Varsayılan scaleDisplay", "Makam", context.scaleDisplay)
    }

    @Test
    fun testPitchFrameEquality() {
        // Arrange
        val frame1 = PitchFrame(0.0, 440.0, 0.9, true)
        val frame2 = PitchFrame(0.0, 440.0, 0.9, true)
        val frame3 = PitchFrame(0.0, 440.0, 0.8, true)

        // Act & Assert
        assertEquals("Aynı çerçeveler eşit olmalı", frame1, frame2)
        assertNotEquals("Farklı çerçeveler eşit olmamalı", frame1, frame3)
    }

    @Test
    fun testLargeFrameArrayHandling() {
        // Arrange: Binlerce çerçeve
        val largeFrameArray = (0 until 5000).map { i ->
            PitchFrame(
                time = i * 0.023,
                frequency = 440.0 + (i * 0.1),
                confidence = 0.9,
                voiced = i % 100 != 0
            )
        }
        val study = Study(
            id = UUID.randomUUID().toString(),
            sourceURL = "/data/large.mp3",
            title = "Large Study",
            duration = 5000 * 0.023,
            frames = largeFrameArray,
            context = StudyContext(),
            analyzedAt = "2024-01-01T00:00:00Z"
        )

        // Act
        store.save(listOf(study))
        val loaded = store.load()

        // Assert
        assertEquals("5000 çerçeve yüklenmeli", 5000, loaded[0].frames.size)
        assertEquals("Sonuncu çerçeve korunmalı", 4999 * 0.023, loaded[0].frames.last().time, 0.001)
    }
}
