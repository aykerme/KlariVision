# KlariVision Test Tabanı

## Turnuva kapısı deliği göremiyordu — 8 Eylül 2026

**Motor oktav tuzağına yanlış nota vererek değil, susarak giriyordu; tabela
bunu tam puanla ödüllendiriyordu.**

Turnuvanın sert kapısı `serious_harmonic_error_frames == 0`. Susmak harmonik
hata değildir, dolayısıyla `klarivision_octave_trap_suite_*` üzerinde
`unified_v1` temiz sayfa alıyordu — oysa çevrimdışı (Dinleme Modu) yolda dört
bölüm **hiç kare yayımlamıyor**:

| Bölüm | clean | room | adverse | suite'in beklediği hata |
|---|---:|---:|---:|---|
| S04 `zayif_temel_0.10` | 0,000 | 0,064 | 0,000 | `1/3x` |
| S05 `zayif_temel_0.03` | 0,000 | 0,009 | 0,000 | `1/3x` |
| S06 `zayif_temel_0.00` | 0,000 | 0,018 | 0,000 | `1/3x` |
| S11 `ucuncu_harmonik_baskin` | 0,000 | 0,000 | 0,000 | `1/3x` |

Her biri ~1,1 saniye kesintisiz sessizlik. Sebebi kapı ya da aday eksikliği
değil: bu karelerin RMS medyanı **0,25** (kapının 24 dB üstünde) ve kare başına
**11–12 aday** var. `unified_trace --diagnostic`'in kare başına verdiği gerekçe
103 karenin 99–112'sinde **`contested`** — yani `harmonic_dominance`, tabanının
(canlı 0,90 / çevrimdışı 0,75) altında. Ölçülen dominance S06'da 0,054, S05'te
0,083, S04'te 0,362, S11'de 0,318–0,776. Temel zayıfladıkça dominance yapısal
olarak çöküyor ve motor kazananın alt-harmonik hayaleti olmadığını
kanıtlayamadığı için cevap vermiyor.

Yapışkanlık bunu bölüm boyuna yayıyor: `contested` bir kare
`abstain_recovery = 2` ve `low_register_confirmations = 3` kuruyor, yani tek
kararsız kare arkasından birkaç kareyi daha susturuyor. Bölümlerin dağınık
değil *tam olarak* boş çıkmasının sebebi budur.

**Bu davranış yanlış olmayabilir; yanlış olan görünmez olmasıydı.**

### Kapı bağlandı

`scripts/pitch_error_metrics.py:score_continuity` kareyi değil **çizgiyi**
ölçer: sesli bölge başına kapsama, iki yayımlanmış kare arasındaki kopmalar ve
`unanswered_regions` — hiç cevaplanmamış sesli bölge sayısı. Son sayaç bu
işin sebebidir: bütünüyle cevapsız bir nota, yayımlanmış perdeleri kıyaslayan
bir kare-hata oranına da, hiçbir şey yayımlanmadığı için harmonik hata
kapısına da görünmez.

`tests/test_pitch_continuity.py` iki iş yapar: ölçenin kendisini ölçer (atak/
release'i kopma saymamak, sessizliği bölge sonu saymak, yanlış notayı
"cevaplanmış" saymak) ve yukarıdaki tabloyu **ölçülen değerinde** sabitler.
Tabloda olmayan her tuzak bölümü `FLOOR = 0,90` üstünde kalmak zorundadır, yani
kapsama başka bir yere sessizce harcanamaz. Kapsama geri kazanan bir değişiklik
bu tabloyu güncellemek zorundadır — kastedilen tam olarak budur.

Kapı testlerdedir, turnuva JSON'una alan eklenmemiştir: `deterministic_fingerprint`
dondurulmuş kayıtları taşıdığı için rapor şemasını genişletmek ayrı bir karardır.

**Gerçek klarnet kayıtlarında bu sorun yok.** Aynı araçla ölçüldü: kapının
üstündeki karelerin %94,5–98,2'si yayımlanıyor ve RMS kapısının kestiği
karelerin **tamamı gerçek sessizlikte** (`gercek-klarnet-calm` 1093 kare,
`calm2` 579, hiçbiri cümle içinde değil). Bu, D-040'ın istediği ürün tarafı
kanıttır ve kapının yerinde kalmasını destekler.


## Dış karşılaştırmada ölçüm hatası bulundu ve düzeltildi — 6 Eylül 2026

**Kayıtlı dış tablo motorun kusurunu değil, ölçen kodun kusurunu gösteriyordu.**
`run_external_pitch_benchmark.py:on_hop_grid`, motor izini hop ızgarasına
`int(round(t / hop))` ile oturtuyordu. Motorun zaman damgası analiz
penceresinin *merkezi*, yani sıfır tabanlı ızgaranın **tam yarısı**; iz CSV'si
de 8 ondalığa yuvarlanıyor. Karar böylece yuvarlamanın hangi tarafa düştüğüne
kalıyor, ardışık iki kare aynı yuvaya yazılıyor ve aralarındaki yuva 0 Hz
(= ötümsüz) kalıyordu.

Ölçüldü: **1994 yayımlanmış kare 1336 yuvaya iniyordu** — karelerin ~%33'ü
puanlanmadan önce siliniyor ve tabloya motorun ötüm kusuru olarak yansıyordu.

**Asimetri tabloyu tek yönde bozuyordu.** pYIN referanslarının kareleri hop'un
tam katlarında (`t % hop` kesir kısmı 0), hiç çakışmıyordu. Yani referans tam
puan alırken motor üçte birini kaybediyordu.

### Düzeltme

Izgara artık izin **fazına** kilitleniyor (kareler tam bir hop aralıklı olduğu
için `(t - faz) / hop` tam sayıdır) ama yine dosyanın başından sonuna uzanıyor.
İki ara hata da ölçülerek yakalandı ve teste bağlandı:

1. Izgarayı ilk *ötümlü* kareye demirlemek baştaki sessizliği kapsam dışı
   bırakıyor; mir_eval o bölgeyi ötümlü sayıyor ve yanlış alarm, hatadan hiç
   etkilenmeyen pYIN'de bile `0,025 -> 0,124`'e çıkıyordu.
2. Zaten ızgarada olan bir iz faz olarak `3,5e-18` veriyor. Sıfır saymazsak
   mir_eval başa bir `t=0` örneği ekliyor, zamanları 10 ondalığa yuvarlıyor ve
   iki sıfır yan yana geliyor: `Expect x to not have duplicates`.

`tests/test_external_pitch_benchmark.py` ölçen kodu ölçer: düzeltme geri
alındığında testlerin üçü kırmızıya döner.

### Düzeltilmiş tablo (aynı 24 dosya, aynı seçim)

| Küme | Ölçüt | Kayıtlı (hatalı) | Düzeltilmiş |
|---|---|---:|---:|
| bach10 | `unified_v1` RPA | 0,6353 | **0,9492** |
| bach10 | `unified_v1` ötüm recall | 0,6412 | **0,9544** |
| mdb | `unified_v1` RPA | 0,3148 | **0,4735** |
| mdb | `unified_v1` ötüm recall | 0,3461 | **0,5139** |
| vocadito | `unified_v1` RPA | ~0,63 | **0,9223** |
| vocadito | `unified_v1` ötüm recall | ~0,63 | **0,9428** |

pYIN referansları **değişmedi** (bach10 librosa RPA 0,9865 / recall 0,9949 /
yanlış alarm 0,0650 — üçü de birebir aynı; en büyük fark 0,0012). Bu, hatanın
yalnız motor tarafını vurduğunun kanıtıdır.

`fingerprint=b6dfba30414ce4586fa682801272fc8ba4d70e9ca254990a00ca0425e5945567`

### Oktav iddiası ayakta, ama büyüklüğü değişti

En zor kümede (`mdb_stem_synth`) oktav hatası: `unified_v1` **0,0193**,
`pyin_vamp` 0,0661, `pyin_librosa` 0,1390. Yani çevrimdışı referansın
**3,4–7,2 katı daha az** oktav hatası. D-038'in metni bunu hatalı sayılarla
"5–10 kat" diye kaydetmişti; iddia korunuyor, çarpan düzeltildi.

### Kalan açık, artık nicel

Geliştirme bölümünün tamamında (96 dosya), aralık **içindeki** ötümlü
referans karelerinin motor tarafından ne yapıldığı:

| Küme | Yayımlandı | RMS kapısı | Çekimserlik (hepsi) |
|---|---:|---:|---:|
| mdb_stem_synth | %69,2 | **%26,6** | %4,2 |
| bach10_mf0_synth | %93,7 | %4,0 | %2,3 |
| vocadito | %83,2 | **%14,6** | %2,0 |

Yani klarnet dışı materyalde kaçırılan ötümün baskın sebebi **sabit RMS kapısı
(0,015 / −36,5 dBFS)**, çekimserlik politikası değil: mdb'de 6 katı, vocadito'da
7 katı. Bu, "ötüm kapsaması düşük" ifadesinden çok daha dar bir problem.

**Kesilen kareler kapının hemen altında.** Kapının reddettiği ötümlü karelerin
seviye dağılımı (geliştirme bölümü, küme başına 8 dosya), kapıya göre dB:

| Küme | 0–3 dB altı | 3–10 dB altı | 10–20 dB altı | >20 dB altı | medyan |
|---|---:|---:|---:|---:|---:|
| mdb_stem_synth | %33,0 | %44,0 | %19,8 | %3,1 | −5,1 dB |
| bach10_mf0_synth | %30,3 | %38,8 | %25,3 | %5,6 | −5,9 dB |
| vocadito | %40,6 | %34,1 | %16,7 | %8,6 | −4,2 dB |

Yani bu kareler sessiz değil, **sınırın az altında**: dörtte üçü kapının 10 dB
içinde. Bu, "malzeme duyulmuyor" değil, "mutlak eşik klarnet mikrofonunun
seviyesine göre konmuş, bu kayıtlar daha aşağıda seyrediyor" tablosudur.
Eşiğin kendisi bir **ürün ayarıdır** (kullanıcı `−60…−20 dBFS` arasında
değiştirir, varsayılan `−36,5 dBFS`), motor eşiği değil.

**Ama projenin kendi yargıcı bu kapıyı suçlamıyor.** `adverse_v1` vetosundaki
23 ciddi eksik ötüm karesi dört aralıkta toplanıyor ve gerekçeleri: 17
`unvoiced`, 2 `contested`, 2 `abstain-recovery`, **0 RMS kapısı**. Yani kapı,
yalnız dış kümelerde baskın çıkıyor — ve o kümeler yeniden sentezlenmiş
stem'ler, seviyeleri gerçek bir mikrofon zincirinin seviyesi değil. Kapıyı bu
tabloya bakarak indirmek, D-038'in yasakladığı hareketin ta kendisi olur.
Ürün tarafında kapının yanlış yerde olduğuna dair bir kanıt **yok**.

Yayın aralığı bu tabloda hesaba katıldı: `kDisplayMinimumHz` 80 Hz,
`kDisplayMaximumHz` 1760 Hz (D-037), ±100 sent toleransla 75,5–1864,7 Hz.
Referansın aralık dışında kalan payı mdb'de %18,1, bach10'da %0,6,
vocadito'da %0.

### Bölme

`data/benchmarks/external-pitch-split-v1.json` (`afe1d9abdb40bbc2`):
geliştirme 96, holdout 72, yedek 142 dosya. Sonucu daha önce görülmüş 24 dosya
geliştirmededir. **Dürüstlük kaydı:** `--split` bağlantısını denerken tek bir
holdout dosyasının (`vocadito_10.wav`) sayıları ekrana geldi; hiçbir eşik o
sayılara bakılarak seçilmedi.


## Faz 7: `swipe_prime` `FrameSpectrum` üstüne katlandı — 6 Eylül 2026

`swipe_prime.cpp` kendi pencere/FFT/interpolasyon kopyasını taşıyordu ve aynı
history'yi karede ikinci kez dönüştürüyordu (`frame_spectrum.cpp`'nin kendi
notu bu katlamayı zaten öngörmüştü). SWIPE′ çekirdeği **değişmedi** — asal
harmonikler, `1/sqrt(k)` ağırlıkları, tepe-eksi-vadi terimi, normalizasyon ve
sqrt sıkıştırması aynı; yalnız genlikler artık hazır `FrameSpectrum`'dan
okunuyor. Sıkıştırma hâlâ interpolasyondan **önce** yapılır: tersi çekirdeği
değiştirirdi, işlem sırasını değil.

Tek davranış farkı bin çözünürlüğü: kendi FFT'si history'yi 4096'ya
dolduruyordu, `FrameSpectrum` 4× dolgu ile 16384 kullanır. Yani ölçüm aynı,
tepe konumu daha keskin.

### Donmuş holdout v1 — katlama öncesi / sonrası

| Dosya | Ciddi eksik ötüm | Ciddi harmonik | Doğru-kare ort. sent |
|---|---|---|---|
| `holdout_clean_v1.wav` | 0 → 0 | 0 → 0 | 1,795 → 1,795 |
| `holdout_room_v1.wav` | 0 → 0 | 0 → 0 | 2,120 → 2,120 |
| `holdout_adverse_v1.wav` | **24 → 23** | 0 → 0 | 2,402 → 2,405 |

Temiz ve oda varyantları **bit düzeyinde aynı** kaldı. Tek değişen, vetolu
adverse dosyasında bir karenin geri kazanılması; sent farkı 0,003 (ölçüm
gürültüsü mertebesinde). `ACCEPTED_VETO_MISSING_VOICED_FRAMES` sabiti 24'ten
**23'e indirildi** — mandal ölçümü izler, ölçüm mandalı değil.

### Kapılar

