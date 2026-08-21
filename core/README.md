# KlariVision Core

KlariVision Core, macOS, iPad/iPhone ve Android uygulamalarının ortak
analiz çekirdeğidir. Kullanıcı arayüzü veya dosya seçimi içermez.

## İlk kapsam

- Kare bazlı pitch veri modeli
- Frekans / sent dönüşümü
- Grafikte kullanılan güvenli görüntü temizleme
- Python referansıyla karşılaştırılabilir sonuç sözleşmesi
- V1'den bağımsız Pitch Engine v2 aday ve seçim sözleşmesi

`src/klarivision/frequency_viewer.py` içindeki mevcut doğrulanmış temizleme
kuralları C++ tarafına aynen aktarılmıştır. Python/Vamp pYIN analizi şimdilik
referans üretici olarak kalır; mobil motor ancak karşılaştırma testlerini
geçtiğinde varsayılan olacaktır.

## Platform bağları

| Platform | İnce bağ katmanı |
| --- | --- |
| macOS / iPad / iPhone | Swift ↔ C++ köprüsü |
| Android | Kotlin/JNI ↔ C++ köprüsü |

Çekirdek, medya oynatma, YouTube indirme ve kullanıcı arayüzü kararlarından
bilerek bağımsız tutulur.

## Pitch Engine v2

`pitch_engine_v2.hpp`, yeni motorun kararlı motordan ayrı sınırıdır. Her aday
frekansla birlikte kaynağını, periyodiklik güvenini ve harmonik desteğini taşır.
`mpm.hpp` NSDF yerel tepelerini `.mpm` kaynaklı adaylar olarak üretir.
`swipe_prime.hpp`, aynı adayları spektrumun karekökü ile birinci ve asal
harmoniklerde puanlar. Kısa gecikmeli yol izleyici sonraki adımda bu sözleşmenin
arkasına eklenecektir; V1 kullanıcı yolu değişmeden kalacaktır.
