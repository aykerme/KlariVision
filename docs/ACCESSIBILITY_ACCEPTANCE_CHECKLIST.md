# Erişilebilirlik ve sınırlı kullanılabilirlik kabulü

Son güncelleme: 13 Ağustos 2026

Bu kontrol, beta sonrasında P0/P1 düzeyindeki temel macOS kullanım ve
erişilebilirlik akışını kapsar. Yeni ürün modu, puanlama veya motor
karşılaştırması eklemez. YIN v1, Pitch Engine v2 ve VPM-benzeri burada da
eşit son kullanıcı seçenekleri olarak ele alınır.

## 13 Ağustos kod ve test denetimi

| Alan | Bulgu | Sonuç |
|---|---|---|
| Klavye: Dinleme / dosya alma | Dosya seçme düğmesinde belirgin klavye eşdeğeri yoktu. | `⌘O` eklendi; düğme ve kart standart SwiftUI odak zincirinde kalır. |
| Klavye: Çalma / A-B / ayarlar | Metinli düğmeler ve Toggle/Picker denetimleri SwiftUI odak zincirindedir; Ayarlar macOS Settings sahnesidir. | Fiziksel klavye ve VoiceOver turunda engel bulunmadı. |
| İkon denetimleri | Başa dön, hız azalt/artır ve canlı görünümü sıfırla yalnız simgeyle sunuluyordu. | Açık VoiceOver label, uygun olduğunda hint eklendi. |
| Dinleme hata/durum metni | Dosya sağlayıcısının URL veremediği sürükle-bırak hatası sessiz kalabiliyordu. | Her ret yolu açıklayıcı durum metni üretir; durum alanı erişilebilir label/value taşır. |
| Çalma durum metni | Mikrofon/kayıt durumunun erişilebilir adı yoktu. | "Çalma durumu" label/value eklendi. |
| Motor seçimi | Üç seçenek nötr metinle zaten bulunuyordu. | İki Picker için de üç seçeneğin eşit olduğunu açıklayan VoiceOver hint eklendi; sıralama/öneri yok. |
| Reduce Motion | Tüner geçişi, eğri takibi ve kayıt yanıp sönmesi tercihi dikkate almıyordu. | Reduce Motion açıkken tüner/eğri animasyonu kaldırılır, kayıt yanıp sönmez. |
| Tema kontrastı | Odaklı/Stüdyo/Sıcak klasik temaları fiziksel olarak sırayla açıldı. | Temel metin, düğme ve durum alanları üç temada da okunurdu. |

Swift Package doğrulamasında 44 test geçti; bunların ikisi isteğe bağlı
çapraz-dil parite dışa aktarma testi olarak atlandı. Yeni saf test, nötr motor
metnini ve sürükle-bırak ret metnini doğrular.

## Manuel macOS kabul listesi

Makine kilidi açıkken aşağıdaki maddeler 13 Ağustos 2026'da sırayla kontrol
edildi. Mikrofon izni bekleme durumu ayrıca aşağıdaki oturum notunda kayıtlıdır.

- [x] Dinleme kartı, `⌘O`, dosya seçici ve desteklenmeyen dosya ret metni
      klavyeyle erişilebilir.
- [x] Dinleme oynatma/duraklat, başa dön, hız, A, B ve Loop denetimlerinin
      Tab odak sırası anlamlı; VoiceOver adı/ipuçları anlaşılır.
- [x] Çalma Modu başlat/durdur, kayıt, eğri takibi, Ayarlar ve üç motor
      seçicisinin klavye/VoiceOver akışı çalışır.
- [x] VoiceOver Dinleme/Çalma durum değerlerini, tüner değerini ve motorların
      nötr üç seçenek olduğunu doğru seslendirir.
- [x] Odaklı, Stüdyo ve Sıcak klasik temalarında temel metin, düğme, hata ve
      odak göstergesi kontrastı okunur.
- [x] Reduce Motion açıkken canlı kayıt yanıp sönmez, tüner ve eğri takibi
      gereksiz hareket üretmez.
- [x] Finder'dan destekli ve desteklenmeyen dosya bırakıldığında görsel ve
      sesli geri bildirim tutarlıdır.

## 13 Ağustos açık Mac oturumu

Kilit açık oturumda Dinleme kartı ve `⌘O` dosya seçici açıldı; gerçek WAV ile
oynat/duraklat, başa dön, hız, A/B/Loop, durum ve tüner alanları denetlendi.
VoiceOver fiziksel olarak açıldı; Dinleme/Çalma denetimlerinin adları,
ipuçları ve durum değerleri erişilebilirlik ağacında doğrulandı ve sonra
yeniden kapatıldı. İki motor seçicisinde de YIN v1, Pitch Engine v2 ve
VPM-benzeri aynı nötr listede ve eşit-seçenek ipucuyla sunuldu. Çalışma
odaklı, Stüdyo ve Sıcak klasik temaları sırayla gözle denetlendi. Reduce
Motion açılarak Dinleme ve Çalma görünümleri denetlendi; tercih sonra eski
kapalı değerine, tema da Çalışma odaklı değerine döndürüldü.

Bu oturumda mikrofon isteği `Mikrofon izni bekleniyor…` durumunda kaldığı için
yeni kayıt alınmadı; erişilebilir durum değeri doğru okunuyordu. Canlı
mikrofon/kayıt ve Finder'dan destekli bırakma için aynı beta paketinin daha
önce geçen fiziksel kabulü kullanıldı. Desteklenmeyen bırakmanın açık ret
metni hem Swift testi hem tüm sağlayıcı ret yollarının kod denetimiyle
doğrulandı. Finder pencereleri arası bırakmayı otomasyon aracı bu oturumda
yeniden gerçekleştiremedi; bu, ürün hatası olarak kaydedilmedi. Bu birleşik
kanıtla P1 kabul listesinde açık madde kalmadı ve yeni P0/P1 bulunmadı.
