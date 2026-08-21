# Yol Haritası

> Bu belge tarihsel planı korur. Güncel ürün durumu için
> `PROJECT_STATE.md`, güncel mimari için `architecture.html` esas alınır.
> Android ve otomatik makam tespiti bu yol haritasında olsa da güncel ürün
> kapsamına alınmamıştır.

## Faz 0 — Temel kararlar

- [x] Yerel proje yapısı
- [x] Ürün ve mimari başlangıç belgeleri
- [x] Pitch Engine veri modeli ve extractor arayüzü
- [ ] Referans kayıt ve test senaryosu seçimi

## Faz 1 — Pitch prototipi

### Kilometre taşı — Çok platformlu çekirdek

- [x] Platformdan bağımsız C++ pitch veri modeli
- [x] Python görüntü temizleme davranışına eş C++ ilk işlem katmanı
- [x] Yerel C++ doğrulama testi
- [ ] Referans kayıtlarından golden karşılaştırma veri kümesi
- [ ] Yerel, pYIN-uyumlu C++ pitch çıkarıcı
- [x] Swift (macOS/iPhone/iPad) bağ katmanları
- [ ] Android bağ katmanı (ürün kapsamı dışında)

### Kilometre taşı — Canlı Çalışma (ilk macOS sürümü)

- [x] Mikrofon izni ve yerel, kaydedilmeyen canlı ses girişi
- [x] Düşük gecikmeli canlı YIN pitch prototipi
- [x] Kayan pitch grafiği ile makam / karar frekans çizgileri
- [x] Ortak C++ çekirdeğinin canlı YIN katmanına bağlanması
- [x] iPad/iPhone mikrofon bağ katmanı
- [ ] Android mikrofon bağ katmanı (ürün kapsamı dışında)

### Kilometre taşı — Pitch Engine v2 (deneysel)

- [x] Kararlı motordan ayrılmış Git dalı ve geri dönüş etiketi
- [x] Kaynak/provenans taşıyan platformdan bağımsız aday sözleşmesi
- [x] Ayrı durum belleğine sahip çalıştırılabilir Swift deney motoru
- [x] Aynı kaynak dosyayla v1/v2 doğrulama girişleri
- [x] MPM/NSDF aday üreticisi
- [x] SWIPE' benzeri asal-harmonik puanlama
- [x] Yaklaşık 5 kare / 50–55 ms sabit gecikmeli yol seçimi (özgün zaman damgasını korur)
- [ ] V2'nin tüm regresyonlarda V1'i geçmesi

### Kilometre taşı — v0.5.0 Stable

- [x] Yerel video/ses ve YouTube bağlantısından medya alma
- [x] Geçici bağlantı hataları için otomatik yeniden deneme
- [x] İçerik imzasına dayalı pitch cache
- [x] Açılış ekranında son kullanılan analizlere doğrudan erişim
- [x] Ayrı paketlenmiş yerel macOS uygulaması (`dist/KlariVision.app`)

Bu sürüm, günlük çalışma için ürün tabanıdır. Sonraki ana faz, mevcut pitch
motorunu koruyarak SwiftUI tabanlı macOS arayüzünü oluşturmaktır.

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
- [x] Klarnet kaydı üzerinde manuel kalite kontrolü
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
