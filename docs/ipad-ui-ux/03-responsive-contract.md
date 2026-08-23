# Responsive yerleşim sözleşmesi

## Genişlik sınıfları

- **Geniş, ≥1000 pt:** 280 pt kalıcı kenar çubuğu; içerik bölünmüş çalışma
  alanıdır. Dinleme medyası iç alanın `%32`si, grafik kalanı alır; aralık
  16 pt'dir.
- **Orta, 700–999 pt:** Navigasyon 320 pt drawer olur. Dinleme medyası üstte
  220–360 pt, grafiğin yüksekliği en az 360 pt'dir. Çalma tüneri üst orta,
  iki denetim grubu altında akar.
- **Dar, <700 pt:** Tek sütun ve modal navigasyon kullanılır. Dinleme ve Çalma
  çalışma alanlarında grafik bütün yüzeyi kaplar (alt safe area'yı da aşar);
  denetimler sabit çubuk yerine grafiğin üstünde yüzen `.ultraThinMaterial`
  kart olarak durur. Çalma'da tüner, navigasyon çubuğunun altında ayrı bir
  yüzer rozettir. Medya 220 pt'ye küçülür.

## Kalıcılık kuralları

Yön, Split View veya Stage Manager boyut değişimi oynatma zamanını, hızını,
A/B işaretlerini, loop'u, grafik görünümünü, makam/kararı ya da canlı oturum
durumunu değiştirmez. Dinleme medya-grafik köprüsü tek `WKWebView` kimliğini
korur; yerleşim değişimi görünümü yeniden oluşturmaz.

## Grafik sözleşmesi

- Tek parmak sürükleme: yatay bileşeni zamanda arar, dikey bileşeni pitch
  merkezini kaydırır (pan). İkisi aynı hareket içinde birlikte çalışır.
- Zamanda arama pencereyi değil `currentTime`'ı değiştirir: ortadaki beyaz
  imleç çizgisi her zaman ortada kalır, kayıt çizginin altından akar.
- Pinch: yatay pinch görünür zaman aralığını, dikey pinch pitch aralığını
  yakınlaştırır/uzaklaştırır; diyagonal pinch ikisini birlikte.
- Pan ve zoom yalnız cents aralığını yeniden hesaplar; canvas dönüştürülmez.
  Perde isimleri kendi çizgisine yapışık kalır, soldaki konumu ve puntosu
  hiçbir zoom/pan seviyesinde değişmez.
- Çift dokunma: zaman ve dikey görünümü başlangıca döndür. (Henüz uygulanmadı;
  pan clamp'i eğrinin en fazla bir ekran uzaklaşmasına izin verdiği için görünüm
  jestle her zaman geri toplanabiliyor.)
- Dinleme denetim çubuğunda konum slider'ı yoktur; yerinde süre okuması durur
  ve VoiceOver bu ögeyi ±5 sn ayarlanabilir eylemle gezinir — temel iş yalnız
  jestle yapılmaz.

### Çalma (canlı) grafiği

- Görünür pencere kendi akış saatiyle ilerler; sessizlikte de sola akar.
  Yalnız analiz durduğunda (Swift `setRunning(false)` yollar) donar. Saat
  macOS canlı grafiğiyle aynı sözleşmedir: son kare zamanı + o kareden bu yana
  geçen gerçek süre.
- Canlı grafikte arama yoktur: tek parmak sürükleme yalnız dikey pan yapar,
  yatay bileşen yok sayılır. En yeni örnek her zaman sağ kenardadır.
- Pinch eksen sınıflandırması Dinleme ile aynıdır (yatay → zaman penceresi
  2–60 sn, dikey → pitch aralığı 0,25×–4×, diyagonal → ikisi).
- Perde isimleri, puntoları ve çizgi kalınlıkları zoom/pan'dan etkilenmez;
  Dinleme'deki gibi yalnız cents aralığı yeniden hesaplanır.
- Pitch yolu üç durumda kesilir: zaman ileri gitmediyse, iki kare arası 40
  ms'yi aştıysa veya perde ~bir oktavdan fazla sıçradıysa. Sessizlik boşlukları
  ve tekrarlanan/geri saran zaman damgaları böylece üst üste çizilmez.
- Yeni bir canlı oturum zaman çizgisini sıfırlar (kare zaman damgaları 0'dan
  başladığı için); önceki kayıt grafikte kalmaz.

## Güvenli alanlar

Gezinme, alt oynatma/kayıt çubuğu ve sheet eylemleri sistem safe area'nın
içinde kalır. Grafik hiçbir sınıfta 360 pt'nin altına düşmez ve sabit denetim
tarafından örtülmez. Her etkileşim hedefi en az 44×44 pt'dir.
