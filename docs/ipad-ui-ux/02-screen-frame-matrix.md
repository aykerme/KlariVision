# Ekran ve frame matrisi

Her SVG aşağıdaki üç referans sınıftan birinde çizilir. Tasarım, aygıt adına
değil kullanılabilir genişliğe göre uygulanır.

| Sınıf | Referans frame | Kullanım |
|---|---:|---|
| Geniş | 1376×1032 pt | 13 inç iPad Pro yatay, kalıcı kenar çubuğu |
| Orta | 834×1194 pt | 11 inç iPad Pro dikey, geri çekilebilir navigasyon |
| Dar | 694×900 pt | Split View / Stage Manager, tek sütun |

| SVG | İçerik | Frame |
|---|---|---:|
| 01 | Ana Sayfa | 1376×1032 |
| 02 | Ana Sayfa, dar | 694×900 |
| 03 | Çalışmalar | 1376×1032 |
| 04 | Çalışmalar, dar | 694×900 |
| 05 | Dinleme, dosya alma | 834×1194 |
| 06 | Dinleme, analiz sürüyor | 834×1194 |
| 07 | Dinleme çalışma alanı | 1376×1032 |
| 08 | Dinleme çalışma alanı, dar | 694×900 |
| 09 | Çalma, hazır | 1376×1032 |
| 10 | Çalma, canlı | 1376×1032 |
| 11 | Çalma, canlı dar | 694×900 |
| 12 | Ayarlar sheet'i | 834×1194 |
| 13 | Kritik durum panosu | 834×1194 |

Bir ekranın ayrı orta frame'i yoksa, `03-responsive-contract.md` içindeki
ölçüler aynı içeriğin orta sınıfta nasıl aktığını belirler.
