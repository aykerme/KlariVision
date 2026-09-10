# Dış Değerlendirme İddialarının Kod Doğrulaması

**Tarih:** 2026-09-10  
**Denetçi:** Claude Code (Agent)  
**Kapsam:** Sekiz dış iddia + iki özel araştırma konusu  
**Not:** Kod değiştirilmedi; bu sadece kanıt toplama ve doğrulama görevidir.

---

## İddia Doğrulama Tablosu

| İddia | Durum | Kanıt (dosya:satır) | Not |
|-------|-------|---------------------|-----|
| 1. Canlı yol Galaxy A73'te bütçenin %86'sını (9,18 ms / 10,67 ms) kullanıyor | **Doğru** | `docs/DECISIONS.md:848-849` | D-044'de ölçülmüş: "NEON ile p50 9,18 ms, RTF 0,86" ve "hop bütçesi 10,667 ms'dir" |
| 2. Her 10 ms'lik çerçevede pYIN, MPM, SWIPE' ve TWM'nin dördü de eksiksiz koşuyor | **Doğru** | `core/src/unified_pitch_session.cpp:154,168,201` | `unified_frame_evidence` içinde üç çağrı da KOŞULSUZ: `pyin_ladder()` (154), `v2::mpm_candidates()` (168), `score_harmonic_evidence()` (201) — SWIPE' ve TWM sonuncusunun içindedir. Tek erken çıkış, sert sessizlik eşiğidir (satır 136-141, `kHardSilenceRatio`); onun üstündeki HER kare üç aşamanın tamamını koşar. Yazılı sözleşme yok, ama kodda doğrudan okunuyor. |
| 3. `pyin_ladder.cpp` içindeki CMNDF fark fonksiyonu her lag için zaman domeninde iç çarpımla hesaplanıyor (FFT kullanılmıyor) | **Doğru** | `core/src/pyin_ladder.cpp:45-68,83-108` | `dot_product()` fonksiyonu iç çarpım yapıyor; CMND fark fonksiyonu satır 88'de `correlation = dot_product(...)` ile zaman domeninde hesaplanıyor; FFT yoktur |
| 4. Viterbi/fixed-lag çözücü 8 hop (85,3 ms) gecikmeyle çalışıyor | **Doğru** | `docs/DECISIONS.md:6-11,20-25` | D-042'de teyit: "8 hop / 85,3 ms" ve "kv_unified_lag_frames: 5 → 8"; üç aynası güncellenmiş |
| 5. Android canlı grafiği WebView içinde çiziliyor ve Kotlin'den JS'e JSON string olarak veri postalanıyor | **Doğru** | `android/app/src/main/kotlin/.../LiveGraphBridge.kt:62-77,146` | WebView kullanılıyor (satır 9, 86); JSON string `LiveFramePayload.toJsonString()` ile oluşturuluyor; `evaluateJavascript()` ile gönderiliyor |
| 6. Android ses girişi Kotlin `AudioRecord` API'siyle alınıp JNI üzerinden C++'a veriliyor (Oboe/AAudio kullanılmıyor) | **Doğru** | `android/app/src/main/kotlin/.../LiveAudioCapture.kt:21` ve `android/core/.../LivePitchSession.kt:54` | `AudioRecord` import mevcut; `NativeBridge` (JNI) çağrıları yapılıyor; grep sonucu Oboe/AAudio yoktur |
| 7. `confidence` alanı doğrudan `winner_posterior`'dır | **Doğru** | `core/src/unified_pitch_session.cpp:600,645,829` ve `docs/DECISIONS.md:824` | Üç yerde `frequency ? decoded.winner_posterior : 0.0` ile atanıyor; D-044'de açıkça belirtilmiş |
| 8. `harmonic_evidence.cpp` / `harmonic_arbitration.cpp` genel bir enstrüman modeli kullanıyor, klarnete özgü tek-harmonik (1-3-5) baskınlığı ağırlıklandırması YOK | **Doğru** | `core/src/harmonic_arbitration.cpp:36-77` ve `core/src/harmonic_evidence.cpp:1-57` | Her iki dosya da genel amaçlı (instrument-agnostic) hesaplamalar yapıyor; klarnet özgü (1,3,5) ağırlıklandırması görülmüyor; yalnızca 2x/3x (octave/twelfth) ghost kontrolü var (satır 55) |

