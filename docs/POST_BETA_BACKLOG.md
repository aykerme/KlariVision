# Beta Sonrası Önceliklendirme

## Kapsam dışı: referans–öğrenci karşılaştırması

Kullanıcı bu özelliği uygulamada istemediğini 13 Ağustos 2026'da açıkça
belirtti. İki kaydı ortak grafikte karşılaştırma, elle zaman hizalama veya
ortak A/B dinleme akışı kullanıcı yeniden istemedikçe geliştirilmez.

## Sıradaki teknik iş: macOS uygulama ayrıştırması

Davranış değiştirmeden `KlariVisionApp.swift` içindeki ekran düzeni, ortak
grafik/tüner, medya köprüsü ve canlı ses/motor adaptörü ayrı Swift dosyalarına
taşınacaktır. Her taşıma mevcut Swift testleri ve imzasız macOS derlemesiyle
korunur; bu iş beta kabulünden önce yapılmaz.

## Sonraki platformlar

iOS/iPadOS ve Android bağ katmanları, macOS beta kararlı hale geldikten ve
ortak C++ çekirdeğin dış arayüzü dondurulduktan sonra değerlendirilir.
