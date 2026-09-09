// KlariVision Android — Dinleme modu grafiği için Kotlin→JS komutları, Swift
// iPadStudyCommand'dan port edildi. Serileştirme WebView'den bağımsızdır: bu
// dosya yalnız komut → JSON dönüşümünü ve hazır-olana-kadar kuyruklamayı
// tanımlar, `StudyGraphBridge` bunu gerçek WKWebView eşdeğerine (WebView)
// bağlar.

package com.aykerme.klarivision.web

import com.aykerme.klarivision.study.PitchFrame
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/**
 * Bir makam kılavuz çizgisi — StudyViewer.html/LiveViewer.html'in beklediği
 * `{name, hz, karar}` şekliyle birebir eşleşir (iPadMusicContext.GuideNote).
 */
@Serializable
data class GuidePayload(val name: String, val hz: Double, val karar: Boolean)

/**
 * Birlikte Çal modunda mikrofon aynasına eklenen tek nokta —
 * StudyViewer.html'in `micAppend(points)` beklediği `{t, hz}` şekliyle
 * birebir eşleşir (bkz. `micAppend` JS gövdesi).
 */
data class MicPoint(val time: Double, val frequency: Double)

/**
 * `window.kvStudy.receive(payload)` çağrısına konacak komutlardan biri.
 * Her alt tip `iPadStudyCommand`'daki karşılığıyla aynı `type` ayırıcısını ve
 * alan adlarını üretir.
 */
sealed class StudyCommand {
    data class Load(val url: String, val frames: List<PitchFrame>) : StudyCommand()

    data class Context(
        val makam: String,
        val karar: String,
        val guides: List<GuidePayload>,
        val pitchColor: String,
        val guideColor: String,
        val kararColor: String
    ) : StudyCommand()

    data object PlayPause : StudyCommand()
    data object Pause : StudyCommand()
    data class Seek(val time: Double) : StudyCommand()

    /** rate 0.10–2.00 aralığında, 0.05 adımlarla — macOS/iPad hız tablosuyla aynı sözleşme. */
    data class Rate(val rate: Double) : StudyCommand()

    data object MarkA : StudyCommand()
    data object MarkB : StudyCommand()
    data object Loop : StudyCommand()
    data object Follow : StudyCommand()

    /** Sahneyi dolduran taraf: true → video, false → grafik. */
    data class SetMode(val isVideo: Boolean) : StudyCommand()

    // ==================== Birlikte Çal (T3) ====================

    /** Mikrofon aynasına yeni noktalar ekle — kareler zaten medya zamanına çevrilmiş gelir. */
    data class MicAppend(val points: List<MicPoint>) : StudyCommand()

    /** Mikrofon aynasını tamamen boşalt (mod açılırken/oturum sıfırlanırken). */
    data object MicClear : StudyCommand()

    /** Mikrofon aynasını `time`'dan sonrasını at — geriye arama/loop B→A dönüşü. */
    data class MicTruncate(val time: Double) : StudyCommand()

    /** Mikrofon aynasının rengini ayarlardan gelen hex koduna ayarla. */
    data class SetMicColor(val hex: String) : StudyCommand()

    /** Medya elemanının sesini kapat/aç — akustik geri besleme (hoparlör→mikrofon) önlemi. */
    data class Mute(val muted: Boolean) : StudyCommand()

    /** `window.kvStudy.receive(...)` çağrısına konacak JSON gövdesi. */
    fun toJsonObject(): JsonObject = when (this) {
        is Load -> buildJsonObject {
            put("type", "load")
            put("url", url)
            putJsonArray("frames") {
                frames.forEach { frame ->
                    addJsonObject {
                        put("t", frame.time)
                        put("f", frame.frequency)
                        put("c", frame.confidence)
                        put("v", frame.voiced)
                    }
                }
            }
        }

        is Context -> buildJsonObject {
            put("type", "context")
            put("makam", makam)
            put("karar", karar)
            putJsonArray("guides") {
                guides.forEach { guide ->
                    addJsonObject {
                        put("name", guide.name)
                        put("hz", guide.hz)
                        put("karar", guide.karar)
                    }
                }
            }
            put("pitchColor", pitchColor)
            put("guideColor", guideColor)
            put("kararColor", kararColor)
        }

        PlayPause -> buildJsonObject { put("type", "playPause") }
        Pause -> buildJsonObject { put("type", "pause") }
        is Seek -> buildJsonObject {
            put("type", "seek")
            put("time", time)
        }

        is Rate -> buildJsonObject {
            put("type", "rate")
            put("rate", rate)
        }

        MarkA -> buildJsonObject { put("type", "markA") }
        MarkB -> buildJsonObject { put("type", "markB") }
        Loop -> buildJsonObject { put("type", "loop") }
        Follow -> buildJsonObject { put("type", "follow") }
        is SetMode -> buildJsonObject {
            put("type", "setMode")
            put("mode", if (isVideo) "video" else "graph")
        }

        is MicAppend -> buildJsonObject {
            put("type", "micAppend")
            putJsonArray("points") {
                points.forEach { point ->
                    addJsonObject {
                        put("t", point.time)
                        put("hz", point.frequency)
                    }
                }
            }
        }

        MicClear -> buildJsonObject { put("type", "micClear") }
        is MicTruncate -> buildJsonObject {
            put("type", "micTruncate")
            put("time", time)
        }

        is SetMicColor -> buildJsonObject {
            put("type", "setMicColor")
            put("hex", hex)
        }

        is Mute -> buildJsonObject {
            put("type", "mute")
            put("muted", muted)
        }
    }

    fun toJsonString(): String = toJsonObject().toString()
}

/**
 * Sayfa `onPageFinished` olana kadar komutları tamponlayan kuyruk —
 * `iPadStudyCommandQueue` ile birebir aynı sözleşme: hazır olmadan gelenler
 * sırayla saklanır, `drainWhenReady()` hepsini sırayla döner ve temizler; art
 * arda iki çağrıdan ikincisi boş liste döner.
 */
class StudyCommandQueue {
    private val pending = mutableListOf<StudyCommand>()

    fun enqueue(command: StudyCommand) {
        pending.add(command)
    }

    fun drainWhenReady(): List<StudyCommand> {
        if (pending.isEmpty()) return emptyList()
        val drained = pending.toList()
        pending.clear()
        return drained
    }

    fun isEmpty(): Boolean = pending.isEmpty()
}
