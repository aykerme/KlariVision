# KlariVision Viewer Assets

Bu dizindeki HTML dosyaları, KlariVision grafik görüntüleyicilerinin kanonik kaynağından buraya kopyalanmıştır.

## Kanonik kaynaklar

- `StudyViewer.html` — orijinal: `ipad/KlariVisioniPadCoreSmoke/KlariVisioniPad/Resources/StudyViewer.html`
- `LiveViewer.html` — orijinal: `ipad/KlariVisioniPadCoreSmoke/KlariVisioniPad/Resources/LiveViewer.html`

## Güncelleme süreci

Bu dosyaları düzenlemek için:

1. **İOS kaynağında değişiklik yap:** Orijinal iOS dosyalarında yapılan değişiklikleri `ipad/.../Resources/` altında düzenle.
2. **Bu kopyaları güncelle:** Düzenleme sonrası, değiştirilmiş dosyaları bu dizine kopyala.
3. **Eşitlik doğru:** `diff` ile kaynaktan bu kopyalara kadar olan byte sayısının eşit olduğunu doğrula.

Aynı anda iki yerden düzenlemeler yapılırsa, dosyalar sapabilir.

## Platform soyutlaması

`StudyViewer.html` her iki platform tarafından kullanılan soyutlanmış bir köprü mekanizması içerir:

- **iOS:** `window.webkit.messageHandlers.studyPlayback` nesnesi Swift tarafından tanıtılır; çağrılar nesneyi olduğu gibi gönderir.
- **Android:** `window.kvStudyBridge` (Java tarafından enjekte edilen) aynı `postMessage` arayüzünü sağlar; çağrılar JSON.stringify ile yapılır.

Köprü tanımı satır 46'da, fallback deseni ile yapılmıştır.
