# Android ortak çekirdek fizibilitesi

Son güncelleme: 13 Ağustos 2026

Bu belge Android ürünü, ekranı veya dağıtımı başlatmaz. Kullanıcı ayrıca istemeden
macOS davranışını genişletmeden, C ABI v1'e dayalı en küçük Android teknik
spike'ının sınırını tanımlar.

## Araç zinciri kanıtı ve sonuç

13 Ağustos yerel denetiminde `ANDROID_HOME`, `ANDROID_SDK_ROOT`,
`ANDROID_NDK_HOME` ve `NDK_HOME` ayarlı değildi. Bilinen SDK dizinleri mevcut
değildi; `gradle`, `cmake` ve `ninja` bulunamadı. Yerel `clang++`, Apple clang
17'dir ve `arm64-apple-darwin` hedeflidir; Android NDK derleyicisi değildir.

Bu nedenle Android `arm64-v8a` compile/link smoke **çalıştırılmadı** ve araç
kurulmadı. C++ kaynaklarının Android uyumluluğu henüz doğrudan kanıt değildir.
`core/CMakeLists.txt` C++20 statik `klarivision_core` hedefini tanımlar ve
Accelerate bağlantısını yalnız `APPLE` üzerinde yapar; bu Android için uygun
başlangıç noktasıdır, ancak NDK ile derlenip bağlanmalıdır.

**Yalnız teknik spike için koşullu go; tam Android ürünü için no-go.** Go
kararı, aşağıdaki NDK smoke kapıları yeşil olduğunda geçerlidir.

## Sabit ürün ve ABI sınırları

- Kotlin/JNI tüketicisi yalnız `analysis_engine_c.h` C ABI v1'i kullanır.
  Üç motor kimliği, 48 kHz mono Float32 PCM, `1536/512` pencere/hop, kaynak
  pencere merkezi zamanı ve `create/reset/process/finish/destroy` sırası
  değişmez.
- `yin_v1`, `pitch_engine_v2` ve `vpm_like` Dinleme ve Çalma akışlarında aynı
  nötr, kalıcı kullanıcı seçenekleri olarak korunur. Kazanan, önerilen motor,
  kalite sırası veya varsayılan terfisi eklenmez.
- JNI katmanı motor eşiği veya pitch kararı üretmez; C++ hata metnini ve kare
  çıktısını yalnız güvenli platform sonucu olarak taşır. Python/Vamp Android
  çalışma zamanına konmaz.
- Kullanıcı medya/analiz/kayıtları yalnız uygulama sandbox'ında kalır. Ağ,
  bulut senkronu, paylaşım, puanlama ve referans–öğrenci karşılaştırması
  kapsam dışındadır.

## Hedef mimari

| Katman | Sorumluluk | Android yaklaşımı |
|---|---|---|
| `klarivision_core` | Pitch ve C ABI | NDK CMake ile C++20 statik çekirdek; JNI paylaşımlı kütüphanesi bunu bağlar. Ürün spike'ında yalnız `arm64-v8a` paketlenir. |
| JNI `PitchSession` | Handle ve hata sınırı | Kotlin `AutoCloseable` sahipliği; opak native pointer yalnız doğrulanmış `Long` handle'dır. `close` idempotent, işlem sonrası kullanım reddedilir; finalizer'a güvenilmez. C++ exception'ı JNI sınırını geçmez, `last_error` Kotlin hata sonucuna çevrilir. |
| PCM hattı | Gerçek zamanlı giriş | Ses iş parçacığı doğrudan `ByteBuffer`/`FloatBuffer` kullanır; JNI `GetDirectBufferAddress` ile tek 1536 örnek pencereyi okur. Doğrudan olmayan buffer, yanlış byte sırası, örnek sayısı veya 48 kHz dışı giriş açık hatadır. |
| Ses adaptörü | Mikrofon ve zaman | `AudioRecord` ayrı yüksek öncelikli iş parçacığında çalışır; desteklenirse 48 kHz `PCM_FLOAT`, değilse platform dönüştürücüsüyle 48 kHz mono Float32'ye çevrilir. Kaynak zamanı örnek sayacı ve uygun `AudioTimestamp` ile türetilir; UI saatiyle ikame edilmez. |
| Web grafik | Dinleme/Çalma canvas | Compose `AndroidView` içinde tek `WebView`; mevcut mesaj şeması korunur. Yalnız paketli veya sandbox yerel HTML yüklenir; `WebMessagePort` tercih edilir, dar köken doğrulaması yapılır, dış gezinme ve evrensel dosya erişimi kapalıdır. |
| Dosya/veri | SAF ve yerel geçmiş | `ACTION_OPEN_DOCUMENT`/Compose picker ile gelen URI kısa süre okunur; app izinliyse persistable grant alınır fakat analiz için medya ve yan dosyalar `filesDir`/`noBackupFilesDir` altına koordineli kopyalanır. Kalıcı çalışma kopyayı kullanır; kullanıcı URI'si erişim sınırı olarak tutulmaz. |
| Compose kabuk | Telefon/tablet yerleşimi | Tek durum sahibi; dar ekranda medya ve grafik ardışık, tablet genişlikte yan yana. Genişlik değişimi `WebView` kimliğini yeniden üretmez. |

### JNI yaşam döngüsü ve iş parçacığı kuralları

