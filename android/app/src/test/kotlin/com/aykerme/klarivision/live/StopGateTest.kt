package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StopGateTest {

    @Test
    fun `first begin succeeds and reports stopping`() {
        val gate = StopGate()
        assertFalse(gate.isStopping())
        assertTrue(gate.begin("kesinti"))
        assertTrue(gate.isStopping())
        assertEquals("kesinti", gate.lastReason())
    }

    @Test
    fun `concurrent begin calls are idempotent — only the first one proceeds`() {
        val gate = StopGate()
        assertTrue(gate.begin("odak kaybı"))
        // Aynı anda başka bir kaynaktan (rota değişimi, yaşam döngüsü, ...) gelen
        // ikinci bir durdurma isteği YÜRÜTÜLMEMELİDİR.
        assertFalse(gate.begin("rota değişti"))
        assertFalse(gate.begin("AudioRecord hatası"))
        // Yürütülen (kabul edilen) neden hâlâ ilkidir.
        assertEquals("odak kaybı", gate.lastReason())
    }

    @Test
    fun `complete reopens the gate for a new stop cycle`() {
        val gate = StopGate()
        gate.begin("ilk")
        gate.complete()
        assertFalse(gate.isStopping())
        assertTrue(gate.begin("ikinci"))
        assertEquals("ikinci", gate.lastReason())
    }

    @Test
    fun `begin accepts a null reason for a user-initiated stop`() {
        val gate = StopGate()
        assertTrue(gate.begin(null))
        assertNull(gate.lastReason())
    }

    @Test
    fun `repeated begin after complete without a new cycle behaves independently`() {
        val gate = StopGate()
        gate.begin("a")
        gate.complete()
        gate.begin("b")
        gate.complete()
        assertFalse(gate.isStopping())
        assertEquals("b", gate.lastReason())
    }
}
