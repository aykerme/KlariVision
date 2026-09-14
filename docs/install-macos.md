# KlariVision macOS kurulumu · Installing on macOS

## Türkçe

**Gereken:** macOS 14 Sonoma veya üstü; Apple Silicon ya da Intel Mac.

1. `KlariVision-…-macos-universal.dmg` dosyasını açın.
2. **KlariVision**'ı **Applications** klasörüne sürükleyin.
3. Applications'tan KlariVision'ı açın.

### "Apple doğrulayamadı" uyarısı

KlariVision ücretsiz, açık kaynaklı bir uygulamadır ve Apple'ın ücretli geliştirici
programıyla imzalanmadığı için macOS ilk açılışta uyarı gösterir. Uygulamayı yalnız
resmi GitHub sayfasından indirdiyseniz güvenle açabilirsiniz:

**macOS 15 Sequoia ve sonrası**
1. KlariVision'ı bir kez açmayı deneyin; uyarıda **Bitti**'ye basın.
2. **Sistem Ayarları → Gizlilik ve Güvenlik** bölümünü açın.
3. Aşağıda "KlariVision engellendi" satırının yanındaki **Yine de Aç**'a basın ve
   parolanızla onaylayın.

**macOS 14 Sonoma**
1. Applications'ta KlariVision'a **Control tuşuyla tıklayın** (ya da sağ tıklayın) → **Aç**.
2. Açılan pencerede yine **Aç**'a basın.

Bu adım yalnız ilk açılışta gerekir. Yeni bir sürüm kurduğunuzda bir kez daha
isteyebilir.

### İndirmeyi doğrulama (isteğe bağlı)

Sürüm sayfasındaki `.sha256` değeriyle karşılaştırın:

```bash
shasum -a 256 ~/Downloads/KlariVision-*-macos-universal.dmg
```

### Mikrofon izni

Çalma Modu ya da Birlikte Çal ilk açıldığında macOS mikrofon izni ister. Yeni sürüm kurduktan sonra
izni yeniden sorabilir. İzni **Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon**
bölümünden yönetebilirsiniz.

### Verileriniz

Analizler ve çalışmalar yalnız Mac'inizde, `~/Library/Application Support/KlariVision`
klasöründe tutulur. Uygulama internete bağlanmaz ve veri toplamaz.

---

## English

**Requires:** macOS 14 Sonoma or later; Apple silicon or Intel Mac.

1. Open `KlariVision-…-macos-universal.dmg`.
2. Drag **KlariVision** to the **Applications** folder.
3. Open KlariVision from Applications.

### "Apple could not verify" warning

KlariVision is a free, open-source app. It is not signed through Apple's paid
developer program, so macOS shows a warning the first time you open it. If you
downloaded it from the official GitHub page, you can open it safely:

**macOS 15 Sequoia and later**
1. Try to open KlariVision once; click **Done** in the warning.
2. Open **System Settings → Privacy & Security**.
3. Next to "KlariVision was blocked", click **Open Anyway** and confirm with your
   password.

**macOS 14 Sonoma**
1. In Applications, **Control-click** (or right-click) KlariVision → **Open**.
2. Click **Open** again in the dialog.

You only need to do this the first time. A new version may ask once more.

### Verifying the download (optional)

Compare with the `.sha256` value on the release page:

```bash
shasum -a 256 ~/Downloads/KlariVision-*-macos-universal.dmg
```

### Microphone access

Playing Mode or Play Together asks for microphone access the first time. It may ask again after you
install a new version. Manage it in **System Settings → Privacy & Security →
Microphone**.

### Your data

Analyses and studies stay on your Mac, in `~/Library/Application Support/KlariVision`.
The app does not connect to the internet and collects no data.
