# KlariVision — Güncel Proje Durumu

Son güncelleme: 6 Eylül 2026
Aktif dal: `fix/pitch-octave-and-stray-points`
Durum anı: Tek pitch motoru (`unified_v1`); Dinleme ve Çalma grafikleri
WebKit/JavaScript canvas renderer'ında
Sürüm anı: `v0.6.0-beta.3` kaynağı + D-037/D-038/D-039 motor turu

## Tek motor

6 Eylül 2026'da dört eski motor (`yin_v1`, `pitch_engine_v2`, `vpm_like`,
`hapt_v1`) koddan çıkarıldı; **çalışan tek motor `unified_v1`'dir** (D-039).
Bu, D-037'nin başından beri ilan edilmiş hedefi ve D-038'in ertelediği adımdır.
D-020'nin "eşit son kullanıcı seçenekleri" politikası burada sona erer:
Ayarlar'da motor seçici yoktur, ne çalıştığını söyleyen tek bir satır vardır.

Kalıcı sınırlar: C ABI **v1 olarak kalır**; 0–3 motor kimlikleri ve yetenek
bitleri rezervedir, yeniden kullanılmaz; kaldırılmış bir kimlikle oturum açmak
hata döner, hayatta kalan motora yönlendirilmez. Kayıtlı seçimi kaldırılmış bir
motoru adlandıran kurulumlar `unified_v1`'e düşer; **daha önce çözümlenmiş
çalışmalar kendi sonuçlarını ve motor kimliğini korur.**

Bu turda motor davranışı, eşikler, gecikme (5 hop / 53,3 ms) ve kalıcı veri
biçimleri değişmedi. Bu belgenin altındaki dört motora ait bölümler tarihçedir.

Doğrulandı: `scripts/test_core.sh`, macOS Swift paketi, macOS Xcode Debug
derlemesi, Python paketi, turnuva testleri. Bu tur ayrıca iki bayat kaydı
düzeltti: **macOS ve iPad Xcode projeleri `unified_*` kaynaklarını hiç
derlemiyordu** — D-037'den beri her iki uygulama da kendi kazanan motorunu
bağlayamıyordu.

13 Ağustos'ta uygulama davranışı değiştirilmeden Swift kaynakları küçük
sorumluluk dosyalarına ayrıştırıldı: ayarlar, çalışma modelleri/medya köprüsü,
Çalma görünümleri, canlı analiz ve görsel/tüner desteği. Üç motor seçimi,
ayrı kalıcılık ve önbellek anahtarları korunur.

Ortak C++ pitch dış arayüzü ABI v1 olarak donduruldu (Harmonik-Faz eklentisi
dahil, sürüm değişmedi). YIN v1, Pitch Engine v2, VPM-benzeri ve Harmonik-Faz
aynı 48 kHz mono Float32 PCM, kaynak-zamanlı oturum sözleşmesini kullanır;
Python CLI sözleşmeyi doğrular. Ayrıntı: `docs/PITCH_ENGINE_C_ABI_V1.md`.

Dört motorun aynı kullanıcı-seçeneği kabul protokolü v6 dondurulmuş fixtures
üzerinde yeniden çalıştırıldı; her motorun ciddi hata sayısı sıfırdır. Fiziksel
çalım/izin/kulakla WAV doğrulamasının otomasyondan ayrı olduğu kayıt ve ayrıntı
`docs/PITCH_ENGINE_USER_OPTION_ACCEPTANCE_V1.md` içindedir (Harmonik-Faz'ın
fiziksel oturumu henüz yapılmadı).

Beta sonrası P1 erişilebilirlik turunda Dinleme dosya alma için `⌘O`, ikona
dayalı oynatma/canlı görünüm denetimleri için VoiceOver adları, Dinleme ve
Çalma durum değerleri, nötr üç-motor Picker ipuçları ve Reduce Motion desteği
eklendi. Reddedilen sürükle-bırak artık her başarısız sağlayıcı yolunda açık
bir durum metni verir. Kod/test, imzasız Debug ve Release derlemeleri geçti;
kilidi açık macOS oturumunda fiziksel VoiceOver/odak, üç tema ve Reduce Motion
denetimi tamamlandı. Canlı mikrofon ile Finder destekli bırakma için aynı beta
paketinin daha önce geçen fiziksel kanıtı, desteklenmeyen bırakma için Swift
testi ve ret-yolu denetimi kullanıldı; P1 listesinde açık madde kalmadı. Ayrıntı:
`docs/ACCESSIBILITY_ACCEPTANCE_CHECKLIST.md`.

