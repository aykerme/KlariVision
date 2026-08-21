# Kalıcı Proje Kararları

Bu dosya yalnızca sonraki çalışmaları etkileyen kararları tutar. Günlük ilerleme
notları `CODEX_HANDOFF.md`, sayısal durum `TEST_BASELINE.md` içindedir.

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
