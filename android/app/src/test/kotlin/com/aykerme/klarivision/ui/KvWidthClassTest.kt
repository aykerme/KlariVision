// KlariVision Android — genişlik sınıfı eşiklerinin saf testi.
//
// `KvWidthClass` bir Compose tipine bağımlı değildir (yalnız `Dp`), bu yüzden
// JVM testiyle koşar. Test edilen asıl şey [KvWidthClass.fromSize]'ın
// yükseklik koşulu: yalnız genişliğe bakan eski karar, yatay çevrilmiş bir
// telefonda ORTA/GENIS yerleşimini seçiyordu ve o yerleşimler dikey yığıldığı
// için kontrol paneli tüm ekranı kaplayıp grafiği bir şeride sıkıştırıyordu
// (fiziksel kabul turu bulgusu B-10).

package com.aykerme.klarivision.ui

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test

class KvWidthClassTest {

    @Test
    fun `genislik esikleri degismedi`() {
        assertEquals(KvWidthClass.DAR, KvWidthClass.fromWidth(699.dp))
        assertEquals(KvWidthClass.ORTA, KvWidthClass.fromWidth(700.dp))
        assertEquals(KvWidthClass.ORTA, KvWidthClass.fromWidth(999.dp))
        assertEquals(KvWidthClass.GENIS, KvWidthClass.fromWidth(1000.dp))
    }

    /** SM-A736B yatay: 2400×1080 piksel, 2,8125 yoğunlukta 853×384 dp. */
    @Test
    fun `yatay telefon DAR olur cunku yukseklik yetmez`() {
        assertEquals(KvWidthClass.ORTA, KvWidthClass.fromWidth(853.dp))
        assertEquals(KvWidthClass.DAR, KvWidthClass.fromSize(853.dp, 384.dp))
    }

    /** Dikey telefon zaten DAR; yükseklik koşulu bunu değiştirmez. */
    @Test
    fun `dikey telefon DAR kalir`() {
        assertEquals(KvWidthClass.DAR, KvWidthClass.fromSize(384.dp, 853.dp))
    }

    /** Tablet yatay: yükseklik yeterli, davranış DEĞİŞMEZ. */
    @Test
    fun `tablet yatayda genislik karari korunur`() {
        assertEquals(KvWidthClass.ORTA, KvWidthClass.fromSize(834.dp, 1194.dp))
        assertEquals(KvWidthClass.GENIS, KvWidthClass.fromSize(1194.dp, 834.dp))
    }

    /** Eşik tam sınırda: 580 dp geçer, 579 dp geçmez. */
    @Test
    fun `yukseklik esigi 580 dp`() {
        assertEquals(KvWidthClass.DAR, KvWidthClass.fromSize(1200.dp, 579.dp))
        assertEquals(KvWidthClass.GENIS, KvWidthClass.fromSize(1200.dp, 580.dp))
    }
}
