# Etkileşim ve durum sözleşmesi

## Genel etkileşim

- Apple Pencil, normal dokunmayla eş davranır; v1'de yazılı anotasyon üretmez.
- Klavye: Space oynat/duraklat, sol/sağ ok ±5 saniye, `A` ve `B` işaretleme,
  `L` loop. Odak halkası görünür ve mantıksal sıradadır.
- Trackpad pointer, tıklanabilir grafik/denetim yüzeyinde görünür geri bildirim
  verir. Reduce Motion açıkken kayıt yanıp sönmesi ve eğri geçişleri durur.
- Oynatma veya mikrofon çalışırken uygulama ekranı açık tutar; oturum bitince
  sistem davranışına döner.

## Kritik durumlar

| Durum | Görünür geri bildirim | Kurtarma |
|---|---|---|
| Desteklenmeyen dosya | Kırmızı olmayan açıklayıcı hata kartı | Başka Dosya Seç |
| Güvenli kopyalama hatası | Yerel kopyanın tamamlanmadığı bilgisi | Tekrar Dene / Başka Dosya Seç |
| Analiz hatası | Hangi adımın tamamlanmadığı | Tekrar Dene |
| Mikrofon izni reddi | İzin olmadan dinleme yapılamaz | Ayarları Aç |
| Mikrofon/rota kesintisi | Oturum durdu, sahte eğri yok | Mikrofonu Başlat |
| Aktif kayıt | Kırmızı nokta + “Kayıt sürüyor” | Kaydı Durdur |
| Kayıt yazma hatası | Kayıt konumu üretilemedi | Yeniden Kaydet |
| Geçersiz 53 koma | Toplam ve sorunlu aralık | Teoriye Dön |
| Eski çalışma geri dönüşü | Gömülü eğrinin kullanıldığı bilgisi | Çalışmaya Devam Et |

Durumların tamamı VoiceOver canlı bölgesinde okunur. Renk hiçbir zaman tek
durum taşıyıcısı değildir.
