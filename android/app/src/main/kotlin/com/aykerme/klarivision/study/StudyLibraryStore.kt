// KlariVision Android — çalışma kütüphanesi kalıcılığı, Swift iPadStudyLibraryStore'dan port edildi.
// Studies-v1.json'den atomik okuma/yazma ve hata toleransı.

package com.aykerme.klarivision.study

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import java.util.UUID

/**
 * Çalışma kütüphanesi depoya Studies-v1.json üzerinden erişim sağlar.
 * Dosya sistemine erişim için dosya kökünü parametre olarak alır (Context bağımlılığı yok).
 */
class StudyLibraryStore(private val root: File) {
    private val fileURL: File = File(root, "Studies-v1.json")
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Kütüphanedeki tüm çalışmaları yükle.
     * - Dosya yoksa: boş liste döndür, istisna yok.
     * - Bilinmeyen karar değeri: "Re" olarak düşür (tolerans).
     * - JSON decode hatası: tamamen başarısız olma (tüm kütüphane korunmalı).
     */
    fun load(): List<Study> {
        if (!fileURL.exists()) return emptyList()

        return try {
            val rawJson = fileURL.readText()
            val jsonArray = json.parseToJsonElement(rawJson).jsonArray

            jsonArray.mapNotNull { element ->
                try {
                    // Her Study'i Manuel olarak deserialize et, böylece karar hatasından kurtulabilir
                    val obj = element.jsonObject
                    val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val sourceURL = obj["sourceURL"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val title = obj["title"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val duration = obj["duration"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: return@mapNotNull null
                    val engine = obj["engine"]?.jsonPrimitive?.content ?: "unified_v1"
                    val analyzedAt = obj["analyzedAt"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val pipelineRevision = obj["pipelineRevision"]?.jsonPrimitive?.content

                    // Frames dizisini deserialize et
                    val frames = obj["frames"]?.jsonArray?.mapNotNull { frameElem ->
                        try {
                            val frameObj = frameElem.jsonObject
                            val time = frameObj["time"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: return@mapNotNull null
                            val frequency = frameObj["frequency"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: return@mapNotNull null
                            val confidence = frameObj["confidence"]?.jsonPrimitive?.content?.toDoubleOrNull() ?: return@mapNotNull null
                            val voiced = frameObj["voiced"]?.jsonPrimitive?.content?.toBoolean() ?: return@mapNotNull null
                            PitchFrame(time, frequency, confidence, voiced)
                        } catch (e: Exception) {
                            null
                        }
                    } ?: emptyList()

                    // StudyContext'i deserialize et, karar hatalarını tolere et
                    val context = try {
                        val contextObj = obj["context"]?.jsonObject ?: return@mapNotNull null
                        val makam = contextObj["makam"]?.jsonPrimitive?.content ?: "Nihavend"
                        val kararRaw = contextObj["karar"]?.jsonPrimitive?.content ?: "Re"
                        // Bilinmeyen karar değerini "Re"'ye düşür
                        val karar = if (kararRaw in listOf("Do", "Re", "Mi", "Fa", "Sol", "La", "Si")) {
                            kararRaw
                        } else {
                            "Re"
                        }
                        val followsCurve = contextObj["followsCurve"]?.jsonPrimitive?.content?.toBoolean() ?: true
                        val scaleDisplay = contextObj["scaleDisplay"]?.jsonPrimitive?.content ?: "Makam"
                        StudyContext(makam, karar, followsCurve, scaleDisplay)
                    } catch (e: Exception) {
                        StudyContext() // Default context
                    }

                    Study(
                        id = id,
                        sourceURL = sourceURL,
                        title = title,
                        duration = duration,
                        frames = frames,
                        engine = engine,
                        context = context,
                        analyzedAt = analyzedAt,
                        pipelineRevision = pipelineRevision ?: "offline-unified-path-r2"
                    )
                } catch (e: Exception) {
                    // Tek bir çalışma deserialize edilemezse onu atla
                    null
                }
            }
        } catch (e: Exception) {
            // JSON parse hatası → exception fırla (tüm kütüphane bozuk)
            throw StudyLibraryException("Çalışma kütüphanesi okunamadı: ${e.message}", e)
        }
    }

    /**
     * Atomik yazma: temp dosyaya yaz, sonra rename et.
     * Yarım yazılmış kütüphane bırakma.
     */
    fun save(studies: List<Study>) {
        // Parent dizini oluştur
        fileURL.parentFile?.mkdirs()

        // Temp dosyaya yaz
        val tempFile = File(fileURL.parentFile, "${fileURL.name}.tmp")
        try {
            val jsonString = json.encodeToString(ListSerializer(Study.serializer()), studies)
            tempFile.writeText(jsonString)
            // Atomik rename: temp → gerçek dosya
            if (!tempFile.renameTo(fileURL)) {
                throw StudyLibraryException("Dosya yazması başarısız: rename başarısız", null)
            }
        } catch (e: Exception) {
            // Temp dosyayı temizle (hata durumunda)
            tempFile.delete()
            throw StudyLibraryException("Çalışma kütüphanesi yazılamadı: ${e.message}", e)
        }
    }

    /**
     * UUID'ye göre çalışmayı sil ve listeyi kaydet.
     * Medya dosyasını silmez, yalnız liste kaydını.
     */
    suspend fun remove(id: UUID, from: List<Study>): List<Study> {
        val result = from.filter { it.id != id.toString() }
        save(result)
        return result
    }

    /**
     * UUID'ye göre çalışmayı sil ve listeyi kaydet (senkron sürüm).
     */
    fun removeSync(id: UUID, from: List<Study>): List<Study> {
        val result = from.filter { it.id != id.toString() }
        save(result)
        return result
    }
}

/**
 * StudyLibraryStore işlemleri sırasında meydana gelen istisnalar.
 */
class StudyLibraryException(message: String, cause: Throwable?) : Exception(message, cause)
