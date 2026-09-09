// KlariVision Android — Storage Access Framework ile dosya alma ve sandbox'a kopyalama.
// iOS iPadStudyImportService'in birebir Android karşılığı: security-scoped erişim yerine
// ACTION_OPEN_DOCUMENT'in verdiği geçici izin, NSFileCoordinator yerine akış tabanlı
// kopyalama kullanılır; atomiklik sözleşmesi (geçici ada yaz, başarıda yeniden adlandır)
// aynen korunur. Bu dosya yalnız servis katmanıdır — Compose UI (P5a) burada yazılmaz.

package com.aykerme.klarivision.study

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.UUID

/** Başarılı bir içe aktarmanın sonucu: sandbox'taki kalıcı dosya ve türü. */
data class ImportedFile(val file: File, val mediaKind: MediaKind)

/**
 * SAF ile seçilen ses/video dosyasını okuyup filesDir/Imports altına kopyalayan servis.
 *
 * Kalıcı çalışma her zaman kopyayı kullanır: seçilen `Uri` hiçbir yerde saklanmaz ve
 * kalıcı izin (`takePersistableUriPermission`) alınmaz — kopya zaten uygulamanın kendi
 * dosyasıdır, kaynağa bir daha erişim gerekmez.
 */
object StudyImportService {
    /** Compose tarafının `rememberLauncherForActivityResult` ile açacağı MIME kümesi. */
    val openDocumentMimeTypes: Array<String> = arrayOf("audio/*", "video/*")

    /** Compose UI'nin kullanacağı hazır kontrat (ActivityResultContracts.OpenDocument). */
    fun openDocumentContract(): ActivityResultContracts.OpenDocument = ActivityResultContracts.OpenDocument()

    /**
     * Seçilen [uri]'yi okuyup `filesDir/Imports/<UUID>.<uzantı>` altına kopyalar.
     * Ana thread'den çağrılabilir; asıl kopyalama `Dispatchers.IO`'da, iptal edilebilir
     * şekilde çalışır (coroutine iptal edilirse [CancellationException] fırlar ve
     * yarım dosya bırakılmadan geçici dosya silinir).
     *
     * Başarısızlıkta: hedef dosya hiçbir zaman yarım içerikle var olmaz, [ImportError]
     * (Türkçe, yeniden denenebilir) fırlatılır ve çağıran mevcut kütüphane kaydına
     * dokunmamalıdır — yeni `Study` kaydı yalnız bu fonksiyon başarıyla döndükten
     * sonra oluşturulmalıdır.
     */
    suspend fun importFile(context: Context, uri: Uri): ImportedFile = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val mimeType = resolver.getType(uri)
        val displayExtension = queryDisplayName(resolver, uri)
            ?.substringAfterLast('.', "")
            ?.lowercase()
            ?.takeIf { it.isNotEmpty() }

        val mediaKind = displayExtension?.let { MediaKind.fromExtension(it) }
            ?: MediaKind.fromMimeType(mimeType)
            ?: throw ImportError.UnsupportedType()

        val extension = displayExtension
            ?.takeIf { MediaKind.fromExtension(it) == mediaKind }
            ?: mimeTypeExtension(mimeType)
            ?: mediaKind.defaultExtension

        val destination = File(AppDirectories.imports(context), "${UUID.randomUUID()}.$extension")

        val input: InputStream = try {
            resolver.openInputStream(uri) ?: throw ImportError.UnableToOpen()
        } catch (e: ImportError) {
            throw e
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw ImportError.UnableToOpen(e)
        }

        input.use { stream -> copyStreamAtomically(stream, destination) }

        ImportedFile(file = destination, mediaKind = mediaKind)
    }

    /**
     * Saf kopyalama fonksiyonu: Context/ContentResolver'dan bağımsız, doğrudan test edilebilir.
     *
     * Atomiklik sözleşmesi (iOS'tan aynen): [destination]'a asla doğrudan yazılmaz — aynı
     * dizinde geçici bir ada yazılır ve kopyalama tamamen, hatasız bitince [destination]'a
     * yeniden adlandırılır. Okuma/yazma sırasında herhangi bir hata (veya iptal) oluşursa
     * geçici dosya silinir; [destination] hiçbir zaman yarım içerikle ortada kalmaz.
     */
    suspend fun copyStreamAtomically(input: InputStream, destination: File) {
        val parent = destination.parentFile ?: throw ImportError.UnableToCopy()
        parent.mkdirs()
        val temp = File(parent, "${destination.name}.tmp-${UUID.randomUUID()}")
        try {
            FileOutputStream(temp).use { out ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = input.read(buffer)
                    if (read < 0) break
                    out.write(buffer, 0, read)
                }
                out.flush()
            }
            if (!temp.renameTo(destination)) {
                throw ImportError.UnableToCopy()
            }
        } catch (e: CancellationException) {
            temp.delete()
            throw e
        } catch (e: ImportError) {
            temp.delete()
            throw e
        } catch (e: Exception) {
            temp.delete()
            throw ImportError.UnableToCopy(e)
        }
    }

    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
        }
    } catch (e: Exception) {
        null
    }

    private fun mimeTypeExtension(mimeType: String?): String? = when (mimeType) {
        "audio/mpeg" -> "mp3"
        "audio/mp4", "audio/x-m4a" -> "m4a"
        "audio/wav", "audio/x-wav", "audio/wave" -> "wav"
        "audio/aac" -> "aac"
        "audio/flac", "audio/x-flac" -> "flac"
        "audio/ogg" -> "ogg"
        "audio/opus" -> "opus"
        "audio/3gpp" -> "3gp"
        "audio/x-ms-wma" -> "wma"
        "video/mp4" -> "mp4"
        "video/quicktime" -> "mov"
        "video/3gpp" -> "3gp"
        "video/x-m4v" -> "m4v"
        else -> null
    }
}
