# macOS Beta Kabul Kontrol Listesi

Bu liste, her beta paketi için aynı kullanıcı kabulünü tekrar etmeye yarar.
Her satırı **geçti**, **sorun** veya **uygulanamadı** olarak kaydedin; sorun
olursa kaynak dosya, zaman ve tekrar adımlarını ekleyin.

## Ön koşullar

- Güncel paket: `dist/KlariVision Beta.app`.
- En az bir video, bir yalnız-ses çalışma ve `.vamp.json` yan dosyası olmayan
  eski bir çalışma hazırdır.
- Mikrofon izni verilebilen sessiz bir ortam ve WAV kaydetmek için yazılabilir
  bir klasör vardır.
- YIN v1, Pitch Engine v2 ve VPM-benzeri eşit kullanıcı seçenekleridir.
  YIN v1 yalnız ilk açılışta geriye uyumluluk için seçili gelir; bu kalite
  sıralaması değildir. Her motor ayrı kabul oturumunda denenir.
- Ayrıntılı üç-motor kullanıcı seçeneği protokolü ve yeniden üretilen v6
  otomatik kanıtı `docs/PITCH_ENGINE_USER_OPTION_ACCEPTANCE_V1.md` içindedir.

## Dinleme Modu

- Video ve yalnız-ses çalışmasını açın; eğri, süre ve tüner görünmelidir.
- Oynat/duraklat, başa dönüş, 0,10×–2,00× hızlar ve arama denetlenir.
- Normal oynatma, yatay sürükleme ve kısa A/B döngüsünde imleç/eğri akıcı
  kalmalı; sıçrama yalnız açık arama veya döngü dönüşünde görülmelidir.
- Dar ve normal pencerede, üç temada ve farklı dikey yakınlaştırmalarda nota
  etiketleri okunaklı olmalıdır.
- Ayarlarda Uygula/Bitti, renk kalıcılığı ve 53-koma toplamı doğrulanır.
- Eski çalışma açıldığında pitch eğrisi bulunmasa bile medya denetimleri
  kullanılabilir kalmalıdır.

## Çalma ve kayıt

- Mikrofon iznini verin; canlı eğri, tüner ve Eğriyi Takip Et ile uzun nota,
  hızlı geçiş, üst register ve glissando çalın.
- Ani bırakma, yavaş sönme ve kısa kesintilerde takılı perde, sahte oda
  kuyruğu veya belirgin harmonik sıçraması görülmemelidir.
- Kayıt başlat/durdur ve kayıt sırasında mikrofonu durdur akışlarında kayıt
  paneli açılmalı; kaydedilen WAV dosyası yeniden dinlenebilmelidir.
- Aynı denemeleri V2 r4 ve VPM r5 ile ayrı ayrı yapın; motor, hata zamanı ve
  koşulu kaydedilir. Bu sonuçlar tek başına varsayılan motoru değiştirmez.

## Çıkış kapısı

- Kullanıcı akışını engelleyen hata, yanlış düğme durumu, kayıp kayıt veya
  normal oynatmada görünür zaman sıçraması yoktur.
- C++ çekirdek testleri, Python testleri, kod imzasız Debug derlemesi ve
  Release paketleme başarılıdır.
- Fiziksel kabul tamamlanmadıysa beta yayımlanabilir bir adaydır; kararlı
  sürüm veya motor terfisi olarak işaretlenmez.

## Kabul oturumu — 13 Ağustos 2026

Durum: **Tamamlandı — beta kapısı açık sorunlar nedeniyle geçmedi**

Not: Bu oturumdan sonra ortak grafik imleci AppKit display-link katmanına
taşındı. Aşağıdaki grafik sorunları, aynı adımlarla fiziksel macOS kabulünde
yeniden doğrulanmayı bekler.

