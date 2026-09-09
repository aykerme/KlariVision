# Harmonik-Faz (HAPT) Pitch Motoru

> **TARİHSEL BELGE — bu motor koddan kaldırıldı (D-039, 6 Eylül 2026).**
> Aşağıdakiler kaldırılma anındaki yöntem, kalibrasyon ve ölçüm kaydıdır ve
> kanıt zinciri olarak korunur. Buradaki komutlar artık koşmaz, eşikler artık
> hiçbir kodu yönetmez. Çalışan tek motor `unified_v1`'dir; güncel durum
> `docs/PROJECT_STATE.md` ve `docs/TEST_BASELINE.md`'dedir.

`hapt_v1`, YIN v1, Pitch Engine v2 ve VPM-benzeri'nin yanında dördüncü, eşit
kullanıcı seçeneğidir. Bir kalite sırası, öneri veya varsayılan değişikliği
değildir; `PitchEngineSettings.initialEngine` hâlâ `yin_v1`dir.

## Amaç

`docs/PITCH_ENGINE_USER_OPTION_ACCEPTANCE_V1.md`'deki v6 kabul koşusu, üç
motorun da aynı baskın zayıflığı paylaştığını gösteriyor: yanlış perde değil,
**yayınlanamayan kare** (195–203 kare/motor, atak/geçiş/sönme) ve kalan
harmonik hata. HAPT bu iki boşluğu hedefleyen, literatürden türetilmiş fakat
mevcut üç motorun hiçbirinde birebir bulunmayan iki fikir üzerine kurulu:

1. **Çözünürlük-farkında ara-harmonik veto** — oktav *ve* on ikili hatasını
   simetrik yakalayan, çift harmoniklere hiç kısıt koymayan bir tek-harmonik
   doluluk kuralı (bkz. "Klarnet akustiği").
2. **Kare-içi faz kilitli anlık-frekans (IF) iyileştirmesi** — kareler arası
   durum gerektirmeden cent-altı hassasiyet.

Motorun tasarımı, makam/perde gridinden tamamen bağımsızdır: 53-koma referansı
bir ön-bilgi (prior) olarak kullanılmaz. Uygulamanın amacı entonasyon sapmasını
göstermektir; grid'e çeken bir prior tam da ölçülmek istenen sapmayı gizler.

## Klarnet akustiği

Klarnet bir ucu kapalı silindirik borudur: tek harmonikler (1., 3., 5.)
baskındır, çift harmonikler (özellikle 2.) fizik gereği zayıftır; enstrüman
oktavdan değil **on ikili**den (3. harmonik) aşırı üfler. Bunun sonucu: "çift
harmonikler yoksa f0'ı yarıya bölmüşüz" kuralı klarnette **yanlış**tır — çift
harmonikler zaten fizik gereği zayıf. Register geçişinde asıl risk oktav (2×)
değil **on ikili (3×)** hatasıdır.

## Yöntem

### Aşama 1 — NSDF aday üretimi

`core/src/hapt.cpp`, McLeod-tipi NSDF'yi (`mpm.cpp` ile aynı formül,
`2Σxy/Σ(x²+y²)`) pencerenin **tüm** çözülebilir gecikme aralığında hesaplar ve
her yerel tepeyi bir aday olarak değerlendirir. Aralığın iki ucu da (`lag ==
minimum_lag` ve `lag == maximum_lag`) aday olabilir — bu, aşağıdaki
"Kalibrasyon" bölümünde anlatılan bir hatanın düzeltilmiş halidir.

### Aşama 2 — Ara-harmonik veto ve mutlak önem ağırlığı

Her aday `f` için:

- `H(f) = Σ|A(k·f)|²`, k=1..K — harmonik enerji (K ≤ 5, Nyquist korumalı).
- Yarım ızgara `I(f) = Σ|A((k−½)f)|²`, üçte-bir ızgara benzer şekilde.
- Pencerenin ana lob yarı-genişliği `Δ = 2·fs/N` altında (yani `f ≤ 3Δ` yarım
  ızgara, `f ≤ 4.5Δ` üçte-bir ızgara için) spektral prob güvenilmez; yerine
  zaman-alanı eşdeğeri kullanılır: `NSDF(round(2τ))/NSDF(round(τ))` (ve `3τ`
  için benzer). 48 kHz/1536 örnek için bu sınırlar 187.5 Hz ve 281.25 Hz.
