# Canlı yol enstrümantasyonu

## Bu neden var

Dış bir değerlendirme, Android canlı grafiğinin takılmasının (jank)
`LiveGraphBridge.kt`'deki WebView + `evaluateJavascript` JSON köprüsünden
kaynaklandığını iddia etti ve WebView'i söküp Jetpack Compose Canvas ile
değiştirmeyi önerdi. Grafiğin HTML'i iPad ile **byte-eşit paylaşılan
kanonik bir varlık**tır (bkz. `app/src/main/assets/viewer/README.md`) —
onu sökmek büyük ve geri dönüşü zor bir mimari değişikliktir.

Bu enstrümantasyon o iddiayı sökmeden ÖLÇER. Canlı yolun bir hop/parti
başına dört ayrı aşamasını ölçer:

1. **JNI + motor** — `LiveAudioCapture.runCaptureLoop` içindeki
   `processor.process(samples)` çağrısı (`LiveCoreProcessor` →
   `LivePitchSession`, C++ motoru).
2. **JSON serileştirme** — `LiveFramePayload.toJsonString` süresi ve
   ürettiği string'in UTF-8 bayt boyutu.
3. **`evaluateJavascript`** — `LiveGraphBridge.evaluate`'in ANA İŞ
   PARÇACIĞINDA geçirdiği süre. `evaluateJavascript` asenkrondur;
   burada ölçülen yalnız scripti WebView'a TESLİM ETME süresidir —
   sayfa içindeki JS'in kendisinin ne kadar sürdüğü DEĞİL. Bu, "ana iş
   parçacığını kim bloklu­yor" sorusuna tam olarak cevap verecek
   ölçümdür (jank ana iş parçacığı bloklanmasından doğar).
4. **Atlanan kareler** — ardışık `Choreographer` vsync'leri arasındaki
   aralık, cihazın gerçek yenileme aralığını (yoksa 16,7 ms/60 Hz'e
   düşerek) aşan kare sayısı.

## Nasıl açılır

Varsayılan olarak KAPALI — `LiveInstrumentation.enabled == false` iken
her ölçüm noktası yalnız bu `Boolean`'ı okur, hiçbir tahsis/zaman ölçümü
yapmaz.

Açmak için (ör. `MainActivity.onCreate` içine, ya da bir debug menüsüne):

```kotlin
com.aykerme.klarivision.profiling.LiveInstrumentation.enabled = true
```

Sonra uygulamada Dinleme/Çalma modunu normal şekilde başlatıp durdurun.
Özet, yakalama durduğunda (`LiveAudioCapture.stop()`/`performStop`) BİR
KEZ loglanır — sürekli akan bir log değil, "bu oturumda ne oldu"
sorusuna cevap.

## Nasıl okunur

```
adb logcat -s KlariVisionLiveProf:I
```

Örnek çıktı:

```
--- canlı yol kare bütçesi (kullanıcı durdurdu) ---
JNI+motor          p50=1.204ms p95=2.891ms max=6.442ms (n=850)
JSON serileştirme  p50=0.031ms p95=0.058ms max=0.210ms (n=850)
JSON bayt boyutu   p50=96B p95=96B max=96B (n=850)
evaluateJavascript p50=0.412ms p95=0.980ms max=3.115ms (n=850)
kare aralığı       p50=16.680ms p95=17.020ms max=41.330ms (n=612)
atlanan kare sayısı (>bütçe): 14
```

(Sayılar örnektir — hipotezi çürüten/doğrulayan gerçek sayılar cihazda
koşulmadan bilinmez.)

## Hangi sayı hangi hipotezi çürütür/doğrular

Dış değerlendirmenin iddiası: **WebView köprüsü** (JSON serileştirme +
`evaluateJavascript`) takılmanın kaynağı, çözüm Compose Canvas'a geçmek.

| Gözlem | Ne anlama gelir |
| --- | --- |
| `evaluateJavascript` p95/max, hop bütçesine (10,67 ms @ 512 hop/48 kHz) yakın veya onu aşıyor, VE atlanan kare sayısı yüksek | İddia GÜÇLENİR — köprü gerçekten ana iş parçacığını bloklu­yor, Compose Canvas'a geçiş gündeme gelebilir. |
| `evaluateJavascript` ve JSON serileştirme süreleri ihmal edilebilir (µs mertebesinde) AMA atlanan kare sayısı hâlâ yüksek | İddia ÇÜRÜR — takılma köprüden değil, WebView'in KENDİ hosting/compositing katmanından (Compose `AndroidView` içinde WebView barındırma — bkz. memory notu "Study mode graph rendering architecture") ya da başka bir kaynaktan geliyor. Sökme gerekçesiz olur. |
| JNI+motor p95/max, hop bütçesini aşıyor | İddia tamamen YANLIŞ YÖNE işaret ediyor — asıl maliyet motorda (`unified_v1`/pYIN), köprüde değil. WebView'i sökmek jank'ı ÇÖZMEZ. |
| JSON bayt boyutu p50/max anormal büyük (ör. binlerce bayt/hop) | Köprünün TAŞIDIĞI yük büyük — serileştirme/evaluate sürelerini bununla birlikte oku; büyük yük + yüksek evaluate süresi köprü hipotezini destekler, küçük yük + yüksek evaluate süresi WebView'in kendi iç maliyetine işaret eder. |
| Atlanan kare sayısı sıfıra yakın, ama kullanıcı yine de takılma bildiriyor | Ölçülen dört aşamanın DIŞINDA bir kaynak var (ör. GC duraklaması, başka bir thread'in kilit çekişmesi) — bu enstrümantasyonun kapsamı dışında, ayrı bir araştırma gerekir. |

## Ölçüm mimarisi (nerede ne var)

- `app/src/main/kotlin/com/aykerme/klarivision/profiling/LiveInstrumentation.kt`
  — saf hesaplama (ring tampon, p50/p95/max, "kaç kare atlandı"
  aritmetiği). Android'e bağımlı DEĞİL, JVM testiyle koşar
  (`app/src/test/kotlin/com/aykerme/klarivision/profiling/LiveInstrumentationTest.kt`).
- `app/src/main/kotlin/com/aykerme/klarivision/profiling/LiveProfilingLog.kt`
  — Android'e bağımlı yarı: `Log.i` çıktısı ve `Choreographer` tabanlı
  `FrameDropWatcher`.
- Ölçüm noktaları: `live/LiveAudioCapture.kt` (JNI+motor, watcher
  start/stop, oturum sonu özeti) ve `web/LiveGraphBridge.kt` (JSON
  serileştirme + `evaluateJavascript`).

## Kapsam dışı

Bu katman mimariyi DEĞİŞTİRMEZ — WebView sökülmedi, Compose Canvas
yazılmadı, Oboe'ya geçilmedi. Yalnız ölçer. Cihaz testi bu değişikliğin
parçası değildir — kullanıcı gerçek cihazda koşup logcat çıktısını
paylaşmalıdır.
