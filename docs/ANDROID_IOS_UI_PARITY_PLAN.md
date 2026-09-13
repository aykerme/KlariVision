# Android ↔ iOS/iPadOS UI/UX Eşitleme Planı

Tarih: 2026-09-13 · Durum: Faz 0 öncesi, ilk PR başladı

Referans taraf iOS/iPadOS'tur ve referans olarak **çalışan kod** alınır, doküman değil:
`ipad/KlariVisioniPadCoreSmoke/KlariVisioniPad/*.swift`. Android tarafı:
`android/app/src/main/kotlin/com/aykerme/klarivision/ui/*.kt`.

Plan iki adımda hazırlandı. Önce Haiku iki platformun envanterini çıkardı, sonra Sonnet
farkları kaynakta doğrulayıp planı yazdı. Kritik iddialar ayrıca elle kontrol edildi;
düzeltmeler §0'da.

---

## 0. Doğrulanmış arka plan ve düzeltmeler

- **Grafik çizgi renkleri zaten aynı.** iOS `AppState.swift:367-370` ile Android
  `SettingsKeys.kt:31-40` birebir aynı hex varsayılanlarını kullanıyor. Tema renkleri,
  tipografi ölçeği ve 12/16/20 köşe yarıçapları da `docs/ipad-ui-ux/05-design-tokens.md`
  ile uyumlu.
- **Grafik şablonları şu an byte düzeyinde aynı.** `ipad/.../Resources/{Study,Live}Viewer.html`
  ile `android/app/src/main/assets/viewer/{Study,Live}Viewer.html` arasında `diff` fark
  bulmadı. Risk bugünkü bir fark değil, iki kopyanın elle senkron tutulması (§1.11).
- **Klavye kısayolları iPad hedefinde yok.** `keyboardShortcut` iPad kaynağında geçmiyor;
  bu kısayollar macOS uygulamasına ait. Bu yüzden eşitleme kapsamı dışında (§1.7).

---

## 1. Gerçek farklar

### 1.1 Navigasyon yapısı — Önem: Yüksek · Zorluk: L
- **iOS:** İki durum. `KlariVisioniPadApp.swift:31` yalnız `horizontalSizeClass`'a bakar:
  compact'ta alttan `TabView` (3 sekme, satır 104-118), regular'da `NavigationSplitView`
  (satır 60-93). Ara durumu sistem yönetir.
- **Android:** Üç elle yazılmış eşik (`DesignTokens.kt:52-68`): DAR <700 (alt
  `NavigationBar`), ORTA 700–999 (320dp `NavigationDrawerPanel`), GENIS ≥1000 (280dp
  kalıcı kenar çubuğu). Bu yapı `docs/ipad-ui-ux/03-responsive-contract.md` ile uyumlu,
  ama iOS kodu bu sözleşmeyi uygulamıyor.
- **Öneri:** Kullanıcı kararına bağlı (§4, soru 1).
- **Dosyalar:** `ui/KlariVisionApp.kt`, `ui/DesignTokens.kt`, `docs/ipad-ui-ux/03-responsive-contract.md`.

### 1.2 Ayarlar → makam aralık düzenleyicisi bağlantısı yok — Yüksek · S — **İlk PR'da çözüldü**
- **iOS:** `KlariVisioniPadApp.swift:480-488`. Her makam satırı bir `NavigationLink` ile
  `iPadMakamIntervalsView`'a gider.
- **Android:** `KlariVisionApp.kt`'deki `onOpenMakamIntervals` boş bir fonksiyondu.
  `SettingsScreens.kt`'deki satırlar da tıklanamıyordu. Hazır duran `MakamIntervalsScreen`
  hiçbir yerde kullanılmıyordu.
- **Çözüm:** Satırlar tıklanabilir yapıldı. Kabuk, `MakamIntervalsScreen`'i bir
  `ModalBottomSheet` içinde açıyor; çalışma alanlarındaki desenle aynı.

### 1.3 Çalma Modu: "kesildi" ile "hata" ayrımı yok — Orta · M
- **iOS:** `LivePhase` iki ayrı durum taşır: `.interrupted(message)` turuncu ve yeniden
  başlatılabilir, `.failed(message)` kırmızı. Bkz. `KlariVisioniPadApp.swift:162-163`,
  `iPadCompactLiveWorkspace.swift:71-72`.
- **Android:** `LiveOrchestrator.kt:41` → `LivePhase2 { STOPPED, STARTING, RUNNING, FAILED }`.
  İzin isteği ayrı bir durum değil, `permissionRequired` bayrağı.
- **Öneri:** `INTERRUPTED(message)` durumu eklenmeli; rota değişimi ve arama kaynaklı
  kesintiler ayrılmalı. `HomeScreen`/`LiveWorkspace` turuncu/kırmızı ayrımını göstermeli.
