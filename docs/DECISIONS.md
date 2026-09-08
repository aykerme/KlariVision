# Kalıcı Proje Kararları

Bu dosya yalnızca sonraki çalışmaları etkileyen kararları tutar. Günlük ilerleme
notları `CODEX_HANDOFF.md`, sayısal durum `TEST_BASELINE.md` içindedir.

## D-042 — D-041'in canlı yola taşınması; gecikme 53 → 85 ms

Kullanıcı kararı: Şükrü Tunar hatası Çalma Modu'nda (canlı yol) duruyordu,
çünkü D-041 kasten yalnız çevrimdışı yola eklenmişti. Kullanıcı, canlı yolda
alt-harmonik hatasının çözülmesini tepkiselliğe **açıkça tercih etti** ve
gecikme artışını (5 hop / 53,3 ms → 8 hop / 85,3 ms) onayladı. D-037'nin
gecikme kararı böylece kısmen geri alınıyor.

**Üç değişiklik:**

1. `kRealtimeAbstention`'daki kanıt-oranı tavanı `+sonsuz` yerine
   `kHarmonicEvidenceRatioAbstainCeiling` (offline ile aynı, 1,0). Ölçüm:
   Şükrü hedef penceresinde (canlı iz, `unified_trace`) 9 yanlış kareyi 6'ya
   indiriyor, maliyeti 14337 sesli karenin 20'si (%0,14).
2. `unified::kDefaultLagFrames`: 5 → 8 (53,3 → 85,3 ms). Üç aynası da
   güncellendi: `core/include/klarivision/core/unified_pitch_constants.hpp`,
   `src/klarivision/pitch/cpp_engine.py:UNIFIED_DEFAULT_LAG_FRAMES`,
   `scripts/pitch_tournament_engines.py:UNIFIED_DEFAULT_LAG_FRAMES`. 8 hop
   seçildi çünkü 8 × 512 örnek = 4096 örnek = tam olarak
   `kSeriesCoherenceLookaheadSamples` — bkz. madde 3.
