// KlariVision Android — çalışma modeli ve kalıcılığı, Swift iPadStudy'den port edildi.
// Offline pitch analizi sonuçlarını kimlik, başlık, çerçeveler ve müzik bağlamıyla tutar.

package com.aykerme.klarivision.study

import kotlinx.serialization.Serializable
import java.util.UUID
import java.time.Instant

/**
 * Depo meta-verisi ve frekans çerçeveleriyle birlikte kaydedilmiş bir çalışma.
 * Yapı Studies-v1.json'de UTC ISO8601 tarihleriyle saklanır.
 *
 * pipelineRevision: Sorun çerçevelerini üreten offline analiz boru hattını tanımlar.
 * nil değeri, kayıt eski causal canlı oturumundan geldiğini anlamına gelir; yeni
 * çalışmalar "offline-unified-path-r2" damgası taşır.
 */
@Serializable
data class Study(
    /** Benzersiz tanıtıcı (UUID string) */
    val id: String = UUID.randomUUID().toString(),
    /** App sahibi kopyasının yolu (string olarak saklanır) */
    val sourceURL: String,
    /** Kullanıcı tarafından sağlanan çalışma başlığı */
    var title: String,
    /** Ses akışının toplam süresi (saniye) */
    val duration: Double,
    /** Offline analiz sonuçlarından sorun çerçeveleri */
    val frames: List<PitchFrame>,
    /** Analiz için kullanılan pitch motoru tanıtıcı ("unified_v1") */
    val engine: String = "unified_v1",
    /** Grafik sunum ve makam seçimi */
    var context: StudyContext,
    /** Analiz anı (ISO8601 UTC) */
    val analyzedAt: String = Instant.now().toString(),
    /** Sorunları üreten offline boru hattı türü */
    var pipelineRevision: String? = "offline-unified-path-r2"
) {
    /**
     * Kaynak dosyasının video parçası olup olmadığını belirle.
     * mp4, mov, m4v → video; aksi halde → audio only.
     */
    val isVideoSource: Boolean
        get() {
            val ext = sourceURL.substringAfterLast(".", "").lowercase()
            return ext in setOf("mp4", "mov", "m4v", "mpeg4")
        }
}
