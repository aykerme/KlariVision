# Çok Platformlu Analiz Çekirdeği

## Amaç

KlariVision'ın pitch ve müzik hesaplarını tek kez geliştirmek; aynı sonuçları
macOS, iPad/iPhone ve Android uygulamalarında üretmektir.

## Sınırlar

Çekirdek şunları içerir:

- zaman hizalı pitch veri modeli;
- frekans, sent ve perde hesapları;
- pYIN sonucu için güvenli görüntü temizleme;
- gelecekteki yerel pitch çıkarıcı ve makam katmanı.

Çekirdek şunları içermez:

- kullanıcı arayüzü;
- medya oynatma;
- dosya seçimi veya YouTube indirme;
- cihazlar arası senkronizasyon.

Bu kararlar SwiftUI ve Jetpack Compose arayüzlerinin aynı çekirdeği doğal
platform deneyiminden ödün vermeden kullanmasını sağlar.

## Geçiş planı

1. **Referans sözleşmesi:** Python/Vamp pYIN JSON çıktısı korunur.
2. **Taşınabilir işlem katmanı:** C++ çekirdeği, Python görüntü temizleme
   davranışını testlerle eşler.
3. **Karşılaştırma veri kümesi:** İzinli kısa kayıtların ham JSON çıktıları
   sürüm kontrollü golden test olarak saklanır.
4. **Yerel pitch çıkarıcı:** C++ içinde pYIN uyumlu aday üretimi ve zaman
   sürekliliği çözümü eklenir.
5. **Platform bağları:** Swift için Swift/C++ köprüsü, Android için JNI
   bağlayıcısı eklenir.

## Başarı ölçütü

Yeni çekirdek, referans kayıtlarında Python/Vamp eğrisinin zaman konumlarını,
sesli/sessiz karelerini ve kabul edilen frekans bandını karşılamalıdır. Görsel
yakınlık tek başına yeterli değildir; test raporu sayısal sapmayı göstermelidir.
