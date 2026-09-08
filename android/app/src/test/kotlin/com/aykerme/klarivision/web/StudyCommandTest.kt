// KlariVision Android — StudyCommand JSON serileştirme testleri.
// window.kvStudy.receive(payload) sözleşmesinin her komut tipi için beklenen
// alan adlarını ürettiğini doğrular.

package com.aykerme.klarivision.web

import com.aykerme.klarivision.study.PitchFrame
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StudyCommandTest {
    private fun parse(command: StudyCommand) = Json.parseToJsonElement(command.toJsonString()).jsonObject

    @Test
    fun loadCommandCarriesUrlAndFrames() {
        val frames = listOf(
            PitchFrame(time = 0.0, frequency = 440.0, confidence = 0.9, voiced = true),
            PitchFrame(time = 0.1, frequency = 0.0, confidence = 0.0, voiced = false)
        )
        val json = parse(StudyCommand.Load(url = "https://appassets.androidplatform.net/imports/a.mp3", frames = frames))

        assertEquals("load", json["type"]?.jsonPrimitive?.content)
        assertEquals("https://appassets.androidplatform.net/imports/a.mp3", json["url"]?.jsonPrimitive?.content)

        val frameArray = json["frames"]?.jsonArray!!
        assertEquals(2, frameArray.size)
        val first = frameArray[0].jsonObject
        assertEquals(0.0, first["t"]?.jsonPrimitive?.double)
        assertEquals(440.0, first["f"]?.jsonPrimitive?.double)
        assertEquals(0.9, first["c"]?.jsonPrimitive?.double)
        assertTrue(first["v"]?.jsonPrimitive?.boolean == true)

        val second = frameArray[1].jsonObject
        assertEquals(0.0, second["f"]?.jsonPrimitive?.double)
        assertFalse(second["v"]?.jsonPrimitive?.boolean == true)
    }

    @Test
    fun contextCommandCarriesMakamKararGuidesAndColors() {
        val guides = listOf(
            GuidePayload(name = "Re4", hz = 293.66, karar = true),
            GuidePayload(name = "Mi4", hz = 329.63, karar = false)
        )
        val json = parse(
            StudyCommand.Context(
                makam = "Nihavend",
                karar = "Re",
                guides = guides,
                pitchColor = "#67d5ff",
                guideColor = "#b7d8ff",
                kararColor = "#E75A5A"
            )
        )

        assertEquals("context", json["type"]?.jsonPrimitive?.content)
        assertEquals("Nihavend", json["makam"]?.jsonPrimitive?.content)
        assertEquals("Re", json["karar"]?.jsonPrimitive?.content)
        assertEquals("#67d5ff", json["pitchColor"]?.jsonPrimitive?.content)
        assertEquals("#b7d8ff", json["guideColor"]?.jsonPrimitive?.content)
        assertEquals("#E75A5A", json["kararColor"]?.jsonPrimitive?.content)

        val guideArray = json["guides"]?.jsonArray!!
        assertEquals(2, guideArray.size)
        assertEquals("Re4", guideArray[0].jsonObject["name"]?.jsonPrimitive?.content)
        assertEquals(293.66, guideArray[0].jsonObject["hz"]?.jsonPrimitive?.double)
        assertTrue(guideArray[0].jsonObject["karar"]?.jsonPrimitive?.boolean == true)
        assertFalse(guideArray[1].jsonObject["karar"]?.jsonPrimitive?.boolean == true)
    }

    @Test
    fun playPauseAndPauseCarryOnlyType() {
        assertEquals("playPause", parse(StudyCommand.PlayPause)["type"]?.jsonPrimitive?.content)
        assertEquals("pause", parse(StudyCommand.Pause)["type"]?.jsonPrimitive?.content)
    }

    @Test
    fun seekCarriesTime() {
        val json = parse(StudyCommand.Seek(12.5))
        assertEquals("seek", json["type"]?.jsonPrimitive?.content)
        assertEquals(12.5, json["time"]?.jsonPrimitive?.double)
    }

    @Test
    fun rateCarriesRate() {
        val json = parse(StudyCommand.Rate(1.25))
        assertEquals("rate", json["type"]?.jsonPrimitive?.content)
        assertEquals(1.25, json["rate"]?.jsonPrimitive?.double)
    }

    @Test
    fun markAndLoopAndFollowCarryOnlyType() {
        assertEquals("markA", parse(StudyCommand.MarkA)["type"]?.jsonPrimitive?.content)
        assertEquals("markB", parse(StudyCommand.MarkB)["type"]?.jsonPrimitive?.content)
        assertEquals("loop", parse(StudyCommand.Loop)["type"]?.jsonPrimitive?.content)
        assertEquals("follow", parse(StudyCommand.Follow)["type"]?.jsonPrimitive?.content)
    }

    @Test
    fun setModeCarriesVideoOrGraphMode() {
        assertEquals("video", parse(StudyCommand.SetMode(isVideo = true))["mode"]?.jsonPrimitive?.content)
        assertEquals("graph", parse(StudyCommand.SetMode(isVideo = false))["mode"]?.jsonPrimitive?.content)
        assertEquals("setMode", parse(StudyCommand.SetMode(isVideo = true))["type"]?.jsonPrimitive?.content)
    }
}
