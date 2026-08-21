# Canlı Pitch Motoru Kararlı Temeli

Tarih: 2 Ağustos 2026

Bu belge, ikinci nesil çok adaylı pitch motoru geliştirilmeden önce korunan
çalışan temeli tanımlar. Yeni deneyler bu sürümün üzerinde doğrudan yapılmaz;
ayrı bir deneysel motor olarak eklenir ve ancak aşağıdaki doğrulamaları geçince
varsayılan motorun yerini alabilir.

## Kapsam

- macOS SwiftUI uygulaması ve düşük gecikmeli canlı YIN motoru;
- doğrudan kaynak dosya ile canlı motor/pYIN karşılaştırması;
- matematiksel hedef eğrili sentetik doğrulama kayıtları;
- frekans oranını da içeren kalıcı ayrışma raporları;
- platformdan bağımsız C++ görüntü/perde çekirdeği;
- mevcut dosya analizi, oynatma ve çalışma arayüzü.

## Doğrulama sonucu

Temel sürüm oluşturulurken aşağıdaki kontroller temiz geçmiştir:

- Python: 30 test geçti;
- C++ çekirdek: tüm pitch-display testleri geçti;
- Xcode: KlariVision Debug derlemesi başarılı.

## Bilinen sınır

Doğrudan dosya yolunda sonuçlar güçlü olsa da hoparlör-oda-mikrofon zinciri,
özellikle düşük klarnet perdelerinde temel ses yerine güçlü üçüncü harmoniğin
seçilmesine yol açabilir. Son doğrulamalarda 110 Hz hedefin yaklaşık 337-341 Hz,
145-147 Hz hedefin yaklaşık 438-449 Hz olarak seçildiği örnekler görülmüştür.

Bu sınırlama tek karelik eşiklerle giderilmeye çalışılmayacaktır. Sonraki motor;
birden fazla perde adayını koruyan, spektral harmonik puanı kullanan ve kısa
sabit gecikmeyle zamansal yol seçen ayrı bir deneysel katman olacaktır.

## Değişiklik kuralı

Yeni pitch yaklaşımı:

1. mevcut motorun yanında ayrı çalışmalı;
2. aynı kaynak ve aynı zaman tabanıyla karşılaştırılmalı;
3. sentetik, doğrudan dosya ve gerçek mikrofon testlerinde ölçülmeli;
4. mevcut regresyon sonuçlarını kötüleştirmemeli;
5. başarılı olmadığı sürece varsayılan kullanıcı yoluna bağlanmamalıdır.

## Deney dalı

Pitch Engine v2 çalışmaları `agent/pitch-engine-v2` dalında yürütülür. macOS
tanılama menüsündeki **Dosyadan Pitch Engine v2 testi…** seçeneği, aynı kaynak
dosyayı mikrofon kullanmadan deney motoruna verir. Normal **Mikrofonu Başlat**
yolu her zaman kararlı YIN v1 motoruna döner.
