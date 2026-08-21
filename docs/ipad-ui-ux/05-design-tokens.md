# Görsel tokenlar

## Renk

| Token | Değer | Kullanım |
|---|---|---|
| `accent-listening` | `#0A84FF` | Dinleme vurgusu, pitch eğrisi |
| `accent-practice` | `#34C759` | Çalma modu kimliği |
| `status-recording` | `#FF453A` | Aktif kayıt ve hata eylemi |
| `graph-guide` | `#8E8E93` | Nota kılavuzu |
| `studio-surface` | `#181E25` | Stüdyo ana yüzeyi |
| `studio-control` | `#27303A` | Stüdyo kontrol yüzeyi |
| `classic-surface` | `#FAF4EA` | Sıcak klasik ana yüzeyi |
| `classic-control` | `#FFFAF1` | Sıcak klasik kontrol yüzeyi |

Çalışma odaklı tema sistem dinamik yüzeylerini kullanır. Grafik pitch çizgisi
1.7 pt, yuvarlak uçlu; 40 ms üzerindeki zaman boşluğu kesik olarak görünür.

## Ölçü ve tipografi

- Boşluk: `4, 8, 12, 16, 20, 24, 32 pt`.
- Köşe: denetim `12`, panel `16`, mod kartı `20 pt`.
- Dokunma hedefi: en az `44×44 pt`.
- SF Pro: büyük başlık `34/41 bold`, başlık `28/34 bold`, bölüm `20/25
  semibold`, gövde `17/22 regular`, yardımcı `13/18 regular`.
- Ana ikonlar SF Symbols'dür; sembol adları `assets/ipad-ui-symbol-map.md`
  içinde listelenir.

## Hareket ve kontrast

Denetim geçişleri 180 ms, panel geçişleri 250 ms kullanır. Reduce Motion'da
anlamı koruyan anlık değişim kullanılır. Açık, Stüdyo ve Sıcak klasik
temalarında metin, odak, hata ve bilgi yüzeyleri WCAG AA düzeyinde ayrışır.