iOS/iPadOS 17+ ürünü kullanıcı yetkisiyle başlatıldı (D-034); aynı hedef
iPhone ve iPad'i kapsar. Çalma WAV'ı artık `Çalışmalara Ekle` ile mevcut
Dinleme analiz yoluna güvenle aktarılır; hata kaynak kaydı korur ve yeniden
denenebilir. Generic iPhoneOS arm64 `build-for-testing` başarılıdır. Başlangıç
Simulator/Catalyst tabanı `33/33`; bağımsız denetimde bulunan atomiklik testi
dahil final iPhone SE ürün paketi `38/38` ve iPad C ABI smoke `1/1` geçti.

20 Ağustos fiziksel kabulünde iPhone 15 Pro / iOS 26.6.1 üzerinde Dinleme,
üç motorlu Çalma, WAV aktarımı, Bluetooth/interruption/background/rota,
portre-landscape, safe area ve XXL Dynamic Type geçti. iPad (9. nesil) /
iPadOS 26.6 üzerinde aynı kritik akışlar, yön değişimi ve regular sidebar
regresyonu geçti. Kabul sırasında bulunan takip, ses-tap izolasyonu, Retina
canvas, yinelenen audio tap ve arka plan restart yarışı kusurları düzeltildi ve
aynı fiziksel tekrar adımlarında geçildi. VoiceOver turu kullanıcı kararıyla
çalıştırılmadı; erişilebilirlik kapısının bu bölümü PASS değildir. Ayrıntı:
`docs/IOS_IPADOS_FEASIBILITY.md`.

Bağımsız denetimde bulunan geç-viewer-hatası atomiklik açığı da kapatıldı.
Son imzalı build iki fiziksel cihaza kuruldu; iPhone'da WAV kayıt → Çalışmalar
→ Dinleme oynatma ve aynı kaydı tekrar eklememe akışı yeniden geçti.

## Mobil sıradaki iş

Tek açık kabul işi, fiziksel büyük iPhone'da VoiceOver odak sırası ile temel
eylemlerin ad/değer/ipucu zincirini doğrulamaktır. Kullanıcı bu turu erteledi;
bu nedenle sonuç “NOT RUN”, başarısızlık veya başarı değildir. Bu kapı geçmeden
TestFlight/App Store hazırlığı başlatılmaz. Pitch motoru veya kalıcı veri biçimi
bu kabul çalışmasının parçası olarak değiştirilmez.

Android için de ürün yapılmadan teknik fizibilite çıkarıldı. Yerel Android
SDK/NDK/CMake/Gradle bulunmadığı için arm64-v8a smoke koşulmadı ve araç
kurulmadı; NDK mevcut olduğunda tek yetkili sonraki adım C ABI v1 Core Smoke'tır.
JNI, AudioRecord, WebView, SAF, lifecycle ve performans kapıları:
`docs/ANDROID_FEASIBILITY.md`.

13 Ağustos son entegrasyon doğrulamasında tüm kabul değişiklikleri birlikte
yeniden sınandı: çekirdek testleri, tam Python paketi (`79 passed`), Swift
paketi (`44 passed`, iki isteğe bağlı çapraz-dil parite dışa aktarma testi
atlandı), imzasız Debug ve imzasız Release geçti. Beta paketleme betiği C ABI
uygulamasını CLI bağlantısına da ekleyecek biçimde düzeltildi; yeniden üretilen
`dist/KlariVision Beta.app` sıkı ad-hoc imza denetimini geçti ve
`--contract` sorgusu ABI v1 / `offline_track_v1` / üç motoru doğruladı.
Fiziksel erişilebilirlik kapısı 13 Ağustos'ta tamamlandıktan sonra,
`v0.6.0-beta.3` kaynak kontrol noktasıyla sürüm zinciri güncellendi. Android
NDK smoke'ı yalnız kullanıcı ayrıca araç
kurulumuna yetki verirse açılır; sıradaki tek iş değildir.

