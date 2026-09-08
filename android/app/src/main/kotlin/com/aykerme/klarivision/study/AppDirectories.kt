// KlariVision Android — uygulama sandbox'ı içindeki alt dizinlerin tek sözleşme noktası.
// iOS'taki iPadStudyImportService.importsDirectory ile aynı rolü oynar, ancak Android'de
// tüm kalıcı veri zaten Context.filesDir altında (harici depolama, paylaşım, ağ yok).

package com.aykerme.klarivision.study

import android.content.Context
import java.io.File

/**
 * filesDir altındaki alt dizinlerin adlarını ve oluşturulmasını tek yerde toplar.
 *
 * - `Imports/`: SAF ile seçilip sandbox'a kopyalanan ses/video dosyaları (bu dosyanın işi).
 * - `Recordings/`: Canlı kayıt çıktıları — dizin sözleşmesi burada kurulur, yazma işi P3a'ya ait.
 * - `Viewer/`: Study/Dinleme görüntüleyicisinin kullandığı yardımcı dosyalar.
 *
 * Hiçbiri harici depolamaya (MediaStore/paylaşılan depolama) dokunmaz; hepsi uygulamanın
 * özel, kaldırıldığında otomatik temizlenen alanında kalır.
 */
object AppDirectories {
    private const val IMPORTS_DIR_NAME = "Imports"
    private const val RECORDINGS_DIR_NAME = "Recordings"
    private const val VIEWER_DIR_NAME = "Viewer"

    /** İçe aktarılan (SAF ile seçilen) dosyaların kopyalandığı dizin. */
    fun imports(context: Context): File = directory(context, IMPORTS_DIR_NAME)

    /** Canlı kayıtların yazılacağı dizin (yazma mantığı P3a'nın işi; burada yalnız dizin kurulur). */
    fun recordings(context: Context): File = directory(context, RECORDINGS_DIR_NAME)

    /** Görüntüleyicinin (WebView tabanlı Study/Dinleme) kullandığı yardımcı dosyalar dizini. */
    fun viewer(context: Context): File = directory(context, VIEWER_DIR_NAME)

    private fun directory(context: Context, name: String): File =
        File(context.filesDir, name).apply { mkdirs() }
}
