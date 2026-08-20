# Responsive yerleşim sözleşmesi

## Genişlik sınıfları

- **Geniş, ≥1000 pt:** 280 pt kalıcı kenar çubuğu; içerik bölünmüş çalışma
  alanıdır. Dinleme medyası iç alanın `%32`si, grafik kalanı alır; aralık
  16 pt'dir.
- **Orta, 700–999 pt:** Navigasyon 320 pt drawer olur. Dinleme medyası üstte
  220–360 pt, grafiğin yüksekliği en az 360 pt'dir. Çalma tüneri üst orta,
  iki denetim grubu altında akar.
- **Dar, <700 pt:** Tek sütun, modal navigasyon ve 64 pt sabit alt oturum
  çubuğu kullanılır. Grafik ana yüzeydir; medya 220 pt'ye küçülür.

## Kalıcılık kuralları

Yön, Split View veya Stage Manager boyut değişimi oynatma zamanını, hızını,
A/B işaretlerini, loop'u, grafik görünümünü, makam/kararı ya da canlı oturum
durumunu değiştirmez. Dinleme medya-grafik köprüsü tek `WKWebView` kimliğini
korur; yerleşim değişimi görünümü yeniden oluşturmaz.

## Grafik sözleşmesi

- Tek parmak yatay sürükleme: zaman içinde ara.
- Pinch: görünür zaman aralığını yakınlaştır/uzaklaştır.
- İki parmak dikey sürükleme: pitch merkezi.
- Çift dokunma: zaman ve dikey görünümü başlangıca döndür.
- Yakınlaştırma, dikey merkez ve sıfırlama için görünür düğme/menü eşdeğeri
  bulunur; temel iş yalnız jestle yapılmaz.

## Güvenli alanlar

Gezinme, alt oynatma/kayıt çubuğu ve sheet eylemleri sistem safe area'nın
içinde kalır. Grafik hiçbir sınıfta 360 pt'nin altına düşmez ve sabit denetim
tarafından örtülmez. Her etkileşim hedefi en az 44×44 pt'dir.