`v0.6.0-beta.2`, önceki fiziksel macOS kabulü geçen WebKit grafik yolu, üç
seçilebilir C++ pitch motoru ve yeniden üretilen beta paketinin değiştirilemez
kaynak anıdır. `v0.6.0-beta.3`, P1 erişilebilirlik kabul kaydını da içeren
sonraki kaynak kontrol noktasıdır. Bu an için çekirdek testleri, tam Python
paketi (`79 passed`), Swift Package (`44 passed`, iki isteğe bağlı çapraz-dil
parite dışa aktarma testi atlandı), imzasız Release paketleme, sıkı ad-hoc
imza doğrulaması ve paketli C++ CLI `--contract` sorgusu yeniden geçti. Sorgu
ABI v1, `offline_track_v1` ve `yin_v1` / `pitch_engine_v2` / `vpm_like`
üçlüsünü doğrular; motor terfisi veya varsayılan değişimi yoktur. Paket Git'e
eklenmez; kaynak etiketi ile `dist/KlariVision Beta.app` birlikte doğrulanır.

13 Ağustos odaklı WebKit yeniden kabulünde güncel beta paketi üretildi ve
otomatik kapılar geçti. Video ilk oynatma/başa dönüşü, 20'den fazla kısa A/B
dönüşü, A/B sırasında 20 pencere küçültme-büyütme, yalnız-ses grafiğine
tıklayarak oynatma ve canlı mikrofon grafiği çalıştı. Kullanıcının son fiziksel
kontrolünde kesintisiz grafik akıcılığı, Finder sürükle-bırak, uygulama geneli
tema, yalnız-ses grafiğinden oynat/duraklat ve çalışmadan çıkınca medyanın
durması olumlu doğrulandı. **Beta kapısı geçti.**

## Son beta kabul sonucu

13 Ağustos 2026 macOS kabulü tamamlandı. Önceki flicker, başlangıç/B→A
takılması, yeniden boyutlandırma yanıp sönmesi, tema, Finder bırakma,
yalnız-ses grafik tıklaması ve arka planda medya oynatma bloklayıcıları güncel
WebKit beta paketinde yeniden üretilemedi. Otomatik doğrulamalar ve son fiziksel
kullanıcı kontrolü geçti. YIN v1 yalnız ilk açılışta geriye uyumlu seçili
değerdir; YIN v1, V2 ve VPM-benzeri eşit son kullanıcı seçenekleridir ve
hiçbiri terfi/kazanan olarak işaretlenmez. Ayrıntılar
`docs/BETA_ACCEPTANCE_CHECKLIST.md` içindedir.

Bu belge geçmiş konuşmaların özeti değil, deponun bugünkü çalışma durumudur.
Yeni bir görevde önce bu dosya, sonra `CODEX_HANDOFF.md` okunmalıdır.

## Ürün bugün ne yapıyor?

- Yerel video/ses dosyasını Dinleme Modu'nda analiz için alır; çevrimiçi bağlantı içe aktarma akışı yoktur.
- Vamp pYIN ile çevrimdışı, yüksek çözünürlüklü pitch eğrisi üretir ve önbelleğe
  alır.
- macOS uygulamasında Dinleme grafiğini `.vamp.json` dosyasından Swift'te
  hazırlar ve çalışma HTML'indeki WebKit/JavaScript canvas çekirdeğinde çizer.
- Medya ile senkron grafik, A/B loop, oynatma hızı, geri sayım, zaman/dikey
  yakınlaştırma ve eğri takibi sunar.
- Eski çalışma HTML'lerinde yan `.vamp.json` dosyası yoksa, uygulama HTML'e
  gömülü hazır eğriye geri döner; medya araçları ve grafik kabuğu çalışır
  kalır. Dinleme imleci ve zaman penceresi WebKit snapshotları arasında
  SwiftUI tarafından kare-hızında enterpole edilir.
