# Bilgi mimarisi

## Birincil yapı

Uygulama üç kök bölüme ayrılır: **Ana Sayfa**, **Çalışmalar** ve **Ayarlar**.
Ana Sayfa iki eşit başlangıç kartını sunar: Dinleme Modu ve Çalma Modu.
Çalışmalar, yerel analizlerin güvenli listesidir; listeden kaldırmak medyayı
ve pitch verisini silmez.

| Bölüm | Amaç | Birincil eylem |
|---|---|---|
| Ana Sayfa | İki çalışma biçiminden birini seçmek | Dosya seçmek veya mikrofonu başlatmak |
| Çalışmalar | Son yerel analizleri açmak ve düzenlemek | Çalışmayı açmak |
| Dinleme | Medyayı pitch eğrisiyle çalışmak | Oynatmak, A/B döngüsü kurmak |
| Çalma | Canlı perdeyi izlemek ve kaydetmek | Mikrofonu başlatmak |
| Ayarlar | Tema ve gelişmiş çalışma ayarları | Geçerli taslağı uygulamak |

## Dinleme akışı

`Ana Sayfa → Dosya Seç → Güvenli yerel kopya → Analiz → Çalışma alanı`

Dosya seçildikten sonra çalışma başlığı, makam ve karar düzenlenebilir. Analiz
durumu dosya alma ve pitch üretimi için ayrı metinlerle görünür. Başarısızlıkta
aynı yerde “Tekrar Dene” ve “Başka Dosya Seç” eylemleri gösterilir.

## Çalma akışı

`Ana Sayfa → Çalma → Mikrofon izni → Canlı grafik → İsteğe bağlı kayıt`

Son seçilmiş makam ve karar geri yüklenir. Mikrofon yalnız kullanıcının
“Mikrofonu Başlat” eylemiyle açılır; kayıt ayrı, kırmızı ve belirgin durumlu
bir eylemdir. Oturum kesintisi veya arka plan sonrası kullanıcı yeniden
başlatır.

## Ayarlar hiyerarşisi

Hızlı, oturum içi denetimler her iki modda görünür: makam, karar, takip ve
görünümü sıfırlama. Tema, grafik renkleri, motor seçimi, sinyal kapısı ve
53-koma aralıkları “Ayarlar” sayfasında yer alır. Ayarlar, kaydırılabilir
içeriğe ve altta sürekli görünen “Uygula” eylemine sahip bir sheet'tir.
