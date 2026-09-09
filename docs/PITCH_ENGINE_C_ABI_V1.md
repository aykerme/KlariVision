# Pitch Engine C ABI v1

Bu sözleşme, çalışan tek motor `unified_v1` (`KV_ENGINE_UNIFIED_V1= 4`) için
ürün sınırıdır.

**Rezerve kimlikler.** `KV_ENGINE_YIN_V1` (0), `KV_ENGINE_V2` (1),
`KV_ENGINE_VPM_LIKE` (2) ve `KV_ENGINE_HAPT_V1` (3) D-039 ile kaldırılan
motorlara aittir. Numaraları ve yetenek bitlerinin konumları kalıcıdır: asla
yeniden kullanılmaz, yeniden numaralanmaz. Bu kimliklerden biriyle oturum
açmak `NULL` döner — hayatta kalan motora yönlendirme yapılmaz.

**Rezerve alan.** `kv_pitch_contract_v1.v2_fixed_lag_frames` yapının donmuş
yerleşiminin parçasıdır ve `5` bildirmeye devam eder, ancak artık hiçbir şeyi
tanımlamaz. Canlı karar gecikmesi `kv_unified_lag_frames()`'tir.

**Rezerve semboller.** `kv_v2_session_*` girişleri dışa verilmeye devam eder ve
temiz biçimde başarısız olur (create `NULL`, diğerleri `0`): v1'in sembol
kümesi sözleşmenin parçasıdır, v1'e karşı derlenmiş bir tüketici çözülemeyen
sembol yerine teşhis edilebilir bir hata almalıdır.

## Taşıma ve yapılandırma

- Girdi tek kanallı, 48 kHz, little-endian olmayan bellek içi `Float32 PCM`
  örnekleridir; C çağrısı örnek belleğini kopyalamaz veya sahiplenmez.
- v1'in standart çözünürlüğü `1536` örnek pencere ve `512` örnek hop'tur.
  C++/C ABI'nin açıkladığı değerler `kv_pitch_contract_get_v1` ile okunur.
- `source_time_seconds`, verilen pencerenin kaynak-zaman merkezidir. Yayın
  gecikmesi (`kv_unified_lag_frames()` kadar sabit gecikme) bu değere
  eklenmez.
- Kullanıcının değiştirebildiği yalnız sinyal kapısı `minimum_rms` değeridir;
  motor karar eşikleri C++ uygulamasının otoritesindedir.

## Yaşam döngüsü ve çıktı

`kv_production_pitch_session_create` → sıfır veya daha çok
`process_frame` → `finish` → `destroy` yaşam döngüsüdür. `reset`, aynı
nesneyi yeni bir akış için temizler. `finish` idempotenttir; ardından yeni
girdi kabul edilmez, önce `reset` gerekir. Her `process_frame` ve `finish`
çağrısı önceki çıkış görünümünü değiştirir; kareler
`output_count`/`output_frame` ile çağrıdan sonra ve bir sonraki mutasyon
çağrısından önce okunur. Çıktıdaki `voiced=0`, `frequency_hz=0` anlamına
gelir; başarılı sessiz çağrı hata değildir. Hata durumunda çağrı `0` döner ve
`last_error` geçici, oturumun sahip olduğu UTF-8 metindir.

## Sürümler ve çevrimdışı dosya çıktısı

`KV_PITCH_C_ABI_V1` geriye uyumlu ilk ABI'dir ve sürümü **1 olarak kalır**:
D-039'un motor kaldırması yapı yerleşimini, sembol kümesini ve numaralandırmayı
değiştirmedi, yalnız hangi bitlerin kurulduğunu değiştirdi. Yetenek maskesi
`KV_CAP_ENGINE_UNIFIED_V1`, gerçek-zamanlı ve `offline_track_v1` profilleri ile
kaynak zamanlarını bildirir. Kaldırılan motorların bitleri —
`KV_CAP_ENGINE_YIN_V1`, `..._V2`, `..._VPM_LIKE`, `..._HAPT_V1` ve v2'ye ait
`KV_CAP_V2_FIXED_LAG_FINISH` — konumlarında durur ve temiz okunur.

Python, ABI'nin paketlenebilir projeksiyonu olan
`klarivision-pitch-track-cli --contract` komutunu doğrular; çevrimdışı
çıktıda `engine`, `profile: offline_track_v1`, `implementation_revision`,
`frames`, `causal_baseline` ve `offline_changes` alanları bulunur. Önbellek
anahtarı motor kimliği, profil ve uygulama revizyonunu birlikte taşır.