- Majör, Minör, Nihavend, Kürdi, Uşşak, Hicaz, Hicazkâr ve
  Kürdilihicazkâr bağlamlarını kullanıcı seçimine göre gösterir.
- macOS SwiftUI uygulamasında Çalma Modu'nda mikrofonla canlı pitch grafiği çizer.
- Ayarlar'daki dBFS kaydırıcısı ve canlı VU metreyle ortak minimum sinyal
  seviyesi ayarlanır; eşik altındaki kareler bütün canlı motorlarda boş kalır.
- Dosyadan sentetik motor doğrulamasında beşli kare sınıflandırmasını grafik
  üstünde gösterir: doğru perde yeşil, harmonik hata kırmızı, harmonik olmayan
  hata turuncu, yanlış sesli mor ve eksik sesli pembe; ölçüm, referans ve
  sınıflandırma katmanları birbirinden bağımsız açılıp kapatılır.
- Sentetik doğrulamada ham hata muhasebesi ile algılanabilir hata ayrıdır:
  renkli varsayılan katman yalnız geçişten uzak en az üç kare süren ciddi
  hataları gösterir; `50–100 sent` sarı yakın-perde uyarısı, ham tekil/geçiş
  noktaları ise isteğe bağlı soluk tanılama işaretidir.
- Son çalışmaları yerel olarak listeler; kullanıcı kayıtları yerel kalır.

## Pitch motorları

| Motor | Rol | Durum |
|---|---|---|
| `unified_v1` | Çoklu aday + yol seçimi + harmonik spektral kanıt; 5 hop (53,3 ms) sabit karar gecikmesi | **Çalışan tek motor** |
| Vamp pYIN | Çevrimdışı dosya analizi ve gerçek kayıtta kararlı referans | Kullanımda |
| YIN v1 / Pitch Engine v2 / VPM-benzeri / Harmonik-Faz | — | **Kaldırıldı (D-039)**; ABI kimlikleri 0–3 rezerve |

Çalışma önbelleği motor kimliğini ve `offline_track` profil sürümünü taşımaya
devam eder; üç kalıcılık anahtarı (Dinleme / Çalma / Birlikte Çal) korunur.

**Bu bölümün altındaki her şey tarihçedir.** Dört motorun kalibrasyonu,
turnuva sıralamaları, parite kapıları ve "varsayılan / deneysel / terfi"
ifadeleri, o motorlar hâlâ koddayken alınmış kararların kaydıdır; güncel ürün
politikası D-039'dur.

Çalışma modu için ayrı üretim-yolu sentetik kontrolü bulunur. Bu kontrol,
aynı mono/48 kHz dönüşüm ve C++ `offline_track_v1` CLI ile üç motorun ham
çıktısını ve grafikte görünen filtrelenmiş eğrisini matematiksel hedefe karşı
ayrı puanlar. Sentetik benchmark açıldığında hedef eğri ile kalıcı hata
aralıkları Çalışma grafiğinde isteğe bağlı katman olarak görünür; normal
kullanıcı kayıtlarına bu katman eklenmez.

12 Ağustos kabul koşusunda canlı ve Çalışma üç motor için aynı durumlu C++
`ProductionPitchSession` tabanına geçirildi. YIN'de güçlü doğrudan
`>800 Hz` üst-register çizgisi düşük alt-periyot yerine seçilir; büyük
harmonik onayı yalnız aşağı yönlüdür ve ani release uzun fade'den ayrılır.
Tam 26 sentetik WAV'da ilk nedensel/ham/görünen ciddi sayılar YIN `0/0/0`, VPM
`43/43/43`, V2 `78/65/65` oldu. YIN ham hata toplamı `5.126`, rapor parmak
izi `c5003d284f6a59feab44a7d8f521553df8975066723d68ac48da596f4b14557a`.
V2 farkı yalnız dosya sonu sabit-gecikme kuyruk boşaltmasıdır.
Görülmemiş v6 holdout'ta YIN ve V2 bütün varyantlarda sıfır; VPM adverse'te
7 ciddi harmonik kare verdi. Bu dosya daha sonra geliştirme kaynağı olarak
kullanıldı; VPM'nin bağımsız kabul kanıtı değildir.

