# Erişilebilirlik ve tasarım kabulü

## Zorunlu erişilebilirlik

- Dynamic Type'ın büyük erişilebilirlik boyutlarında metin kesilmez; gerekli
  yerde denetim grupları dikey akar.
- VoiceOver sırası: başlık → bağlam → birincil eylem → durum → ikincil
  eylemler → grafik. Grafik, zaman/pitch özetine ve düğme eşdeğerlerine sahiptir.
- Full Keyboard Access, pointer ve Switch Control için tüm ana akışlar
  erişilebilir kalır.
- Mikrofon, analiz ve kayıt durumları erişilebilir canlı bölge kullanır.
- Renk körlüğü, yüksek kontrast ve Reduce Motion'da bilgi kaybı olmaz.

## Tasarım kabul senaryoları

- İlk açılıştan analiz başlatmak en fazla iki ana karar adımıdır.
- Son çalışmayı açmak, A/B işaretlemek ve loop kurmak mümkündür.
- Çalma modunda makam/karar seçmek, mikrofon iznini yönetmek ve kayıt almak
  anlaşılırdır.
- 1376×1032, 834×1194 ve 694×900 geçişlerinde bağlam korunur.
- Desteklenmeyen dosya, analiz hatası, mikrofon reddi ve kesinti sonrası tek
  görünür kurtarma eylemi bulunur.
- Hiçbir referans frame'de grafik, sabit denetimlerle örtülmez; 44 pt altı
  etkileşim hedefi ya da salt renkle anlatılan durum bulunmaz.

## SVG gözden geçirme

Teslimde tüm SVG dosyaları XML olarak parse edilir, üç tema için en az bir
ekran görsel olarak incelenir ve bu listedeki kabul maddeleri ekran bazında
işaretlenir.
