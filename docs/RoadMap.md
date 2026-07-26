# Yol Haritası

## Faz 0 — Temel kararlar

- [x] Yerel proje yapısı
- [x] Ürün ve mimari başlangıç belgeleri
- [x] Pitch Engine veri modeli ve extractor arayüzü
- [ ] Referans kayıt ve test senaryosu seçimi

## Faz 1 — Pitch prototipi

### Kilometre taşı — v0.4.0 Pitch Viewer Foundation

- [x] Yerel video/ses seçimi ve analiz ilerleme ekranı
- [x] Vamp pYIN ile yüksek çözünürlüklü pitch eğrisi
- [x] Video/ses ile güvenilir zaman eşleme
- [x] A/B işaretleri ve döngüde dinleme
- [x] Zaman/dikey yakınlaştırma, kaydırma ve eğri takibi
- [x] Majör, Minör, Nihavend ve Türk Müziği (Sol Klarnet) eksenleri
- [x] Video/ses için byte-aralığı desteği; doğru süre ve seek davranışı

Bu sürüm, sonraki çalışmaların korunacak temelidir. Pitch eğrisi, medya süresi,
A/B loop ve mevcut eksen davranışları geriye dönük kontrol edilmeden değiştirilmeyecektir.

- [ ] Ses yükleme / standardizasyon
- [x] pYIN tabanlı ilk extractor
- [x] YIN ve pYIN karşılaştırması
- [x] JSON çıktısı
- [x] Pitch grafiği ve sesle zaman eşleme
- [x] Zaman aralığı seçimi, döngüde dinleme ve seçime yakınlaşma
- [ ] Klarnet kaydı üzerinde manuel kalite kontrolü
- [x] Süslemesiz ve süslemeli eş kayıtlar için A/B karşılaştırma ekranı

## Faz 2 — Müzikal katman

- [ ] Hz/sent ekseni
- [x] Kullanıcı seçimli makam / karar perdesi menüsü
- [ ] Makam-perde eşleme tasarımı
- [ ] Nota segmentasyonu

## Faz 3 — Süslemeler

> Durum: Bu faz ana ürün akışından çıkarıldı. Süsleme araçları yalnızca isteğe bağlı deneysel modda tutulacak; ürün geliştirme önceliği pitch görselleştirmesidir.

- [ ] Etiketleme taksonomisi
- [x] Vibrato aday kuralları ve insan etiketleme akışı
- [x] İlk çarpma aday kuralı ve insan etiketiyle değerlendirme
- [ ] Glissando aday kuralları

## Faz 4 — Öğrenme deneyimi

- [ ] Referans ve öğrenci kaydını karşılaştırma
- [ ] Süsleme sözlüğü
- [ ] Üslup/istatistik katmanı
