# Pitch Engine C ABI v1

Bu sözleşme, YIN v1 (`yin_v1`), Pitch Engine v2 (`pitch_engine_v2`) ve
VPM-benzeri (`vpm_like`) için ortak ve eşit ürün sınırıdır. Bir kalite sırası,
öneri veya terfi kuralı değildir.

## Taşıma ve yapılandırma

- Girdi tek kanallı, 48 kHz, little-endian olmayan bellek içi `Float32 PCM`
  örnekleridir; C çağrısı örnek belleğini kopyalamaz veya sahiplenmez.
- v1'in standart çözünürlüğü `1536` örnek pencere ve `512` örnek hop'tur.
  C++/C ABI'nin açıkladığı değerler `kv_pitch_contract_get_v1` ile okunur.
- `source_time_seconds`, verilen pencerenin kaynak-zaman merkezidir. Yayın
  gecikmesi (özellikle v2 sabit gecikmesi) bu değere eklenmez.
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

`KV_PITCH_C_ABI_V1` geriye uyumlu ilk ABI'dir. Yetenek maskesi üç motoru,
gerçek-zamanlı ve `offline_track_v1` profillerini, kaynak zamanlarını ve
v2'nin `finish` ile sabit-gecikme kuyruğu boşaltmasını bildirir.

Python, ABI'nin paketlenebilir projeksiyonu olan
`klarivision-pitch-track-cli --contract` komutunu doğrular; çevrimdışı
çıktıda `engine`, `profile: offline_track_v1`, `implementation_revision`,
`frames`, `causal_baseline` ve `offline_changes` alanları bulunur. Önbellek
anahtarı motor kimliği, profil ve uygulama revizyonunu birlikte taşır.
