# Mimari (v0.1)

## İlk akış

    Ses dosyası → ses hazırlama → pitch çıkarıcı → PitchTrack → görselleştirme / JSON

## Bileşenler

| Bileşen | Sorumluluk |
| --- | --- |
| AudioSource | Dosya yolu ve analiz ayarlarını taşır. |
| PitchExtractor | Seçilen algoritmayı ortak arayüzle çalıştırır. |
| PitchTrack | Zaman, frekans, seslilik ve güven örneklerini saklar. |
| Görselleştirme | Sonraki aşamada PitchTrack verisini çizer. |

## Teknoloji kararları

- İlk analiz katmanı: Python 3.11+.
- Sayısal veri modeli: numpy.
- İlk üretim extractor: pYIN (librosa 0.11). Basit YIN, karşılaştırılabilir ve açıklanabilir temel olarak korunur; CREPE sonraki karşılaştırma seçeneğidir.
- Arayüz: İlk olarak yerel web arayüzü; frontend seçimi pitch çıktısı doğrulandıktan sonra yapılacak.

## Veri sözleşmesi

Her örnek şu alanları taşır: `time_seconds`, `frequency_hz`, `voiced`, `confidence`. `frequency_hz`, sessiz veya belirsiz karelerde boş olabilir.

## Perde ekseni görünümü

Sol eksen Arel–Ezgi–Uzdilek 53 koma sistemiyle hesaplanır ve Dügâh (La) referans alınır. Çârgâh (Do), Nîm Hicaz, Hicaz, Dik Hicaz, Neva (Re), Nîm/Dik Hisar, Hüseynî (Mi), Acem (Fa), Eviç, Mâhur, Gerdâniye (Sol), Nîm/Dik Şehnaz, Muhayyer (La), Sünbüle, Tiz Segâh, Tiz Bûselik ve Tiz Çârgâh (Do) aynı eksende gösterilir.

Yegâh bu referansta Re'dir ve Dügâh'a göre −701,9 senttedir. Etiketler eşit aralığa zorlanmaz; her perdenin gerçek koma konumu korunur.

## Sonraki genişleme noktaları

1. Hz → sent → Türk müziği perde eşleme
2. Nota segmentasyonu
3. Kural tabanlı süsleme adayları
4. İnsan doğrulaması ve etiket veri kümesi
