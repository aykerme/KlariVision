# Toplantı Notları

## 001 — 20 Temmuz 2026

### Kararlar

- Proje adı: **KlariVision**.
- İlk geliştirme yerelde yapılacak.
- İlk ürün hedefi: ses → pitch → görselleştirme.
- İlk sürümde otomatik süsleme ve makam tespiti kapsam dışı.
- Veri ve analiz ayrılacak; otomatik bulgular kullanıcı düzeltmesine açık olacak.

### Bu oturumda tamamlananlar

- Boş proje klasörü incelendi.
- Belgeler ve Pitch Engine başlangıç iskeleti oluşturuldu.
- Proje içine izole Python 3.12.13 ortamı kuruldu.
- Hüsnü Şenlendirici Hüzzam Taksim kaydı içe aktarıldı ve 22.050 Hz mono WAV'a dönüştürüldü.
- İlk YIN tabanlı pitch çıkarıcı, JSON çıktısı ve temel otomatik test eklendi.
- İlk gerçek analiz 3.073 kare üretti; karelerin %82,3'ünde sesli pitch bulundu.
- Grafik ekseni kararı: Türk müziği perde adı, ardından parantez içinde nota karşılığı gösterilecek.
- pYIN (librosa 0.11) çalışır hâle getirildi ve ilk kayıt üzerinde %90,4 sesli kare buldu.
- pYIN/YIN ortak sesli karelerinde medyan fark 2,7 sent; pYIN ek 249 sesli kare tespit etti.

### Açık kararlar

- İlk test kaydı ve hedef kayıt kalitesi
- YIN çıktısının görsel/müzikal kalite doğrulaması; gerekirse pYIN veya CREPE ile karşılaştırma
- Makam/perde gösterimi için referans sistem
# Karar — Etiketli kayıtların bağımsızlığı

- `suslemesiz-kontrol` ve `suslemeli-karsilik`, aynı parçanın iki yarısı olsa da
  iki ayrı klarnet icrası olarak veri setine eklendi.
- A/B ilişkisi yalnızca karşılaştırma amacıyla `comparison_group` alanında tutulur.
- Her kaydın insan etiketleri kendi zaman ekseninde ve kendi JSON dosyasında kalır.

# İlk çarpma adayı denemesi

- Kural, kısa sürede başlangıç perdesine dönen belirgin pitch sapmalarını çarpma adayı sayar.
- `klarnetistanbul-kaybolan-yillar` kaydında 3 aday oluşturdu; bunların 2'si mevcut insan etiketleriyle anlamlı biçimde örtüştü.
- Bu sonuç otomatik sınıflandırma olarak değil, insanın hızlı incelemesi için aday listesi olarak kullanılacak.

# Süsleme eğitim kaynakları

- Paylaşılan Drive klasörü kaynak kataloğuna eklendi.
- Klasör; temel teknik anlatımları, egzersizleri, motif çalışmaları ve üç eserde uygulama/final çiftlerini içeriyor.
- İlk detaylı inceleme sırası: çarpma, vibrato, glissando.

# İlk eğitim videosu analizi

- `8. Vibrato.mp4` yerel kaynaktan proje verisine alındı ve pYIN ile analiz edildi.
- Çıktı: `outputs/egitim-vibrato.html`.
- Kaydın sözlü anlatım da içermesi nedeniyle otomatik adaylar veri setine eklenmedi;
  önce klarnet bölümleri insan tarafından etiketlenecek.

# Vibrato eğitim etiketleri

- İnsan etiketiyle 3 vibrato egzersiz aralığı eklendi.
- `egitim-vibrato`, veri setinde bağımsız bir `technique_exercise` kaydı olarak yer alıyor.
- Bu örnek özellikle vibratonun başlangıç/bitiş sınırlarını geliştirmek için kullanılacak.

# Çarpma egzersizi etiketleri

- `3. Çarpma egzersizleri` videosu pYIN ile analiz edildi ve insan etiketleri içe aktarıldı.
- Kayıt, 49 ham etiketiyle bağımsız bir `technique_exercise` örneği olarak veri setine eklendi.
- Etiketler çarpma ile birlikte görülen vibrato bölümlerini de içeriyor.