- **Tek-harmonik doluluk**: yalnız k=1,3,5 konumlarında (asla çift
  harmoniklerde) `A(k·f) ≥ 0.10·max_j A(j·f)` oranı. Çift harmoniklere hiç
  kısıt konmaması, "f0'ı yarıya böldüm" (tek konumlar boş) ile "bu bir
  klarnet" (tek konumlar dolu) ayrımını yapan tek doğru kuraldır.

Adayın kendi harmonik enerjisi `H(f)`, karedeki **tüm adaylar arasında en
yüksek `H`ye** göre normalize edilerek bir `significance ∈ [0,1]` üretir.
Tek-harmonik doluluk çarpanı ve NSDF'nin ürettiği (ama gerçek spektral karşılığı
olmayan) her aşağı-katlı aday, bu `significance` ile ölçeklenir — "Kalibrasyon"
bölümünde açıklanan ikinci hatanın düzeltmesi.

### Aşama 3 — Faz kilitli IF iyileştirmesi

Kazanan adayın periyodikliği `≥ 0.75` ise, aynı 1536 örneklik pencere içinde
512 örnek kaydırmalı iki 1024-örneklik alt-pencere (erken/geç) üzerinde en
güçlü tek harmonikte (m ∈ {1,3,5}) karmaşık Hann-DFT alınır:

```
Δφ = arg(C_geç · conj(C_erken))
df = −Δφ · fs / (2π · 512)          // ±93.75 Hz belirsizlik aralığı
f_son = (m·f̂ + df) / m
```

Kapılar: iki alt-pencere genliği ≤6 dB fark (atak/geçiş elenir), düzeltme
≤40 cent (aksi hâlde `f̂` korunur). `docs/HAPTPitchEngine.md`'nin türetimi
`core/include/klarivision/core/harmonic_probe.hpp`'de tekrarlanır.

### Aşama 4 — Atak/sönme kurtarma ve iki eşikli seslilik

Tam pencere skoru onset eşiğinin (0.55) altındaysa, son/ilk 768 örnek üzerinde
skor yeniden hesaplanır (`×0.85` güven indirimiyle). Bir aday, mevcut yayınlanan
kontura `≤180 cent` içindeyse yalnız sustain eşiğini (0.32) geçmesi yeterlidir;
uzak veya yeni bir kontur onset eşiğini geçmelidir.

### Aşama 5 — HAPTTracker (oturum durumu)

`HAPTTracker`, hem RMS-tabanlı serbest bırakma (release) dedektörünü hem de
aşağı-yönlü harmonik sıçrama teyidini taşır — çevrimdışı/turnuva iz aracıyla
(`hapt_trace.cpp`) üretim oturumu arasında paylaşılan **tek** durum parçası
budur, ikisi de aynı yayın davranışını görür:

- İki ardışık keskin (>%20) düşüş **veya** RMS'in kendi yakın-zaman tepesinin
  `%35`inin altına inmesi (yumuşak oda-yankısı kuyruğu için) serbest bırakmayı
  kilitler; `%40` tepe kurtarma eşiğine kadar tutulur.
- Yayınlanan konturun `1/2` veya `1/3`'üne `30 cent` yakın yeni bir tahmin
  `2` ardışık teyit ister.

Oturum tarafı (`ProductionPitchSession`), kısa boşlukları köprülemek için
paylaşılan `append_bridged(...)` yardımcısına `.60`/`.30` (güçlü/zayıf uç
güveni) ile katılır — bkz. "Kalibrasyon".

## Kalibrasyon

Plan gereği eşikler yalnız `data/benchmarks/` (turnuva holdout v1–v5,
kalibrasyon amaçlı) üzerinde ayarlandı; `data/holdouts/v6/` yalnız son, tek
seferlik kabul koşusunda kullanıldı ve sonrasında hiçbir eşik değiştirilmedi.
Gerçek v1–v5 koşusu üç gerçek hata ortaya çıkardı ve düzeltti:

1. **Sınır hatası**: aday arama döngüsü `lag == minimum_lag`'ı hiç
   değerlendirmiyordu. `maximum_frequency_hz`e (1500 Hz) yakın bir gerçek
   temel ses (ör. 1489.1 Hz) bu yüzden asla aday olamıyor, motor NSDF'nin
   eşit-güçlü bir alt-katına (ör. ~149 Hz, gerçek f0'ın onda biri) kilitleniyordu.
   Düzeltme: gecikme tablosunun her iki ucuna birer dolgu sıfırı eklenip arama
   `[minimum_lag, maximum_lag]`'ın tamamını kapsayacak şekilde genişletildi.
2. **Sahte doluluk**: tek-harmonik doluluk oranı yalnız adayın **kendi** beş
   harmoniği arasında göreceliydi. Gerçek sinyalden tamamen kopuk bir aday
   (harmonikleri yalnız pencere sızıntısı/gürültü tabanında) bu beş değerin
   birbirine yakın olması yüzünden yanlışlıkla "tam dolu" (1.0) skorlanıyor,
   NSDF'nin ürettiği herhangi bir uzak alt-kat adayını yapay olarak
   güçlendiriyordu. Düzeltme: doluluk çarpanı artık karedeki en güçlü adayın
   mutlak harmonik enerjisine göre ağırlıklandırılıyor (`significance`); gerçek
   spektral desteği olmayan bir aday artık göreceli doluluk oranından bağımsız
   olarak bastırılıyor.
3. **Serbest bırakma ve köprüleme eşikleri**: ilk seçilen `0.60` uç-güven
   eşiği, gerçek bir kısa kesintinin (dropout) hemen öncesindeki kareyi
   (ölçülen: `0.551`, gürültülü varyantta `0.376`) reddediyordu. Güçlü uç
   `≥0.60`, zayıf uç `≥0.30` olacak şekilde asimetrik bir kapıya geçildi —
   bir dropout'un tam kenarı, motorun kendi güveninin kesintinin kendisi
   yüzünden en çok düştüğü yerdir; iki ucun da aynı çıtayı bağımsız geçmesini
   istemek gerçek kısa boşlukları yetersiz köprülüyordu.

Kalibrasyon sonrası durum: `hapt_v1`, turnuva holdout v1–v5'in tamamında
(clean/room/adverse) `serious_total_error_frames == 0`.

Tekrar üretim:

```sh
.venv/bin/python -m pytest tests/test_pitch_engine_tournament.py -k test_hapt_has_no_serious_error_on_all_holdouts
```

## Bilinen sınırlar

- 187.5 Hz altında yarım ızgara, 281.25 Hz altında üçte-bir ızgara spektral
  olarak ayrıştırılamaz; zaman-alanı NSDF oranına düşülür (daha az kesin ama
  belgelenmiş bir geri düşüş).
- Atak/sönme kurtarma alt-pencere kullandığından, kaynak zamanı sözleşme
  gereği yine tam pencere merkezidir — küçük, belgelenmiş bir yanlılık.
- Faz kilitli IF iyileştirmesi yalnız `≥1536` örneklik pencerelerde ve
  atak/sönme-kurtarmalı karelerde **değil** çalışır (kurtarma pencereleri
  768 örnek, IF için yetersiz).
- Saf, harmoniksiz test tonlarında (ör. tek bir sinüs) tek-harmonik doluluk
  oranı düşük çıkar (yalnız k=1 dolu), bu da confidence'ı düşürür. Bu,
  klarnetin fiziğini yansıtan kasıtlı bir davranıştır; gerçek klarnet
  sesinde nadiren karşılaşılan bir kenar durumdur.
- Swift aynası yoktur (V2/VPM'nin aksine): `KLARIVISION_SWIFT_PACKAGE`
  derlemesinde `.hapt` her zaman `nil` döner. Ürün, HAPT'ı her zaman üretim
  C++ çekirdeği üzerinden çalıştırır.

## Kaynaklar

Bkz. literatür taraması ve tam atıflar için proje kök konuşma geçmişi; öne
çıkanlar:

- de Cheveigné & Kawahara, *YIN, a fundamental frequency estimator for speech
  and music*, JASA 111(4), 2002.
- McLeod & Wyvill, *A Smarter Way to Find Pitch*, ICMC 2005 (NSDF).
- Camacho & Harris, *A sawtooth waveform inspired pitch estimator for speech
  and music*, JASA 124(3), 2008 (asal-harmonik spektral skorlama fikri;
  `swipe_prime.cpp` ile ortak köken).
- Puckette & Brown, faz vokoder anlık frekans kestirimi; Kawahara ve ark.,
  *Fixed point analysis of frequency to instantaneous frequency mapping*,
  Eurospeech 1999 (IF iyileştirmesinin türetildiği aile).
- Holz, *The Acoustics of the Clarinet: An Observation of Harmonics*, UIUC
  Physics 406 REU, 2013 (klarnet akustiği).