- **Dosyalar:** `state/LiveOrchestrator.kt`, `ui/HomeScreen.kt`, `ui/LiveWorkspace.kt`, `RouteChangePolicy.kt`.

### 1.4 Boş ve hata durumlarının görsel dili — Düşük-Orta · S
- **iOS:** Sistem bileşeni `ContentUnavailableView` kullanılıyor (6 kullanım).
- **Android:** `Column{Icon;Text;Text}` üç yerde elle kopyalanmış
  (`LibraryScreen.kt:80-93`, `StudyWorkspace.kt:132-165`).
- **Öneri:** Ortak `EmptyStateView` composable'ı: ikon + başlık + açıklama + isteğe bağlı eylem.

### 1.5 Dar ekranda mod kartı — Düşük · S
- **iOS:** Regular genişlikte `iPadModeCard` kullanılıyor: 72pt daire ikon, 28pt padding
  (`KlariVisioniPadApp.swift:224-255`). Compact genişlikte daha sade bir `compactCard`
  var: dairesiz ikon, 20pt padding, tint opaklığı 0.07 (`iPadCompactLiveWorkspace.swift:165-176`).
- **Android:** Tek `ModeCard` (`HomeScreen.kt:160-196`), 64dp ikon ve 24dp padding.
- **Öneri:** Kullanıcı kararına bağlı (§4, soru 2).

### 1.6 Ayarlar bileşen dili — Düşük · S
- **iOS:** `Form` + `Section`, tema seçimi `Picker` ile.
- **Android:** `LazyColumn` + `HorizontalDivider`, tema seçimi `RadioButton` listesiyle.
- **Öneri:** Bu fark büyük ölçüde platform geleneği. Bölümler kart içinde gruplanarak iOS
  görünümüne yaklaştırılabilir.

### 1.7 Klavye kısayolları — Kapsam dışı
iPad kodunda da yok (§0). İstenirse iki platform için yeni bir özellik olarak ayrıca planlanır.

### 1.8 TalkBack ile konum ayarı — Orta-Yüksek · M — **İlk PR'da çözüldü**
- **iOS:** `WorkspaceControls.swift:32-61`. `accessibilityElement(children: .ignore)` ve
  "Konum" etiketi kullanılıyor; `accessibilityAdjustableAction` ±5 sn arama yapıyor.
- **Android:** `PositionReadout` yalnız statik bir `contentDescription` taşıyordu.
- **Çözüm:** `clearAndSetSemantics` ile çocuk metinler gizlendi; iOS'taki `.ignore`
  karşılığı. "5 saniye ileri" ve "5 saniye geri" özel eylemleri eklendi, sınırlar iOS ile
  aynı. `StudyWorkspace` bu eylemleri `orchestrator.seek`'e bağlıyor.

### 1.9 "Hareketi azalt" ayarı — Orta · M
- **iOS:** `WorkspaceControls.swift:70,100-107`. `accessibilityReduceMotion` açıksa kayıt
  düğmesi yanıp sönmüyor.
- **Android:** `RecordButton`'daki `rememberInfiniteTransition` her durumda çalışıyor.
- **Öneri:** `Settings.Global.ANIMATOR_DURATION_SCALE == 0` değerini okuyan bir
  `CompositionLocal` eklenmeli; yanıp sönme buna bağlanmalı.

### 1.10 Mod kartı vurgu rengi — Düşük · S
- **iOS:** Sistem dinamik renkleri `.blue`/`.green` kullanılıyor (`KlariVisioniPadApp.swift:209,218`).
- **Android:** Sabit `KvColors.AccentListening`/`AccentPractice` kullanılıyor (`HomeScreen.kt:104,113`).
- **Öneri:** Platform farkı olarak bırakılabilir; istenirse `colorScheme` rollerine bağlanır.

### 1.11 Grafik şablonlarının iki kopyası — Orta · M
Şu an aynılar (§0), ama elle senkron tutuluyorlar. Kopyalardan biri değişirse fark sessizce
oluşur.
- **Öneri:** Tek kaynaktan kopyalayan bir derleme adımı ya da CI'da `diff` kontrolü
  (§4, soru 3).

---

## 2. Bilinçli bırakılacak farklar

| Fark | Gerekçe |
|---|---|
| Geri tuşu ve sistem gezinme hareketleri | Platform sözleşmesi. |
| `Form`/`NavigationLink` ↔ `LazyColumn`/`ModalBottomSheet` | Her platformun kendi bileşen karşılığı. |
| Mikrofon izni sistem diyaloğu | İşletim sistemi kontrolünde. |
| `ContentUnavailableView` yerine elle yazılmış bileşen | Material'de karşılığı yok; iç boşluk ve tipografi yine de iOS'a yaklaştırılır. |
| SF Symbols → Material Icons (`KvIcons.kt`) | Eşleme zaten belgelenmiş ve gerekçeli. |
| SF Pro yerine platform fontu, aynı punto ölçeği | `05-design-tokens.md` Decision #2. |

