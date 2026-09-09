package com.aykerme.klarivision.live

/**
 * 16-bit PCM örneklerini Float32'ye çeviren saf yardımcı.
 *
 * `AudioRecord`, `ENCODING_PCM_FLOAT`'ı desteklemeyen cihazlarda bu geri
 * düşüş yolu kullanılır (bkz. `LiveAudioCapture`). Bu dosya Android API'sine
 * bağımlı DEĞİLDİR — JVM testiyle koşar.
 *
 * Ölçek asimetriktir (standart PCM16→Float32 dönüşümü): `Short.MIN_VALUE`
 * (-32768) tam olarak -1.0'a gider; `Short.MAX_VALUE` (32767) ise
 * 32767/32768 ≈ 0.999969'a gider (asla +1.0'ı geçmez).
 */
object PcmConversion {
    private const val SCALE = 1f / 32768f

    /**
     * `input`'un ilk [sampleCount] örneğini Float32'ye çevirir.
     *
     * Tahsis yapmadan çağrılabilmesi için [output] önceden ayrılmış bir
     * tampon olarak verilebilir — çağıran taraf (canlı yakalama döngüsü)
     * bunu döngü dışında bir kez ayırıp tekrar tekrar kullanmalıdır.
     */
    fun int16ToFloat32(
        input: ShortArray,
        sampleCount: Int = input.size,
        output: FloatArray = FloatArray(sampleCount),
    ): FloatArray {
        require(sampleCount in 0..input.size) { "sampleCount, input sınırları içinde olmalı." }
        require(output.size >= sampleCount) { "output, sampleCount kadar örneği taşıyabilmeli." }
        for (i in 0 until sampleCount) {
            output[i] = input[i] * SCALE
        }
        return output
    }
}