3. Seri tutarlılık vetosu artık canlı yolda da çalışıyor.
   `UnifiedPitchSession`, gelen her hopun ham örneklerini
   `kSeriesCoherenceLookaheadSamples` (4096 örnek) kapasiteli bir tampona
   yazıyor; fixed-lag decoder bir kareyi tam `lag_frames` hop sonra çözdüğü
   için, o an tampon o karenin kendi sınırından **hemen sonraki** 4096
   örneği tutuyor -- çevrimdışı yolun `collect_unified_evidence`'ta verdiği
   look-ahead ile örnek örnek aynı. `has_series_incoherence`
   (`core/src/harmonic_evidence.cpp` / `.hpp`) bu amaçla dosya-yerel
   olmaktan çıkarılıp public yapıldı, çünkü çözülmüş kareyi yeniden
   puanlamak (tüm `unified_frame_evidence`'ı tekrar koşmak) her hop'un
   maliyetini ikiye katlardı; kontrol yalnız `lookahead_samples`'tan
   kurulan spektruma bakıyor, `history`'ye hiç ihtiyaç duymuyor.

**Hedef ölçüm (canlı iz, `unified_trace`, 164,55–164,90 sn):** 9 → 6 (yalnız
oran kapısı) → **4** (oran kapısı + seri vetosu). Sıfıra inmedi. Kalan 4 kare,
etkilenen serinin en erken kareleri; aynı 4096 örneklik look-ahead'e karşı
bağımsız bir kontrol (offline'ın kullandığı örneklerin birebir aynısıyla)
de bu kareleri tutarlı okuyor -- yani bu bir hizalama hatası değil, ölçülmüş
bir gerçek. Offline'ın aynı pencerede 0 yanlış vermesinin sebebi seri
vetosunun bu 4 karede tetiklenmesi değil, **bütün-dizi Viterbi'sinin**
sonraki, doğru vetolanmış karelerin çektiği yolu geriye doğru
etkilemesi -- 8 hop'luk sabit-gecikmeli pencere bunu üretemiyor, çünkü
herhangi bir karenin TAM look-ahead'i hazır olduğu an, o kare zaten
çözülüyor olur; komşu bir kareye erken ödünç verilemez. Canlı kapsama
kaybolmadı: aynı izde toplam sesli kare 14337 → 14438 (+101, kayıp yok).

**Kapılar:**
- `./scripts/test_core.sh`: temiz (kv_unified_lag_frames() == 8 sözleşme
  doğrulaması dahil).
- Çevrimdışı yol bozulmadı: `pitch_track_cli`, Şükrü'de 164,63–164,80 sn'de
  hâlâ 0 yanlış kare, kapsama %81,79 (değişmedi).
- Turnuva: `serious_harmonic_error_frames` her kayıtta 0 (korunuyor).
  `holdout_adverse_v1` vetosu **23 → 24 kare** (2365 sesli karenin
  %1,01'i) -- kabul edilen istisna 1 kare kötüleşti.
  `tests/test_pitch_engine_tournament.py::test_unified_v1_missing_voiced_stays_inside_the_safety_bound[write_holdout-v1]`
  bu yüzden **düşüyor** (`assert 24 <= 23`); bu dosya görev kapsamının
  dışında olduğu için düzeltilmedi. Diğer tüm dondurulmuş holdout'lar
  (v1 clean/room, v2–v5) 0 kayıpla temiz kaldı.
- `.venv/bin/python -m pytest tests/ -q`: 99 geçti, 1 atlandı, **1 düştü**
  (yukarıdaki test). Sözleşme doğrulama testleri (`test_cpp_engine.py`)
  etkilenmedi.
- Dış karşılaştırma (development bölmesi, canlı yol, aynı komut):
  bach10 recall 0,9558 → 0,9400 (−1,58 puan), oktav 0,0004 → 0,0013;
  vocadito recall 0,9412 → 0,9310 (−1,02 puan), oktav 0,0006 → 0,0004;
  mdb recall 0,6974 → 0,6928 (−0,46 puan), oktav 0,0070 → 0,0025. Genel
  materyalde ötüm kaybı 0,5–1,6 puan; oktav hatası mdb ve vocadito'da
  belirgin iyileşti, bach10'da hafif kötüleşti. D-041'in offline ölçümüyle
  aynı yönde ve aynı büyüklük mertebesinde bir bedel.

**Sonuç:** hedef sıfıra inmedi (4 kare kaldı, gerekçesi ölçüldü); bir kabul
edilen istisna 1 kare kötüleşti ve buna bağlı pytest testi düşüyor; genel
materyalde 0,5–1,6 puan ötüm kaybı var. Kullanıcı 85 ms'yi zaten onaylamıştı
ama bu bedelleri bilerek onaylamış olmalı -- kayıt buradadır.

### Kabul edilmiş vetonun büyümesi (23 → 24) ayrıca onaylandı

`holdout_adverse_v1.wav`'da geri tutulan kare sayısı bu değişiklikle 23'ten
24'e çıktı ve `test_unified_v1_missing_voiced_stays_inside_the_safety_bound`
kırıldı. Bu testin varlık sebebi tam olarak budur: istisna **ölçülen değerinde**
savlanır ki sessizce büyüyemesin.

Sayı kullanıcıya tam bedeliyle sunuldu ve kullanıcı kabul etti. Karşılığında
alınan ölçülmüş kazanç:

| Ölçüt | 53 ms | 85 ms |
|---|---:|---:|
| Şükrü canlı iz, hedef pencerede yanlış kare | 9 | **4** |
| mdb_stem_synth oktav hatası (canlı yol) | 0,0070 | **0,0025** |
| vocadito oktav hatası (canlı yol) | 0,0006 | 0,0004 |
| bach10 oktav hatası (canlı yol) | 0,0004 | 0,0013 |
| bach10 / vocadito / mdb ötüm recall | 0,9558 / 0,9412 / 0,6974 | 0,9400 / 0,9310 / 0,6928 |

Yani en zor dış kümede oktav hatası **2,8 kat azaldı**; bedeli 0,5–1,6 puan
ötüm kaybı, bach10'da küçük bir oktav artışı ve bu bir kare.

**Hedef sıfırlanmadı ve sıfırlanamaz.** Canlı yolda 4 kare kaldı. Sebebi pencere
darlığı değil mimari: çevrimdışı yolun 0'a inmesi bütün-dizi Viterbi'sinin yolu
sonraki doğru-vetolanmış karelerden geriye yansıtmasından geliyor. Sabit
gecikmeli bir çözücü bunu üretemez — bir karenin tam ileri bakışı hazır olduğu
an o kare zaten çözülmüştür, komşusuna ödünç veremez. **Daha fazla gecikme bu
4 kareyi çözmez;** çözmek için canlı yolun sabit-gecikmeli olmaktan çıkması
gerekir, ki bu ayrı ve çok daha büyük bir karardır.

## D-041 — Çevrimdışı yola iki çekimserlik kuralı; canlı yol dokunulmadı

Kullanıcı bildirimi: Şükrü Tunar uşşak taksiminde `2:44,621`'de motor alt
harmoniğe düşüyor. Ölçüldü ve doğrulandı: `164,629–164,800 sn` arası 17 kare
`~149,4 Hz`, güven 0,99–1,00.

**Teşhis — klasik oktav hatası değil, EBOB (greatest common divisor) tuzağı.**
`298,8 Hz` notası sönerken `448,2 Hz` notası giriyor; oran tam beşli (3:2) ve
ortak alt katları `149,4 Hz` (= 298,8/2 = 448,2/3). Örtüşme boyunca toplam
sinyal gerçekten o periyotta periyodiktir, dolayısıyla ACF/pYIN haklı olarak
orada mükemmele yakın bir tepe görür — güvenin 1,000 olması bundandır. Ayrıca
`149,4` hem önceki notaya `f/2` hem yeni notaya `f/3` düştüğü için **süreklilik
cezası onu cezalandırmaz, ödüllendirir.** Bütün-dizi Viterbi'si çalışıyordu ve
bu hatayı hiç düzeltmiyordu (hizalanmış karşılaştırmada oktav düzeltmesi: 0).

**İki kural eklendi, ikisi de yalnız `offline_track` profilinde:**

1. `kHarmonicEvidenceRatioAbstainCeiling = 1.0` — `harmonic_dominance`
   *posterior*'dan okunur ve yoldan miras kalan atalet taşır; bir aday, ham
   kanıtı her karede rakibinden kötüyken bile bu tabanı birkaç kare geçebilir.
   `harmonic_evidence_ratio` bu ataleti taşımaz, ham karşılaştırmadır. Ölçüm:
   hedef karelerde oran 1,32–1,85 iken dominance 0,75 tabanının üstünde asılı
   kalıyordu.
2. Çevrimdışı düşük-register onayı — canlı yoldaki `low_register_confirmations`
   korumasının çevrimdışı eşdeğeri. Canlı yol beklemek zorundadır; çevrimdışı
   yol diziyi zaten görmüştür, bu yüzden komşuluğa tek geçişte bakar.
3. Seri tutarlılık vetosu (`has_series_incoherence`) — bir adayın kendi
   partiyel dizisinde ≥2 ardışık delik olup partiyelin geri dönmesi **ve**
   en güçlü partiyelin adayın kendi temelini `kSeriesCoherenceFundamentalDominanceRatio`
   (3,0) katından fazla aşması.

**İkinci koşul sonradan eklendi ve kararın özüdür.** Yalnız "delik-sonra-dönüş"
koşuluyla veto, dış development bölmesinde (96 dosya) ötüm kapsamasını 1,5–3,2
puan düşürüyor ve o kümelerde oktav hatasını **iyileştirmek yerine kötüleştiriyordu**
— çok sesli/vokal materyalde üst üste binen kaynaklar neredeyse her düşük
adayın serisine delik açıyor. EBOB hayaletini ayıran şey delik değil, enerjinin
nerede olduğudur: hayaletin "partiyelleri" başka gerçek notalardır, bu yüzden en
güçlüsü nominal temelini kat kat aşar (ölçüm: 0,0014 → 0,0067, 4,8 kat). Ek
koşulla kapsama kaybının %38–87'si geri alındı ve vocadito'daki oktav gerilemesi
tamamen giderildi.

**Sonuç (aynı 96 dosya, çevrimdışı yol, r1 → r3):**

| Küme | Kapsama r1 → r3 | Oktav r1 → r3 | GPE r1 → r3 |
|---|---|---|---|
| bach10 | 0,9709 → 0,9614 | 0,0002 → 0,0002 | 0,0312 → 0,0330 |
| mdb | 0,7168 → 0,7082 | 0,0088 → **0,0084** | 0,1294 → **0,1263** |
| vocadito | 0,9263 → 0,9226 | 0,0002 → 0,0002 | 0,1141 → **0,1127** |

Kapsama kaybı 0,4–1,0 puan (r2'de 1,4–2,4 idi). **Oktav hatası üç kümede de r1
seviyesinde veya altında**; mdb'de r1'in de altına indi. GPE üçte ikisinde
iyileşti, bach10'da hafif kötüleşti.

> Kayıt için: bu satırlar önce küme başına 8 dosyalık bir alt kümeyle
> yazılmıştı ve mdb'de `0,0021 → 0,0026` gibi bir oktav gerilemesi
> gösteriyordu. Tam 96 dosyalık koşu bunu çürüttü — o gerileme alt küme
> gürültüsüydü. Bu mekanizmanın etkileri küçük olduğu için alt kümeyle
> ölçülmemelidir.
Hedef kayıtta 17 yanlış karenin **tamamı** gitti (10 kare sessiz, 6 kare gerçek
`~448 Hz` perdeye döndü) ve kapsama `%82,03 → %81,79`.

**Kapılar:** turnuvada ciddi harmonik hata 30 kaydın hepsinde 0;
`holdout_adverse_v1` vetosu 23 kare (kötüleşmedi); `test_core.sh` ve oktav
tuzağı paketi temiz.

**Canlı yol kasten değiştirilmedi.** `kRealtimeAbstention`'daki oran tavanı
`+sonsuz` (hiç tetiklenmez) ve seri vetosu ileri bakış istediği için canlıda
yapısal olarak kapalıdır. Dolayısıyla **Çalma Modu'nda bu hata durmaktadır**;
canlı gecikme sözleşmesi (5 hop / 53,3 ms) korunsun diye böyle bırakıldı.
Taşınması ayrı bir karardır ve dış ölçüm bu mekanizmanın genel materyalde
bedava olmadığını gösterdiği için gerekçesi ayrıca kurulmalıdır.

**Ölçüm aracı düzeltildi:** dış karşılaştırma o güne dek yalnız **canlı** yolu
ölçüyordu (`unified_trace` → `process_frame`), yani çevrimdışı bir değişiklik
hakkında yapısal olarak kör. `--offline` bayrağı ve `unified_offline_frames()`
adaptörü eklendi; çıktı JSON'una hangi yolun ölçüldüğünü söyleyen `path` alanı
kondu. Bundan önce çevrimdışı yol için kaydedilmiş hiçbir dış sayı yoktur.

`OFFLINE_TRACK_REVISION`: `offline-unified-path-r1` → `offline-unified-path-r2`.

## D-040 — RMS kapısı dış veri kümelerine bakılarak değiştirilmez

Kullanıcı kararı, 6 Eylül 2026. "Klarnet dışı ötüm kapsaması" kalemi ölçüldü
ve **kapatıldı**: kapı olduğu yerde kalır, varsayılan `0,015` (−36,5 dBFS)
değişmez.

Gerekçe ölçümdür, tercih değil. Klarnet dışı materyalde kaçırılan ötümün
baskın sebebi çekimserlik politikası değil, sabit RMS kapısıdır (geliştirme
bölümünde mdb %26,6 / vocadito %14,6, çekimserliğin tamamı %4,2 / %2,0). Ama:

- **Projenin kendi donmuş yargıcı kapıyı suçlamıyor.** `adverse_v1` vetosunun
  23 ciddi eksik ötüm karesinin gerekçesi 17 `unvoiced`, 2 `contested`,
  2 `abstain-recovery`, **0 RMS kapısı**.
- Kapının baskın çıktığı tek yer, yeniden sentezlenmiş dış stem'ler. Onların
  seviyesi gerçek bir mikrofon zincirinin seviyesi değil ve kesilen karelerin
  dörtte üçü kapının 10 dB içinde — yani "duyulmayan malzeme" değil, "eşik
  başka bir sinyal zincirine göre konmuş".
- Bu tabloya bakarak eşiği indirmek, D-038'in kaydettiği kuralın ihlalidir:
  o tablo elimizdeki tek ayarlanmamış ölçüttür ve ona karşı ayar yapmak onu
  ölçüt olmaktan çıkarır.

Kapı zaten bir **ürün ayarıdır**: kullanıcı Ayarlar'da canlı VU metreye
bakarak `−60…−20 dBFS` arasında değiştirir. Sessiz kayıtta yapılacak şey
eşiği ürün genelinde indirmek değil, o ayarı kullanmaktır.

Bu kalem yeniden açılırsa gereken şey yeni bir eşik denemesi değil, **ürün
tarafından kanıttır**: sessiz çalınmış gerçek bir klarnet kaydında kapının ne
kadarını kestiğinin ölçümü. Dış kümeler bu soruyu cevaplayamaz.

## D-039 — Dört eski motor koddan çıkarıldı; `unified_v1` tek motordur

Kullanıcı kararı, 6 Eylül 2026. D-037'nin nihai hedefi uygulandı: `yin_v1`,
`pitch_engine_v2`, `vpm_like` ve `hapt_v1` kaynak, yapı, UI, betik ve test
düzeyinde kaldırıldı. D-038 bu adımı "ayrı bir turda yapılır" diye ertelemişti;
bu, o turdur. D-020'nin "eşit son kullanıcı seçenekleri" politikası da bununla
sona erer: seçilecek motor kalmadı.

**ABI numaraları donmuş kalır.** `KV_ENGINE_YIN_V1..HAPT_V1` (0–3) ve onların
yetenek bitleri başlıkta *rezerve* olarak durur; yeniden numaralanmaz, başka
bir motora verilmez. Kaldırılan bir motorun kimliğiyle oturum açmak **hata
döndürür**, hayatta kalan motora yönlendirilmez: istenmeyen bir motorun
çıktısını istenen motorun adıyla vermek, aşağı akışta hiçbir yerden
görülemeyecek tek hata biçimidir.

- `kv_pitch_contract_v1` yerleşimi değişmedi (iPad sert doğruluyor).
  `v2_fixed_lag_frames` alanı **rezerve**dir, `5` bildirmeye devam eder ve artık
  hiçbir şeyi tanımlamaz; canlı gecikme `kv_unified_lag_frames()`'tir.
- Yetenek maskesi artık yalnız `KV_CAP_ENGINE_UNIFIED_V1`, `..._PROFILE_*` ve
  `..._SOURCE_TIMESTAMPS` bitlerini kurar. Kaldırılan motorların bitleri
  konumlarında durur ve **temiz okunur**.
- `kv_v2_session_*` girişleri **başlıkta ve sembol tablosunda kalır**, hepsi
  temiz biçimde başarısız olur (create `NULL`, diğerleri `0`). v1'in dışa
  verdiği sembol kümesi donmuş sözleşmedir; v1'e karşı derlenmiş bir tüketici
  çözülemeyen sembol yerine teşhis edilebilir bir hata almalıdır.

**Kullanıcı seçimi geriye uyumlu düşer.** macOS `PitchEngineSettings`, iPad
`iPadAppState.engine(_:)` ve Python köprüsü, kaldırılmış bir motoru adlandıran
kayıtlı değeri `unified_v1`'e çözer. Üç ayrı kalıcılık anahtarı (Dinleme /
Çalma / Birlikte Çal) korunur. **Daha önce çözümlenmiş çalışmalar kendi
sonuçlarını ve kendi motor kimliğini korur**; görüntüleyici o kimliği
"(kaldırıldı)" etiketiyle doğru biçimde göstermeye devam eder. Motor seçici
arayüzlerin yerini, ne çalıştığını söyleyen tek bir satır aldı.

**Turnuva artık seçim yapmaz, ölçer.** `selection()` bir terfi mekanizmasıydı:
dört adayı `yin_v1` tabanına karşı sıralıyordu. Sıralanacak bir şey kalmadığı
için `benchmark_winner` / `default_engine` / `outcome` alanları kaldırıldı —
tek atlı bir yarışta kazanan ilan etmek, hiç yapılmamış bir kıyası yapılmış
gibi gösterirdi. Güvenlik kapısının **eşiği değişmedi**: "bir donmuş holdout
dosyasında hiçbir ciddi sınıf `yin_v1`'i 0,5 puandan fazla geçemez" kuralı,
`yin_v1` bütün donmuş holdout'larda sıfır aldığı için aynı sınırın mutlak
ifadesine (`SAFETY_RATE_LIMIT = 0.005`) dönüştü. Yalnız referans noktası
değişti.

D-038'in kayıtlı ölçümleri (turnuvanın `benchmark_winner=vpm_like` satırı
dahil) `outputs/` altındaki raporlarda kayıt olarak durur. Bu adımdan sonra o
kıyas **yeniden üretilemez**; kararın bilinen ve kabul edilen bedeli budur.

Kaldırılan geliştirme araçları: `check_v2_swift_python_parity.py`,
`check_vpm_swift_cpp_parity.py`, `calibrate_vpm_like_engine.py`,
`diagnose_sukru_vpm_divergences.py`, `pitch_engine_divergence_map.py` (+ HTML
şablonu), `run_pitch_regression_suite.py` (canlı-YIN ↔ pYIN kapısı) ve onun iki
`evaluate_*` tüketicisi, `pitch_track_cli`'nin `--diagnostic` kipi (üç
kaldırılmış motora aitti) ve Swift/Python motor aynaları.

## D-038 — `unified_v1` kazanan motordur; yeni kurulumların varsayılanı

Kullanıcı kararı, 6 Eylül 2026. D-037'nin "eski motorlar ölçümle geçilene kadar
kodda kalır" şartı karşılandı sayılır ve `unified_v1` projenin kazanan motoru
ilan edilir.

**Turnuvanın otomatik çıktısı değiştirilmedi.** Turnuva hâlâ
`benchmark_winner=vpm_like` ve `outcome=candidate_requires_parity` diyor; bu
kasten öyle bırakıldı. Sıralama her sınıftan ciddi hatayı eşit ağırlıkla sayar,
ürünün şartı ise asimetrik: **sessiz bir nokta harmonik hataya yeğdir.** Bu
şartı karşılayan tek motor `unified_v1` (ciddi harmonik hata 0; en yakın rakip
34, üretim varsayılanı 498). Karar bu yüzden ölçümü yeniden yazarak değil,
ölçümün üstüne konan bir ürün hükmü olarak veriliyor. İkisini ayrı tutmak,
elimizdeki tek ayarlanmamış ölçütü korur.

Dayanak ölçümler `TEST_BASELINE.md`'de: sentetik turnuvada ciddi harmonik hata
sıfır, yedi donmuş holdout'ta sıfır, 85/85 donmuş dinleyici kararı temiz, üç
dış veri kümesinde oktav hatası çevrimdışı pYIN referansının **altında**.

> **Düzeltme (6 Eylül 2026).** Bu paragraf en zor kümedeki farkı "5–10 kat"
> diye kaydetmişti; o sayılar, dış karşılaştırma koşucusundaki bir ızgara
> hatasıyla üretilmişti (motorun karelerinin üçte biri puanlanmadan siliniyordu;
> pYIN etkilenmiyordu). Düzeltilmiş ölçümde `mdb_stem_synth` oktav hatası
> `unified_v1` 0,0193, `pyin_vamp` 0,0661, `pyin_librosa` 0,1390 — yani
> **3,4–7,2 kat**. Kararın dayanağı ayakta, çarpanı düzeltildi; ayrıntı
> `TEST_BASELINE.md`'nin en üstündedir. Karar metni tarihçe olduğu için
> silinmedi, üstüne not düşüldü.

- Yeni kurulum varsayılanı `yin_v1` → **`unified_v1`** (macOS
  `PitchEngineSettings.initialEngine`, iPad `iPadAppState.engine(_:)` yedeği).
  **Mevcut kurulumlar etkilenmez:** her yüzey kendi `@AppStorage`/`UserDefaults`
  anahtarını okur, dolayısıyla uygulamayı bir kez açmış olan herkes seçimini
  korur. Beş motor da kullanıcı seçeneği olarak kalır (D-020).
- Bilinen ve **kabul edilen** açık: `holdout_adverse_v1.wav` vetosu (ciddi eksik
  ötüm 24 kare, sınır 12). Kullanıcı bunu şimdilik kabul etti. Veto satırı
  raporda görünmeye devam eder — susturulmadı.
- Bilinen ve **açık** ikinci konu: klarnet dışı materyalde ötüm kapsaması.
  (Buradaki "RPA 0,315–0,635" rakamları yukarıdaki ızgara hatasından etkilenmiş
  sayılardır; düzeltilmiş hâli 0,47–0,95'tir ve kalan açığın baskın sebebi
  ölçüldü: sabit RMS kapısı. Bkz. `TEST_BASELINE.md`.) Bu, dış karşılaştırma
  tablosuna bakılarak ayarlanamaz; ayrı bir doğrulama kümesi ayrılmadan bu
  konuya girilmez — o bölme artık `data/benchmarks/external-pitch-split-v1.json`
  içinde hazırdır.
- Dört eski motorun koddan çıkarılması (D-037'nin nihai hedefi) bu kararla
  **tetiklenmez**; ayrı bir turda yapılır. ABI numaraları 0–3 her hâlükârda
  kalıcıdır.

## D-037 — Birleşik motor (`unified_v1`) tek motor hedefiyle eklendi

Kullanıcı kararı: dört motor tek bir genel amaçlı motorla değiştirilecek,
harmonik hata sıfırlanacak, harmonik hata yerine sessizlik tercih edilecek,
aralık 80–1760 Hz olacak (sol klarnetin en üst notası La6, yazılı Re7), sinir
ağı kapsam dışı. Eski motorlar ölçümle geçilene kadar kodda kalır.

Dayanak `docs/OktavHatasi-Arastirma-Raporu.pdf`. Raporun teşhisi: klasik YIN
kare başına tek tahmin üretir ve f/3'ü seçtiği anda doğru cevap boru hattından
tamamen kaybolur; sonradan yumuşatma onu geri getiremez (pYIN makalesinin YIN+S
kontrolü recall'ı 0,935'ten 0,918'e **düşürüyor**). Çözüm üçlüsü: çoklu aday +
yol seçimi + harmonik spektral kanıt.

Mimari ve kalıcı kararlar:

- `PitchEngineId::unified_v1` / `KV_ENGINE_UNIFIED_V1 = 4` eklendi. Enum
  değerleri **sona** eklenir, 0–3 kalıcıdır: eski motorlar silindiğinde ABI
  yeniden numaralandırılmaz. Bir tüketici gerçekten kaldırılmalarına ihtiyaç
  duyarsa `KV_PITCH_C_ABI_V2` açılır, v1 mutasyona uğratılmaz.
- Gecikme `kv_unified_lag_frames()` ile açılır, `kv_pitch_contract_v1`'e alan
  **eklenmez**: struct yerleşimi kalıcı sözleşmedir ve iPad sert doğrular.
  `v2_fixed_lag_frames` yalnız v2'yi tanımlamaya devam eder.
- Canlı karar gecikmesi **5 hop ≈ 53 ms** — v2 ile aynı. Başlangıçta 15 hop
  (160 ms) seçilmişti; gerekçesi "oktav hataları medyan 2, en fazla 9 kare
  sürüyor, 5 karelik look-ahead çoğunun sonunu göremez" idi. **Bu gerekçe
  ölçümle çürüdü:** gecikme taramasında ciddi harmonik hata 5'ten 25'e kadar
  her değerde sıfır, sent hassasiyeti üç ondalığa kadar aynı. 160 ms'nin satın
  aldığı tek şey tuzak paketi kapsamasıydı (2171'e karşı 1696 yayımlanan kare),
  bedeli 107 ms canlı tepkisellik. Kullanıcı kararı: tepkiselliği al.
  Tarama `TEST_BASELINE.md`'de.
- Çekimserlik birinci sınıf bir sonuçtur. Sessiz durum yolun üzerinde bir
  durumdur, yoldaki bir boşluk değil — bu sayede çevrimdışı kod çözücü voicing'i
  yeniden ziyaret edebilir. Mevcut çevrimdışı iyileştirme bunu yapamaz: yalnız
  nedensel geçişin *yayımladığı* kareleri yeniden fiyatlandırabilir, dolayısıyla
  çekimser kalınmış bir kare ona kalıcı olarak kapalıdır.
- Çift/tek harmonik toleransı **ölçülür, varsayılmaz**. Klarnete sabit
  `{1,3,5,7}` yazmak motoru enstrümana özgü kılar ve başka her şeyde doğru
  notaları reddetmeye başlar. Parity indeksi **bağlanmış ize** demirlenir,
  test edilen adaya değil: adayda ölçülseydi bir f/3 hayaleti gerçek temeli
  kendi üçüncü harmoniği sanıp "tek-harmonikli" görünür ve eksik çift
  harmonikleri için kendine mazeret üretirdi.
- Paylaşılan `PitchEngineConfig` varsayılanları **değişmedi**: 120 Hz üretim
  tabanı dört eski motoru yönetmeye devam eder, birleşik oturum kendi 65 Hz
  kestirici tabanına içeride genişler. Varsayılanı düşürmek, kıyasın altındaki
  tabanı kaydırırdı.

Ölçülmüş sonuç ve bilinen sınır `docs/TEST_BASELINE.md`'dedir.

## D-036 — Dördüncü motor (Harmonik-Faz / `hapt_v1`) eşit son kullanıcı seçeneğidir

`hapt_v1`, D-020'nin "eşit son kullanıcı seçeneği" politikasına dördüncü,
bağımsız tasarlanmış bir motor olarak eklenir. Yöntem, sözleşme, kalibrasyon
kaynağı ve bilinen sınırlar `docs/HAPTPitchEngine.md`'dedir. D-020, D-031
(ortak C++ ABI v1 sözleşmesi) ve D-011 (VPM'in ACF'yi yalnız aşağı düzeltmesi)
şu şekilde genişler:

- `PitchEngineId::hapt_v1` / `KV_ENGINE_HAPT_V1 = 3` eklendi; ABI **sürümü 1
  olarak kaldı** (`KV_CAP_ENGINE_HAPT_V1` yetenek maskesine eklendi — başlığın
  kendi sözleşmesi bu genişlemeyi öngörüyor).
- `PitchEngineSettings.initialEngine` (`yin_v1`) değişmedi; dört motor da
  Dinleme ve Çalma Modu'nda eşit erişilebilir.
- YIN v1, Pitch Engine v2 ve VPM-benzeri'nin davranışı **değişmedi**.
- HAPT'ın Swift aynası yoktur (V2/VPM'nin aksine): `KLARIVISION_SWIFT_PACKAGE`
  derlemesinde `.hapt` her zaman `nil` döner. Ürün onu her zaman üretim C++
  çekirdeği üzerinden çalıştırır.
- Eşikler yalnız turnuva holdout v1–v5 üzerinde kalibre edildi; v6 dondurulmuş
  kabul kümesi yalnız tek, son doğrulama koşusunda kullanıldı (bkz.
  `docs/PITCH_ENGINE_USER_OPTION_ACCEPTANCE_V1.md`).
- Fiziksel klarnet/mikrofon kabul oturumu (D-035'teki gibi bir fiziksel kapı)
  HAPT için henüz yapılmadı; otomasyon bunun yerine geçmez.

## D-035 — Mobil fiziksel harici ses rotası kapısı Bluetooth'tur

iOS/iPadOS fiziksel kabulünde zorunlu harici ses rotası senaryosu Bluetooth
bağlanması, aktif Bluetooth rotasına geçiş, bağlantının kesilmesi ve dahili
rotaya dönüş döngüsüdür. Bu kapı; audio tap, C ABI pitch oturumu, WAV yazıcı
ve `AVAudioSession` kapanışının güvenli ve yinelenebilir olduğunu, rota
kapanışından sonra otomatik yeniden başlatma olmadığını doğrular.

Kablolu kulaklık ve diğer rota varyantları ayrı fiziksel dağıtım kapısı
değildir; ortak rota politikası ve teardown otomasyonlarıyla kapsanır.
Bluetooth kapısı gerçek iPhone ve gerçek iPad kabulünün diğer maddelerinin
yerine geçmez. İki fiziksel cihaz kapısı tamamlanmadan TestFlight/App Store
hazırlığı başlatılmaz.

## D-034 — Evrensel iPhone+iPad ürünü kullanıcı yetkisiyle başlatıldı

Kullanıcının açık yetkisiyle D-032'nin “yalnız teknik spike, ürün başlatılmaz”
sınırı iOS/iPadOS için geçersiz kılındı; D-032 teknik kanıtın tarihçesi olarak
korunur. Ürün hedefi iOS/iPadOS 17+ SwiftUI uygulamasıdır ve aynı uygulama
hedefinde `TARGETED_DEVICE_FAMILY = "1,2"` ile iPhone ve iPad'i kapsar.
`KlariVisionCore` statik
hedefi, üretimde de yalnız C ABI v1 üzerinden bağlanır.

Yerel ve ağsız uygulama kabuğu regular genişlikte `NavigationSplitView`,
compact genişlikte üç sekmeli `TabView` kullanır. Dinleme ve Çalma rotaları
compact düzende tab bar'ı gizleyen çalışma ekranlarıdır. Dinleme ve Çalma
motor seçimi ayrı kalıcıdır;
YIN v1, Pitch Engine v2 ve VPM-benzeri nötr ve eşit kullanıcı seçenekleri
olarak kalır. Bu karar otomatik makam tespiti, bulut/ağ veya motor
algoritması/eşik değişikliği yetkisi vermez.

Yerel dosya+Dinleme ve izin/lifecycle kurallarına bağlı Çalma dilimleri
`docs/ipad-ui-ux/` sözleşmesine ve D-027/D-028'in tek WebKit kimliği ilkesine
uyar. Bundle kimliği, UserDefaults anahtarları ve `Studies-v1.json` biçimi iki
cihaz ailesinde ortaktır.

## D-033 — Android yalnız C ABI v1 NDK spike'ı ile değerlendirilir

Android ürün başlatılmış değildir. Yetki verilirse ilk Android işi, NDK ile
`arm64-v8a` C++ core ve küçük JNI kontrat testini derleyen sınırlı bir spike'tır.
Kotlin yalnız `analysis_engine_c.h` C ABI v1'i çağırır; motor kararını yeniden
uygulamaz. Üç motorun eşit kullanıcı seçeneği, PCM/zaman sözleşmesi ve yerel
veri sınırı D-020/D-031 ile aynıdır.

Bu spike Compose ekranı, WebView, AudioRecord, dosya alma, kayıt, ağ veya
dağıtım ürünü içermez. Tam Android ürününe geçmek için ayrıca kullanıcı kararı
gerekir; D-007 ve D-027'nin ortak çekirdek/web grafik yönü sürer.

## D-032 — iOS/iPadOS yalnız C ABI v1 teknik spike'ı ile değerlendirilir

Mobil ürün başlatılmış değildir. Yetki verilirse ilk iOS/iPadOS işi, yalnız
`analysis_engine_c.h` C ABI v1'i cihaz ve simulator arm64 için bağlayan küçük
bir derlenebilir smoke hedefidir. Swift, C++ motor kararını yeniden uygulamaz;
üç motor kimliği, 48 kHz mono Float32 PCM, pencere/hop, kaynak zamanı ve
yaşam döngüsü D-031'deki sözleşmeyle aynıdır.

Bu spike ekran, mikrofon, kayıt, WebKit, dosya içe aktarma, ağ veya dağıtım
ürünü içermez. Tam mobil ürün için ayrıca kullanıcı kararı gerekir. D-007 ve
D-027'nin ortak çekirdek/WebKit yönü sürer; D-020'nin üç eşit motor politikası
mobil tüketicide de aynen geçerlidir.

## D-031 — Ortak C++ pitch sınırı v1 sözleşmesidir

Üç son kullanıcı motoru ortak `ProductionPitchSession` C++ sınırından geçer.
C ABI v1 motor kimliğini, mono 48 kHz Float32 PCM'i, 1536/512 standart
pencere-hop'u, kaynak-zaman merkezini, yaşam döngüsünü ve kare sahipliğini
sabitler. Python, aynı sınırın `pitch-track-cli --contract` projeksiyonunu
doğrular. Motor eşikleri C++ otoritesindedir; Swift yalnız kullanıcı sinyal
kapısı ve UI dönüşümünü taşır. Ayrıntı: `PITCH_ENGINE_C_ABI_V1.md`.

## D-030 — WebKit üretim grafiği, eski SwiftUI Canvas anlatımını geçersiz kılar

D-027, Dinleme ve Çalma için üretim grafik yoludur: iki akış WebKit canvas
kullanır. D-025'in ortak renk rolleri, kalıcı hex profili ve çizgi kuralları
geçerliliğini korur; ancak oradaki SwiftUI Canvas'ın üretim çizicisi olduğu
tarihsel anlatım D-027 tarafından geçersiz kılınmıştır. Swift/AppKit görsel
tipleri yalnız destek, test ve tanılama yüzeyleri olarak kalabilir.

## D-029 — Tema uygulama genelinde tek kalıcı tercihtir

Çalışma odaklı, Stüdyo ve Sıcak klasik görünümü dosyaya veya HTML
görüntüleyiciye ait değildir. Seçim Genel Ayarlar'da tutulur ve ana pencere,
kenar çubuğu, Dinleme, Çalma, ayarlar ile native görüntüleyiciye birlikte
uygulanır. Bağımsız açılan eski HTML görüntüleyiciler kendi yerel tema
davranışını korur.

## D-028 — Dinleme köprüsü tek WebKit örneği ve enterpole edilmiş zamanı kullanır

Uyarlanabilir Dinleme yerleşiminde aynı medya görünümünü alternatif düzenlere
iki kez yerleştirmek yasaktır: tek `WKWebView` korunur ve genişlik eşiği yalnız
yerleşim yönünü değiştirir. Böylece SwiftUI komut köprüsü görünmeyen bir medya
örneğine bağlanamaz.

WebKit'in periyodik zaman snapshotları otoritatif medya konumudur; SwiftUI
grafiği oynatma sürerken bu iki snapshot arasındaki zamanı oynatma hızına göre
enterpole eder. Ham/yan analiz JSON'u eksik eski çalışma HTML'lerinde, aynı
HTML'e gömülü zaten hazırlanmış `frames` verisi yalnız görüntüleme geri dönüşü
olarak kullanılır. Bu geri dönüş analiz sonucunu veya kullanıcı verisini
değiştirmez.

## D-027 — Dinleme ve Çalma WebKit canvas çizim yolunu kullanır

Dinleme çalışma HTML'indeki medya ve grafikle aynı JavaScript canvas
`requestAnimationFrame` saatini kullanır. Çalma'nın mikrofon ve pitch motoru
native kalır; üretilen kareler en çok 30 Hz toplu JSON mesajlarıyla ayrı WebKit
canvas yüzeyine aktarılır. SwiftUI/AppKit grafik renderer'ı iki modun üretim
yolunda kullanılmaz.

Bu ayrım iOS `WKWebView` ve Android `WebView` için ortak bir web grafik
çekirdeğine uygundur. Tema, makam, yakınlaştırma ve takip davranışları mesaj
sözleşmesiyle taşınır; pitch motoru, fiziksel frekans ve kullanıcı analiz
dosyaları değişmez. Dinleme eğrisi mevcut HTML'e gömülü hazır `frames` verisini
ve taşınabilir bağımsız görüntüleyici davranışını korur.

Medya köprüsü zaman, süre, oynatma, tema, A/B ve loop durumunu SwiftUI'a
aktarır; SwiftUI arama işlemi saniye değerli `seek` komutuyla geri gönderilir.
Köprü nesnesi bulunmayan eski çalışma HTML'lerinde uygulama aynı minimum
snapshot/komut arayüzünü medya öğesinin üstüne kurar. Bu karar pitch motorunu,
fiziksel frekansı veya kullanıcı analiz dosyalarını değiştirmez.

## D-026 — Mod ayarları ortak, kaydırılabilir yerel pencere kullanır

Dinleme ve Çalma Modu ayarları aynı SwiftUI pencere kabuğunu kullanır: üstte
taslağı kaydetmeden kapatan `Bitti`, ortada kaydırılabilir içerik ve altta her
zaman görünür `Uygula` alanı bulunur. Dinleme, güncel değerleri WebKit
görüntüleyiciden anlık görüntü olarak alır; yalnız geçerli taslak uygulandığında
tema, grafik renkleri, makam/karar, geri sayım ve makam aralıklarını birlikte
geri yazar. Bağımsız HTML görüntüleyicinin kendi ayar diyaloğu da ekran
yüksekliğine göre kaydırılır.

## D-025 — Grafik renkleri iki modda tek profildir

Dinleme ve Çalma grafikleri iki ortak renk rolünü paylaşır: ölçülen pitch
eğrisi ve nota kılavuz çizgileri/etiketleri. Profil `#RRGGBB` olarak uygulama
ayarlarında saklanır; bozuk değerler varsayılan `#0A84FF` ve `#8E8E93`
renklerine geri döner. İki grafik de uygulama içinde SwiftUI Canvas kullanır;
bağımsız HTML görüntüleyici aynı renkleri kendi taşınabilir canvas çiziminde
kullanır.

Tema, arka plan, zaman ızgarası, A/B işaretleri, oynatma çizgisi ve tüner bu
profilin dışındadır. İki çizici pitch için `1.7 pt` yuvarlak çizgi ve `40 ms`
üzerindeki zaman boşluklarında kesinti kuralını paylaşır.

## D-024 — Dinleme ve Çalma ortak, sabit ibreli tüner kullanır

Dinleme ve Çalma Modu aynı SwiftUI tüneri kullanır. Üçgen ibre sabittir;
ölçülen perdeye göre kayan cetvel, ibrenin iki yanında toplam `±200 sent`
bağlam gösterir. Kromatik satır 100 sent aralıklarla bemol/diyez eşadlarını
birlikte yazar; makamlarda bunun altında seçili kullanıcının 53-koma dizisinin
mevcut `♭/♯ + koma` etiketli perdeleri bulunur. Dar pencerede tüner
denetimlerin altına iner, cetvel ve etiketler saklanmaz.

Dinleme Modu yalnız mevcut çevrimdışı pitch karesini aktarır; Çalma Modu
yalnız canlı `currentFrequency` akışını kullanır. Bu karar fiziksel frekans,
Sol klarnet transpozisyon katmanı, makam hedefleme, pitch motorları veya
sinyal eşiğini değiştirmez.

## D-023 — Çalma Modu yalnız canlı pitch deneyimidir

Çalma Modu son kullanıcıya canlı pitch eğrisi, tüner ve mikrofon denetimini
sunar. Başlık ve kompakt tüner aynı üst satırı paylaşır; grafik kalan dikey
alanı öncelikli kullanır. Makam/karar bağlamı ile anlık frekans/nota metinleri
üst bölümde gösterilmez; makam ve karar seçimi alt şeritte kalır. Alt şeritte
görünür ancak devre dışı bir Kayıt düğmesi bulunur. Referans eğrileri, hata
sınıfları, dosyadan motor testleri, raporlar ve motor tanılama denetimleri bu
yüzeyde gösterilmez.
Tanılama ve regresyon altyapısı korunur; motor seçimi Ayarlar'daki mevcut
kullanıcı tercihiyle sürer. Bu karar analiz motorunu veya ölçülen pitch verisini
değiştirmez.

## D-022 — Başlangıçta iki eşit mod, yalnız yerel dosya girişi

Başlangıç ekranı Dinleme Modu ve Çalma Modu'nu eşit öncelikte sunar. Dinleme
Modu yerel ses/video dosyasını, Çalma Modu mikrofon akışını açar. Çevrimiçi
bağlantı girişi ürün yüzeyinde tutulmaz. Bu adlandırma motorun veya fiziksel
pitch verisinin davranışını değiştirmez; çalışma alanındaki üç görsel mod
(Çalışma odaklı, Stüdyo ve Sıcak klasik) aynen korunur.

## D-021 — V2 sabit gecikmesi açık sonlandırmayla tamamlanır

Pitch Engine v2, akış sürerken beş-hop sabit gecikmesini korur. Akış
sonlandığında elde kalan kaynak kararları yapay sessizlik pencereleriyle değil,
aynı gerçek aday tamponunun küçülen bakışıyla çözülür. `finish` tek-seferliktir
ve oturumu terminal yapar; yeni giriş için `reset` gerekir. Hızlı release
oda kuyruğunu yayınlamaz; yavaş, destekli kontur ile yalnız `±90 sent` aynı
kontura dönen en çok yedi karelik dropout korunur.

## D-001 — Yerel öncelikli ürün

Kullanıcı sesleri, videoları, analizleri ve çalışma geçmişi varsayılan olarak
yerel kalır. Bulut ve paylaşım özellikleri daha sonra, açık kullanıcı kararıyla
eklenir.

## D-002 — Pitch görselleştirme ana ürün değeridir

Süsleme tespiti uzun vadeli araştırma alanıdır; ana geliştirme akışı güvenilir
pitch eğrisi, dinleme, tekrar ve öğrenme deneyimine odaklanır.

## D-003 — Makam ve karar kullanıcı seçimidir

İlk ürün otomatik makam tanımaz. Makam/karar seçimi grafik referans çizgilerini
ve nota adlandırmasını belirler.

## D-004 — Fiziksel pitch ile nota gösterimi ayrıdır

Grafik duyulan fiziksel frekansı korur. Sol klarnet transpozesi veya makam
adlandırması yalnız gösterim katmanını değiştirir; ölçülen Hz değerini taşımaz.

## D-005 — Çevrimdışı referans pYIN'dir

Vamp pYIN, dosya analizindeki yüksek çözünürlüklü ve kararlı referanstır.
Gerçek icrada kesin gerçek-değer değildir; yalnız iki motorun da sesli kabul
ettiği karelerde karşılaştırma yapılır. Sentetik hedef eğri bulunduğunda asıl
gerçek-değer odur.

## D-006 — Kararlı YIN v1 korunur

Normal canlı mikrofon yolu YIN v1'dir. Deneysel motorlar ayrı seçilir ve sayısal
regresyon tabanını geçmeden varsayılan kullanıcı yoluna bağlanmaz.

## D-007 — Ortak motor C++ çekirdeğinde yaşamalıdır

macOS/iOS SwiftUI ve Android Jetpack Compose arayüzleri aynı C++ analiz
çekirdeğini kullanacaktır. UI, medya seçimi ve platform izinleri yerel kalır.

## D-008 — Pitch Engine v2 ayrı deneydir

V2; MPM/NSDF adayları, SWIPE′ benzeri asal-harmonik puanlama ve yaklaşık
5 kare/50–55 ms sabit gecikmeli yol seçimi kullanır. Kararlı v1 kodunun içine
örtük biçimde karıştırılmaz.

## D-009 — VPM-benzeri motor bağımsız ve dürüst adlandırılır

Motor, Tadao Yamaoka'nın açıkladığı ilkelerden esinlenir; Vocal Pitch Monitor'ün
kodu veya doğrulanmış birebir uygulaması değildir. Arayüz ve raporlarda
“VPM-benzeri” olarak adlandırılır.

## D-010 — Kullanıcıya motor/eşik karmaşası verilmez

Geliştirme sırasında motorlar ve ayrıntı modları tanılama menüsünde bulunabilir.
Son kullanıcı sürümünde güvenilir tek varsayılan davranış sunulur; harmonik
eşikleri veya “hızlı/dengeli” gibi motor ayarları kullanıcıya yüklenmez.
Sinyalin işlenip işlenmeyeceğini belirleyen ortak giriş seviyesi bunun
istisnasıdır: kullanıcı bu fiziksel sınırı dBFS kaydırıcısı ve canlı VU metreyle
ayarlayabilir; motorların perde/harmonik karar eşikleri yine gösterilmez.

## D-011 — VPM-benzeri spektrum kontrolü ACF'yi yalnız aşağı düzeltir

Spektral `1/3`, `1/2`, `1x`, `2x`, `3x` adayları tanılamada korunur; seçim
yalnız ACF sonucundaki eksik temeli aşağı yönde düzeltebilir. Keskin bir üst
harmonik, yüksek-periodicity ACF temelini `2x/3x` değerine yükseltemez. Bu kural
C++ ve Swift uygulamalarında birlikte korunur; mutlak spektral destek eşiği
`0.005`tir. Aşağı düzeltme ayrıca yalnız ACF'nin seçtiği erken tepe en güçlü
ACF tepesi değilse yapılır. ACF zaten en güçlü tepeyi seçmişse spektrum sonucu
`f/2` veya `f/3` değerine indiremez.

## D-012 — Canlı motor seçimi sentetik gerçek-değerli turnuvayla yapılır

pYIN gerçek icrada tanısal karşılaştırma ve ayrışma bulma aracıdır; canlı motor
seçiminde gerçek-değer sayılmaz. YIN v1, Pitch Engine v2 ve VPM-benzeri motor
aynı pencere/hop ve kaynak zaman ekseninde matematiksel hedefli sentetik
klarnet kayıtlarıyla ölçülür. Geliştirme seti eşik çalışmasına açıktır; sürümlü
holdout sonucu görüldükten sonra aynı holdout'a göre ayar yapılmaz.

Sayısal benchmark kazananı ancak üretim C++/Swift iz paritesi ve canlı gerçek
zaman profili doğrulanırsa varsayılan olabilir. Bu kapı geçilmediğinde kararlı
YIN v1 kullanıcı varsayılanı olarak kalır.

Turnuva doğruluğu kapsama, p95 veya hata yüzdeleriyle ölçülmez. Her sentetik
referans karesi beşli muhasebeye girer; sayısal kazanan bütün sentetik WAV'lar
üzerinde önce en düşük ciddi hata, eşitlikte en düşük ciddi olmayan ham hata,
sonra doğru-perde karelerinin ortalama mutlak sent farkı ve gecikme ile
seçilir. YIN'e göre hata-sınıfı vetosu ve C++/Swift parite kapısı kazananı
değiştirmez; yalnız kullanıcının varsayılan motoruna terfi kararını sınırlar.

8 Ağustos 2026'da holdout v1 kullanıcı denemesi ve aday teşhisi için doğrudan
kullanıldı. Bu nedenle v1, bu tarihten sonraki güçlü-ACF kilidi değişikliğinin
bağımsız kabul kanıtı değildir; motor terfisi öncesinde görülmemiş parametreli
yeni bir kilitli holdout sürümü gerekir.

## D-013 — Algılanabilir hata ham muhasebeden ayrıdır

Sentetik gerçek-değer doğrulaması ham beşli kare muhasebesini eksiksiz
saklar. Kullanıcıya gösterilen renkli hata katmanı ve motor turnuvası ise
algılanabilir hata katmanını kullanır: `≤50 sent` doğru, `50–100 sent` yakın
uyarıdır; diğer hata sınıfları yalnız hedef rejimi geçişinin `±30 ms` dışında
en az üç ardışık analitik kare sürerse ciddidir. Ham tekil/geçiş hataları
tanılama ayrıntısında soluk gösterilir; eğri veya motor eşikleri değişmez.

## D-014 — Düşük sinyal motor ve matematiksel hedefte birlikte boştur

Canlı YIN, öz-ilinti, Pitch Engine v2 ve VPM-benzeri yolları, DC bileşeni
çıkarılmış analiz penceresi RMS'i ortak eşiğin kesin olarak altındaysa aday
üretmez. Varsayılan `RMS 0.015` (yaklaşık `−36.5 dBFS`) değeridir. Seviye
kapısıyla reddedilen kaynak karesi kısa-boşluk köprüleriyle geri doldurulamaz.

Sentetik doğrulamada dondurulmuş formül manifesti değiştirilmez. Her WAV'ın
etkin matematiksel hedefi aynı merkezlenmiş RMS penceresiyle çalışma anında
üretilir ve eşik altındaki hedefler `null`/sessiz sayılır. Ayar oturum sırasında
değişirse yalnız sonraki karelerde uygulanır ve kaynak-zamanlı eşik geçmişi
doğrulama raporunda saklanır. Normal çevrimdışı pYIN bu kapıya dahil değildir.

## D-015 — Son kullanıcı pitch yolu üç taşınabilir C++ motordur

Ürün çalışma ve canlı seçimleri `yin_v1`, `pitch_engine_v2` ve `vpm_like`
ile sınırlıdır. Yeni çalışma analizleri yalnız Ayarlar'da seçili motorla
yürütülür ve motor kimliği ile `offline_track` profil sürümü cache anahtarına
dahildir. Vamp pYIN, ürün paketi veya otomatik fallback değildir; masaüstü
geliştirme karşılaştırmalarında tanısal referans olarak kalabilir.

Çalışma profili, canlı profilin aday üretimini koruyup tüm dosya bağlamında
motor başına ayrı yol çözümü kullanabilir. Bu, çizgiyi hareketli ortalamayla
yumuşatmak değildir: seçilen her perde motorun gerçek adaylarından biri
olmalıdır; açık ve uzun sessizlikler sesli olarak doldurulmaz.

## D-016 — Pitch Engine v2 üretimde tek durumlu C++ oturumudur

V2 aday üretimi (YIN, öz-ilinti, MPM ve spektral ortak aday), SWIPE′
asal-harmonik desteği, beş-hop sabit-gecikmeli yol, `0.70` yayın kapısı,
yüksek-register kanıtı, iki-onaylı aşağı harmonik koruması ve en çok yedi
karelik aynı-kontur boşluk köprüsü tek C++ oturumunda yaşar. C ABI kaynak
analiz penceresinin merkez zamanını alır ve sıfırlanabilir canlı oturum sunar.

Swift mikrofon/UI katmanı ile Python turnuva adaptörü bu oturumu kullanır.
Swift ve Python algoritma aynaları üretim seçimine katılmaz; yalnız sayısal
geçiş kanıtı ve ayrışma teşhisi için korunur. Bu geçiş kararlı YIN v1
varsayılanını değiştirmez.

## D-017 — Canlı ve Çalışma aynı nedensel C++ oturumunu kullanır

`yin_v1`, `pitch_engine_v2` ve `vpm_like` motorlarının her biri canlı mikrofon
ve dosyadan Çalışma için aynı `ProductionPitchSession` C++ sınırından geçer.
Swift canlı katmanı pitch kararı vermez; pencereyi ortak oturuma verir ve
oturumun yayımladığı kaynak-zamanlı kareyi çizer. Böylece Çalışma'nın
`causal_baseline` izi aynı PCM kareleri için canlı üretim iziyle yapısal olarak
aynıdır.

`offline_track_v1`, bu izin ardından ayrı ve sınırlı bir iyileştirme aşaması
çalıştırabilir. Bu aşama RMS altındaki kareyi sesli yapamaz, zamanı kaydıramaz,
yeni perde sentezleyemez veya doğru nota geçişini yumuşatamaz. Güncel kabulde
YIN ve VPM izi değiştirilmez; yalnız V2'nin sabit gecikme kuyruğu dosya sonunda
özgün kaynak zamanlarıyla boşaltılır. Görülmüş holdout sonucuna göre eşik
ayarlanmaz ve bu mimari karar YIN v1 varsayılanını değiştirmez.

## D-018 — VPM yayın katmanı dropout ve release'i tek durum makinesinde ayırır

VPM kare kestiricisinin ACF/spektrum kararları ve `0.80` normal yayın eşiği
kalıcı sözleşmedir. Ortak `ProductionPitchSession` yalnız yayın durumunu yönetir:
güçlü ankraj, en çok yedi kaynak karesi bekleyen boşluk, nedensel release
şüphesi ve kurulmuş kontura bağlı zayıf tutma. Bekleyen boşluk yalnız aynı
kontura `±90 sent` içinde dönüşte tamamlanır; farklı perde, süre aşımı veya
gerçek release boşluğu atar.

Kurulmuş üst konturun doğrudan çizgisi düşük `f/2`/`f/3` aday çizgisinden en
az `2.5x` güçlüyse mevcut kontur korunabilir. Bu kanıt yalnız veto içindir;
yeni üst aday üretmez ve D-011'i değiştirmez. Swift canlı ve Çalışma C ABI
üzerinden aynı C++ durum makinesini kullanır. VPM deneysel kalır; YIN v1 ve V2
kod yolları bu karardan etkilenmez.

## D-019 — Referans–öğrenci karşılaştırması ürün kapsamında değildir

Kullanıcı iki kaydın pitch eğrilerini ortak zaman ekseninde üst üste gösteren,
elle başlangıç ofseti ve ortak A/B dinleme sunan bir karşılaştırma modunu
uygulamada istememektedir. Bu akış, puanlama veya otomatik hizalama içerse de
içermese de kullanıcı yeniden açıkça talep etmedikçe geliştirilmez.

## D-020 — Üç pitch motoru eşit son kullanıcı seçeneğidir

`yin_v1`, `pitch_engine_v2` ve `vpm_like`, hem Dinleme hem Çalma Modu'nda
kalıcı ve eşit derecede erişilebilir son kullanıcı seçimleridir. Ürün bu üç
motor arasında kazanan, önerilen veya terfi edilecek bir motor seçmez. İlk
açılıştaki YIN v1 seçimi yalnız mevcut kurulumların davranışını koruyan geriye
uyumlu başlangıç değeridir; kalite sıralaması değildir.

D-006, D-010 ve D-012'nin kararlı/deneysel, tek varsayılan ve terfi anlatımı
tarihsel teknik bağlam olarak korunur; bu karar onların ürün politikası
sonucunu geçersiz kılar. Sentetik turnuvalar, parite ve gerçek-zaman ölçümleri
üç motorun regresyon güvenliği içindir; varsayılanı değiştiren veya kullanıcıya
bir motor öneren karar mekanizması değildir. Motor kimliği ile
`offline_track` profil sürümünün çalışma önbelleği anahtarında kalması
zorunludur.

## D-043 — Android ürünü başlatıldı; taşınabilirlik kanıtlandı

Kullanıcı kararı: Android'e **tam ürün paritesi** hedefiyle geçilmesi, araç
zincirinin kurulması ve kabulün fiziksel cihazda yapılması. D-034'ün
iOS/iPadOS için verdiği yetkinin Android karşılığıdır. `docs/ANDROID_FEASIBILITY.md`
"yalnız teknik spike için koşullu go" konumundaydı; bu karar onu aşar.

**Çekirdek taşınabilirliği artık ölçüm, akıl yürütme değil.** 13 Ağustos'tan
beri açık duran `arm64-v8a` compile/link smoke koşuldu ve **tek satır C++
değişikliği olmadan** geçti. Ön koşullar zaten yerindeydi: sıfır üçüncü parti
bağımlılık, elde yazılmış FFT, `if(APPLE)` ile sınırlı Accelerate bağlantısı ve
`pyin_ladder.cpp`'deki tek `vDSP_dotpr` çağrısının hazır skaler `#else` yolu.

**Üç kalıcı değişiklik:**

1. `core/src/pyin_ladder.cpp`'ye `__aarch64__` korumalı NEON iç çarpım yolu.
   Gerekçe ölçümdür: optimize skaler yol SM-A736B'de pencere başına p50
   10,71 ms üretiyordu ve hop bütçesi 10,667 ms'dir — yani canlı yol gerçek
   zamanın **üstündeydi** (RTF 1,004). NEON ile p50 9,18 ms, RTF 0,86.
   Apple `vDSP_dotpr` yolu ve taşınabilir skaler yol değişmedi. Sayısal not:
   vektör toplama sırası skalerden farklıdır, ancak `vDSP_dotpr` zaten
   vektör toplaması yapar — NEON, Android'i macOS'tan uzaklaştırmaz,
   ona yaklaştırır.

2. `android/core` debug varyantı da `CMAKE_BUILD_TYPE=RelWithDebInfo` ile
   derlenir. NDK debug varsayılanı `-O` bayrağı vermez; DSP çekirdeği o hâlde
   RTF **7,68** ile çalışır ve canlı yol hiç sınanamaz. Ölçümdeki en büyük
   kaldıraç NEON değil, native kodun optimize edilmesiydi (7,68 → 1,004).

3. `StudyViewer.html`'deki oynatma köprüsü platformdan bağımsız hâle getirildi:
   WebKit `messageHandlers` yoksa Android `@JavascriptInterface` global'ine
   düşer ve nesneyi `JSON.stringify` ile taşır. Bu, tüm ağaçtaki tek WebKit'e
   bağımlı satırdı. iOS yolu `||` kısa devresiyle birebir korunur; macOS
   Debug derlemesi ve C++/Python kapıları değişiklikten sonra yeniden geçti.

**C ABI v1 dondurulmuş kalır.** Android yalnız `KV_ENGINE_UNIFIED_V1` (4)
kullanır; 0–3 rezervedir. 48 kHz mono Float32, `1536/512` pencere/hop ve
pencere merkezi kaynak zamanı sözleşmesi değişmedi.

**Sözleşmede kapatılan açık:** fizibilite belgesi baştan beri "yanlış byte
sırası açık hatadır" diyordu; ilk JNI katmanı bunu doğrulamıyordu. Kusur
cihazda ortaya çıktı — 440 Hz sinüs 160 Hz okundu, aynı sinyal host
çekirdeğinde 440,00 Hz verdi. Sebep Java `ByteBuffer.allocateDirect`
varsayılanının BIG_ENDIAN olmasıdır. Üretim kodu doğruydu; doğrulama eksikti.
Artık yerel olmayan byte sırası açık hatayla reddedilir ve regresyon testi
vardır. Bu kusurun imzası çökme değil, **makul görünen yanlış bir pitch**tir.

**Açık risk:** RTF payı %14'tür (bütçenin %86'sı), tek cihazda, sentetik
sinyalle, tek çalıştırmada ölçüldü. Termal kısıtlama ve daha zayıf cihazlar bu
payı yiyebilir. Masaüstü rakamlarının Android kabulü olmadığı kuralı bu sayı
için de geçerlidir: ölçüm **SM-A736B'ye** aittir.

**Kapsanmayan:** fiziksel kullanıcı akış kabulü (mikrofon, kayıt, SAF içe
aktarma, A/B döngüsü, rota/kesinti, yön değişimi) **NOT RUN**'dır — başarısızlık
değil, yapılmamış turdur. `x86_64` emülatör ABI'si eklenmedi; 32-bit ABI
eklenmez. Ağ, bulut, paylaşım ve puanlama kapsam dışıdır.
