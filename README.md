# KlariVision

**Türk müziği icrasında perde hareketini ve süslemeleri görünür kılan analiz ve eğitim platformu.**

KlariVision'ın ilk hedefi bir ses dosyasındaki baskın melodik çizgiyi çıkarıp zamanla birlikte göstermektir. Sonraki katmanlar bu çizgi üzerinden nota/perde eşleme, makam bağlamı ve süsleme analizi ekleyecektir.

## İlk hedef: Pitch Engine

1. WAV/MP3 girdisini analiz için hazırla.
2. Her zaman karesi için perde, seslilik ve güven değeri üret.
3. Sonucu ortak bir veri modeliyle dışarı ver.

Bu depo başlangıçta yerel geliştirme içindir. Referans kayıtlarının kullanım hakları ayrıca ele alınacaktır; yalnızca izinli veya kişisel kayıtlar `data/` altında tutulmalıdır.

## Başlangıç yapısı

    docs/                   Ürün ve teknik kararlar
    src/klarivision/pitch/  Pitch Engine çekirdeği
    tests/                  Otomatik kontroller
    data/                   Yerel çalışma verileri
    research/               Müzikoloji ve algoritma notları

## Tek komutla analiz

22.050 Hz WAV kaydı için:

```bash
PYTHONPATH=src .venv/bin/python -m klarivision.cli data/audio/kaydiniz.wav --makam huzzam --karar dugah
```

Komut `outputs/` içinde pYIN JSON verisini ve sesle senkron HTML pitch
görünümünü oluşturur. Makam ve karar sesi iki ayrı menüden değiştirilebilir.
Karar sesi, yalnızca görsel pitch eğrisini transpoze eder; ses kaydını
değiştirmez. Otomatik makam tespiti henüz yapılmaz.
