package com.aykerme.klarivision.live

/**
 * Ham örnek sayacından SAF kaynak zamanı türeticisi.
 *
 * Kaynak zamanı UI saatiyle (`System.currentTimeMillis`/`nanoTime`)
 * İKAME EDİLMEZ — yalnız bu akışa gerçekten yazılmış örnek sayısından
 * türetilir. `LiveAudioCapture`, `AudioRecord`'dan okuduğu (ve gerekirse
 * 48 kHz'e yeniden örneklediği) her bloğu bu sayaca [advance] ile ekler;
 * cihaz `AudioRecord.getTimestamp()` sağlıyorsa bu, o donanım zaman
 * damgasının temsil ettiği örnek konumuyla hizalanır (bkz.
 * `LiveAudioCapture.alignWithHardwareTimestamp`) — ikisi de aynı örnek
 * sayacı temeline dayanır, duvar saatine değil.
 *
 * Android API'sine bağımlı değildir — JVM testiyle koşar.
 */
class SampleClock(private val sampleRateHz: Double = 48_000.0) {
    var samplesWritten: Long = 0
        private set

    /** Şu ana kadar yazılan örnek sayısına karşılık gelen kaynak zamanı (saniye). */
    fun currentTimeSeconds(): Double = samplesWritten / sampleRateHz

    /**
     * [sampleCount] kadar yeni örneğin akışa eklendiğini bildirir ve bu
     * blok BAŞLAMADAN ÖNCEKİ kaynak zamanını döner (bloğun ilk örneğinin
     * zamanı).
     */
    fun advance(sampleCount: Int): Double {
        require(sampleCount >= 0) { "sampleCount negatif olamaz." }
        val time = currentTimeSeconds()
        samplesWritten += sampleCount
        return time
    }

    /**
     * Sayacı, donanımın bildirdiği MUTLAK örnek konumuna hizalar (ör.
     * `AudioRecord.getTimestamp()`'ten okunan `framePosition`). Yalnız
     * ileri sıçramaya izin verilir — donanım konumu bizim saydığımızdan
     * gerideyse (ör. gecikmeli/eski bir zaman damgası) sayaç GERİ ALINMAZ,
     * kaynak zamanı asla geri gitmez.
     */
    fun alignTo(hardwareFramePosition: Long) {
        if (hardwareFramePosition > samplesWritten) {
            samplesWritten = hardwareFramePosition
        }
    }

    fun reset() {
        samplesWritten = 0
    }
}
