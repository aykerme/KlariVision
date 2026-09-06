# KlariVision Core

KlariVision Core, macOS, iPad/iPhone ve Android uygulamalarının ortak
analiz çekirdeğidir. Kullanıcı arayüzü veya dosya seçimi içermez.

## İlk kapsam

- Kare bazlı pitch veri modeli
- Frekans / sent dönüşümü
- Grafikte kullanılan güvenli görüntü temizleme
- Python referansıyla karşılaştırılabilir sonuç sözleşmesi
- Çoklu aday + harmonik kanıt + yol çözümü sözleşmesi (`unified_v1`)

`src/klarivision/frequency_viewer.py` içindeki mevcut doğrulanmış temizleme
kuralları C++ tarafına aynen aktarılmıştır. Python/Vamp pYIN analizi çevrimdışı
dosya analizinde referans üretici olarak kalır.

## Platform bağları

| Platform | İnce bağ katmanı |
| --- | --- |
| macOS / iPad / iPhone | Swift ↔ C++ köprüsü |
| Android | Kotlin/JNI ↔ C++ köprüsü |

Çekirdek, medya oynatma, YouTube indirme ve kullanıcı arayüzü kararlarından
bilerek bağımsız tutulur.

## `unified_v1` — tek motor

D-039 ile dört eski motor kaldırıldı; çalışan tek motor `unified_v1`'dir.
`pitch_candidate.hpp`, aday sözlüğüdür: her aday frekansla birlikte kaynağını,
periyodiklik güvenini ve harmonik desteğini taşır. `pyin_ladder.hpp` olasılık
merdivenini, `mpm.hpp` NSDF yerel tepelerini üretir; `frame_spectrum.hpp` ve
`swipe_prime.hpp` adayları spektral kanıtla puanlar; `harmonic_evidence.hpp`
harmonik aile üyeliğini ölçer; `unified_track_decoder.hpp` 5 hop (53,3 ms)
sabit gecikmeli yolu çözer ve **sessiz kalmayı yolun üzerinde bir durum**
olarak taşır. `analysis_engine.hpp` bu oturumun ürün sınırıdır.

`pitch_candidate.hpp`'nin `klarivision::core::v2` ad alanı tarihsel bir isimdir
(aday sözlüğü `pitch_engine_v2` ile doğmuştu). Yeniden adlandırma, motor
kaldırma commit'ini okunamaz hale getirmemek için ayrı bırakıldı.