**Özet:** Sekiz iddianın tamamı kodda doğrulandı.

> **Düzeltme (ana oturum):** 2. iddia ilk denetimde "Ölçülmedi" işaretlenmişti; aranan şey yazılı bir performans sözleşmesiydi, oysa kanıt kodun kendisindedir. Bu satır yukarıda düzeltildi. Önemi büyüktür: bu iddia, dış değerlendirmenin "erken çıkış budaması" önerisinin tek dayanağıdır.

---

## Değerlendirmenin Atladıkları

### A) `score_harmonic_evidence` Çıktısının Kullanım Alanı

**Sorun:** İddia sadece hakemlik (arbitration) için kullanıldığını ima ediyordu; gerçek değişikliğin motor çıktısını etkileyip etkilemeyeceğini sorgulamıştı.

**Bulgu:** `score_harmonic_evidence` çıktısı **hem hakemlik hem de aday KABUL/VETO kapısı** olarak kullanılıyor.

**Kanıt:**  
- Satır 201-204: `score_harmonic_evidence()` çağrısı, çıktısı `frame.evidence` alanında saklanıyor  
- Satır 225-228: `evidence.fundamental_presence` ve `evidence.twm_score` — **aday VETO koşulları** (continue → kopyalanmıyor)  
- Satır 239-240: `evidence.series_incoherent` — **aday VETO koşulu** (continue → kopyalanmıyor)  

**Sonuç:** SWIPE'/TWM'yi atlama önerisi motor çıktısını değiştirebilir; bu adayları veto ederek kapalı adaylar elenir ve sonraki hakemlik süreci geri kalan adaylar üzerinde yürür.

**Referans:** `core/src/unified_pitch_session.cpp:210-252`

---

### B) `confidence` Alanının C ABI v1 Sözleşme Durumu

**Sorun:** "Confidence'ı normalize et" önerisinin C ABI'yi kırıp kırmayacağını sorgulamıştı.

**Bulgu:** `confidence` alanı **C ABI v1'de donmuş bir sözleşme alanıdır**. Yapı yerleşimi kilitlidir.

**Kanıt:**  
- `core/include/klarivision/core/analysis_engine_c.h:12-17`: `kv_pitch_frame` struct tanımı  
  ```c
  typedef struct {
      double time_seconds;
      double frequency_hz;
      double confidence;
      int voiced;
  } kv_pitch_frame;
  ```
- Satır 19-20: "Stable C ABI contract. New fields may only be appended in a later ABI version..."
- `docs/PITCH_ENGINE_C_ABI_V1.md:47` : "KV_PITCH_C_ABI_V1 geriye uyumlu ilk ABI'dir ve sürümü **1 olarak kalır**"

**Sonuç:** `confidence` alanının tanımı, türü veya konumu değiştirilemez. Normalize etme veya başka türde değişiklik C ABI v2'yi gerektirir (ürün alanı kararı).

**Referans:**  
- `core/include/klarivision/core/analysis_engine_c.h` (tüm struct)  
- `docs/PITCH_ENGINE_C_ABI_V1.md` (sözleşme deklarasyonu)  
- `docs/DECISIONS.md:D-031` (ABI v1 kararı)

---

## Referans Kararlar

- **D-044:** Çekişme oranı 0,75; kapsama kapısı ekranı ölçer  
- **D-043:** Android ürünü başlatıldı; taşınabilirlik kanıtlandı  
- **D-042:** D-041'in canlı yola taşınması; gecikme 53 → 85 ms  
- **D-041:** Çevrimdışı yola iki çekimserlik kuralı  
- **D-040:** RMS kapısı dış veri kümelerine bakılarak değiştirilmez  
- **D-038:** `unified_v1` kazanan motordur  
- **D-037:** Birleşik motor (`unified_v1`) tek motor hedefiyle eklendi  
- **D-031:** Ortak C++ pitch sınırı v1 sözleşmesidir  

---

## İlgili Dokümanlar

- `docs/CODEX_HANDOFF.md` — Proje bilgi geçişi  
- `docs/PITCH_ENGINE_C_ABI_V1.md` — C ABI v1 sözleşmesi  
- `docs/TEST_BASELINE.md` — Ölçüm temelleri  

---

**Doğrulama Tamamlandı**
