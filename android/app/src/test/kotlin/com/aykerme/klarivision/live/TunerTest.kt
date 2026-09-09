package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Test

class TunerTest {

    @Test
    fun `null frequency yields dash`() {
        assertEquals("—", Tuner.label(null))
    }

    @Test
    fun `zero or negative frequency yields dash`() {
        assertEquals("—", Tuner.label(0.0))
        assertEquals("—", Tuner.label(-10.0))
    }

    @Test
    fun `440 Hz is La4`() {
        assertEquals("La4", Tuner.label(440.0))
    }

    @Test
    fun `261-63 Hz is roughly Do4`() {
        assertEquals("Do4", Tuner.label(261.63))
    }
}
