# KlariVision — Gizlilik Politikası ve App Privacy Yanıtları

Sürüm 1 (0.6.0) · Taslak tarihi 2026-09-13

Bölüm A ve B herkese açık bir sayfada yayımlanır; adresi App Store Connect → App
Information → Privacy Policy URL alanına girer. Bölüm C yalnız App Store Connect
formunu doldurmak içindir.

Doğrulanan davranış (kod, 2026-09-13):
- Ağ isteği yok: Swift kaynaklarında `URLSession`/`URLRequest` kullanılmıyor; sandbox
  izinlerinde `network.client` yok, yani uygulama ağa çıkamaz.
- Mikrofon yalnız Çalma Modu açıkken dinlenir. Ses diske yalnız kullanıcı **Kayıt**'a
  basıp **Kaydı Sakla** penceresinde bir yer seçerse yazılır.
- Açılan dosyalar ve analiz sonuçları uygulamanın sandbox konteynerinde tutulur
  (`~/Library/Containers/…/Application Support/KlariVision`).
- Analitik, reklam, çökme raporlama veya üçüncü taraf SDK yok.

---

## A. Gizlilik Politikası (Türkçe)

**KlariVision Gizlilik Politikası**
Yürürlük tarihi: [yayın tarihi]

KlariVision, çaldığınız veya dinlediğiniz sesin perde eğrisini gösteren bir müzik
çalışma uygulamasıdır. Bu politika uygulamanın hangi verilerle ne yaptığını anlatır.

**Veri toplamıyoruz.** KlariVision kişisel veri toplamaz, hesap istemez ve internete
bağlanmaz. Hiçbir bilgi bize ya da başka birine gönderilmez.

**Mikrofon.** Mikrofon yalnız Çalma Modu'nu başlattığınızda, canlı perde grafiğini
çizmek için kullanılır. Ses Mac'inizde, bellekte işlenir. Siz kayıt başlatıp kaydı
saklamayı seçmedikçe diske yazılmaz; sakladığınız kayıt yalnız sizin seçtiğiniz yere
yazılır. Mikrofon iznini istediğiniz zaman Sistem Ayarları → Gizlilik ve Güvenlik →
Mikrofon bölümünden kapatabilirsiniz.

**Açtığınız dosyalar.** Dinleme Modu'nda seçtiğiniz ses ve video dosyaları Mac'inizde
analiz edilir. Analiz sonuçları, çalışma adları ve ayarlarınız uygulamanın kendi
klasöründe, yalnız sizin Mac'inizde saklanır. Bir çalışmayı uygulama içinden
sildiğinizde ona ait dosyalar da silinir.

**Üçüncü taraflar.** Uygulamada analitik, reklam, izleme ya da veri toplayan üçüncü
taraf yazılım yoktur.

**Çocuklar.** Uygulama kimseden veri toplamadığı için çocuklardan da veri toplamaz.

**Değişiklikler.** Bu politika değişirse güncel hâli bu sayfada, yeni yürürlük
tarihiyle yayımlanır.

**İletişim.** [destek e-postası] · https://github.com/aykerme/KlariVision/issues

---

## B. Privacy Policy (English)

**KlariVision Privacy Policy**
Effective date: [release date]

KlariVision is a music practice app that shows the pitch curve of what you play or
listen to. This policy explains what the app does with data.

**We do not collect data.** KlariVision collects no personal data, requires no account
and does not connect to the internet. No information is sent to us or anyone else.

**Microphone.** The microphone is used only while Playing Mode is running, to draw the
live pitch graph. Audio is processed in memory on your Mac. It is written to disk only
if you start a recording and choose to save it, and only to the location you choose.
You can turn microphone access off at any time in System Settings → Privacy &
Security → Microphone.

**Files you open.** Audio and video files you choose in Listening Mode are analysed on
your Mac. Analysis results, study names and your settings are stored in the app's own
folder, only on your Mac. When you delete a study in the app, its files are deleted
too.

**Third parties.** The app contains no analytics, advertising, tracking or third-party
software that collects data.

**Children.** Because the app collects no data from anyone, it collects no data from
children.

**Changes.** If this policy changes, the updated version will be published on this page
with a new effective date.

**Contact.** [support email] · https://github.com/aykerme/KlariVision/issues

---

## C. App Store Connect → App Privacy

1. **Do you or your third-party partners collect data from this app?** → **No, we do not
   collect data from this app.**
   Apple'ın tanımında "toplama", verinin cihazdan çıkarılıp geliştiriciye veya üçüncü
   tarafa aktarılmasıdır. Yalnız cihazda işlenen ses ve dosyalar toplama sayılmaz. Sonuç
   etiketi: **Data Not Collected**.
2. **Privacy Policy URL:** A/B bölümlerinin yayımlandığı adres. Seçenek: depo herkese
   açık olduğu için bu dosyanın GitHub adresi
   (`https://github.com/aykerme/KlariVision/blob/main/docs/app-store/privacy.md`) —
   ancak dosya `main` dalına girdikten sonra çalışır. Daha temiz bir seçenek GitHub Pages
   ya da kişisel bir alan adında yalnız A/B'yi içeren sayfa.
3. **Age Rating** anketi: tüm sorular "None/No" (kullanıcı içeriği paylaşımı, web erişimi,
   sohbet yok) → 4+.

## Sürüm 2'de yeniden bakılacak

Pro kilidi (StoreKit) eklenince satın alma işlemleri Apple üzerinden yürür; uygulama kendi
sunucusuna bir şey göndermezse yanıt büyük olasılıkla değişmez, ama gönderim anında
Apple'ın güncel tanımıyla yeniden kontrol edilmeli (bkz. `PLAN.md`).