Sonraki V2 r4 düzeltmesinde açık oturum-sonlandırması gerçek sabit-gecikme
tamponunu boşaltacak şekilde eklendi; sıfır pencereyle flush kaldırıldı.
Hızlı RMS release’i oda kuyruğunu sustururken yavaş fade ve en çok yedi
karelik aynı-kontur dropout köprüsü korundu. 26 geliştirme WAV’ında V2
nedensel/ham/görünen ciddi hata `0/0/0`; toplam ham hata `5191/5191/5191`
oldu. V6 clean/room/adverse üçü de `0/0/0`dır. V2 hâlâ kullanıcı doğrulaması
bekleyen deneysel motordur; YIN v1 varsayılanı değişmedi.

Bütün canlı/test motorları DC'si çıkarılmış analiz penceresinde ortak
`0.015 RMS` (`−36.5 dBFS`) varsayılan kapısını kullanır. Kullanıcı Ayarlar'da
`−60…−20 dBFS` kaydırıcısını canlı VU metreye bakarak değiştirebilir. Kapı
yalnız sonraki karelere hemen uygulanır; düşük-seviyeli kareler boşluk
köprüleriyle geri getirilmez. Sentetik hedefin aynı kareleri de etkin
matematiksel referansta boş bırakılır; normal çevrimdışı pYIN değişmemiştir.

YIN v1 Python aynası, v1–v3 holdout'larının clean/room/adverse dokuz
varyantında ciddi hatayı sıfırladı. Swift canlı yolunda aynı kısa-kesinti,
release ve süreklilik korumaları bulunur. v4 bir geliştirme kaynağı değildir:
yalnız kabul kontrolü olarak tutulur. v4 dosyasındaki yüksek hata raporunun
sebebi de motor değil, v3/v4 analitik referansının eski v1 manifestine
yönlenmesiydi; açık sürüm eşlemesiyle düzeltildi.

Pitch Engine v2 aynası da v1–v3'teki dokuz varyantta ciddi hatayı sıfırladı.
Python aynası ile Swift referans yolu 26 WAV ve `67.354 / 67.354` karede sıfır
ayrışmayla doğrulandı. Kanıtlanan davranış tek durumlu C++ V2 oturumuna
taşındı; ortak C++ ile Swift referansı aynı envanterde yine sıfır ayrıştı.
Swift canlı V2 ve Python turnuva üretim adaptörü C ABI/C++ oturumunu kullanır;
Swift ve Python algoritmaları yalnız geçiş kanıtıdır. V2 aday araması, 1500 Hz
gösterim aralığını aşmadan 1650 Hz analiz koruma bandı kullanır; güçlü 2x
spektral temel kanıtı alt-period adayına karşı yol skoruna katılır. Kullanıcı
onayıyla v4 zorlu varyantındaki yayın eşiği de düzeltildi. V1–V5
clean/room/adverse bütün ölçümlerde ciddi hata sıfırdır. V2 varsayılan değildir
ve kullanıcı doğrulaması beklenmektedir.

VPM-benzeri kare kestiricisi değişmeden, ortak C++ yayın katmanı güçlü kontur,
en çok yedi karelik geri-dönebilir dropout ve release durumlarını ayırır.
Doğrudan üst çizginin düşük harmonik adaydan en az `2.5x` güçlü olması mevcut
üst konturu yalnız veto amacıyla korur. 26 geliştirme WAV'ında ciddi sonuç
`43/43/43 -> 0/0/0`, ham toplam `5722 -> 5130`; V6 clean/room/adverse de ayrı
ayrı sıfırdır. Revizyon `shared-production-session-r5`tir. YIN v1 ve V2 kabul
ölçümleri değişmemiştir. VPM varsayılan değildir ve kullanıcı doğrulaması
beklenmektedir.

YIN v1, Pitch Engine v2 ve VPM-benzeri iyileştirmeleri ana uygulama paketi
`dist/KlariVision.app` içine alındı. YIN v1 varsayılan motor olarak kaldı;
diğer iki motor uygulama içinden seçilebilir. Önceki ana paket geri alınabilir
`dist/KlariVision.app.before-all-engine-improvements` adıyla saklandı.

