# KlariVision regular-width UI/UX paketi

Bu paket, KlariVision'ın iPad ve diğer regular-width yerleşimleri için v1
arayüz sözleşmesidir. D-034 ile başlatılan evrensel iPhone+iPad ürününde bu
tasarım regular genişlikte korunur; compact iPhone kabuğu üç sekmeli `TabView`
ve ayrı Dinleme/Çalma çalışma rotaları kullanır.

## İçindekiler

- `01-information-architecture.md`: ekranlar ve kullanıcı akışları.
- `02-screen-frame-matrix.md`: zorunlu referans çerçeveleri.
- `03-responsive-contract.md`: genişlik, panel ve WebKit kimliği kuralları.
- `04-interaction-and-states.md`: dokunma, klavye ve hata durumları.
- `05-design-tokens.md`: renk, tipografi, ölçü ve hareket tokenları.
- `06-accessibility-and-acceptance.md`: erişilebilirlik ve tasarım kabulü.
- `screens/`: 13 yüksek sadakatli SVG ekranı ve kritik durum panosu.
- `flows/primary-flows.svg`: üç ana kullanıcı akışı.

SVG dosyaları tarayıcıda açılabilir ve doğrudan tasarım incelemesi için
kullanılabilir. Her ekran kendi içinde aynı token adlarını tekrarlar; görsel
referans değil, uygulayıcı için ölçülü bir davranış sözleşmesidir.

## Sabit ürün sınırları

- iOS/iPadOS 17+ aynı uygulama hedefinden üretilir.
- Medya, kayıtlar ve analiz önbelleği yerelde kalır.
- Makam ve karar kullanıcı tarafından seçilir; otomatik makam tespiti yoktur.
- Fiziksel pitch ile gösterilen/transpoze nota adı ayrıdır.
- YIN v1, Pitch Engine v2 ve VPM-benzeri eşit kullanıcı seçenekleridir.
- Bulut, paylaşım, puanlama, referans–öğrenci karşılaştırması ve Pencil
  anotasyonu kapsam dışıdır.

## Uygulama sözleşmesi

Ürün kararı ve C ABI v1 Core Smoke kapısı D-034 kapsamında geçmiştir.
Uygulama katmanı Python çalıştırmaz; yerel
analiz C ABI v1, medya/grafik ise tek kimliği korunan `WKWebView` üzerinden
çalışır.