`scripts/test_core.sh` temiz (13 ikili) · turnuva testleri 27 geçti (beş
holdout'un bütün varyantlarında ciddi harmonik hata **hâlâ sıfır**) ·
`pytest` 87 geçti / 1 atlandı · macOS `xcodebuild` Debug BUILD SUCCEEDED.

### Hız

Çevrimdışı iz, 25,45 sn'lik adverse holdout üzerinde, 5 koşunun en iyisi:
**7,336 sn → 7,137 sn (%2,7)**. Kaldırılan 4096 noktalı FFT, korunan 16384
noktalı bandın yanında küçük kaldığı için kazanç mütevazı; asıl kazanç tek
kopya kalan spektrum kodu.


## Dört motor kaldırıldı — 6 Eylül 2026 (D-039)

Bu tur **hiçbir ölçümü değiştirmedi**: motor davranışı, eşikler ve 5 hop
(53,3 ms) gecikme aynı. Değişen, geri kalan dört motorun koddan çıkarılması.

### Kapılar

| Kapı | Sonuç |
|---|---|
| `zsh scripts/test_core.sh` | temiz (13 çekirdek ikilisi) |
| `swift test` (macos/KlariVision) | 49 test / 0 hata |
| macOS `xcodebuild` Debug (imzasız) | BUILD SUCCEEDED |
| `pytest` | 87 geçti / 1 atlandı |
| Turnuva testleri | 27 test, `unified_v1` tek motor olarak |
| Paketlenen CLI `--contract` | `abi_version=1`, `engines=["unified_v1"]`, `unified_lag_frames=5` |
| iPad `xcodebuild` | **KOŞULMADI** — bu makinede iOS 26.5 platformu kurulu değil |

### Turnuva testinin yeni biçimi

Motor başına holdout testleri (`yin_v1`, `pitch_engine_v2`, `hapt_v1`,
`vpm_like`) yerine `unified_v1` için iki test kondu:

1. **Ciddi harmonik / harmonik olmayan / yanlış ötüm hatası, beş donmuş
   holdout'un bütün varyantlarında sıfır.** D-037'nin sert şartı.
2. **Ciddi eksik ötüm** güvenlik oranının (`SAFETY_RATE_LIMIT = 0.005`)
   içinde — tek kayıtlı istisnayla:
   `klarivision_pitch_tournament_holdout_adverse_v1.wav`, **24 / 2365 kare
   (%1,01)**. Bu, D-038'de kabul edilen ve hâlâ açık olan vetodur; muaf
   tutulmadı, ölçülen değerine sabitlendi — sessizce büyüyemez.

Eksik ötüm bilerek sıfıra sabitlenmedi: çekimserlik bu motorun merkezî
mekanizması ve ürünün istediği takas budur (D-038).

### Güvenlik kapısının eşiği değişmedi, referansı değişti

Kural "bir donmuş holdout dosyasında hiçbir ciddi sınıf `yin_v1`'i 0,5 puandan
fazla geçemez" idi. `yin_v1` bütün donmuş holdout'larda sıfır aldığı için aynı
sınır artık mutlak olarak ifade ediliyor: dosyanın kendi referans karelerinin
%0,5'i. Sayı aynı, dayanağı kalkan bir motor değil.

### Turnuva artık seçim yapmaz

`selection()` bir terfi mekanizmasıydı. `benchmark_winner`, `default_engine` ve
`outcome` alanları kaldırıldı: tek atlı bir yarışta kazanan ilan etmek,
yapılmamış bir kıyası yapılmış gibi gösterirdi. D-038'in koruduğu ayrım
(`benchmark_winner=vpm_like`) `outputs/` altındaki raporlarda kayıt olarak
durur; **o kıyas bu adımdan sonra yeniden üretilemez.** Kararın kabul edilmiş
bedeli budur.

### Bu turda bulunan üç bayat kayıt

1. **macOS Xcode projesi `unified_*` kaynaklarını hiç derlemiyordu.** D-037'den
   beri masaüstü uygulaması kendi kazanan motorunu bağlayamazdı. Beş kaynak
   eklendi (aynı hata `scripts/build_beta_app.sh`'de daha önce bulunmuştu).
2. **iPad Xcode projesi de aynı durumdaydı**; beş kaynak eklendi.
3. `pitch_track_cli`'nin `--diagnostic` kipi yalnız kaldırılan üç motora
   hizmet ediyordu; kip kaldırıldı (`core/tools/unified_trace.cpp` durur).

### Geriye uyum: eski motorla çözümlenmiş çalışmalar

`cpp_engine.OFFLINE_TRACK_ENGINES`, kaldırılan motorların kimliklerini de
içerir — **sonucu bulmak için** kullanılır, **çalıştırmak için** `ENGINES`.
Bu ayrım olmadan D-039 öncesi analiz edilmiş her çalışmanın önbellek dosyası
bulunamaz hale geliyordu (bu tur önce kırıldı, sonra testle birlikte
düzeltildi). Görüntüleyici bu çalışmaların motor adını "(kaldırıldı)"
etiketiyle doğru gösterir.


## `unified_v1` kazanan ilan edildi, gecikme 53 ms — 6 Eylül 2026

Kullanıcı kararı (D-038): `unified_v1` projenin kazanan motorudur ve karar
gecikmesi 15 hop (160 ms) yerine **5 hop (53,3 ms)** olur. `adverse_v1` vetosu
şimdilik kabul edilmiş durumda.

Gecikme düşürüldükten sonra **tam turnuva yeniden koşuldu**
(`fingerprint=00a55e421e523b3befead9f5ed755a859f225183bd6f0885877206605f982453`).
Bu tablo 15 hop'luk koşuyla aynı derlemeden değil, yeni değerle üretilmiştir:

| Motor | ciddi harmonik | ciddi toplam | doğru perde ort. sent | gecikme |
|---|---|---|---|---|
| **unified_v1** | **0** | 2239 | 1,908 | 53,3 ms |
| yin_v1 | 498 | 658 | 1,606 | 16,0 ms |
| pitch_engine_v2 | 495 | 1037 | 1,532 | 69,3 ms |
| vpm_like | 34 | 115 | ~1,6 | 16,0 ms |
| hapt_v1 | 107 | 442 | 4,842 | 16,0 ms |

Ciddi harmonik hata **hâlâ tam sıfır** — 53 ms'de de. Gecikme taramasının
öngördüğü gibi. `unified_v1`'in ciddi toplam hatasının tamamına yakını
(2234/2239) *eksik ötüm*, yani sessizlik: ürünün istediği takas tam olarak
budur.

Bedeli ölçüldü ve kabul edildi: 15 hop'a göre yaklaşık **540 kare daha fazla
sessizlik**, karşılığında **107 ms daha hızlı canlı tepki**.

### Veto tek dosyada kaldı

53 ms'ye inmek **yeni veto dosyası eklemedi**. Otomatik seçim hâlâ:

- `unified_v1`: `eligible=false`, tek veto — `holdout_adverse_v1.wav`,
  ciddi eksik ötüm 24 kare (yin_v1: 0), sınır ≈ 12 kare (2365 sesli karenin
  %0,5'i).
- `benchmark_winner=vpm_like`, `outcome=candidate_requires_parity`.

**Bu iki satır kasten değiştirilmedi.** Turnuvanın sıralaması her sınıftan ciddi
hatayı eşit sayar; ürünün şartı ise asimetriktir (sessizlik harmonik hataya
yeğdir). Kazanan ilanı bu yüzden turnuvanın çıktısını yeniden yazarak değil,
D-038'de kayıtlı bir ürün kararı olarak verildi. Ölçüm ne diyorsa öyle duruyor.

### Bu koşuda düzeltilen üç bayat kayıt

Gecikme değişikliği üç yerin senkron tutulmasını gerektirdi ve bunu yaparken
üç bağımsız bozukluk ortaya çıktı:

1. `scripts/pitch_tournament_engines.py:UNIFIED_DEFAULT_LAG_FRAMES` C++
   varsayılanını **gölgeliyor** — `unified_frames()` değeri her zaman açıkça
   geçiriyor. İkisi ayrı düşerse turnuva, gönderilenden farklı bir motoru ölçer.
   Sabitin başına bu uyarı yazıldı.
2. `macos/.../LiveNotationTests.swift` beş motor eklendiğinden beri **kırmızıydı**
   ve fark edilmemişti (dört motor bekliyordu). Düzeltildi; `swift test`
   50 test / 0 hata.
3. `scripts/build_beta_app.sh` `unified_*` kaynaklarını derlemiyordu, yani beta
   paketi `unified_v1` eklendiğinden beri link edemezdi. Beş kaynak eklendi.

## Dış karşılaştırma — pYIN referansıyla — 6 Eylül 2026

24 dosya, üç küme, beş motor + iki çevrimdışı pYIN referansı.

### Oktav hata oranı (RPA − RCA)

| Küme | **unified_v1** | pyin_vamp | pyin_librosa | yin_v1 |
|---|---|---|---|---|
| bach10_mf0_synth | 0,0007 | 0,0006 | 0,0005 | 0,0206 |
| **mdb_stem_synth** | **0,0134** | 0,0658 | 0,1390 | 0,0804 |
| vocadito | **0,0000** | 0,0000 | 0,0000 | 0,0141 |

**En zor ve en çeşitli kümede `unified_v1`, pYIN'den 5–10 kat az oktav hatası
yapıyor** — raporun "ulaşılabilir en iyi" dediği çevrimdışı referanstan. Diğer
iki kümede pYIN ile aynı seviyede. Beş motorun tamamı arasında da her kümede
birinci ya da birinciyle eşit.

Bu, D-037'nin sert şartının hiç görülmemiş veride, üstelik referans tavanının
üstünde karşılandığı anlamına gelir.

### Ham perde doğruluğu — açık burada

| Küme | unified_v1 | pyin_vamp | pyin_librosa |
|---|---|---|---|
| bach10_mf0_synth | 0,635 | 0,988 | 0,987 |
| mdb_stem_synth | 0,315 | 0,655 | 0,661 |
| vocadito | 0,620 | 0,989 | 0,992 |

Fark neredeyse tamamen **ötüm recall**'dan geliyor: `unified_v1` 0,641 / 0,346 /
0,635, pYIN 0,995 / 0,754 / 0,991. Yani motor perdeyi doğru ölçüyor ama sesli
karelerin önemli bir kısmında susuyor.

pYIN'in yanlış alarmı ise çok daha yüksek (vocadito'da 0,15 ve 0,34, bizde
0,06) — yani kapsamanın bir kısmını sessizliğe perde bildirerek alıyor.
Karşılaştırma bu yüzden tek yönlü okunmamalı; ama recall farkı bununla
açıklanamayacak kadar büyük.

**Projenin bir sonraki gerçek işi budur:** klarnet dışı materyalde ötüm
kapsaması. Ve bu tabloya bakarak ayarlanamaz — ayrı bir doğrulama kümesi
ayrılmalıdır.


## Dış karşılaştırma — tam koşu — 6 Eylül 2026

36 dosya, üç küme, beş motor. **Oktav hata oranı (RPA − RCA)**, hiç görülmemiş
veride:

| Küme | unified_v1 | En iyi diğer | yin_v1 |
|---|---|---|---|
| bach10_mf0_synth (nefesli/yaylı) | **0,0002** | 0,0001 (v2) | 0,0201 |
| mdb_stem_synth (çok enstrümanlı) | **0,0075** | 0,0077 (hapt) | 0,0522 |
| vocadito (vokal) | 0,0016 | 0,0007 (v2) | 0,0139 |

Raw pitch accuracy'de **üç kümenin üçünde de birinci**: 0,639 / 0,359 / 0,602
(en yakın rakip 0,635 / 0,286 / 0,572). Ötüm recall'da da üçünde birinci.

**Bu, harmonik hatanın sıfırlanmasının bu veriye oturma değil gerçek bir
düzeltme olduğunun kanıtıdır.** Motor hiç görmediği enstrümanlarda, insan
sesinde ve çok sesli karışımda da `yin_v1`'in oktav hatasının 7 ila 100'de
birini yapıyor.

Metodoloji uyarısı geçerliliğini korur: sayısal eşikler hâlâ donmuş holdout'lara
bakılarak seçildi. Bu tablo o eşiklerin *zarar vermediğini* gösteriyor; onları
haklı çıkarmıyor. Ve bu tabloya bakarak ayar yapılırsa elimizdeki son bağımsız
ölçüt de kaybedilir.

## Karar gecikmesi taraması — 160 ms'nin gerekçesi çürüdü — 6 Eylül 2026

D-037'de canlı karar gecikmesi 15 hop (160 ms) seçilmişti; gerekçe, oktav
hatalarının medyan 2 en fazla 9 kare sürmesi ve 5 karelik look-ahead'in çoğunun
sonunu görememesiydi. Tarama hiç koşulmamıştı. (İlk denemem de düzdü: Python
tarafındaki `UNIFIED_DEFAULT_LAG_FRAMES` C++ varsayılanını eziyor.)

| Gecikme | Holdout eksik | adverse_v1 | Tuzak eksik | Harmonik | Ort. sent |
|---|---|---|---|---|---|
| 5 hop (53 ms) | **27** | **24** | 2171 | **0** | 1,834 |
| 10 hop (107 ms) | 42 | 27 | 2007 | 0 | 1,838 |
| 15 hop (160 ms) | 40 | 25 | **1696** | 0 | 1,838 |
| 20 hop (213 ms) | 42 | 27 | 1683 | 0 | 1,838 |
| 30 hop (320 ms) | 42 | 27 | 1683 | 0 | 1,838 |

**Harmonik hata her gecikmede sıfır, 53 ms dahil.** Hassasiyet de fiilen aynı.
Yani uzun look-ahead harmonik güvenlik için gerekli değil — o işi kanıt katmanı
yapıyor. 160 ms'nin satın aldığı tek şey tuzak paketi kapsamasıdır
(2171 → 1696), karşılığında canlı modda 107 ms tepkisellik.

Bu bir ürün kararıdır ve artık ölçümle verilebilir.


## Altıncı turnuva — veto tek dosyaya indi — 6 Eylül 2026

| Motor | Ciddi yanlış | Ciddi eksik | Ciddi harmonik | Ciddi toplam | Ort. sent | Kapı |
|---|---|---|---|---|---|---|
| yin_v1 | 54 | 13 | 498 | 658 | 1,606 | — |
| pitch_engine_v2 | 6 | 536 | 495 | 1037 | 1,532 | — |
| vpm_like | 15 | 54 | 34 | 115 | 1,463 | — |
| hapt_v1 | 6 | 329 | 107 | 442 | 4,842 | — |
| **unified_v1** | **5** | **1784** | **0** | **1789** | 1,899 | VETO (1 dosya) |

Veto seyri: 7 → 6 → 5 → 3 → **1 dosya**. Kalan tek engel `adverse_v1`,
yalnızca eksik-sesli üzerinden: 25 kare, limit 12.

Ciddi harmonik hata sıfırda; yanlış-sesli beş motorun en düşüğü.

## Dış karşılaştırma — ilk bağımsız ölçüm — 6 Eylül 2026

`scripts/run_external_pitch_benchmark.py` yazıldı ve koşuldu. Bu takım bir
**iddia kapısıdır, ayar hedefi değildir**; buradan sabit seçmek tablonun tek
işlevini yok eder.

Çevrimdışı pYIN (native Vamp ve librosa) **referans tavanı** olarak eklendi —
rakip değil, mesafe ölçüsü.

Vocadito (vokal) ilk dosyada, raw pitch accuracy:

| Motor | RPA | Ötüm recall |
|---|---|---|
| yin_v1 | 0,362 | 0,364 |
| pitch_engine_v2 | 0,358 | 0,359 |
| vpm_like | 0,403 | 0,404 |
| hapt_v1 | 0,408 | 0,410 |
| **unified_v1** | **0,577** | **0,591** |
| pyin_vamp (referans) | 0,977 | 0,978 |
| pyin_librosa (referans) | 0,992 | 0,998 |

**Projenin beş motorunun tamamı klarnet dışı materyalde pYIN'in çok
gerisinde.** `unified_v1` beşinin en iyisi ve ikincisinden %41 önde, ama açık
büyük ve neredeyse tamamı ötüm recall'dan geliyor: motorlar sesli karelerin
çoğunda susuyor.

Bu bir `unified_v1` kusuru değil, proje çapında bir açık — ve depodaki hiçbir
yargıç bunu söyleyemezdi. Bağımsız ölçütün varlık sebebi tam olarak budur.

**Uyarı:** ötüm recall'ı bu tabloya bakarak yükseltmek, elimizdeki son
bağımsız ölçütü de ayar sinyaline çevirir. Klarnet dışı kapsama üzerinde
çalışılacaksa, ölçüt yine bu küme olmamalı.

> ## Metodoloji uyarısı — 6 Eylül 2026
>
> **`unified_v1`'in sayısal eşikleri, donmuş holdout'ların sonuçlarına
> bakılarak seçildi.** O manifestlerin politikası açıkça
> `frozen-no-retuning-after-first-result`; bu kural fiilen korunamadı. Berraklık
> tabanı ise dinleyici kararlarındaki iki kaçak görülerek 0,50'den 0,60'a
> çekildi — yani o küme de bir ayar sinyali olarak kullanıldı.
>
> Değişiklikler iki sınıfa ayrılır:
>
> **Yapısal (gerekçeye dayanır, genellenmesi beklenir):** taramanın bantlar
> arasında havuzlanması, emisyonun çarpım olması, seçim ile alt-örnek ince
> ayarının ayrı pencerelere alınması, analiz sınırının adayla ölçeklenmesi,
> gizli temelin harmonik kanıtla kabul edilmesi.
>
> **Ayarlanmış (bu veriye oturmuş olabilir):** `kSwipeWeight`/`kTwmWeight`
> `0,55/0,45`, `kVoicingClarityFloor/Ceiling` `0,60/0,85`,
> `winner_posterior_floor` `0,015`, `kHardSilenceRatio` `0,35`,
> `kLowFundamentalPresenceFloor` `0,05`,
> `kHarmonicContestEvidenceRatio` `0,40`, `kHiddenFundamentalTwmFloor` `0,55`.
>
> Spektral karışım oranının duyarlılığı bu kaygıyı somutlaştırıyor: `45:55`'te
> 114 kayıp, `55:45`'te 40. Beş puanlık bir kayma sonucu üçe bölüyorsa, o nokta
> olgudan çok veriden gelmiş olabilir.
>
> **Bu depoda artık bağımsız bir yargıç yok.** Her ölçüt bir noktada ayar
> sinyali olarak kullanıldı. `unified_v1` varsayılan yapılmadan önce
> `scripts/run_external_pitch_benchmark.py` yazılmalı ve hiç görülmemiş veride
> (MDB-stem-synth, PTDB-TUG, vocadito) koşulmalıdır. **RPA − RCA** farkı tanımı
> gereği oktav hata oranıdır ve ayarlamayla düzeltmeyi ayırt edebilecek tek
> sayıdır.


## `adverse_v1` ve `adverse_v4` incelemesi — kalan vetonun tükendiği nokta — 6 Eylül 2026

Üç engelleyici dosyanın diğer ikisi. Doğruluk farkı küçük:

| Dosya | unified doğru | yin_v1 doğru | Fark | unified ort. sent | yin ort. sent |
|---|---|---|---|---|---|
| adverse_v1 | 2124 | 2184 | −60 | 2,412 | 2,149 |
| adverse_v4 | 1024 | 1067 | −43 | 1,654 | 1,573 |

Hassasiyet pratikte eşit; kayıp yalnızca çekimserlikten.

**Teşhis aracının yanılttığı yer.** `why` histogramı kayıpların çoğunu
`voiced_posterior` kapısına yazıyordu (`adverse_v1` 183, `adverse_v4` 67). Bu
yanlış: o kareler bir eşik tarafından reddedilmiyor, **kod çözücünün kendisi
sessizliği seçiyor** (yayın sebebi `unvoiced`). Eşiği taramak bunu gösterdi —
0,40'tan 0,15'e indirmek **tek kare** değiştirmedi.

**Kayıp kareler atakta değil.** Bölüm başlangıcından medyan 610 ms (`v1`) ve
796 ms (`v4`) sonra; yalnızca beşte biri ilk 200 ms içinde. Yani 160 ms'lik
karar gecikmesi açıklama değil. `adverse_v1`'de en büyük küme
`irregular_dropouts`: 22/263 kare — gerçek bir boşluktan sonra toparlanma.

### Bu turda ölçülen ve reddedilen kollar

| Kol | Holdout eksik | Maliyet |
|---|---|---|
| Ses posterior tabanı 0,40 → 0,25 → 0,15 | 114 → 114 → 114 | — (hiç etkisi yok) |
| Berraklık tavanı 0,85 → 0,80 → 0,72 → 0,66 | 114 → 120 → 123 → 120 | daha kötü |
| Emisyonları en iyi adaya göre kalibre etmek | 114 → 118 | daha kötü |
| Yapışkan toparlanma 2 → 1 | 114 → **96** | tuzak harmonik 0 → **6** |
| Yapışkan toparlanma 2 → 0 | 114 → **76** | tuzak harmonik 0 → **20** |

Kapsamayı gerçekten hareket ettiren tek kol, harmonik hatayı geri getiriyor —
ve bu, gizli-temel düzeltmesinden sonra yeniden ölçüldüğünde de aynı çıktı.

**Durum:** veto marjı `adverse_v1` için ≤12, `adverse_v4` için ≤6,
`adverse_v5` için ≤5 kare istiyor; sırasıyla 39, 14, 45'teyiz. Ucuz kol
kalmadı. Kalan kareler, kod çözücünün 15 karelik pencerenin tamamını görüp
sessizliği daha iyi açıklama saydığı karelerdir; çekimserliği gevşetmek
ölçülmüş biçimde harmonik hatayı geri getiriyor.


## Beşinci turnuva — ayrık pencere mimarisi — 6 Eylül 2026

| Motor | Ciddi yanlış | Ciddi eksik | Ciddi harmonik | Ciddi toplam | **Ort. sent** | Kapı |
|---|---|---|---|---|---|---|
| yin_v1 | 54 | 13 | 498 | 658 | 1,606 | — |
| pitch_engine_v2 | 6 | 536 | 495 | 1037 | 1,532 | — |
| vpm_like | 15 | 54 | 34 | 115 | 1,463 | — |
| hapt_v1 | 6 | 329 | 107 | 442 | 4,842 | — |
| **unified_v1** | 5 | 2470 | **0** | 2475 | **1,913** | VETO (3 dosya) |

Harmonik hata sıfır korunuyor. Ortalama sent hatası 2,681 → **1,913**;
`hapt_v1`'in 4,842'sinin çok altında, `yin_v1`'in 1,606'sına yaklaştı.

**Ayrık pencere mimarisi.** Hangi lag'in doğru olduğu ile o lag'in tam olarak
nereye düştüğü farklı sorulardır ve aynı pencereyi paylaşıyorlardı. Seçim
bandın kendi penceresinde koşmalı — tiz oktavda 768 örnek, vibrato ve
glissando ortalanmasın diye. Alt-örnek yerleştirme ise yalnızca **zaten
seçilmiş** bir minimumun iki yanındaki eğrinin şeklini ister ve bunu daha uzun,
daha sessiz bir pencerede çok daha iyi ölçer. İnce ayar ham fark fonksiyonunu
kullanır: kümülatif ortalama normalizasyonu değerleri *lag'ler arasında*
karşılaştırılabilir kılmak içindir, bu ise bir seçim meselesidir.

Tiz register fikstüründe ortalama hata:

| | Önce | Sonra | yin_v1 |
|---|---|---|---|
| adverse_v5 | 4,000 | **1,635** | 1,627 |
| room_v5 | 3,711 | **1,577** | 1,587 |
| clean_v5 | 4,063 | **1,537** | 1,493 |

**İnce ayar penceresi uzunluğu — ölçülmüş eğri.** Uzun her zaman iyi değil;
pencere hareket eden notanın yeterince büyük bir kısmını kapsadığında, yerini
bulmaya çalıştığı minimumu kendisi kaydırıyor:

| İnce ayar penceresi | adverse_v5 ort. sent |
|---|---|
| **1536 (seçilen)** | **1,64** |
| 2048 | 2,69 |
| 3072 (tüm geçmiş) | 5,75 — bölmemekten de kötü |

İlk deneme tüm geçmişi kullandı ve tam bu yüzden başarısız oldu.

Kalan veto üç dosyada ve yalnızca eksik-sesli üzerinden: `adverse_v1` 39,
`adverse_v4` 14, `adverse_v5` 45. Donmuş holdout'ların yedisinde de ciddi
harmonik hata sıfır; dinleyici kararları 85/85 temiz.


## `adverse_v5` incelemesi — kalan vetonun kaynağı — 6 Eylül 2026

Tiz register fikstürü (839–1460 Hz, glissando + vibrato + derin bozulma),
kalan üç veto dosyasının en zoru. Bölüm bazında kayıp, **frekansla artıyor**:
1089,7 Hz demirinde %32, 1433,8 Hz'de %20, 941,3 Hz'de %5.

**Bu bir metrik yapaylığı değil.** Aynı dosyada doğru kare sayıları:

| Motor | Doğru | Eksik | Harmonik | Ortalama sent |
|---|---|---|---|---|
| yin_v1 | 980 | 0 | 0 | 1,627 |
| pitch_engine_v2 | 986 | 0 | 0 | 1,491 |
| vpm_like | 979 | 0 | 0 | 1,868 |
| hapt_v1 | 988 | 0 | 0 | 12,539 |
| **unified_v1** | **901** | 47 | 0 | 4,000 |

`yin_v1` burada hata yapmıyor; gerçekten doğru izliyor ve biz susuyoruz.
Vetonun "asla çekimser kalmayan bir motorla kıyaslıyor" savunması **bu dosya
için geçerli değil** — 79 doğru kare gerçekten kaybediliyor, üstelik
hassasiyet de daha düşük.

Sinyal geniş bantlı: enerji tepe değerin %10'u üzerinde 6–8 kHz'e uzanıyor ve
1433,8 Hz'deki tonun genliği spektral tepenin yüzde biri. Yani ton gürültünün
altında; kanıt gerçekten zayıf.

Kapı dağılımı (1041 uygun kareden 900'ü yayımlanıyor): `voiced_posterior` 65,
`harmonic_dominance` 29 + yapışkan toparlanma 27, `winner_posterior` 19.

### Tiz bant penceresi — ölçülmüş takas

Şüpheli, üç bantlı tasarımın tiz bandıydı: 1434 Hz için 768 örneklik pencere
kullanılıyor, `yin_v1` ise 1536. Gürültü ortalaması yarı yarıya az.

| `kHighWindowSamples` | adverse_v5 doğru | clean_v5 doğru | Ortalama sent |
|---|---|---|---|
| **768** (seçilen) | **901** | 978 | 4,00 |
| 1024 | 889 | 982 | 2,88 |
| 1536 | 823 | **989** | **1,95** |

Uzun pencere hassasiyeti iki katına çıkarıyor ve temiz/oda materyalinde daha
çok kare kazandırıyor, ama vetoyu tıkayan dosyada 78 kare kaybettiriyor. 768'de
kalındı, çünkü veto marjı açık iş. Ancak **tiz bölgede 4 sentlik ortalama hata,
`yin_v1`'in 1,6'sına karşı, akort uygulaması için gerçek bir kalite farkıdır**
ve bu takas kullanıcı kararı olarak açık bırakılıyor.

Doğru çözüm muhtemelen ikisini ayırmaktır: aday üretimi için kısa pencere,
seçilen lag'in ince ayarı için uzun pencere. Hassasiyet CMND penceresinin
uzunluğundan geliyor, aday aramasından değil.

## Dördüncü turnuva — harmonik hata sıfır — 6 Eylül 2026

| Motor | Ciddi yanlış | Ciddi eksik | **Ciddi harmonik** | Ciddi toplam | Gecikme | Kapı |
|---|---|---|---|---|---|---|
| yin_v1 | 54 | 13 | 498 | 658 | 16 ms | — |
| pitch_engine_v2 | 6 | 536 | 495 | 1037 | 69 ms | — |
| vpm_like | 15 | 54 | 34 | 115 | 16 ms | — |
| hapt_v1 | 6 | 329 | 107 | 442 | 16 ms | — |
| **unified_v1** | 5 | 2462 | **0** | 2467 | 160 ms | VETO (3 dosya) |

**Tüm sentetik turnuvada ciddi harmonik hata sıfır.** D-037'nin sert şartı
karşılandı. Ciddi diğer de sıfır; yanlış-sesli 5 ile en düşük.

Kalan veto yalnızca eksik-sesli üzerinden, üç dosyada: `adverse_v1` 38 kare,
`adverse_v4` 9, `adverse_v5` 47 (tiz register, glissando + vibrato). Harmonik
veto tamamen kalktı.

Belirleyici düzeltme, alçak register kapısının gizli temeli silmesini
durdurmaktı. Kalan harmonik hataların **hepsi** aynı yöndeydi — 96,3 Hz'lik
temel, kendi üçüncü harmoniği olan 288,9 Hz olarak — yani motorun önlemek için
kurulduğu alt-harmonik kilidinin **tersi**. Kapı 160 Hz altındaki adayı ancak
kendi frekansında enerji taşıyorsa kabul ediyordu; gizli temelin sahip olmadığı
tek şey bu. Aynı fikstürün 171,4 Hz'lik gizli-temel bölümü kapının üstünde
kaldığı için hiç hata vermiyordu — kapının itirafı.

Formülasyon: **varlık, gerçek olmanın tek yolu değil.** Temeli süzülmüş bir
notanın harmonik serisi sağlamdır ve iki yönlü uyumsuzluk zaten bunu ölçer.
Aday artık ikisinden biriyle kabul ediliyor. Hayaletleri geri almıyor: f/3'teki
bir hayalet 5f/3 ve 7f/3'te enerji vaat eder, orada hiçbir şey yoktur ve o
harmonikler tam ağırlık taşır.

Karşılığında tuzak paketinde 354 kare kapsama verildi — daha çok alçak aday
karara ulaşıyor ve zayıf-temel bölümlerinde bir kısmı gerçekten çekişmeli.


## Birleşik motor `unified_v1` — 6 Eylül 2026

Yeni motor: pYIN eşik-dağılımı merdiveni (üç bantta havuzlanmış tarama, YIN
Adım 6 dahil) → harmonik spektral kanıt (SWIPE′-asal, iki yönlü uyumsuzluk,
hayalet vetosu, uyarlanabilir parity) → açık sessiz durumlu sabit-gecikmeli
Viterbi (15 hop ≈ 160 ms) → çekimserlik. Çevrimdışında aynı kanıt üzerinden
tüm diziyi çözen global Viterbi.

### Oktav tuzağı paketi — ham / ciddi harmonik hata

| Motor | clean | room | adverse |
|---|---|---|---|
| yin_v1 | 332 / 307 | 128 / 115 | 92 / 76 |
| pitch_engine_v2 | 220 / 205 | 92 / 71 | 251 / 219 |
| vpm_like | 13 / 0 | 20 / 7 | 43 / 27 |
| hapt_v1 | 1 / 0 | 3 / 0 | 115 / 107 |
| **unified_v1** | **4 / 0** | **4 / 0** | **3 / 0** |

Üç varyantta da **ciddi** harmonik hatası sıfır olan tek motor. Kalan 3–4 ham
kare tamamen `oktav_sicramasi` ve `register_sicramasi_12li` bölümlerinde:
294 → 588 ve 294 → 882, yani **gerçek** sıçramalar. Gerçek değer değiştikten
sonra iki–üç kare boyunca motor hâlâ çaldığı notada; o nota yeninin tam yarısı
veya üçte biri olduğu için metrik gecikmeyi harmonik hata sayıyor. Alt-harmoniğe
kilitlenme yok. Gecikme de arızi değil: bir sıçramayı anında izleyen kod çözücü,
tam olarak sıçrama uyduran kod çözücüdür — kanıtın ısrar etmesini beklemek
mekanizmanın kendisidir. Metriğin geçiş toleransı bunun içindir.

### Gerçek kayıtta kapsama (ortak payda: dosyadaki hop sayısı)

| Kayıt | yin_v1 | unified_v1 | oktav/onikili uyuşmazlığı |
|---|---|---|---|
| gercek-klarnet-calm (70 s) | %79,5 | %77,9 | **0** / 5117 |
| calm2 (57 s) | %87,1 | %86,5 | **0** / 4605 |
| Şükrü Tunar taksim (191 s) | %80,8 | %78,5 | 9 oktav + 4 onikili / 13857 |

Eski motorlar sessiz kareyi hiç yayımlamaz, `unified_v1` sessiz kareyi de
bildirir; bu yüzden payda her motor için dosyadaki hop sayısıdır, motorun kendi
kare sayısı değil.

### Donmuş dinleyici kararları (`quick_pitch_check.py`, 85 aralık)

| Motor | Koruma hücresi | Bozuldu | Kalan kusurlar |
|---|---|---|---|
| yin_v1 | 46 | 0 | boşluk 18, kaçak 2, oktav 1 |
| pitch_engine_v2 | 61 | 0 | boşluk 18, kaçak 1, oktav 1 |
| vpm_like | 39 | 6 | boşluk 28, oktav 4 |
| hapt_v1 | 33 | 2 | boşluk 31, kaçak 1, oktav 1 |
| **unified_v1** | **85** | **0** | **—** |

`unified_v1` kararlar dosyasında etiketli değil, bu yüzden 85 aralığın tamamı
onun için koruma hücresidir: testi "yeni kusur çıktı mı" sorusudur ve
diğerlerinin karşılaştığından **daha zor** bir sınavdır. Sıfır oktav, sıfır
kaçak, sıfır yeni boşluk. Diğer dördünde toplam 7 oktav hatası duruyor.

### Sentetik oturum testleri

82–1760 Hz arası, hem kapalı-boru tınısı (temel kendi 3. harmoniğinin onda
biri) hem tam harmonik seri: **her vakada %100 kapsama, sıfır harmonik hata**.

Testler kapsamayı ve hatayı **birlikte** doğruluyor. Tek başına "sıfır harmonik
hata", her karede susan bir motorda da geçer — sessiz kare yanlış kare değildir.

### Bilinen sınır — temeli tamamen yok olan sinyal

Temel **fiziksel olarak hiç yokken** (yalnız 3f, 5f, 7f), 294 Hz ile kendi
üçüncü harmoniği arasındaki kanıt oranı 0,46'dır: rakip gerçekten kazananın
yarısı kadar delil taşır. Motor orada susar. Kullanıcı kararı: olduğu gibi
bırakılacak (çekişme eşiğini gevşetmek korumayı her yerde zayıflatır). Tuzak
paketinde iki bölüm; üç gerçek klarnet kaydında hiç görülmedi.

### Sentetik turnuva — 6 Eylül 2026 (üçüncü koşu, adaya göre ölçeklenen analiz sınırı)

| Motor | Ciddi yanlış | Ciddi eksik | Ciddi harmonik | Ciddi toplam | Kapı |
|---|---|---|---|---|---|
| yin_v1 | 54 | 13 | 498 | 658 | — |
| **unified_v1** | **5** | **2161** | **43** | **2212** | VETO (5 dosya) |

Üç koşuda ciddi toplam 3192 → 2432 → **2212**, veto 7 → 6 → **5 dosya**.
Donmuş holdout'larda ciddi eksik 1034 → 352 → **142**.

**Kalan tıkanıklık tek bir akustik olguda toplanıyor.** `clean_v1` ve
`adverse_v1`'de hem harmonik hatalar hem kayıplar `hidden_fundamental`
bölümlerinde yığılıyor (96,3 Hz ve 128,6 Hz):

| Dosya | Bölüm | Harmonik | Eksik | Toplam kare |
|---|---|---|---|---|
| clean_v1 | hidden_fundamental_96.3 | 13 | 12 | 127 |
| clean_v1 | hidden_fundamental_128.6 | 10 | 9 | 141 |
| adverse_v1 | hidden_fundamental_96.3 | 21 | 17 | 127 |
| adverse_v1 | hidden_fundamental_128.6 | 3 | 12 | 141 |

Bu, tuzak paketindeki `temel_yok` bölümleriyle **aynı olgu**, yalnızca alçak
register'da olduğu için sessizliğin yanında harmonik hata da üretiyor. Geri
kalan her şey pratikte başabaş.

**Alt-harmonik toplaması (SHS) denendi ve alınmadı.** Raporun bu vaka için
kendi reçetesiydi (Hermes 1988) ve sadakatle uygulandı: adayın harmoniklerinin
geometrik azalan ağırlıklı toplamı, **istenen** ağırlığa bölünerek — yani
adayın öngörüp de sinyalin sağlamadığı her harmonik ona maliyet olarak yazıldı,
ki SHS'in klasik alt-harmoniğe kayma yanlılığı doğmasın. Kare içinde en iyi
adaya göre normalize edildi. Ham hâliyle tiz bölgeyi ağır bozdu
(`adverse_v5` 47 → 225), çünkü bir alt-harmonik üstündeki notanın bütün
kısmi seslerini miras alır. Yalnız temelin zayıf/yok olduğu yerde konuşacak
şekilde kapılandı (`1 - fundamental_presence` ağırlığıyla) ve 0,10–0,25
aralığında tarandı.

Ölçüm (`kShsWeight = 0,10`, kapılı):

| | SHS'siz | SHS'li |
|---|---|---|
| Holdout ciddi eksik | 142 | **131** |
| Holdout ciddi harmonik | **27** | 30 |
| `clean_v1` harmonik | **12** | 15 |
| Tuzak ciddi eksik | 1914 | **1805** |
| Tuzak ciddi harmonik | 0 | 0 |

Kapsamada 120 kare kazandırıyor, harmonikte 3 kaybettiriyor — ve kaybın
tamamı, harmonik vetosunu taşıyan tek dosya olan `clean_v1`'de. D-037'nin açık
önceliği harmonik hatanın sıfırlanması olduğu için alınmadı.

**Kalan iş:** `clean_v1`'in `hidden_fundamental_96.3` ve `_128.6`
bölümlerindeki 12 harmonik karesi. SHS bu haliyle cevap değil; gizli temele
pozitif kanıt vermenin, alt-harmoniği aynı anda güçlendirmeyen bir biçimi
gerekiyor.

### Sentetik turnuva — 6 Eylül 2026 (ikinci koşu, berraklık tabanlı ses kararı)

| Motor | Ciddi yanlış | Ciddi eksik | Ciddi harmonik | Ciddi toplam | Gecikme | Kapı |
|---|---|---|---|---|---|---|
| yin_v1 | 54 | 13 | 498 | 658 | 16 ms | — |
| pitch_engine_v2 | 6 | 536 | 495 | 1037 | 69 ms | — |
| vpm_like | 15 | 54 | 34 | 115 | 16 ms | — |
| hapt_v1 | 6 | 329 | 107 | 442 | 16 ms | — |
| **unified_v1** | 5 | **2380** | **44** | 2432 | 160 ms | **VETO (6 dosya)** |

Ciddi eksik 3146 → 2380, ciddi toplam 3192 → 2432. Veto 7 dosyadan 6'ya indi
ama duruyor. Dosya bazında marj (limit: `yin_v1`'i 0,5 puandan fazla aşmamak):

| Dosya | unified eksik | yin | Marj |
|---|---|---|---|
| adverse_v5 (tiz 840–1460 Hz, glissando + vibrato) | 189 | 0 | +17,9pp |
| adverse_v4 | 64 | 0 | +5,6pp |
| adverse_v1 | 44 | 0 | +1,9pp |
| room_v1 | 24 | 0 | +1,0pp |
| adverse_v3 | 12 | 0 | +1,1pp |
| clean_v1 | 19 | 0 | +0,8pp |

**Yapısal not:** `yin_v1` altı dosyanın hepsinde sıfır veriyor, çünkü hiç
çekimser kalmıyor — işlediği her kareyi yayımlar. Çekimserlik mekanizması olan
herhangi bir motor bu ölçütte tanımı gereği geriden başlar. Veto anlamlıdır ve
geçilmelidir, ama "0,5pp içinde kal" şartı, karşılaştırılan motorun asla
susmamasıyla birlikte okunmalıdır.

`adverse_v5`'te kalan 276 kare üç kaynağa ayrılıyor: `harmonic_dominance` 86 +
yapışkan toparlanma 52 (yani gerçek çekişme 138), `winner_posterior` 87 (taban
zaten 0,015 — bu kareler gerçekten düz), `voiced_posterior` 65. Tiz bölgede
alt-harmonik rakipler (840–1460 Hz'in yarısı ve üçte biri) spektral olarak iyi
desteklenen bölgelere düştüğü için çekişme sık. Bu, tasarımın çalışması ve
kapsamanın bedeli.

### Sentetik turnuva — 6 Eylül 2026 (ilk koşu)

| Motor | Ciddi yanlış | Ciddi eksik | Ciddi harmonik | Ciddi toplam | Gecikme | Güvenlik kapısı |
|---|---|---|---|---|---|---|
| yin_v1 | 54 | 13 | 498 | 658 | 16 ms | — |
| pitch_engine_v2 | 6 | 536 | 495 | 1037 | 69 ms | — |
| vpm_like | 15 | 54 | 34 | 115 | 16 ms | — |
| hapt_v1 | 6 | 329 | 107 | 442 | 16 ms | — |
| **unified_v1** | 5 | **3146** | **38** | 3192 | 160 ms | **VETO** |

Harmonik hatada `yin_v1` ve `pitch_engine_v2`'nin on üçte biri. Ama
`serious_missing_voiced_frames` yedi donmuş holdout'ta `yin_v1`'i 0,5 puandan
fazla aşıyor ve turnuva motoru **veto ediyor**. Bu, projenin kendi güvenlik
kuralının "hatayı sessizliğe taşıma" demesidir ve açık iştir.

Kaybın kaynağı ikiye ayrılıyor:

- **1964 kare** oktav tuzağı paketinden — temeli tamamen yok olan bölümler,
  yukarıdaki bilinen sınır. Tuzak paketi vetoya girmez.
- **1034 kare** donmuş holdout'lardan, ve neredeyse tamamı gürültülü
  varyantlarda yoğunlaşıyor: `adverse_v5` 481 kayıp / 487 doğru, `adverse_v4`
  333 / 712. Gürültü altında motor susuyor.

Ölçülen kök neden: merdivenin sesli olasılığı gürültüde çöküyor. 294 Hz saf
tonda beyaz gürültüyle:

| SNR | voiced_prob | tespit |
|---|---|---|
| 20 dB | 0,99 | 294,0 Hz ✓ |
| 12 dB | 0,83 | 293,8 Hz ✓ |
| 6 dB | **0,20** | **294,4 Hz ✓** |
| 0 dB | 0,01 | 73,7 Hz ✗ |

6 dB'de frekans hâlâ üç sent içinde doğru; atılan şey doğru cevabın kendisi.

### Ölçülüp reddedilenler

Aşağıdakiler denendi, ölçüldü ve işe yaramadı — tekrar denenmesin:

- Ses posterior tabanını 0,4'ten 0,1'e indirmek: 17922 karede 41 kare kazandırdı.
  O kareler zaten sonraki bir kapıda kalıyordu.
- Sert-sessizlik eşiğini kapının üçte birinin altına indirmek: hiçbir şey
  kazandırmadı, o kareler gerçekten sessiz.
- Ağırlığı asal-harmonik çekirdeğinden uyumsuzluk terimine kaydırmak: **daha
  kötü**. 0,15/0,85'te temeli-yok vakasında dominance 0,08'e çöküyor. Çekirdek
  gerçek bilgi taşıyor; hata çıktısının nasıl okunduğundaydı.
- Kare emisyonlarını toplama göre normalleştirip düzgün dağılım yapmak: **daha
  kötü** (`adverse_v5` 481 → 654). Kütleyi bir düzine adaya bölmek kazananı
  zayıflatıyor, çünkü motor rakipleri kasten üretiyor.
- Emisyonları en iyi adaya göre çapalamak (oranları koruyarak): nötr-kötü
  (holdout 947 → 990, `clean_v1` harmonik 6 → 12). Kapsama kaybı emisyon
  ölçeğinden gelmiyor.
- Beta önselini ses ve seçim için ayırmak (seçim dar, ses geniş): **nötr**
  (holdout 947 → 941). Kapsama kazancı ses önselinden değil, seçim
  önselinden geliyor.
- Seçim önselini genişletmek (`+0,25`): holdout kayıplarını yarıya indiriyor
  (947 → 457) **ama** `ucuncu_harmonik_baskin` bölümünde onikili hatası
  üretiyor (tuzak ciddi harmonik 0 → 6; `+0,35/0,50` ile 0 → 99). Klarnetin
  imza tınısında harmonik hata karşılığında kapsama satın almak, D-037'nin
  açık önceliğine aykırı. Alınmadı; takas tablosu kullanıcıya sunuldu.


## Çevrimdışı harmonik yol merdiveni `{1/3,1/2,2,3} -> {1/5..5}` — 31 Ağustos 2026

Kullanıcı, YIN v1 simülasyonunda iki oktav hatası bildirdi: `116,379` sn'de
`604,5 Hz` yerine `121,3 Hz` seçiliyor (spektrumda en güçlü çizgi `604,5`), ve
`143,589–143,600` sn arasında seçilen frekansın şiddeti olması gerekenden çok
küçük. İkisi de aynı kök nedene çıktı: kare, gerçek temelin **4. ya da 5.**
alt-periyodunda yayınlanıyor (`488,60/122,15 = 4,00`, `604,5/121,3 = 5,0`).

`refine_offline_harmonics` alternatiflerini `{1/3, 1/2, 2, 3}` oranlarından
kuruyordu. `121,25 Hz` yayınlanmış bir kare için bu küme yalnız `242,5` ve
`363,75` üretiyor — doğru cevap `604,5` **erişilebilir bile değildi**; Viterbi
yanlış cevaplar arasından seçiyordu. Küme `{1/5, 1/4, 1/3, 1/2, 2, 3, 4, 5}`
yapıldı.

Neden nedensel katmanda değil: `116,379` sn'de `121,27 Hz`in `5x` baskınlık
oranı `14,5`, `112,293` sn'de ise **doğru** cevap olan `264,55 Hz`in `2x`
baskınlık oranı `10,2`. İki durum spektral olarak neredeyse aynı, doğru
cevapları zıt. Salt spektral hiçbir kural ikisini ayıramaz — ayırt edici olan
zamansal bağlamdır. Denenip elenen üç ara sürüm:

| Denenen | Oktav | Bozulan koruma hücresi |
|---|---:|---:|
| `yin_candidates` oktav kurtarma: eşik `800->500 Hz`, çarpan `2x->2..5x` | `2 -> 4` | `0 -> 20` |
| `causal_yin_choice`: aday-destekli hayaleti sert eleme | `2 -> 1` | `0 -> 2` |
| `causal_yin_choice`: yalnız güven tabanı muafiyeti | `2 -> 2` | `0 -> 0` |
| **`refine_offline_harmonics` merdiveni (alınan)** | **`2 -> 1`** | **`0 -> 0`** |

Sert eleme neden kötüledi: eleme süreklilik cezasından **önce** işliyor, yani
hiçbir şeye kaybedemiyor; `112,25` sn'de doğru izlenen `267 Hz` kendi `2x`ine
sürüklendi. Çevrimdışı merdivende bu risk yok, çünkü kararı geçiş maliyeti
veriyor: `5x` alternatifi ancak komşu kareler zaten oradaysa kendini amorti
ediyor.

### Sonuç (kullanıcı hükümleri, 85 aralık, dört motor)

| Motor | Etiketli kusur | Duruyor önce | Duruyor sonra | Oktav önce | Oktav sonra | Bozulan koruma |
|---|---:|---:|---:|---:|---:|---:|
| YIN v1 | 38 | 22 | **21** | 2 | **1** | 0 |
| Pitch Engine v2 | 24 | 20 | 20 | 1 | 1 | 0 |
| VPM-benzeri | 46 | 33 | **32** | 5 | **4** | 0 |
| Harmonik-Faz (HAPT) | 50 | 33 | 33 | 1 | 1 | 0 |

İki iyileşme (`yin_v1` idx 32 `116,349`; `vpm_like` idx 66 `155,100`), **sıfır
gerileme** — 85 satırın ve dört motorun tamamında başka hiçbir hücre değişmedi.
Bildirilen iki kare: `116,3787` `121,25 -> 606,26` (referans `601,47`),
`143,5893` `122,15 -> 488,60` ve `143,6000` `121,38 -> 485,50` (komşular
`490,51 / 491,01 / 493,61`).

### Testler

`core/tests/analysis_engine_tests.cpp` içinde merdivenin **riski** kilitleniyor:
kapalı silindirde `5.` kısmi ses gerçek ve güçlüdür, dolayısıyla zayıf temelli
(`150 Hz`, baskın `3f`/`5f`) bir ton kendi `4x`/`5x`'ine terfi ettirilmemeli.
Test boş değil: `kOfflineAlternativeDiscount` savruk bir değere çekildiğinde
kırılıyor, doğru değerle geçiyor. Onarımın kendisi bu dosyanın önceki
kayıtlarındaki gerekçeyle sentetikle değil hüküm kümesiyle ölçülüyor.

`OFFLINE_TRACK_REVISION` `r6 -> offline-harmonic-path-r7` yükseltildi; aksi
hâlde değişen motorun eski çıktıları önbellekten sessizce yeniden kullanılırdı.

Doğrulama: `zsh scripts/test_core.sh` geçti, Python paketi `115 passed`,
`scripts/quick_pitch_check.py` dört motorda sıfır gerileme.


## Çevrimdışı iz revizyonu `r5 -> offline-harmonic-path-r6` — 26 Ağustos 2026

`OFFLINE_TRACK_REVISION` yükseltildi. Bu sayı `offline_track_v1` JSON
sözleşmesini değil, **önbellek kimliğini** taşır: `analyse_upload` dosya adında
bu revizyonu kullanır ve dosya varsa yeniden analiz yapmaz. Revizyon
yükseltilmeden, davranışı değişmiş motorların eski çıktıları sessizce yeniden
kullanılırdı — kullanıcı Xcode'dan çalıştırdığında hâlâ eski eğriyi görürdü.

Aynı sayı üç yerde tutuluyordu; artık testler sabit metin yerine
`OFFLINE_TRACK_REVISION` sabitini okuyor, `pitch_track_cli.cpp` ise aynı değeri
`implementation_revision` alanına yazıyor.

**Yan düzeltme:** `pitch_track_cli --contract` çıktısı satır sonu yerine düz
`\n` metni basıyordu, dolayısıyla `cpp_engine.contract()` gerçek ikiliyi hiç
ayrıştıramıyordu (testler monkeypatch'li olduğu için görünmüyordu). Düzeltildi;
`contract()` artık gerçek CLI'ya karşı çalışıyor.


## Çevrimdışı kaçak nokta elemesi — 26 Ağustos 2026

Çevrimdışı yola ikinci bir aşama eklendi: kısa, iki yanı sessiz ve yalnız düşük
güvenle yayımlanmış koşular düşürülür. Canlı yol yine dokunulmadı.

### Kural ve dayanağı

Bir koşu şu üçünü birden sağlıyorsa nokta sayılır, nota değil: en çok `7` kare,
iki yanında en az `40 ms` sessizlik, tepe güven `0,80`in altında.

`0,80` uydurulmuş bir sayı değil, **VPM-benzeri'nin kendi yayın eşiği**.
Kullanıcının kaçak işaretlediği dört aralığın tamamında doğru davranarak susan
motor VPM'di; diğerlerinin oraya bastığı koşular `0,66–0,81` güvende
kalıyordu. Kural, kısa ve yalıtılmış bir koşuyu aynı bara tutmaktan ibarettir.

### Neden çarpmayı silmiyor

Süsleme de kısadır ve kanıtı zayıftır; onu koruyan şey **iki yanındaki
sessizlik şartıdır**. Çarpma, süslediği notaya bitişiktir, sessizlikte yalnız
kalmaz, dolayısıyla kuralı hiç geçmez. Bu, eşiğe bırakılmadan
`core/tests/analysis_engine_tests.cpp` içinde kilitlendi: `40 ms` `300 Hz` +
hemen ardından `400 ms` `400 Hz` sinyalinde üç motorda da süsleme kareleri
çevrimdışı geçişten sayıca **değişmeden** çıkar.

### Ölçüm

| Motor | Kaçak öncesi | Kaçak sonrası | Toplam kusur |
|---|---:|---:|---:|
| YIN v1 | 3 | **2** | 23 → **22** |
| Pitch Engine v2 | 3 | **1** | 22 → **20** |
| VPM-benzeri | 0 | 0 | 33 → 33 |
| Harmonik-Faz (HAPT) | 2 | **1** | 34 → **33** |

Şükrü Tunar kaydında toplam `13` koşu silindi: `5`i doğrulanmış kaçak, `8`i
gerçek-değeri olmayan aralıklarda, kullanıcının "sorun yok" dediği hücrelerle
**sıfır çelişki**. Koruma ihlali VPM'de `7 -> 6` düştü.

Temkinli davranıyor: ayrı bir kayıtta (`gercek-klarnet-calm`) YIN, V2 ve VPM
tek kare silmedi, HAPT `3` kare sildi.

**Açık kalan:** silinen `8` koşu için gerçek-değer yok. Gözden geçirilmeleri
gerekir; `162,14 sn` civarındaki iki koşu (YIN ve V2 aynı anda, `~324 Hz`)
gerçek ama çok kısa bir nota olabilir.

### Üç turun toplamı

| Motor | Başlangıç | Şimdi | Oktav | Kaçak |
|---|---:|---:|---:|---:|
| YIN v1 | 35 | **22** | 14 → **2** | 3 → **2** |
| Pitch Engine v2 | 24 | **20** | 3 → **1** | 3 → **1** |
| VPM-benzeri | 46 | **33** | 18 → **5** | 0 → 0 |
| Harmonik-Faz (HAPT) | 45 | **33** | 12 → **1** | 2 → **1** |

Doğrulama: `zsh scripts/test_core.sh` geçti, Python paketi `115 passed`,
`scripts/quick_pitch_check.py` regresyon yok.


## Çevrimdışı harmonik yol iyileştirmesi — 26 Ağustos 2026

`PitchEngineProfile::offline_track` için ayrılmış yer dolduruldu.
`PitchEngine::analyse()` artık nedensel taban üzerinde **nedensel olmayan** bir
Viterbi yol araması koşuyor; `analyse_causal()` ve her `ProductionPitchSession`
dokunulmadı, yani canlı gecikme sözleşmesi aynı.

### Neden

Aynı 85 aralıkta pYIN'in **hiç** oktav hatası yok (8 kusurunun 7'si boşluk,
1'i kaçak); bizim motorlarımızda 47 vardı. Fark kestiricide değil karar
vericide: pYIN tüm kayıt üzerinde bir yol çözer, bizim motorlar nedensel karar
verir. Ölçüm bunu doğruluyor — işaretli 47 oktav hatasının **33'ü 1-3 kare**
sürüyor (medyan 2, en uzun 9 kare / 96 ms), hepsi doğru takibin ortasında izole
sıçrama. Viterbi'si olan tek motorumuz V2 ve zaten en az hata onda.

### Yöntem

Yayınlanmış her kare için aday ailesi `{f, f/3, f/2, 2f, 3f}` kurulur, adaylar
karenin **kendi analiz penceresinde** ölçülür. Nedensel karar her zaman en
yüksek yayılım skorunu alır (alternatifler `0,72` ile indirimli), bu yüzden bir
kare yalnız **yol sürekliliği** gerektirdiğinde yer değiştirir. Geçiş cezası
sent uzaklığının karesidir; `30 ms`ten uzun boşluklar ayrı bölüm sayılır.

Spektral kanıt **kapı değil fiyattır**. Kapı olarak denendi ve yanlıştı: onarıma
muhtaç karelerde doğru temel ses çoğu zaman ailenin en güçlü üyesinin `%2`sinin
altında ölçülüyor — zaten bu yüzden nedensel motor yanılıyor ve tam da orada
bilgi yalnız yolda. Kanıtsız aday elenmez, `0,30` tabanlı bir çarpanla pahalanır.

### Sonuç (kullanıcı hükümleri, 85 aralık)

| Motor | Etiketli kusur | Tur başı | Tur sonu | Oktav başlangıç | Oktav şimdi |
|---|---:|---:|---:|---:|---:|
| YIN v1 | 38 | 35 | **23** | 14 | **2** |
| Pitch Engine v2 | 24 | 24 | **22** | 3 | **1** |
| VPM-benzeri | 46 | 46 | **33** | 18 | **5** |
| Harmonik-Faz (HAPT) | 50 | 45 | **34** | 12 | **1** |

Üç turun toplamında dört motorda **oktav hatası `47 -> 9`**. Koruma hücrelerinde
yeni kusur: YIN `1 -> 0`, V2 `0 -> 0`, VPM `9 -> 7`, HAPT `3 -> 2`.

Temkinli davranıyor: farklı bir kayıtta (`gercek-klarnet-calm`) dört motorun
hiçbirinde tek kare değişmedi — körü körüne düzleştirme yapmıyor.

### Testler

`core/tests/analysis_engine_tests.cpp` iki değişmezi kilitler: (1) `realtime`
profili `analyse_causal` ile birebir aynı döner, (2) nedensel geçişin taahhüt
ettiği gerçek bir register sıçraması yol aramasından sağ çıkar. Onarımın kendisi
sentetikle değil hüküm kümesiyle ölçülür: nedensel hatayı güvenilir biçimde
tetikleyen sentetik kurulamadı — kestiriciler temiz eksik-temel durumunu doğru
çözüyor, sesi gerçekten zıplatınca da oktav zaten **doğru** cevap oluyor.

`offline_track_v1` JSON'unda değişen kareler artık
`change_reason: "offline_harmonic_path"` ile işaretlenir.

Doğrulama: `zsh scripts/test_core.sh` geçti, Python paketi `115 passed`,
`scripts/quick_pitch_check.py` regresyon yok.


## YIN v1 oktav terfisine tek-harmonik doluluk koşulu — 26 Ağustos 2026

`yin_candidates` içindeki oktav kurtarma geçişi, bir adayın `2x` frekansında
`8x` spektral baskınlık görürse o frekansı `0,99999` güvenle aday listesine
ekler ve `causal_yin_choice` onu kısa devre ile doğrudan seçer. Geçiş, CMND'nin
gerçek bir tiz temeli kendi `f/2` alt-periyodu olarak okuduğu durumu kurtarmak
için var.

Klarnette ham `2x` baskınlık tek başına yetmiyor: çalgı kapalı silindir olduğu
için çift kısmi sesler fizik gereği zayıf, dolayısıyla ince bir karede gerçek
bir temel de `2x`te baskınlanmış görünebiliyor. Ölçüm: kullanıcı hükümlerinde
YIN v1'in işaretli 13 oktav hatasının **12'si** bu geçişten geliyordu ve hepsi
`800 Hz` üzerindeydi.

Eklenen koşul: üst çizgi, terfi edilmeden önce **tek-harmonik doluluğu** da
kazanmalı — `E(3f)+E(5f)` karşılaştırması. Gerçek bir temel `3f` ve `5f`'ine
sahiptir; hayalet bir alt-harmonikte o konumlar gerçek notanın kısmileri arasına,
boşluğa düşer.

| Motor | Etiketli kusur | Tur öncesi | Tur sonrası | Oktav öncesi | Oktav sonrası |
|---|---:|---:|---:|---:|---:|
| YIN v1 | 38 | 35 | **27** | 14 | **6** |
| Pitch Engine v2 | 24 | 24 | 24 | 3 | 3 |
| VPM-benzeri | 46 | 46 | **37** | 18 | **9** |
| Harmonik-Faz (HAPT) | 50 | 45 | **44** | 12 | 11 |

Dört motorda toplam oktav hatası `47 -> 29`. Hiçbir motor kötüleşmedi; "sorun
yok" denen hücrelerde YIN `1 -> 0`, VPM `9 -> 7`, HAPT `3 -> 2`.

Elenen alternatifler: kurtarma geçişini tamamen kapatmak `-12` verirdi fakat
tasarlanmış güvenliği kaldırır; `causal_yin_choice` kısa devresini kaldırmak tek
başına yalnız `-2`, tek-harmonik testiyle birlikte ek kazanç `0`.

Regresyon testi `core/tests/analysis_engine_tests.cpp` içinde: güçlü `3f`/`5f`,
zayıf `2f` taşıyan sentetik klarnet tonu `480 Hz`te bulunmalı ve `960 Hz`te
**hiç** kare yayınlanmamalı. Test, düzeltme geri alındığında kırılıyor.

Doğrulama: `zsh scripts/test_core.sh` geçti, Python paketi `115 passed`,
`scripts/quick_pitch_check.py` regresyon yok.

Kalan `29` oktav hatasının yapısı: `+3x` (on ikili, klarnetin gerçek aşırı
üfleme aralığı) ve `120–160 Hz` bandındaki aşağı yönlü hatalar. İkincisi için
tabanı `145 Hz`e çekmek `7` hata daha alırdı; sol klarnetin en pes sesini
(`~123,5 Hz`) kestiği için yapılmadı.


## Üretim oturumu perde tabanı 80 -> 120 Hz — 26 Ağustos 2026

`AnalysisEngineConfig::minimum_frequency_hz` 80 Hz'den 120 Hz'e çıkarıldı. Bu bir
görüntüleme tercihi değil: değer öz-ilinti gecikme aramasını
(`rate / minimum_frequency_hz`) sınırlar ve fazla geniş bir gecikme aralığı,
ACF'nin gerçek periyodun katına kilitlenip alt-harmonik yayınlamasına yol açar.

Kanıt: Şükrü Tunar kaydı için kullanıcının dinleyerek verdiği hükümler
(`data/annotations/sukru-tunar-ussak-taksim.verdicts.v1.json`, 85 aralık, 8,7 sn).
İşaretlenen aşağı yönlü oktav hatalarının tamamı `83–160 Hz` arasına iniyordu;
motorların uzlaştığı hiçbir kare `146 Hz`in altında değil. Taban seçimi Türk
sol klarnetinin en pes duyulan sesini (`~123,5 Hz`) korumak üzere 120 Hz'dir;
daha dar bir taban burada biraz daha kazandırırdı fakat o çalgıda gerçek pes
notaları keserdi.

| Motor | Etiketli kusur | Önce duruyor | Sonra duruyor | Oktav önce | Oktav sonra |
|---|---:|---:|---:|---:|---:|
| YIN v1 | 38 | 35 | 35 | 14 | 14 |
| Pitch Engine v2 | 24 | 24 | 24 | 3 | 3 |
| VPM-benzeri | 46 | 46 | **37** | 18 | **9** |
| Harmonik-Faz (HAPT) | 50 | 45 | **44** | 12 | 11 |

"Sorun yok" denen hücrelerde yeni kusur da azaldı: YIN `1 -> 0`, VPM `9 -> 7`,
HAPT `3 -> 2`, V2 `0 -> 0`. Hiçbir motor kötüleşmedi.

Elenen alternatifler (aynı ölçüm kümesinde): VPM `minimum_absolute_spectral_amplitude`
`0,005 -> 0,010/0,020/0,040` yalnız `-2` kazandırdı ve platoya oturdu;
`maximum_period_multiple` `6 -> 3` ve `-> 2` **hiçbir etki yapmadı**. İkincisi,
aşağı yönlü hataların spektral alt-harmonik düzeltmesinden değil doğrudan ACF
aday üretiminden geldiğini kanıtlar.

Bağımsız estimator'lar (`VPMLikeConfig`, `HAPTConfig`) kendi 80 Hz
varsayılanlarını korur; yalnız üretim oturumu daralır, bu yüzden çekirdek
aralık testleri (ör. VPM 110 Hz tonu) etkilenmez.

Yeniden üretim:

```sh
.venv/bin/python -B scripts/quick_pitch_check.py --baseline outputs/quick-pitch-baseline.json
```

Doğrulama: `zsh scripts/test_core.sh` geçti, Python paketi `115 passed`.
Kalan açık iş: YIN/V2'nin yukarı yönlü `+2x`/`+3x` hataları (17 hücre) ve
kaçak noktalar bu turda ele alınmadı.

# Pitch Test Tabanı

Son güncelleme: 13 Ağustos 2026

Bu yaşayan belge, bir pitch motoru değişikliğinin kabul edilmesi için korunacak
ölçümleri ve doğrulama komutlarını tanımlar. YIN v1'in tarihsel kararlı sınırı
`PitchEngineBaseline.md` içinde saklanır.

## Ürün motor politikası

YIN v1, Pitch Engine v2 ve VPM-benzeri üç eşit son kullanıcı seçeneğidir.
Buradaki sentetik turnuva, parite, gecikme ve RTF ölçümleri motoru terfi
ettirmek, kullanıcıya öneri sunmak veya bir kalite kazananı ilan etmek için
kullanılmaz; yalnız her motorun regresyon güvenliğini izler. YIN v1'in ilk
açılıştaki seçili değeri geriye uyumluluk içindir. Her motor değişikliğinde
üç kimlik de aynı kapılardan geçer; Çalışma önbelleğinde motor kimliği ve
`offline_track` profil sürümü ayrık kalır.

## Ortak C ABI v1 sözleşme kapısı

`core/tests/analysis_engine_c_tests.cpp`, ABI sürümü, üç motor yeteneği,
48 kHz mono Float32 PCM sözleşmesi, `1536/512` pencere-hop, v2'nin beş kare
sabit gecikmesi, create/reset/process/finish/destroy yaşam döngüsü ve C++
`ProductionPitchSession` ile C adaptörü kare eşitliğini korur. Python
`tests/test_cpp_engine.py`, paketli CLI'nin aynı `--contract` projeksiyonunu
ve `offline_track_v1` şemasını doğrular. Bu kapı motor kalitesini sıralamaz.

## Üç kullanıcı-seçeneği v1 yeniden kabulü

13 Ağustos'ta dondurulmuş v6 clean/room/adverse fixtures, üretim C++ Çalışma
yolunda üç motor için yeniden ölçüldü: ciddi hata YIN/V2/VPM için sırasıyla
`0/0/0`. Ham sesli/sessiz/harmonik muhasebesi, CLI duvar-zamanı RTF'i ve
fiziksel kabul kapsamı `PITCH_ENGINE_USER_OPTION_ACCEPTANCE_V1.md` içindedir.
Bu yalnız seçenek kabulüdür; motor sıralaması, önerisi veya varsayılan değişimi
değildir.

## Beta snapshot doğrulaması — v0.6.0-beta.2

13 Ağustos'ta fiziksel macOS beta kabulünün ardından aynı kaynakta C++ çekirdek
testleri, Python `77 passed`, Swift Package `41` test (iki isteğe bağlı parite
dışa aktarma testi atlandı), imzasız Debug derlemesi ve Release paketleme
yeniden geçti. Bu snapshot üç son kullanıcı motorunu (`yin_v1`,
`pitch_engine_v2`, `vpm_like`) birlikte içerir; bu kayıt motor terfisi veya
varsayılan değişikliği değildir.

## Beta snapshot doğrulaması — v0.6.0-beta.3

13 Ağustos'ta P1 erişilebilirlik kabul kaydından sonra oluşturulan annotated
kaynak kontrol noktasıdır. C++ çekirdek testleri, tam Python paketi (`79
passed`), Swift Package (`44 passed`, iki isteğe bağlı çapraz-dil parite dışa
aktarma testi atlandı), imzasız Release paketleme, sıkı ad-hoc imza doğrulaması
ve paketli `pitch-track-cli --contract` geçti. Kontrat ABI v1,
`offline_track_v1` ve `yin_v1`, `pitch_engine_v2`, `vpm_like` üçlüsünü
doğrular. Bu kayıt yalnız sürüm tekrarlanabilirliği içindir; motor terfisi,
önerisi veya varsayılan değişikliği değildir.

## VPM-benzeri r5 ciddi-hata sıfır kabulü — 12 Ağustos 2026

VPM kare kestiricisi ve `0.80` normal yayın eşiği değişmeden, ortak
`ProductionPitchSession` yayın katmanı güçlü kontur, en çok yedi karelik
geri-dönebilir dropout ve gerçek release durumlarını ayırır. Zayıf kontur
tutma yalnız `periodicity >= 0.38`, `±90 sent` ve doğrudan temel desteğiyle
çalışır; güçlü ankrajı değiştirmez. Kurulmuş üst çizginin düşük aday çizgisine
oranı en az `2.5x` ise yalnız aşağı harmonik ada veto edilir; spektrum yeni üst
perde üretmez ve D-011 korunur.

| Motor | Nedensel ciddi | Ham ciddi | Görünen ciddi | Ham toplam |
|---|---:|---:|---:|---:|
| VPM-benzeri (26 WAV) | 0 | 0 | 0 | 5130 |

Başlangıç VPM sonucu `43/43/43` ciddi ve `5722` ham hataydı. Yeni rapor
`outputs/study-mode-vpm-remediation.*`, parmak izi
`7017a860bd5cfd27791e714a62338b162f0cbee23779cfa76c75f000ed0b8499`.
V6 clean/room/adverse ayrı ayrı `0/0/0`; rapor parmak izi
`61ec82a8d1c1ba78dc05323951379c8dc29e28ae3f3e2b8759ce99602f4434d3`.
YIN v1 kabul özeti değişmedi; V2 raporu parmak izi dahil aynı kaldı.
Üç motorun 78 vakalık birleşik r5 rapor parmak izi
`99019e5e5238e40daa1efadaf0f7832de67d2ef6c1642061934bb675c82a6909`.

Şükrü Tunar gerçek kayıt tanısında önceki yayın katmanına göre ortak pYIN
kapsaması `%98.009 -> %96.754`, p95 `22.514 -> 22.220 sent`, harmonik sapma
`41 -> 30` oldu. Bu yalnız regresyon tanısıdır; pYIN gerçek-değer sayılmaz ve
kare kestiricisi eşikleri yeniden kalibre edilmedi. Rapor:
`outputs/vpm-real-recording-regression-r5.json`.

`pitch_track_cli --diagnostic` VPM için normal `offline_track_v1` şemasından
ayrı RMS/tepe, periodicity, normal/zayıf kestirim, doğrudan destek, release,
pending-gap, harmonik veto ve yayın gerekçesi JSON'u üretir. Revizyon
`shared-production-session-r5`; `1536/512`, `0.015 RMS` ve 16 ms karar
gecikmesi değişmemiştir.

## Pitch Engine v2 r4 ciddi-hata sıfır kabulü — 12 Ağustos 2026

V2 sabit-gecikme kuyruğu artık yapay sıfır analiz pencereleriyle değil,
oturumun `finish` çağrısında elde kalan gerçek aday tamponuyla çözülür.
Sonlandırılmış oturum yeni giriş kabul etmez; `reset` yeni yol açar. Yayın
kapıları her zaman çözülen kaynak karenin RMS/release durumuna uygulanır.

Hızlı iki RMS düşüşü release’i etkinleştirir; yavaş fade’de aynı konturdaki
en az `0.55` kanıtlı adaylar ve kısa (en çok yedi kare) dönüş köprüsü korunur.
Normal yayın kapısı `0.70`, ortak RMS eşiği `0.015`, pencere/hop `1536/512`
ve V2’nin beş-hop gecikmesi değişmemiştir.

| Motor | Nedensel ciddi | Ham ciddi | Görünen ciddi |
|---|---:|---:|---:|
| Pitch Engine v2 (26 WAV) | 0 | 0 | 0 |

V2 ham toplamları önceki `5694/5678/5678`den `5191/5191/5191`e indi.
Geliştirme raporu `outputs/study-mode-v2-remediation.*`, parmak izi
`20cb002f5df18a1bfbb5d370b8d5728de040c9381d072c4cec77490e00bbf4c3`.
V6 clean/room/adverse üçlüsünde de V2 `0/0/0`dır; parmak izi
`bfb3c9f8767b8427ba3749a289eb29f172c51145feab07895f5eebe315e6e4f3`.

## Tek üretim oturumu ve Çalışma kabulü — 12 Ağustos 2026

Canlı Swift ve dosyadan Çalışma artık üç motor için aynı durumlu C++
`ProductionPitchSession` oturumunu kullanır. `offline_track_v1` JSON'u nihai
`frames` yanında `causal_baseline`, kare başına `change_reason`, motor profili
ve `shared-production-session-r3` uygulama revizyonunu taşır. YIN ve VPM'de
çevrimdışı iz nedensel tabanla aynıdır; V2 yalnız dosya sonundaki sabit gecikme
kuyruğunu kaynak zamanlarını değiştirmeden boşaltır.

26 geliştirme WAV'ının son tek kabul koşusu:

| Motor | Nedensel ciddi | Ham ciddi | Görünen ciddi |
|---|---:|---:|---:|
| YIN v1 | 0 | 0 | 0 |
| VPM-benzeri | 43 | 43 | 43 |
| Pitch Engine v2 | 78 | 65 | 65 |

YIN düzeltmesi, güçlü doğrudan üst-register çizgisini düşük alt-periyot yerine
seçer, yalnız aşağı yönlü büyük harmonik sıçramayı onaylar ve ani release'i
uzun müzikal fade'den ayırır. Tam YIN raporu
`outputs/study-mode-yin-v1-remediation.*`; parmak izi
`c5003d284f6a59feab44a7d8f521553df8975066723d68ac48da596f4b14557a`.
Ham YIN hata toplamı `5.126`; ciddi toplam `0`dır.

Sonuçları görülmeden üretilip dondurulan holdout v6 kabulü:

| Motor | Clean | Room | Adverse |
|---|---:|---:|---:|
| YIN v1 | 0 | 0 | 0 |
| Pitch Engine v2 | 0 | 0 | 0 |
| VPM-benzeri | 0 | 0 | 7 |

v6 rapor parmak izi
`a1ae287d75b04fb64f52e5ded871be44c827b2a8ee0fad84cc475e60b9587346`.
VPM adverse hataları `0.59–0.62 sn` dört harmonik ve `3.94–3.96 sn` üç
harmonik karedir. Sonuç açıldıktan sonra eşik ayarlanmadı; bu nedenle VPM'nin
adverse kabul kapısı açıkça başarısız ve motor deneysel kalır.

Son doğrulama: C++ çekirdek ve C ABI oturum testleri geçti; Python
`75 passed`; Swift Package `11 passed`, yalnız ortam değişkeni isteyen iki iz
dışa aktarma testi atlandı; kod imzasız macOS Debug derlemesi başarılıdır.

## Taşınabilir C++ çalışma profili — 10 Ağustos 2026

`core/include/klarivision/core/analysis_engine.hpp` üç ürün motoru için ortak
PCM sınırını tanımlar. `klarivision_pitch_track_cli`, WAV'ı mono 48 kHz
Float32'a getirir ve seçili motorun `offline_track_v1` JSON'unu üretir.
Çalışma profilinde YIN/V2/VPM ayrı aday ve yol kuralları taşır; sonuçta
hareketli ortalama veya pYIN/Vamp bağımlılığı yoktur.

Başlangıç birim kapısı, 48 kHz 440 Hz sentetik tonun üç motorla sesli ve
yaklaşık 440 Hz çıkmasını; eşik altı sessizliğin boş kalmasını doğrular.
Kapsamlı sentetik turnuva ve Swift canlı-C++ iz paritesi, Swift üretim
uygulamaları kaldırılmadan önce zorunlu terfi kapılarıdır.

## Çalışma modu sentetik gerçek-değer kapısı — 12 Ağustos 2026

`scripts/run_study_mode_synthetic_validation.py`, uygulamanın Çalışma
yolunu doğrudan ölçer: kaynak WAV önce aynı mono/48 kHz dönüşümden geçer,
ardından paketli C++ `offline_track_v1` CLI sonucu oluşturulur. Her sentetik
WAV, ham JSON ve `prepare_display_frames` sonrası kullanıcıya çizilen eğri
olarak ayrı ayrı matematiksel hedefe karşı beşli muhasebeyle puanlanır.
Gerçek `klarnet_gercek_*` kayıtları bu gerçek-değer raporunun dışındadır.

```bash
.venv/bin/python -B scripts/run_study_mode_synthetic_validation.py
```

Raporlar `outputs/study-mode-synthetic-validation.json` ve `.md` dosyalarına
yazılır. Sentetik bir kaynak Çalışma'da açıldığında hedef eğri ve kalıcı hata
aralıkları grafikte isteğe bağlı katman olarak görünür; normal kullanıcı
kayıtlarına doğrulama katmanı eklenmez.

## Pitch Engine v2 geçiş ve üretim paritesi — 10 Ağustos 2026

V2 önce Python benchmark aynası ile gerçek Swift referans yayın yolunda,
ardından ortak C++ oturumu ile aynı Swift referansında doğrulandı. Her iki kapı
26 sentetik WAV'ın tamamını aynı Float32 giriş, `1536/512` pencere-hop ve
`0.015 RMS` kapısıyla çalıştırır. Kabul sınırı aynı sesli/sessiz karar,
`≤1 sent` frekans ve `≤0.01` güven farkıdır.

- Python / Swift geçiş kanıtı: `67.354 / 67.354` kare, `0` ayrışma
- C++ / Swift üretim paritesi: `67.354 / 67.354` kare, `0` ayrışma
- C++ stress-adverse canlı profili: `66.39 sn` ses, `1.3576 sn` çalışma,
  RTF `0.02045`
- Sabit gecikme: `5` hop; yayın kapısı: `0.70`; kısa boşluk: en çok `7` kare

Raporlar `outputs/v2-python-swift-trace-parity.*`,
`outputs/v2-cpp-swift-trace-parity.*` ve
`outputs/v2-cpp-realtime-profile.json` içindedir. Swift canlı V2 seçimi C ABI
oturumuna, Python turnuva adaptörü aynı C++ iz aracına yönelir. Swift/Python
algoritma gövdeleri yalnız geçiş oracle'ı olarak kalır. Kararlı YIN v1
varsayılanı değiştirilmemiştir.

```bash
.venv/bin/python -B scripts/check_v2_swift_python_parity.py
.venv/bin/python -B scripts/check_v2_swift_python_parity.py --cpp \
  --output outputs/v2-cpp-swift-trace-parity.json
```

## VPM-benzeri C++ / Swift üretim paritesi — 10 Ağustos 2026

`scripts/check_vpm_swift_cpp_parity.py`, gerçek C++ turnuva izini uygulamanın
gerçek Swift VPM yayın yoluyla karşılaştırır. İki taraf aynı Float32 örnekleri,
`1536` pencereyi, `512` hop'u, `0.015 RMS` kapısını ve kaynak analiz penceresi
merkezi zamanını kullanır; karar gecikmesi izden çıkarılmaz. Sesli/sessiz
kararı birebir aynı olmalı, eşleşen sesli karelerde frekans farkı `≤1 sent`,
güven farkı `≤0.01` kalmalıdır.

Turnuvadaki iki gerçek kayıt dışındaki 26 sentetik WAV sonucu:

- C++ yayımlanmış kare: `67.595`
- Swift yayımlanmış kare: `67.595`
- sesli/sessiz ayrışması: `0`
- frekans ayrışması: `0`
- güven ayrışması: `0`

Kalıcı rapor: `outputs/vpm-swift-cpp-trace-parity.json` ve `.md`. Bu kapı VPM
için geçmiştir; V2 için kanıt sayılmaz. Pariteyi sağlayan sözleşme Swift'te
C++ ile aynı `0.80` yayın eşiği, üç-onaylı yalnız-aşağı harmonik kapısı, Hann
spektral genlik normalizasyonu ve sert sinyal kapısında sona eren en çok yedi
karelik VPM boşluk köprüsüdür. V2'nin ayrı köprü davranışı korunur.

```bash
.venv/bin/python -B scripts/check_vpm_swift_cpp_parity.py
```

## Beşli kare muhasebesi

Sentetik gerçek-değer raporları kapsama, medyan, p95 ve yüzde/oran metrikleri
kullanmaz. Referansın her 10 ms karesi, motor karesiyle `0.55 × hop` zaman
toleransında bire bir eşleştirilir; bir motor karesi ikinci kez kullanılamaz.

- **Yanlış sesli:** Referans sessizken motorun sesli kare yayımlaması.
- **Eksik sesli:** Referans sesliyken motor karesi olmaması.
- **Doğru perde:** İki kare sesliyken mutlak sent farkının `≤50` olması.
  Sayı ile yalnız bu karelerin ortalama mutlak sent farkı raporlanır.
- **Harmonik hata:** Fark `>50` sentken imzalı farkın `1/3×`, `1/2×`, `2×`
  veya `3×` hedefine en fazla `90` sent uzak olması.
- **Harmonik olmayan hata:** Fark `>50` sentken harmonik koşulunun sağlanmaması.

Her rapor `reference_voiced_frames`, `reference_silent_frames`, beşli sayımlar,
`correct_pitch_absolute_cents_sum`, `correct_pitch_mean_absolute_cents` ve
`total_error_frames` alanlarını taşır. Sesli toplam, `eksik + doğru + harmonik
+ harmonik olmayan`; sessiz toplam, `doğru sessizlik + yanlış sesli` olmalıdır.
- **Kalıcı ayrışma:** Kısa tek-kare gürültüsünden farklı olarak belirli süre
  devam eden motor/referans uyuşmazlığı.
- **Eksik sesli nokta:** Matematiksel hedef sesliyken, `0.55 × hop` zaman
  toleransında motorun hiç yayınlamadığı referans örneği. Üç ardışık örnek
  (yaklaşık 30 ms) kalıcı eksik perde aralığı olarak ayrıca raporlanır.

## Algılanabilir hata katmanı

Ham beşli sayımlar değişmez; `near_pitch_frames` ham harmonik-olmayan
sayımın `50–100 sent` alt kümesidir. Renkli hata katmanı ve turnuva seçimi
yalnız ciddi sayımları kullanır: `serious_*_frames` ve
`serious_total_error_frames`.

- Hedef rejimi geçişinin `±30 ms` içindeki hata kareleri
  `transition_tolerated_frames` olur.
- Geçiş dışında üç ardışık kareye ulaşmayan hata koşuları
  `transient_tolerated_frames` olur.
- Harmonik olmayan ciddi hata `>100 sent` olmalıdır; harmonik hedefler
  mevcut `±90 sent` penceresini kullanır.
- Turnuva vetosu, bir vakada ciddi sınıf oranının YIN v1'i ilgili referans
  paydasında `0.5` yüzde puanından fazla aşmasıdır.

Holdout v2 bu politikanın geliştirme kanıtıdır. Kabul sonucu, politika
kilitlendikten sonra üretilen `klarivision_pitch_tournament_holdout_*_v3`
üzerinden alınır.

## Yüksek glissando ve eksik-perde kontrolü

Doğrudan kaynak doğrulaması artık hem yayımlanmış noktaları hedefe karşı
ölçer hem de her sesli hedef örneği için bir motor noktası arar. Böylece
yüksek glissando sonunda çizginin kaybolması yalnız p95 hesabından düşmez;
`missing_voiced_points`, kapsama, en uzun boşluk ve `900–1500 Hz` bandı
ayrıca raporlanır. Grafikte bu aralıklar pembe bant, beklenen perdeler pembe
nokta olarak gösterilir.

V2 yüksek-register adayını yalnız en az iki kestirici `55 sent` içinde
uzlaşıyorsa yayınlar. VPM-benzeri yeni iz için `0.80` güveni korur; kurulmuş
bir `>900 Hz` konturunda ACF/spektrum uzlaşıyor, hareket `180 sent/hop`u
aşmıyor ve güven `≥0.70` ise yayın sürer. Desteklenen aralık `80–1500 Hz`dir.

Kilitli holdout v2 sonucu: clean/room/adverse varyantlarının her birinde V2
ve VPM-benzeri `900–1500 Hz` kapsaması `%100`, eksik nokta sayısı `0`dır.
YIN v1 aynı bandın clean/room/adverse varyantlarında sırasıyla `14/17/51`
eksik nokta üretmiştir. Turnuva v2 parmak izi
`ef7d4aaeaadbba9f0eb7f2b8910a39c7b48f15069a0120a3662a2189db5ba264`.

## YIN v1 holdout v2 ciddi-hata sıfır adayı

## YIN v1 v1–v3 ciddi-hata sıfır doğrulaması — 9 Ağustos 2026

YIN v1 aynası, bağımsız v1, v2 ve v3 holdout'larının clean/room/adverse
varyantlarının her birinde `0` ciddi hata verdi. İyileştirme v4 ile
ayarlanmadı: kısa giriş kesintisi ancak ham aday ve düzeltilmiş kontur önceki
perdeye `±90 sent` içinde dönüyorsa kaynak zamanında tamamlanır; düşük enerjili
oda kuyruğu `güven < 0.90` ve göreli RMS kapısıyla sessiz bırakılır; sürekli
üst kontur tek pencerenin alt-harmonik enerji tercihiyle aşağı çekilmez.

Swift YIN v1 yolu aynı kapıları uygular. v4 yalnız kabul kontrolüdür; bu
değişiklikten sonra clean/room/adverse sonuçları `0/0/0` ciddi hatadır.
Dosyadan doğrulamada v3/v4 için açık analitik-manifest yönlendirmesi zorunludur;
aksi halde v1 hedefinin yanlış seçilmesi motorla ilgisiz büyük hata sayımları
üretir.

## Pitch Engine v2 v1–v3 geliştirme sonucu — 9 Ağustos 2026

V2 aynası v1–v3 clean/room/adverse dokuz varyantında `0` ciddi hata verdi.
Yüksek register yayınında çapraz uzlaşı kaybolursa yalnız `>900 Hz`,
periyodiklik `≥0.90` ve prime-harmonic destek `≥0.75` ortak koşuluyla yayın
sürer. Düşük enerjili release kuyruğu sessizdir; sabit-gecikmeli yol kısa
boşluğu yalnız aynı kaynak konturu `±90 sent` içinde geri dönerse tamamlar.

Bu kurallar v1–v3 geliştirme setleriyle ayarlandığı için kabul kanıtı değildir.
V4, ilk ölçümde `accept4_anchor_1489.1` bölümünde harmonik hata gösterdi.
V2 analiz aday aramasına (gösterim aralığı değişmeden) `1650 Hz` koruma bandı,
güçlü `2x` spektral ortak aday ve dengeli periyodiklik/prime-harmonic yolu
eklendi. Kullanıcı onayıyla V4 zorlu varyantı doğrudan düzeltildi; yüksek
register yayın kapısının prime-harmonic eşiği `0.80 -> 0.75` oldu. V1–V5
clean/room/adverse bütün ölçümlerde ciddi hata `0`dır.

## VPM-benzeri V1–V5 ciddi-hata sıfır doğrulaması — 9 Ağustos 2026

VPM-benzeri C++ çekirdek, 1500 Hz ekran sınırını değiştirmeden `1650 Hz`
analiz koruma bandı kullanır. Böylece sınırdaki gerçek temel, f/2 adayına
karşı değerlendirmeye alınır. C++ turnuva yayımlayıcısı ve Swift canlı yolu,
kısa boşluğu yalnız önceki kontura `±90 sent` içinde geri dönüş varsa en çok
yedi kaynak karesiyle tamamlar. V1–V5 clean/room/adverse 15 ölçümün tamamında
ciddi hata `0`dır.

9 Ağustos 2026'da üst-register kurtarma, seçilmiş tek YIN sonucundan bütün
`>=0.55` güvenli YIN adaylarının güçlü `2x/3x` spektral eşlerine genişletildi.
Her üst eş kendi kaynak tepesine göre `80x` ve pencere enerji ölçeğine göre
`0.008` kapısını birlikte geçer. `0.76` altı güven ile yakın RMS tepesinin
`%20` altına düşen kısa release kuyruğu yayınlanmaz.

| V2 vaka | Önce ciddi toplam | Sonra ciddi toplam | Önce ham toplam | Sonra ham toplam | Sonra doğru ort. sent |
|---|---:|---:|---:|---:|---:|
| clean | 59 | 0 | 191 | 113 | 1.524912 |
| room | 122 | 0 | 299 | 147 | 1.572736 |
| adverse | 263 | 0 | 431 | 106 | 1.591347 |

Holdout v3 ve v4 clean/room/adverse vakalarının her birinde YIN ciddi toplamı
`0` kaldı. Azami YIN CPU RTF `0.22244`, karar gecikmesi `16 ms`; tam turnuva
parmak izi `c84fbbad45f3c526802e1eab42a9c2105dfde06e73d00ba6fbd05897db299db8`.
Bu değişiklik v2'ye göre geliştirildiğinden bağımsız yeni kabul kanıtı değildir
ve kullanıcı kontrolü beklenmektedir.

## Deneysel kısa harmonik sıçrama koruması

Swift canlı/dosyadan-test V2 ve VPM-benzeri yolları, önceki yayınlanmış
perdeyle yaklaşık `1/3`, `1/2` veya `2/3` ilişkili aşağı yönlü büyük bir
sıçramayı ilk karede tutar; aynı yeni perde bir sonraki hopta sürerse kabul
eder. Yanlış alt harmonikten doğru perdeye yukarı dönüş geciktirilmez. Bu bir
hareketli ortalama değildir: normal küçük nota hareketi ve vibrato korunur.
V2'nin mevcut beş-hop gecikmesine ek olarak yalnız bir onay-hop'u gerektirir;
VPM-benzeri yolda bu varsayılan `512` örnek hop ile yaklaşık 11 ms'dir.

Bu değişiklik için henüz turnuva sonucu yoktur; kullanıcı önce canlı deneme
istemiştir. Turnuva çalıştırıldığında önce/sonra raporu, tek-hop harmonik hata
oranını ayrıca vermeli; kapsama, gerçek nota geçiş yerleşme süresi ve vibrato
genliği de korunmalıdır.

Adverse holdout v1 ile yapılan ilk kullanıcı denemesi iki ek kusuru gösterdi:
VPM spektrumu bazı doğru/en-güçlü ACF sonuçlarını `f/2` değerine indiriyor ve
simetrik çıkış kapısı doğru perdeye yukarı dönüşü de geciktiriyordu. C++/Swift
güçlü-ACF kilidi ve yalnız-aşağı çıkış kapısıyla güncellendi. Matematiksel
referans değerlendirmesinde `25 ms` üzerindeki boşluklar artık interpole
edilmez. Holdout v1 bu teşhiste kullanıldığından yeni kural için bağımsız
holdout sayılmaz; kabul ölçümü görülmemiş yeni holdout v2 üzerinde yapılmalıdır.

## Referans hiyerarşisi

1. Matematiksel hedefi bulunan sentetik benchmark gerçek-değerdir.
2. Doğrulanmış bağımsız clean/room kayıtları holdout testidir.
3. Gerçek icralarda pYIN kararlı referanstır; gerçek-değer değildir.
4. Mikrofon testi, hoparlör/oda/dış ses sağlamlığını gösterir fakat otomatik
   eşik ayarının tek kaynağı olamaz.

## VPM-benzeri kabul tabanı

`outputs/vpm-like-calibration.json` içindeki seçili konfigürasyon korunur:

| Kayıt | Kapsama | p95 sent | Harmonik hata |
|---|---:|---:|---:|
| stress clean | %99.882 | 24.258 | %0.0000 |
| stress clarinet | %99.882 | 24.263 | %0.0000 |
| stress adverse | %100.000 | 28.143 | %1.2036 |
| Şükrü Tunar / pYIN ortak kareleri | %100.000 | 32.614 | %0.4251 |
| validated clean holdout | %100.000 | 25.274 | %0.0000 |
| validated room holdout | %100.000 | 25.796 | %0.0000 |

Kalibrasyon seçim kuralı: ağırlıklı pitch/harmonik hata azalmalı ve hiçbir
kaynakta kapsama başlangıca göre 2 yüzde puanından fazla düşmemelidir.

Şükrü Tunar için izlenecek aralıklar:

- `79–83 sn`: p95 `14.70`, 0 harmonik kare
- `106–107 sn`: p95 `23.65`, 0 harmonik kare
- `111–113 sn`: p95 `1207.78`, 7 harmonik kare; bağımsız doğrulama gerekli
- `130–133 sn`: p95 `7.94`, 0 harmonik kare
- `150–154 sn`: p95 `15.94`, 3 harmonik kare

Tam aday raporunda eski seçimdeki 45 harmonik ayrışmanın 32 tanesi ACF/pYIN
uzlaşmasına rağmen spektral `2x/3x` terfisiydi. Düzeltmeden sonra aynı üç hedef
aralıkta 16 harmonik ayrışma kaldı. Kalanlar otomatik olarak motor hatası kabul
edilmez; gerçek kayıtta pYIN kesin gerçek-değer değildir ve JSON'daki `0.95`
güven alanı gerçek Vamp olasılığı değil sabit içe aktarma vekilidir.

## Otomatik kontroller

```bash
zsh scripts/test_core.sh
.venv/bin/python -B -m pytest -q
.venv/bin/python scripts/calibrate_vpm_like_engine.py
.venv/bin/python scripts/run_pitch_engine_tournament.py
```

## Tüm sentetik WAV turnuvası — 9 Ağustos 2026

26 sentetik WAV'ın tümü ortak `0.015 RMS` kapısı ve 10 ms etkin analitik
gerçek-değerle ölçüldü; iki gerçek `klarnet_gercek_*` WAV dışarıda bırakıldı.
Toplam 22 sesli formül karesi WAV'ın merkezlenmiş penceresi eşik altında
kaldığı için etkin hedefte boş bırakıldı. İki koşu aynı deterministik parmak
izini (`685e73dda06e598b2c56afc51cfdcfa5aff2202bba31ffd5e62fc8f4da467b4d`)
verdi.

| Motor | Ciddi toplam | Ciddi olmayan | Ham toplam | Doğru-kare ort. sent |
|---|---:|---:|---:|---:|
| YIN v1 | 48 | 5686 | 5734 | 1.668 |
| Pitch Engine v2 | 58 | 5577 | 5635 | 1.600 |
| VPM-benzeri | 40 | 5686 | 5726 | 1.543 |

Sayısal kazanan VPM-benzeridir. Bu 9 Ağustos raporu üretildiğinde C++/Swift iz
paritesi doğrulanmadığı için `candidate_requires_parity` sonucu oluştu ve
kullanıcı varsayılanı YIN v1 olarak kaldı. VPM paritesi 10 Ağustos'ta üstteki
ayrı kapıyla doğrulandı; tarihsel turnuva kararı geriye dönük değiştirilmedi.
Rapor şeması `klarivision-pitch-engine-tournament-all-synthetic-v2`dir.

## Pitch motoru turnuvası v1

## Turnuva v4 geliştirme aynası — 9 Ağustos 2026

VPM-benzeri C++ izleyicisi kısa aşağı `1/2`/`1/3` harmonik adayını, yerleşik
üst konturun spektral desteği sürerken üç kare doğrulamayla sınırlar. V3 adverse
holdout'ta ciddi harmonik hata `4 -> 0`, VPM ham toplamı `336 -> 279` oldu.
V2 gecikme adayları `{2,3,4,5}` sözleşmesine açıldı; dört-hop denemesi v2
adverse kaydında üç ciddi hata verdiği için kabul edilmedi ve beş-hop
gecikme korundu.
Bu ölçümler V1–V3 holdout'larıyla ayarlandığı için kabul kanıtı değildir;
ayrı, dondurulmuş V4 holdout üzerinde tek sefer çalıştırıldı. V4'te iki aday
`accept4_anchor_1489.1` yüksek-anchor bölümünde ciddi harmonik hata sınıf
vetosunu geçti; bu nedenle resmi kazanan ve varsayılan YIN v1 olarak kaldı.
V4'e göre yeniden ayar yapılmaz; sonraki deneme yeni V5 holdout gerektirir.

Turnuva `klarivision-pitch-engine-tournament-v1` rapor şemasını kullanır.
Pitch zaman damgası kaynak analiz penceresinin merkezidir; otomatik global
offset yoktur. Yarım pencere ve v2'nin beş hop sabit gecikmesi ayrı raporlanır.

Seçim kapıları: hiçbir holdout varyantında YIN v1'e göre kapsama `2` yüzde
puanından, harmonik hata `0.5` yüzde puanından, p95 `15` sentten veya yanlış
sesli oranı `5` yüzde puanından fazla kötüleşemez. Aday ayrıca p95'te en az
`%10` ya da p95'i korurken harmonik hatada en az `%50` iyileşmelidir.

Kilitli holdout v1 sonucu:

| Motor | Kapsama | p95 sent | Harmonik hata | Yanlış sesli | CPU RTF azami |
|---|---:|---:|---:|---:|---:|
| YIN v1 | %98.451 | 1902.532 | %10.7405 | %0.000 | ~0.18 |
| Pitch Engine v2 | %99.749 | 7.817 | %0.0592 | %0.303 | ~0.52 |
| VPM-benzeri | %99.749 | 9.440 | %1.3309 | %0.303 | ~0.13 |

Benchmark kazananı v2, kullanıcı varsayılanı YIN v1'dir. V2'nin üretim
C++/Swift paritesi artık doğrulanmıştır; bu mimari geçiş varsayılan motoru
kendiliğinden değiştirmez. Pitch ölçümlerinin
CPU sürelerinden arındırılmış deterministik parmak izi:
`56d319c5d5dadbda73e73178946d53005f9dfb0a2faedf7970de9eea10e2ff34`.
CPU RTF gözlemi makine yüküne göre küçük değişiklik gösterebilir ve parmak
izine dahil değildir; pitch, kapsama, harmonik hata ve seçim sonucu dahildir.

Bilinen temiz durum:

- C++20 çekirdek testlerinin tamamı geçer.
- Python: `69 passed`.
- Swift Package testleri başarılıdır. C++ canlı köprülü kod imzasız Xcode
  Debug derlemesi geçti; son RMS-setter çağrısından sonraki tekrar araç onay
  kotasında başlatılamadı, son ek C ABI ve Swift Package tarafında ayrı ayrı
  derlendi.
- Xcode'da mevcut, işlev dışı uyarı: eski `onChange` kullanımı.

## Kısa sessizlikte yanlış sesli yayın kontrolü

`klarivision_pitch_tournament_holdout_adverse_v1` dosyasındaki analitik hedef
boşlukları ayrıca ölçülür. Dosyadan-test ekranı ve doğrulama JSON'u, eşleşen
sesli karelerden bağımsız olarak `false_voiced_points`,
`false_voiced_percent` ve örnek zaman/frekansları raporlar. 150 ms'den kısa
boşluklar artık bu kontrolden çıkarılmaz.

8 Ağustos 2026 odaklı ayna ölçümü (tam turnuva değildir):

| Motor | Yayın güven eşiği | Önce yanlış sessizlik karesi | Sonra | Elenen sesli hedef karesi |
|---|---:|---:|---:|---:|
| Pitch Engine v2 | 0.70 | 80 | 6 | 40/2208 (%1.8) |
| VPM-benzeri | 0.80 | 81 | 7 | 37/2208 (%1.7) |

Bu dosya teşhis ve eşik seçimi için kullanıldığından değişiklik bakımından
artık geliştirme verisidir. Terfi kararı görülmemiş holdout v2 ve tam turnuva
sonucuna dayanmalıdır.

## Motor değişikliğinde raporlanacaklar

Her değişiklik için önce/sonra şu değerler verilir:

1. her sentetik WAV ve motor için beşli kare sayımı ve doğru-kare ortalaması;
2. referans sesli/sessiz toplamlarının muhasebe denklikleri;
3. holdout sonuçları ve toplam hata sıralaması;
4. toplam gecikme ve CPU RTF değiştiyse bunlar;
5. hangi motorun kullanıcı varsayılanı olduğu.