## Yüksek glissando görünürlüğü

Dosyadan motor doğrulaması, motorun ürettiği noktaları hedefe karşı ölçmenin
yanı sıra her analitik sesli hedef için motor noktası arar. Bu nedenle
`900–1500 Hz` glissando bölümünde çizginin kaybolması artık ayrı kapsama/
`missing_voiced` hatasıdır; üç ardışık eksik örnek pembe bant ve hedef
frekansında pembe işaret olarak görünür. Yeni holdout v2 bu üst-register
durumları ayrı clean/room/adverse varyantlarıyla kilitler.

Platformdan bağımsız parçalar `core/` altında C++20 ile geliştirilmektedir.
Pitch Engine v2'nin üretim algoritması artık tek C++ oturumundadır; SwiftUI
mikrofon, RMS ayarı, grafik ve UI katmanlarını yerel tutar.

## YIN v1 üst-register kullanıcı adayı

YIN v1, bütün güvenilir YIN tepelerinin ölçülen `2x/3x` üst eşlerini yalnız
üst çizgi kaynak tepeye göre en az `80x` güçlü ve pencere enerji ölçeğinde en
az `0.008` olduğunda kullanır. Düşük güvenli bir oda kuyruğu, yakın geçmiş RMS
tepesinin `%20` altına hızlı düştüğünde yayınlanmaz. Swift üretim yolu ve
Python turnuva aynası aynı kuralları taşır.

Holdout v2 clean/room/adverse ciddi hata toplamları `59/122/263 -> 0/0/0`;
ham toplamlar `191/299/431 -> 113/147/106` oldu. Holdout v3 ve v4'ün bütün
varyantlarında da YIN ciddi hata toplamı `0`; azami RTF `0.22244`, gecikme
`16 ms`. Bu, v2 geliştirme verisine göre hazırlanmış kullanıcı doğrulama
adayıdır; kullanıcı onayından önce sonraki motora geçilmez.

## VPM-benzeri motorun son kalibrasyonu

Etkin eşikler:

- minimum periodicity: `0.38`
- near-strongest ratio: `0.90`
- relative spectral support: `0.080`
- absolute spectral support: `0.005`
- maximum period multiple: `6`
- spektral adaylar ACF sonucunu yalnız aşağı doğru düzeltebilir; `2x/3x`
  adayları güçlü ACF temelini yukarı taşıyamaz
- seçilmiş ACF tepesi aynı zamanda en güçlü tepeyse spektrum sonucu aşağı
  taşıyamaz; aşağı düzeltme yalnız erken, yakın-güçlü ACF tepesini onarır

Seçim kuralı: ağırlıklı pitch/harmonik hatayı azalt; hiçbir kaynakta kapsama
oranını başlangıca göre 2 yüzde puanından fazla düşürme.

Önemli sonuçlar:

- Şükrü Tunar: `%98.902` kapsama, p95 `29.358 sent`, harmonik hata `%0.3044`
- Temiz sentetik: p95 `24.246 sent`, harmonik hata `%0`
- Klarnet sentetik: p95 `24.26 sent`, harmonik hata `%0`
- Zorlayıcı sentetik: p95 `26.397 sent`, harmonik hata `%0`

12 Ağustos r5 regresyon koşusunda kalibrasyon ızgarası daha gevşek bir
alternatifi az farkla birinci sıraladı; bu plan kare kestiricisini yeniden
kalibre etmediği için öneri ürüne alınmadı ve yukarıdaki etkin eşikler korundu.

Kaynak rapor: `outputs/vpm-like-calibration.json`.
Aday düzeyi kanıt: `outputs/sukru-tunar-vpm-candidate-diagnostics.json`.

## Sentetik gerçek-değerli motor turnuvası