---

## 3. Aşamalar

**Faz 0: Tek doğruluk kaynağı.** Her ekran için buton sırası, ikon, metin ve token adını
listeleyen `docs/ui-parity-contract.md` oluşturulur. `03-responsive-contract.md`, §1.1
kararına göre güncellenir. Şablonlar için senkron mekanizması seçilir.
*Kabul:* Sözleşme dosyası yazılmış, §4'teki sorular yanıtlanmış.

**Faz 1: Token, tema ve tipografi.** Reduce Motion altyapısı (§1.9), gerekirse kart
ölçüleri (§1.5) ve vurgu rengi (§1.10).
*Kabul:* Üç temada WCAG AA kontrastı sağlanıyor; ölçüler sözleşmeyle uyuşuyor.
*Doğrulama:* Compose UI testi ve adb ile gerçek cihazda ekran görüntüsü; iOS için fiziksel
iPhone/iPad.

**Faz 2: Navigasyon ve ekran akışı.** §1.1 kararının uygulanması; §1.2 ilk PR'da yapıldı.
*Kabul:* Genişlik sınıfı geçişlerinde oturum durumu sıfırlanmıyor; `movableContentOf`
sözleşmesi korunuyor.
*Doğrulama:* `KvWidthClassTest` genişletilir; cihazda `adb shell wm size` ve döndürme
testi yapılır; iPad'de Split View denenir.

**Faz 3: Dinleme çalışma alanı.** Ortak boş/hata bileşeni (§1.4); §1.8 ilk PR'da yapıldı.
*Kabul:* TalkBack ile konum ±5 sn ayarlanıyor; kontrol sırası sözleşmeyle uyuşuyor.
*Doğrulama:* Gerçek cihazda TalkBack turu ve 10 dakikadan uzun kayıtla B-2 regresyon
kontrolü.

**Faz 4: Çalma çalışma alanı.** `INTERRUPTED` durumu (§1.3) ve kayıt düğmesinin Reduce
Motion'a bağlanması.
*Kabul:* Kulaklık takılıp çıkarıldığında ya da arama geldiğinde turuncu "kesildi" mesajı
görünüyor.
*Doğrulama:* Fiziksel cihazda gerçek kulaklık ve arama testi (kabul turundaki #12/#13);
`RouteChangePolicyTest` genişletilir.

**Faz 5: Ayarlar ve sheet'ler.** Bölüm gruplaması (§1.6) ve tema seçicinin gözden geçirilmesi.
*Kabul:* Bölüm sırası ve başlıklar sözleşmeyle aynı.

**Faz 6: Erişilebilirlik cilası.** `docs/ACCESSIBILITY_ACCEPTANCE_CHECKLIST.md`
maddelerinin Android için tek tek işaretlenmesi; kalan VoiceOver/TalkBack ipuçlarının
eşitlenmesi.

---

## 4. Riskler ve açık sorular

**Riskler**
- **WebView kimliği:** Navigasyon değişiklikleri `movableContentOf` sözleşmesini bozmamalı.
  Her değişiklikten sonra 5 dakikadan uzun bir Dinleme oturumunda genişlik geçişi test
  edilmeli.
- **B-2 / B-2b:** Şablon değişikliklerinden sonra büyük çalışmalarla yeniden test gerekir.
- **Açık kabul turu kalemleri:** `ANDROID_KABUL_TURU.md` #9 başarısız, #12/#13 koşulmadı.
  Bunlar bu planın kapsamında değil.
- **iOS'ta simülatör yok:** iOS doğrulaması fiziksel cihazda ve elle yapılmak zorunda.
- **`MakamIntervalsStore` bellekte tutuluyor:** Değişiklikler kalıcı değil ve mağaza
  gözlemlenebilir değil. "Teori/Özel" etiketi ancak ekran yeniden çizildiğinde güncellenir.
  Bu mevcut bir sorun ve ayrıca ele alınmalı.

**Açık sorular**
1. **Navigasyon:** iOS'un iki durumlu yapısı mı esas alınacak (Android'deki ORTA düzeni
   kaldırılır), yoksa üç durumlu sözleşme mi (iPad'e de ara düzen eklenir)?
2. **Dar ekran kartı:** iOS'taki sade kart Android'e ayrı bir varyant olarak eklensin mi?
3. **Grafik şablonları:** Tek kaynaktan kopyalama mı, yoksa CI'da `diff` kontrolü mü?

---

## 5. İlk PR

- §1.2: Ayarlar'daki makam satırları aralık düzenleyicisini açıyor.
- §1.8: TalkBack'te konum için "5 saniye ileri/geri" eylemleri.
- Bu plan dokümanı.
