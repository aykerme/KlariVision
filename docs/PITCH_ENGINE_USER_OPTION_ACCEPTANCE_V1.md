# Dört Motor Kullanıcı-Seçeneği Kabulü v1

> **TARİHSEL BELGE — bu motor koddan kaldırıldı (D-039, 6 Eylül 2026).**
> Aşağıdakiler kaldırılma anındaki yöntem, kalibrasyon ve ölçüm kaydıdır ve
> kanıt zinciri olarak korunur. Buradaki komutlar artık koşmaz, eşikler artık
> hiçbir kodu yönetmez. Çalışan tek motor `unified_v1`'dir; güncel durum
> `docs/PROJECT_STATE.md` ve `docs/TEST_BASELINE.md`'dedir.

Tarih: 13 Ağustos 2026 (YIN v1, Pitch Engine v2, VPM-benzeri), eklenti:
24 Ağustos 2026 (Harmonik-Faz / `hapt_v1`, bkz. `docs/HAPTPitchEngine.md`).
Bu kabul, dört motor için **aynı** kullanıcı seçeneği protokolüdür. Rapor bir
kazanan, önerilen motor veya varsayılan değişikliği üretmez.

## Otomatik yeniden üretim

Üretim C++ `offline_track_v1` yolu, dondurulmuş v6 clean/room/adverse
fixtures üzerinde yeniden çalıştırıldı. Sözleşme 48 kHz mono Float32 PCM,
`1536/512` pencere-hop, merkez kaynak zamanı ve ortak C++ oturum sınırıdır.

İlk üç motorun (13 Ağustos) rapor parmak izi:
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

HAPT (24 Ağustos), aynı üç v6 fixture'ıyla, ayrı bir koşuda ölçüldü (rapor
parmak izi: `5397c2651abd9e5a4f71085b4a329ba8bf313646a384d23cfa5e4bff9b413dac`,
`outputs/hapt-v1-v6-acceptance.json`):

| Motor | Ciddi hata | Ham hata (toplam) | Çalışma duvar-zamanı RTF* |
|---|---:|---:|---:|
| Harmonik-Faz (HAPT) | 0 | 217 | 0.599 |

HAPT'ın duvar-zamanı RTF'i VPM-benzeri ile aynı büyüklük mertebesindedir
(spektral prob sayısı fazladır); ikisi de gerçek zamanın altında kalır. Bu bir
kalite sıralaması değildir, yalnız ölçülen maliyettir.

Fixture'lar sabit nota, hızlı geçiş, üst register, glissando, kısa kesinti,
ani bırakma/yavaş sönme ve sessizlik bölümlerini içerir. Dosya bütünlüğü
manifest SHA-256 değerleriyle doğrulandı; yeni holdout üretilmedi ve sonucu
gördükten sonra hiçbir eşik ayarlanmadı (HAPT'ın kendi eşik kalibrasyonu,
`docs/HAPTPitchEngine.md`'de anlatıldığı gibi, yalnız v1–v5 turnuva
holdout'larında yapıldı; v6 yalnız bu tek, son doğrulama koşusunda kullanıldı).

## Bağlantı ve arayüz kanıtı

- C++/C ABI: `analysis_engine_c_tests` dört motorun create/reset/process/
  finish/destroy yaşam döngüsünü, kaynak-zamanlı kareleri ve ABI v1
  yeteneklerini (`KV_CAP_ENGINE_HAPT_V1` dahil) doğrular.
- Swift/C++: imzasız macOS Debug derlemesi aynı C başlığı ve
  `ProductionPitchSession` adaptörüyle geçti; Swift Package testleri dört
  nötr motor seçeneğinin kalıcılığını ayrıca doğrular. iPad/iPhone tarafında
  `KlariVisionCoreSmokeTests` ve `KlariVisioniPadTests` de dört motoru içerir
  (simülatörde derlenip koşuldu; fiziksel cihaz testi ayrı, aşağıda).
- Python/C++: `cpp_engine.contract()` CLI `--contract` çıktısında aynı dört
  kimliği ve `offline_track_v1` şemasını doğrular; Çalışma sentetik koşusu
  aynı paketlenebilir C++ CLI'yi kullandı.

Bu kanıtlar ayrışma olmadığını gösteren sözleşme/regresyon kontrolleridir;
Swift'teki V2/VPM paralel kodu yalnız deterministic parity/diagnostic
oracle'dır, ürün yolundaki motor eşiği değildir. HAPT'ın Swift aynası yoktur
(bkz. `docs/HAPTPitchEngine.md` "Bilinen sınırlar"); ürün onu her zaman
üretim C++ çekirdeği üzerinden çalıştırır.

## Fiziksel kullanıcı protokolü

Her motor için Dinleme ve Çalma ayarlarında motoru seçin, seçimi kapatıp
yeniden açarak kalıcılığı kontrol edin; sonra aşağıdakileri aynı oturumda
kaydedin.

| Kontrol | YIN v1 | Pitch Engine v2 | VPM-benzeri | Harmonik-Faz (HAPT) |
|---|---|---|---|---|
| Sabit nota, hızlı geçiş, üst register, glissando | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti | Fiziksel oturum gerekli — uygulanmadı |
| Kısa kesinti, ani bırakma, yavaş sönme/sessizlik | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti | 13 Ağu fiziksel kayıt: geçti | Fiziksel oturum gerekli — uygulanmadı |
| Kayıt başlat/durdur, mikrofon durunca güvenli sonlandırma, WAV yeniden dinleme | 13 Ağu ortak kayıt akışı: geçti | Aynı kayıt akışı için tekrar fiziksel koşu gerekir | Aynı kayıt akışı için tekrar fiziksel koşu gerekir | Fiziksel oturum gerekli — uygulanmadı |

Kaynak: `BETA_ACCEPTANCE_CHECKLIST.md` 13 Ağustos 2026 kabul oturumu;
YIN için satır 8–9, V2 için 10, VPM için 11. Otomasyon fiziksel klarnet
çalımını, mikrofon iznini veya WAV'ı kulakla yeniden dinlemeyi ikame etmez.
HAPT satırları bu yüzden **kasıtlı olarak boş bırakıldı**: gerçek klarnet ve
mikrofonla fiziksel bir oturum, otomasyonun yerini tutamaz ve bu ajan
tarafından yapılamaz. Yeni fiziksel oturumda sonuç motor başına
**geçti/sorun/uygulanamadı** olarak aynı tabloda kaydedilir; hiçbir sonuç bir
motoru terfi ettirmez.