9 Ağustos 2026'da tüm sentetik WAV turnuvası, 26 dosyanın tamamında ortak
`0.015 RMS` kapısıyla iki kez aynı deterministik sonuçla çalıştı. İki gerçek
`klarnet_gercek_*` kayıt pYIN tanı kapsamındadır ve gerçek-değer turnuvasına
alınmadı. Eşik altındaki 22 analitik hedef karesi etkin referansta boş kaldı.
Kazanan sırası ciddi toplam, ciddi olmayan ham toplam, doğru-kare ortalama
sent ve gecikmedir; YIN v1 / V2 / VPM ciddi toplamları `48 / 58 / 40`, ciddi
olmayan toplamları `5686 / 5577 / 5686` oldu. Sayısal kazanan VPM-benzeridir.
Bu rapor üretildiğinde C++/Swift iz paritesi eksikti; 10 Ağustos'ta ayrı tam
envanter parite kapısı geçti. Canlı profil ve diğer terfi kapıları tamamlanmadığı
için varsayılan YIN v1 olarak kaldı. Rapor:
`outputs/pitch-engine-tournament-all-synthetic-2026-08-09.md`.

VPM-benzeri üretim paritesi, turnuvadaki 26 sentetik WAV'ın tamamında aynı
Float32 kaynakla doğrulandı: C++ ve Swift tarafında `67.595 / 67.595` yayımlanmış
kare, `0` sesli/sessiz, frekans veya güven ayrışması. Rapor
`outputs/vpm-swift-cpp-trace-parity.md` içindedir. V2 için ayrı geçiş ve üretim
raporları `outputs/v2-python-swift-trace-parity.md` ile
`outputs/v2-cpp-swift-trace-parity.md` içindedir.

Turnuva doğruluk raporu beşli kare muhasebesine geçirilmektedir: yanlış sesli,
eksik sesli, `≤50 sent` doğru perde, harmonik hata ve harmonik olmayan hata.
Kapsama/p95/yüzde tabloları yeni rapor şemasında yer almaz; referansın sesli ve
sessiz kare toplamları ile doğru-kare ortalama mutlak sent farkı kullanılır.

Üç canlı motor, pYIN kullanılmadan aynı `1536/512` pencere-hop düzeninde
geliştirme seti ve ayrı kilitli holdout v1 üzerinde ölçüldü. Kaynak zamanına
otomatik offset uygulanmadı; karar gecikmesi ayrıca raporlandı.

Holdout ortalamaları:

| Motor | Kapsama | p95 sent | Harmonik hata | Yanlış sesli | Karar gecikmesi |
|---|---:|---:|---:|---:|---:|
| YIN v1 | %98.451 | 1902.532 | %10.7405 | %0.000 | 16.000 ms |
| Pitch Engine v2 | %99.749 | 7.817 | %0.0592 | %0.303 | 69.333 ms |
| VPM-benzeri | %99.749 | 9.440 | %1.3309 | %0.303 | 16.000 ms |

Sayısal kazanan Pitch Engine v2'dir. V2 turnuva adaptörü artık ortak C++
oturumunu kullanır ve C++/Swift kare-iz paritesi doğrulanmıştır. Kararlı YIN v1
ürün varsayılanı bu mimari geçişte değiştirilmemiştir. Okunabilir rapor
`outputs/pitch-engine-tournament-v1.md`, dinleme indeksi
`outputs/pitch-engine-tournament-sample-index-v1.md` içindedir.

macOS dosyadan-test grafiği, turnuva WAV'larının üç ailesinde pYIN yerine
manifestteki matematiksel hedef eğrisini gösterir. Referans ve ölçüm eğrisi
ayrı görünürlük düğmeleriyle açılıp kapatılır. Normal kullanıcı dosyalarında
pYIN referansı değişmeden korunur.

## Deneysel kısa harmonik sıçrama koruması

8 Ağustos 2026'da yalnız Swift canlı ve dosyadan-test yollarında V2 ile
VPM-benzeri motor için ortak iki-kare onay koruması eklendi. Koruma, önceki
yayınlanmış perdeye göre yaklaşık `1/3`, `1/2` veya `2/3` oranındaki aşağı
yönlü büyük atlamayı ilk karede tutar; takip eden kare aynı hedefi desteklerse
geçirir. Doğru perdeye yukarı dönüş geciktirilmez. Bu, normal küçük perde
hareketini ve vibratoyu filtrelemeyi amaçlamaz. Kullanıcı isteğiyle turnuva
henüz yeniden çalıştırılmadı; V2 ve VPM-benzeri canlı denenmelidir.

