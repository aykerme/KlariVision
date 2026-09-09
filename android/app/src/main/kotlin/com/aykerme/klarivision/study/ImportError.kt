// KlariVision Android — SAF içe aktarma hataları. iOS iPadStudyImportError'ın Android
// karşılığı: hiçbiri kütüphaneyi (Studies-v1.json) kirletmez, çünkü çağıran yalnız
// importFile() başarıyla döndükten sonra bir Study kaydı oluşturur.

package com.aykerme.klarivision.study

/**
 * SAF ile dosya alma sırasında oluşabilecek hatalar.
 *
 * Hepsi yeniden denenebilir kabul edilir: kopyalama geçici ada yazılıp yalnız
 * başarıda yeniden adlandırıldığından, bu hatalardan hiçbiri yarım bir dosya ya
 * da bozuk bir kütüphane kaydı bırakmaz — kaynak (henüz kütüphaneye eklenmemiş
 * olan) sağlam kalır ve kullanıcı işlemi baştan deneyebilir.
 */
sealed class ImportError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** Seçilen dosya ne ses ne de görüntü olarak tanınabildi. */
    class UnsupportedType : ImportError(
        "Bu dosya türü desteklenmiyor. Ses veya video dosyası seçin."
    )

    /** ContentResolver seçilen Uri için bir giriş akışı açamadı. */
    class UnableToOpen(cause: Throwable? = null) : ImportError(
        "Seçilen dosyaya erişilemedi. Lütfen tekrar deneyin.", cause
    )

    /** Akış okunurken veya hedefe yazılırken hata oluştu; yarım dosya bırakılmadı. */
    class UnableToCopy(cause: Throwable? = null) : ImportError(
        "Dosya uygulamanın yerel çalışma alanına kopyalanamadı. Lütfen tekrar deneyin.", cause
    )

    /** İşlem kullanıcı veya sistem tarafından iptal edildi. */
    class Cancelled : ImportError("İçe aktarma iptal edildi.")
}