1. `nativeCreate(engine, minimumRms)` C++ `create` çağırır ve yalnız seçili üç
   engine kimliğini kabul eder.
2. `nativeProcess(handle, directBuffer, sourceTime)` tek ses/işleme
   iş parçacığında çalışır; handle aynı anda iki thread'de kullanılamaz.
3. `nativeFinish` yalnız bir kez çağrılır; kalan v2 gecikme çıktıları okunur.
   Ardından `nativeDestroy` handle'ı geçersizleştirir. Rota/kesinti/arka plan
   sonrası yeni ses başlatma yeni oturum oluşturur.
4. Her native giriş dönüş değeri kontrol edilir. Java exception varsa temizlenir
   ve Kotlin tarafına tanımlı yerel hata döner; C++ istisnası sınırı geçmez.

## Platform riskleri

- `RECORD_AUDIO` çalışma zamanında istenir; SAF ile dosya almak için geniş
  depolama izni gerekmez. Kullanıcı izni, route değişimi, cihaz mikrofonu ve
  48 kHz desteklenmemesi ayrı hata durumlarıdır.
- `AudioFocusRequest`, kulaklık/Bluetooth rota değişimi, telefon/assistant
  kesintisi, `onPause`/`onStop`, process yeniden oluşumu ve arka plan için açık
  stop/finish/destroy politikası gerekir. Sürekli arka plan kaydı bu spike'ta
  vaat edilmez; kullanıcı görünür akışta yeniden başlatır.
- `WebView.addJavascriptInterface` geniş yüzey oluşturur; bu nedenle paketli
  içerik dışında açılmaz, köken/mesaj doğrulanır ve mümkün yerde
  `WebMessagePort` kullanılır. JavaScript yalnız mevcut canvas için etkindir.
- NDK `.so` paketi ABI filtresiyle ilk spike'ta `arm64-v8a` ile sınırlandırılır.
  Release sembolleri ayrı saklanır; `x86_64` emulator ancak sonraki açık
  kararla eklenir. 32-bit ABI eklenmez.
- Thermal throttling, Bluetooth örnek oranı ve üretici ses sürücüleri RTF ve
  gecikmeyi değiştirir; masaüstü RTF rakamları Android kabulü değildir.

## Tekrarlanabilir NDK smoke planı (NDK kurulduktan sonra)

`ANDROID_NDK_HOME` ve CMake/Ninja erişilebilir olduğunda, boş bir geçici build
dizininde aşağıdaki komutlar çalışır. Kaynak, kullanıcı verisi veya Android UI
değiştirilmez:

```bash
cmake -S core -B /private/tmp/klarivision-android-arm64 \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-26 \
  -DKLARIVISION_CORE_BUILD_TESTS=OFF
cmake --build /private/tmp/klarivision-android-arm64 --target klarivision_core
```

Bu smoke `libklarivision_core.a` için compile/link kanıtıdır. İlk JNI spike'ı
ardından emülatör veya arm64 cihaz üzerinde çalışan Kotlin instrumentation
testi C ABI kontratını ve üç motor yaşam döngüsünü ayrıca doğrular; çapraz
derlenmiş masaüstü `ctest` ikilisi host üzerinde çalıştırılmaz.

## Android kabul ve performans planı

| Kapı | Kanıt |
|---|---|
| ABI paketi | `arm64-v8a` static core + JNI shared library bağlanır; `kv_pitch_contract_get_v1` ABI v1, üç capability, 48 kHz ve `1536/512` değerlerini döndürür. |
| Yaşam döngüsü | Her üç motor için sessiz ve sabit-nota sentetik pencereyle `create/process/finish/destroy`; çift kapatma, yanlış handle, yanlış buffer ve hata metni test edilir. |
| Gerçek zaman | AudioRecord 48 kHz mono Float32 kaynak zinciri; input overflow, dönüşüm, rota/kesinti ve foreground dönüşü test edilir. C++ source timestamp ile UI yayım zamanı ayrı kaydedilir. |
| RTF/gecikme | Motor başına aynı kayıt protokolünde native işlem süresi / PCM kaynak süresi, p50/p95/max RTF, buffer düşümü, JNI kopya/ayırma sayısı, kaynak-karar-yayım gecikmesi ölçülür. Sayılar motor seçimi için kullanılmaz. |
| C++ regresyon | NDK'da çekirdek test kaynakları derlenir; çalıştırılabilir kontroller emulator/cihaz üzerinde JNI instrumentation veya `adb` native runner ile yürür. Masaüstü C++/Swift kapıları da yeşil kalır. |
| Web/veri | Yalnız yerel HTML/medya, köken doğrulanmış mesaj köprüsü, SAF kopya hata metni ve uygulama sandbox dışına yazmama denetlenir. |

## En küçük sonraki derlenebilir spike (henüz uygulanmadı)

Kullanıcı açıkça yetki verirse yalnız şu hedef eklenir: `arm64-v8a`
`klarivision_core` + küçük JNI kontrat test kütüphanesi + cihaz/emulator
instrumentation testi. Compose ekranı, `WebView`, AudioRecord, izin diyaloğu,
dosya picker, kayıt, ağ ve dağıtım içermez. Giriş kapısı NDK smoke'ın yeşil
olmasıdır; çıkış kapısı C ABI v1 ve üç eşit motor kimliğinin değişmeden
bağlanmasıdır. Bu teknik kanıt tam Android ürününü başlatma yetkisi vermez.
