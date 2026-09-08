// KlariVision Android — JS→Kotlin oynatma anlık görüntüsü, Swift'teki
// `onSnapshot`/`userContentController(didReceive:)` sözleşmesinin karşılığı.
// StudyViewer.html WebKit köprüsü yokken nesneyi `JSON.stringify` ile metne
// çevirir (bkz. assets/viewer/README.md); bu yüzden Android tarafı ham bir
// JSON dizesi alır ve burada çözer.

package com.aykerme.klarivision.web

import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/**
 * `window.kvStudyBridge.postMessage(...)` ile gelen oynatma durumu.
 * `loopA`/`loopB` A-B döngü işaretlenmediğinde `null` olur.
 */
@Serializable
data class PlaybackSnapshot(
    val time: Double,
    val duration: Double,
    val isPlaying: Boolean,
    val rate: Double,
    val loopA: Double? = null,
    val loopB: Double? = null,
    val loopEnabled: Boolean = false,
    val followsCurve: Boolean = true
) {
    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }

        /**
         * `postMessage` metnini çöz. Bozuk/eksik JSON durumunda istisna
         * fırlatmak yerine `null` döner — köprü bir kareyi kaybetmek, tüm
         * oynatma durumunu bozmaktan iyidir.
         */
        fun parse(raw: String): PlaybackSnapshot? = try {
            json.decodeFromString(serializer(), raw)
        } catch (error: SerializationException) {
            null
        } catch (error: IllegalArgumentException) {
            null
        }
    }
}