| No | Kontrol | Sonuç | Gözlem / tekrar adımları |
|---:|---|---|---|
| 1 | Beta uygulamasının açılışı | Geçti | Ana ekran hatasız açıldı; Dinleme ve Çalma kartları kullanılabilir. |
| 2 | Video açma ve normal oynatma | Sorun | Build 3'teki C++ motor paket yolu build 4'te düzeltildi ve aynı video dosya seçiciyle analiz edildi. Video/ses oynuyor, pitch eğrisi görünüyor ve tüner güncelleniyor. İlk Oynat'ta ve Başa Dön sonrası grafiğin dikey çizgisi yaklaşık ilk 1 saniye takılıyor, sonra akıcı hale geliyor; duraklatıp devam ettirmede sorun yok. Kaynağın başlangıcı karanlık/sessiz olduğundan aynı anda medya takılması değerlendirilemedi. Finder'dan Dinleme Modu kartına ses/video sürükle-bırak dosyayı kabul etmiyor ve analiz başlamıyor; dosya seçici alternatif akışı çalışıyor. Dinleme Modu'nda medya oynarken giriş ekranına dönülürse ses/video yeni dosya açılana kadar arka planda oynamayı sürdürüyor; giriş ekranına dönüşte oynatma durmalı. |
| 3 | Hız, arama, yatay sürükleme ve A/B döngüsü | Sorun | Zaman araması ve 0,50×/1,50×/1,00× hızlar çalışıyor. A ve B işaretleri ile Loop işlevi çalışıyor ve aralık doğru biçimde tekrarlanıyor; fakat B'den A'ya her dönüşte başlangıçtaki yaklaşık bir saniyelik grafik takılması yeniden oluşuyor. Grafik flicker'ı bütün videolarda, sabit hızda ve Eğriyi Takip Et kapalıyken de sürüyor. Build 4–7 arasındaki çizim sıklığı, asenkron Canvas, görünür veri aralığı ve dikey sınır önbelleği denemeleri kullanıcı gözleminde sorunu gidermedi. Build 7 yeniden testi: aynı. |
| 4 | Yalnız-ses çalışması | Sorun | Ses duyuluyor, pitch eğrisi görünüyor, dikey oynatma çizgisi ilerliyor, tüner güncelleniyor ve düğmelerle oynat/duraklat çalışıyor. Grafiğin üzerine tıklamak beklenen oynat/duraklat davranışını başlatmıyor. Video çalışmasındaki takılma ve flicker yalnız-seste de aynı şekilde sürüyor. |
| 5 | Temalar, pencere boyutları ve nota etiketleri | Sorun — yüksek öncelik | Çalışma odaklı, Stüdyo ve Sıcak klasik seçenekleri seçilebiliyor ve grafik alanının görünümü temaya göre değişiyor; uygulamanın grafik dışındaki bölümlerinde görünür tema değişikliği olmuyor. Nota adları farklı dikey yakınlaştırmalarda okunaklı. Pencere daraltılıp büyütülürken grafik alanı bütünüyle görünür/görünmez olarak yanıp sönüyor ve yeniden boyutlandırma bırakıldıktan sonra da bu durum sürüyor; normal oynatmadaki eğri flicker'ından daha ağır. Tekrar: medya açıkken pencere kenarını sürükleyerek art arda küçültüp büyüt. Teste devam etmek için uygulamayı yeniden başlatmak gerekiyor. |
| 6 | Ayarlar, renk kalıcılığı ve 53-koma koruması | Geçti | Pitch eğrisi rengi Uygula ile grafiğe yansıdı ve Ayarlar yeniden açıldığında seçilen renk korundu. Uygula kullanılmadan Bitti ile kapatılan yeni renk seçimi kaydedilmedi. Aralık toplamı 53'ten farklı yapıldığında toplam kırmızı gösterildi ve Uygula devre dışı kaldı; Teoriye Dön toplamı 53/53 yaptı ve Uygula yeniden etkinleşti. |
| 7 | Eski çalışma uyumluluğu | Geçti | Yanında `.vamp.json` bulunmayan `data/audio/egitim-vibrato.wav` dosyasının analizi tamamlandı ve ses oynatılabildi. |
| 8 | YIN v1 ile mikrofon, eğri ve tüner | Sorun | Mikrofon başladı, canlı pitch eğrisi oluştu ve tüner güncellendi. Eğriyi Takip Et perdeyi dikeyde izledi. Glissando, hızlı nota geçişi, üst register, ani bırakma, yavaş sönme ve kısa ses kesintilerinde takılı perde, belirgin alt/üst harmonik sıçraması veya sessizlikte sahte çizgi görülmedi. Perde motoru davranışı geçti; ancak dinleme modundaki grafik flicker'ı canlı grafikte de sürüyor. |
| 9 | Canlı kayıt ve WAV doğrulaması | Geçti | Kayıt başladı; kayıt devam ederken mikrofon durdurulduğunda kayıt güvenli biçimde sonlandı ve WAV dosyası kaydedildi. Kaydedilen WAV yeniden dinlendi; ses eksiksiz duyuldu. |
| 10 | V2 r4 gerçek cihaz kontrolü | Geçti | Sabit nota ve hızlı iki-üç nota geçişinde canlı eğri ve tüner çalıştı; belirgin gecikme, takılı perde veya alt/üst oktav sıçraması görülmedi. Yavaş sönme ve kısa kesintilerde sahte kuyruk veya geri dönüş gecikmesi görülmedi. |
| 11 | VPM r5 gerçek cihaz kontrolü | Geçti | Sabit nota, hızlı geçiş ve kısa kesintide belirgin gecikme, takılı perde, oktav sıçraması veya sessizlikte sahte çizgi görülmedi. Üst register ve yavaş sönmede de problem görülmedi. |

