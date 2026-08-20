# KlariVision çalışma sözleşmesi

Bu dosya Codex ve projeye katılan geliştiriciler için kısa, kalıcı çalışma
kurallarını içerir. Ayrıntılı güncel durum için önce
`docs/PROJECT_STATE.md`, ardından `docs/CODEX_HANDOFF.md` okunur.

## Ürün sınırı

- KlariVision, Türk müziği ve klarnet çalışması için yerel pitch analiz ve
  görselleştirme uygulamasıdır.
- Ana ürün önceliği güvenilir pitch eğrisi, canlı çalışma, makam/karar ekseni,
  medya oynatma ve A/B döngüsüdür.
- Süsleme tanıma ana ürün akışında değildir; kullanıcı açıkça istemedikçe bu
  kapsam büyütülmez.
- Makam ve karar perdesi kullanıcı tarafından seçilir. Otomatik makam tespiti
  varsayılmaz.
- Duyulan fiziksel frekans ile ekranda gösterilen/transpoze nota adı ayrı
  katmanlardır; nota adı seçimi pitch verisini değiştirmez.

## Değişiklik güvenliği

- `data/audio/`, `data/video/`, `data/annotations/` ve kullanıcının referans
  çalışma kitapları kullanıcı verisidir. Silinmez, yeniden adlandırılmaz ve
  açık talep olmadan Git'e eklenmez.
- Kararlı canlı YIN v1 korunur. Deneysel motor, `docs/TEST_BASELINE.md`
  ölçütlerini geçmeden varsayılan yapılmaz.
- VPM-benzeri eşikler C++ ve Swift içinde geçici olarak yinelenmektedir. Ortak
  çekirdek köprüsü tamamlanana kadar iki uygulama birlikte güncellenir.
- Bir pitch düzeltmesi yalnız tek zaman aralığına göre ayarlanmaz; sentetik
  gerçek-değer, doğrudan dosya ve gerçek kayıt regresyonları birlikte ölçülür.
- pYIN gerçek kayıtlarda kararlı bir referanstır, kesin gerçek-değer değildir.
  pYIN'in sessiz bıraktığı veya hata yaptığı bölge otomatik olarak ürün hatası
  sayılmaz.

## Doğrulama komutları

```bash
zsh scripts/test_core.sh
.venv/bin/python -B -m pytest -q
```

macOS uygulamasını kod imzasız doğrulamak için:

```bash
xcodebuild \
  -project macos/KlariVision/KlariVision.xcodeproj \
  -scheme KlariVision \
  -configuration Debug \
  -derivedDataPath /private/tmp/KlariVisionDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

VPM-benzeri kalibrasyonu yeniden üretmek için:

```bash
.venv/bin/python scripts/calibrate_vpm_like_engine.py
```

## Bir işin tamamlanma koşulu

1. Değişikliğin kapsamına uygun testler geçer.
2. Kullanıcı verileri ve ilgisiz çalışma ağacı değişiklikleri korunur.
3. Motor davranışı değiştiyse `docs/TEST_BASELINE.md` ve ölçüm raporu güncellenir.
4. Güncel sonuç ve sıradaki tek somut iş `docs/CODEX_HANDOFF.md` içine yazılır.
5. Kalıcı mimari/ürün kararı alındıysa `docs/DECISIONS.md` güncellenir.
