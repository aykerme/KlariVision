# Üç Motor Kullanıcı-Seçeneği Kabulü v1

Tarih: 13 Ağustos 2026. Bu kabul, YIN v1 (`yin_v1`), Pitch Engine v2
(`pitch_engine_v2`) ve VPM-benzeri (`vpm_like`) için **aynı** kullanıcı
seçeneği protokolüdür. Rapor bir kazanan, önerilen motor veya varsayılan
değişikliği üretmez.

## Otomatik yeniden üretim

Üretim C++ `offline_track_v1` yolu, dondurulmuş v6 clean/room/adverse
fixtures üzerinde üç motorla yeniden çalıştırıldı. Sözleşme 48 kHz mono
Float32 PCM, `1536/512` pencere-hop, merkez kaynak zamanı ve ortak C++ oturum
sınırıdır. Rapor parmak izi:
`27178bf1708f8c3337dfdcaf91edca006d1216c57e096addc57d6bf85a2309a0`.

| Motor | Ciddi hata | Yanlış sesli | Eksik sesli | Harmonik | Diğer | Çalışma duvar-zamanı RTF* |
|---|---:|---:|---:|---:|---:|---:|
| YIN v1 | 0 | 15 | 195 | 7 | 0 | 0.069 |
| Pitch Engine v2 | 0 | 18 | 203 | 3 | 0 | 0.229 |
| VPM-benzeri | 0 | 17 | 195 | 3 | 2 | 0.572 |

*Üç yaklaşık 10.386 sn v6 WAV'ın uçtan uca CLI/JSON duvar-zamanı; CPU
mikro-benchmark veya kalite sıralaması değildir. Ciddi hata tanımı geçiş
payı dışında en az üç ardışık kareyi gerektirir. Ham sesli/sessiz sayımları
motorların kabul sırasını değiştirmez.

Fixture'lar sabit nota, hızlı geçiş, üst register, glissando, kısa kesinti,
ani bırakma/yavaş sönme ve sessizlik bölümlerini içerir. Dosya bütünlüğü
manifest SHA-256 değerleriyle doğrulandı; yeni holdout üretilmedi ve sonucu
gördükten sonra hiçbir eşik ayarlanmadı.

## Bağlantı ve arayüz kanıtı

- C++/C ABI: `analysis_engine_c_tests` üç motorun create/reset/process/
  finish/destroy yaşam döngüsünü, kaynak-zamanlı kareleri ve ABI v1
  yeteneklerini doğrular.
- Swift/C++: imzasız macOS Debug derlemesi aynı C başlığı ve
  `ProductionPitchSession` adaptörüyle geçti; Swift Package testleri üç
  nötr motor seçeneğinin kalıcılığını ayrıca doğrular.
- Python/C++: `cpp_engine.contract()` CLI `--contract` çıktısında aynı üç
  kimliği ve `offline_track_v1` şemasını doğrular; Çalışma sentetik koşusu
  aynı paketlenebilir C++ CLI'yi kullandı.

Bu kanıtlar ayrışma olmadığını gösteren sözleşme/regresyon kontrolleridir;
Swift'teki V2/VPM paralel kodu yalnız deterministic parity/diagnostic
oracle'dır, ürün yolundaki motor eşiği değildir.

## Fiziksel kullanıcı protokolü

Her motor için Dinleme ve Çalma ayarlarında motoru seçin, seçimi kapatıp
yeniden açarak kalıcılığı kontrol edin; sonra aşağıdakileri aynı oturumda
kaydedin.

| Kontrol | YIN v1 | Pitch Engine v2 | VPM-benzeri |
|---|---|---|---|
| Sabit nota, hızlı geçiş, üst register, glissando | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti |
| Kısa kesinti, ani bırakma, yavaş sönme/sessizlik | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti |
| Kayıt başlat/durdur, mikrofon durunca güvenli sonlandırma, WAV yeniden dinleme | 13 Ağu ortak kayıt akışı: geçti | Aynı kayıt akışı için tekrar fiziksel koşu gerekir | Aynı kayıt akışı için tekrar fiziksel koşu gerekir |

Kaynak: `BETA_ACCEPTANCE_CHECKLIST.md` 13 Ağustos 2026 kabul oturumu;
YIN için satır 8–9, V2 için 10, VPM için 11. Otomasyon fiziksel klarnet
çalımını, mikrofon iznini veya WAV'ı kulakla yeniden dinlemeyi ikame etmez.
Yeni fiziksel oturumda sonuç motor başına **geçti/sorun/uygulanamadı** olarak
aynı tabloda kaydedilir; hiçbir sonuç bir motoru terfi ettirmez.
