// KlariVision Android — window.kvLive.append([{t,f,c,v}]) çerçeve listesi
// serileştirme testleri. unvoiced karede f=0'a düşürüldüğünü ve v'nin yalnız
// sesli+pozitif-frekanslı karelerde true olduğunu doğrular.

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

class LiveFramePayloadTest {
    @Test
    fun voicedFrameKeepsItsFrequencyAndKeys() {
        val json = Json.parseToJsonElement(
            LiveFramePayload.toJsonString(listOf(PitchFrame(time = 1.5, frequency = 220.0, confidence = 0.8, voiced = true)))
        ).jsonArray
        val frame = json[0].jsonObject

        assertEquals(setOf("t", "f", "c", "v"), frame.keys)
        assertEquals(1.5, frame["t"]?.jsonPrimitive?.double)
        assertEquals(220.0, frame["f"]?.jsonPrimitive?.double)
        assertEquals(0.8, frame["c"]?.jsonPrimitive?.double)
        assertTrue(frame["v"]?.jsonPrimitive?.boolean == true)
    }

    @Test
    fun unvoicedFrameKeepsFrequencyButClearsVoicedFlag() {
        val json = Json.parseToJsonElement(
            LiveFramePayload.toJsonString(listOf(PitchFrame(time = 2.0, frequency = 330.0, confidence = 0.3, voiced = false)))
        ).jsonArray
        val frame = json[0].jsonObject

        // Swift LiveWebView.swift ile birebir: `f` yalnız frekans sonlu
        // değilse ya da <= 0 ise sıfırlanır. Pozitif bir frekans, kare
        // unvoiced olsa da olduğu gibi taşınır; unvoiced bilgisi `v`
        // alanında verilir.
        assertEquals(330.0, frame["f"]?.jsonPrimitive?.double)
        assertFalse(frame["v"]?.jsonPrimitive?.boolean == true)
    }

    @Test
    fun voicedFrameWithNonPositiveFrequencyIsTreatedAsUnvoiced() {
        val json = Json.parseToJsonElement(
            LiveFramePayload.toJsonString(listOf(PitchFrame(time = 3.0, frequency = 0.0, confidence = 0.5, voiced = true)))
        ).jsonArray
        val frame = json[0].jsonObject

        assertEquals(0.0, frame["f"]?.jsonPrimitive?.double)
        assertFalse(frame["v"]?.jsonPrimitive?.boolean == true)
    }

    @Test
    fun nonFiniteTimeFrameIsDropped() {
        val json = Json.parseToJsonElement(
            LiveFramePayload.toJsonString(
                listOf(
                    PitchFrame(time = Double.NaN, frequency = 440.0, confidence = 1.0, voiced = true),
                    PitchFrame(time = 4.0, frequency = 440.0, confidence = 1.0, voiced = true)
                )
            )
        ).jsonArray

        assertEquals(1, json.size)
        assertEquals(4.0, json[0].jsonObject["t"]?.jsonPrimitive?.double)
    }

    @Test
    fun nonFiniteConfidenceFallsBackToZero() {
        val json = Json.parseToJsonElement(
            LiveFramePayload.toJsonString(listOf(PitchFrame(time = 5.0, frequency = 100.0, confidence = Double.NaN, voiced = true)))
        ).jsonArray

        assertEquals(0.0, json[0].jsonObject["c"]?.jsonPrimitive?.double)
    }

    @Test
    fun emptyFrameListSerializesToEmptyArray() {
        assertEquals("[]", LiveFramePayload.toJsonString(emptyList()))
    }
}
