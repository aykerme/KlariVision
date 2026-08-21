# VPM-benzeri Pitch Motoru

## Üretim iz paritesi

10 Ağustos 2026'da C++ turnuva izi ile macOS Swift yayın yolu, turnuvadaki 26
sentetik WAV'ın tamamında kare kare eşlendi. Aynı Float32 girdi ve `1536/512`
düzeninde iki tarafta da `67.595` kare yayımlandı; sesli/sessiz, `≤1 sent`
frekans ve `≤0.01` güven ölçütlerinde ayrışma yoktur. Yeniden üretim komutu:
`.venv/bin/python -B scripts/check_vpm_swift_cpp_parity.py`.

## Amaç

Tadao Yamaoka'nın Vocal Pitch Monitor için yayımladığı teknik yazılardan
yararlanan, fakat kapalı kaynak uygulamanın birebir kopyası olduğunu iddia
etmeyen bağımsız bir deney motorudur. Kararlı YIN ve Pitch Engine v2 korunur;
yeni motor aynı kaynak üzerinde pYIN ile ayrıca karşılaştırılabilir.

## Kaynaklardan alınan yöntem

1. Normalleştirilmiş öz-ilinti ile temel periyot adayı bulunur.
2. Yüksek frekansta gecikme örneklemesinin yarattığı hatayı azaltmak için
   `2T`, `3T` ve sonraki öz-ilinti tepeleri aranır; tepe konumları kendi
   katsayılarına bölünerek periyot hassaslaştırılır.
3. İlk adayın `1/3`, `1/2`, `1×`, `2×` ve `3×` frekansları gerçek spektrumda
   sınanır.
4. Yerel spektral tepe, mutlak genlik ve ana adaya göre bağıl genlik
   koşullarını geçen en düşük frekans temel ses olarak seçilir. Spektral kontrol
   ACF adayını `1/3` veya `1/2` temel sese indirebilir; güçlü bir üst harmonik
   ACF sonucunu `2x/3x` değerine yükseltemez. ACF'nin seçtiği tepe aynı zamanda
   en güçlü ACF tepesiyse spektrum bu sonucu aşağı da çekemez; aşağı düzeltme
   yalnız daha erken, yakın-güçlü bir ACF tepesini onarmak için kullanılır.

Yamaoka eşik değerlerinin kayıt ve çalgıya göre ayarlanması gerektiğini
belirtiyor; Vocal Pitch Monitor'ün üretim eşikleri yayımlanmış değil. Bu
nedenle KlariVision eşikleri açık yapılandırma ve regresyon testleriyle kendi
verimiz üzerinde geliştirilir. İlk ortak kalibrasyonda üç sentetik stres
varyantı ile Şükrü Tunar kaydının kararlı pYIN kareleri birlikte kullanıldı.
Yakın öz-ilinti tepesi oranı `0,84` değerinden `0,90` değerine, bağıl spektral
destek eşiği `0,055` değerinden `0,080` değerine çıkarıldı. Kapsam hiçbir test
kaydında düşmezken Şükrü Tunar karşılaştırmasının p95 hatası `93,97 cent`ten
`55,58 cent`e, harmonik hata oranı `%4,41`den `%3,17`ye geriledi.
Seçimden sonra hiç eşik aramasında kullanılmayan temiz ve oda koşullu iki
sentetik klarnet kaydı holdout olarak çalıştırıldı; ikisinde de `%100` kapsam
ve `%0` harmonik hata korundu.

Şükrü Tunar aday teşhisinde eski seçimin yüksek-periodicity ACF/pYIN
uzlaşmasını 32 karede daha keskin `2x/3x` spektral tepeyle bozduğu görüldü.
Mutlak spektral destek `0,004`ten `0,005`e çıkarıldı ve üst-harmoniğe terfi
kapatıldı. Şükrü Tunar p95 hatası `32,61 sent`e, harmonik hata `%0,4251`e
inerken bütün kaynaklarda kapsama korundu. Her karenin ACF/spektral adayları,
red gerekçeleri ve pYIN oranları
`outputs/sukru-tunar-vpm-candidate-diagnostics.json` içindedir.

Adverse holdout v1'in `9,1–9,4 sn` aday izinde ACF yaklaşık `171,4 Hz` sonucu
verirken spektral seçim aralıklı olarak `85,7 Hz` değerine indi. En güçlü ACF
tepesi zaten seçilmiş karelerde aşağı spektral düzeltmenin kilitlenmesi C++ ve
Swift'e birlikte eklendi. Aynı dosyanın kararlı, sesli karelerinde C++ aday
izine göre p95 `11,832 → 9,536 sent`, harmonik kare `70 → 52` oldu; 18 kare
iyileşti ve hiçbir kare kötüleşmedi. Bu dosya düzeltme teşhisinde kullanıldığı
için sonuç bağımsız holdout kanıtı değildir.

Aynı dosyanın ekran incelemesi, kalan izole noktaların büyük bölümünün kısa
analitik sessizlik boşluklarında oluştuğunu gösterdi. Aday üretimi korunarak
yayın için en az `0,80` periodicity/güven koşulu C++ ve Swift'e birlikte
eklendi. Odaklı ayna sayımında sessizlikteki kareler `81`den `7`ye inerken
sesli hedef karelerinin `37/2208`i (%1,7) elendi. Bu sonuç tam turnuva değildir;
eşik görülmemiş holdout v2 ile yeniden sınanmalıdır.

Kalibrasyon tekrar üretilebilir:

```sh
.venv/bin/python -B -u scripts/calibrate_vpm_like_engine.py
```

Tam sayısal rapor `outputs/vpm-like-calibration.json` dosyasına yazılır.

## Teknik kaynaklar

- [Pitch doğruluğunu geliştirme ve harmonik düzeltme (2015)](https://tadaoyamaoka.hatenablog.com/entry/2015/01/08/175350)
- [Öz-ilinti ile temel frekans ölçümü (2016)](https://tadaoyamaoka.hatenablog.com/entry/2016/08/28/114423)
- [İleri periyot tepeleriyle hassaslaştırma (2017)](https://tadaoyamaoka.hatenablog.com/entry/2017/01/14/105823)
- [Sıfır doldurma ile hassaslaştırma (2017)](https://tadaoyamaoka.hatenablog.com/entry/2017/01/14/121517)
- [Yamaoka'nın güncel MPM değerlendirmesi (2025)](https://tadaoyamaoka.hatenablog.com/entry/2025/03/18/224246)

## Uygulamadaki erişim

Canlı çalışma ekranındaki tanılama menüsünden:

- `Dosyadan VPM-benzeri motor testi…`: aynı dosyada VPM-benzeri eğriyi pYIN
  referansıyla karşılaştırır ve doğrulama raporu üretir.
- `Canlı motor: VPM-benzeri`: mikrofonla canlı çalışma motorunu değiştirir.
- `Canlı motor: Kararlı YIN`: mevcut kararlı motora geri döner.

## İlk doğrulama sınırı

Taşınabilir C++ testleri, harmonik zengin sentetik klarnet sinyalinde 110,
220, 880 ve 1173 Hz örneklerini ve sessizlik reddini kapsar. Gerçek klarnet,
oda ve mikrofon testleri ayrı regresyon turudur; bu ilk testler ürün motorunun
Vocal Pitch Monitor ile eş performansta olduğunu kanıtlamaz.
