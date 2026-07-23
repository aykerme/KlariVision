# KlariVision — Ürün Gereksinimleri (v0.1)

## Vizyon

Türk müziği icrasındaki perde hareketi ve süslemeleri analiz edip öğrenilebilir hâle getiren bir platform oluşturmak. Ürün zamanla “hangi süsleme nerede ve hangi müzikal bağlamda kullanıldı?” sorusuna yardımcı olur.

## Problem

Öğrenciler ustaların icralarını dinlerken çarpma, vibrato ve kaydırmaları çoğu zaman ayırt edemez. Genel amaçlı pitch araçları Türk müziğinin perde/makam bağlamını ve öğretici süsleme katmanını birlikte sunmaz.

## MVP kapsamı

- Yerel WAV/MP3 dosyası seçimi
- Baskın melodik pitch eğrisi, seslilik ve güven çıktısı
- Zamanla senkronize edilebilecek standart analiz çıktısı
- Pitch grafiğinin ilk sürümü
- Sol eksende Türk müziği perde adı ve parantez içinde nota karşılığı

Örnek eksen etiketi: **Dügâh (La)**, **Segâh (Si)**, **Çârgâh (Do)**, **Neva (Re)**.

## MVP dışında

- Otomatik makam tespiti
- Otomatik süsleme sınıflandırması
- Sanatçı/üslup benzerliği
- YouTube’dan içerik alma
- Çok kullanıcılı bulut hizmeti

## Başarı ölçütleri

- Temiz, tek klarnetli kısa kayıtlarda melodik çizgi görsel olarak takip edilebilir olmalı.
- Her analiz tekrar üretilebilir bir veri çıktısı vermeli.
- Kullanıcı, grafik üzerindeki zamanı ses kaydındaki karşılığıyla ilişkilendirebilmeli.

## Ürün ilkesi

Otomatik tespit kesin hüküm değil, kullanıcı tarafından doğrulanabilen bir aday analiz olarak sunulacaktır.
