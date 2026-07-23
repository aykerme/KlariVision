# KlariVision

## Sürüm

Mevcut stabil temel: **v0.2.0**. Bu sürüm pYIN ile ölçülen duyulan frekansı ve
ana nota frekanslarını gösterir; makam, karar, transpozisyon ve süsleme
katmanları bu temel görünümden ayrıdır.

## Kod inceleme

- `KlariVision.code-workspace`: Projeyi Visual Studio Code ile tek çalışma alanı olarak açar.
- `scripts/build_code_review.py`: Kaynak, test, betik ve belgeleri tek yerel HTML sayfasında toplar.

## Pitch motorları

- **Hızlı pYIN (Vamp)**: Varsayılan seçenek. Yerel Sonic Annotator ve Vamp pYIN
  eklentisini kullanır; uzun kayıtlar için tasarlanmıştır.
- **Ayrıntılı pYIN (Python)**: Librosa tabanlı deneysel yol. Daha maliyetli
  parametre araştırmaları için korunur.

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