## Odaklı WebKit yeniden kabulü — 13 Ağustos 2026

Durum: **Tamamlandı — beta kapısı geçti**

Sürüm anı: **`v0.6.0-beta.2`** (uygulama paket build'i: `0.6.0 (7)`). Bu
etiket, aşağıdaki fiziksel kabulün ardından C++ çekirdek, Python `77 passed`,
Swift Package `41` test (iki isteğe bağlı parite dışa aktarma testi atlandı),
imzasız Debug derlemesi, Release paketleme ve paket imza doğrulaması yeniden
geçtikten sonra oluşturulmuştur.

Güncel `dist/KlariVision Beta.app` paketi yeniden üretildi. C++ çekirdek
kontrolleri, 77 Python testi, 41 Swift testi (2 isteğe bağlı parite testi
atlandı), imzasız Debug derlemesi ve Release paketleme geçti.

## Erişilebilirlik sonrası kaynak kontrol noktası — 13 Ağustos 2026

Sürüm anı: **`v0.6.0-beta.3`**. Bu annotated kaynak etiketi, uygulama paket
build numarasını değiştirmez; `v0.6.0-beta.2` önceki kabul anı olarak aynen
korunur. P1 erişilebilirlik kabulü tamamlandıktan sonra C++ çekirdek testleri,
tam Python paketi (`79 passed`), Swift Package (`44 passed`, 2 isteğe bağlı
çapraz-dil parite dışa aktarma testi atlandı), imzasız Release paketleme, sıkı
ad-hoc imza doğrulaması ve paketli `pitch-track-cli --contract` yeniden geçti.
Kontrat ABI v1 / `offline_track_v1` ile `yin_v1`, `pitch_engine_v2` ve
`vpm_like` üçlüsünü içerir. Bu sürüm kaydı motorlardan birini varsayılan,
önerilen veya kazanan yapmaz.

- `egitim-vibrato.mp4` dosya seçiciyle açıldı; analiz, ilk oynatma ve başa
  dönüş sonrasında grafik örneklenen ekran görüntülerinde görünür kaldı.
- Yaklaşık 1,8 saniyelik A/B aralığı etkinleştirildi ve 20'den fazla dönüş
  boyunca oynatma/grafik devam etti.
- A/B oynarken pencere art arda 20 kez küçültülüp büyütüldü; son durumda
  grafik bütünüyle görünür ve döngü çalışır kaldı.
- `sukru-tunar-08-14.wav` yalnız-ses çalışması açıldı; grafik alanına tıklama
  oynatmayı başlattı.
- Çalma Modu'nda mikrofon başladı, tüner güncellendi ve canlı WebKit grafiği
  sabit bir çizgiyle yükselen perde geçişini çizdi; oturum güvenle durduruldu.
- Kullanıcının devam eden fiziksel kontrolünde kesintisiz grafik akıcılığı,
  Finder sürükle-bırak, uygulama geneli tema, yalnız-ses grafiğinden hem
  oynatma hem duraklatma ve çalışmadan çıkınca medyanın durması olumlu
  doğrulandı. Önceki beta bloklayıcıları yeniden üretilemedi.
