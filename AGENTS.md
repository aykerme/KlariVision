# KlariVision çalışma notları

## Amaç

Türk müziği icralarından perde eğrisi çıkaran, bunu makam/perde bağlamında
gösteren ve daha sonra süslemeleri etiketleyip tanıyacak yerel analiz aracı.

## Çalışma ilkeleri

- İlk sürümde makam otomatik tespit edilmez; kullanıcı makamı ve karar perdesini seçer.
- Pitch çıktısı ham ses kaydından gelir; görsel eksen ayrı bir makam/perde katmanıdır.
- Segâh, Dügâh'a göre 181 sent olarak temsil edilir.
- Her yeni pitch yöntemi, referans kayıt ve zaman kodlarıyla karşılaştırılarak doğrulanır.
- Kullanıcı verileri ve kayıtlar varsayılan olarak yerel kalır.

## Doğrulama

```bash
.venv/bin/python -m pytest -q
```

## Yakın hedef

Tek komutla ses/video dosyasından pYIN çıktısı ve sesle senkron HTML pitch
görünümü üretmek; görünümde makam ile karar perdesi seçilebilmelidir.