Adverse holdout v1 üzerindeki kullanıcı denemesinde VPM'nin bazı doğru, en
güçlü ACF sonuçlarını spektral `f/2` adayına indirdiği doğrulandı. C++ ve Swift
birlikte güçlü-ACF kilidiyle düzeltildi. Aynı zamanda çıkış kapısı yalnız aşağı
atlamayı geciktirecek şekilde daraltıldı; yanlış alt harmonikten doğru perdeye
yukarı dönüş artık bekletilmez. Matematiksel referans raporu da açık sessizlik
boşluklarını nota geçişi gibi interpolasyonla doldurmaz. Holdout v1 bu teşhiste
kullanıldığı için yeni değişiklik açısından geliştirme verisidir; bağımsız
kabul için yeni bir holdout sürümü gerekir.

Kısa çıkış kapısının görünür etkisinin yetersiz kalması üzerine Swift
VPM-benzeri yolunda spektral ve ACF adaylarını beraber puanlayan ayrı bir
nedensel izleyici denenmişti. 10 Ağustos parite çalışmasında bu yinelenen yol
kaldırıldı; Swift yayın katmanı artık C++ ile aynı `0.80` kapısı ve üç-onaylı
yalnız-aşağı harmonik korumasını kullanır. Tam sentetik envanter paritesi
geçmiştir; varsayılan terfisi için canlı profil ve diğer kapılar korunur.

Ekranda işaretlenen izole noktaların çoğu nota içi harmonik atlama değil,
sentetik hedefteki kısa sessizliklerde yanlış sesli yayın olarak teşhis edildi.
V2 yayın güven eşiği `0.70`, VPM-benzeri yayın güven eşiği `0.80` oldu; VPM
eşiği C++ ve Swift'te, V2 eşiği Swift ve benchmark aynasında eşlendi. Adverse
v1 odaklı ayna sayımında sessizlik kareleri V2 için `80 -> 6`, VPM-benzeri
için `81 -> 7` olurken sesli hedef karelerinin yaklaşık %1.8/%1.7'si elendi.
Bu odaklı ölçüm tam turnuva değildir. Dosyadan-test özeti artık kısa analitik
sessizlik boşluklarını `sessizlikte N yanlış nokta` olarak ayrıca raporlar.

## Bilinen açık konular

1. Şükrü Tunar kaydında `111–113 sn` aralığında 7 adet yaklaşık `2x` kare
   kalıyor. ACF, spektrum ve sabit pYIN güven vekili tek başına gerçek-değer
   sağlamadığı için yeni eşik ayarı yapılmadan bağımsız/elle doğrulama gerekir.
2. Hoparlör/oda/mikrofon zinciri doğrudan dosyaya göre daha zorlayıcıdır;
   dış sesler ve güçlü 2x/3x harmonikler ek sağlamlık gerektirir.
3. `unified_v1`'in `holdout_adverse_v1.wav` vetosu açık: 24 kare ciddi eksik
   ötüm, sınır ≈ 12. Kullanıcı bunu kabul etti (D-038) ama kapanmadı. Klarnet
   dışı materyalde ötüm kapsaması da açık; **dış karşılaştırma tablosuna
   bakılarak ayarlanamaz** — ayrı bir doğrulama kümesi ayrılmadan girilmez.
4. Android bağ katmanı henüz oluşturulmadı; iOS/iPadOS'ta kalan kabul gerçek
   iPhone'da dosya ve mikrofon yaşam döngüsü, ardından gerçek iPad regresyonudur.

## Ana dizinler

- `core/`: platformdan bağımsız C++ pitch/müzik çekirdeği ve testleri
- `src/klarivision/`: Python analiz, yerel servis ve görselleştirme katmanı
- `macos/KlariVision/`: SwiftUI macOS uygulaması
- `scripts/`: kalibrasyon, regresyon, paketleme ve yardımcı araçlar
- `data/benchmarks/`: sürüm kontrollü sentetik/validasyon kayıtları
- `outputs/`: yeniden üretilebilir raporlar ve yerel görünümler
- `docs/`: ürün, mimari, karar, test ve görev devri belgeleri
