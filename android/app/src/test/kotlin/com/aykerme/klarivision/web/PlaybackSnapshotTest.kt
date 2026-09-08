// KlariVision Android — PlaybackSnapshot JSON çözümleme testleri.
// window.kvStudyBridge.postMessage(JSON.stringify(...)) ile gelen metnin
// loopA/loopB null durumları dahil doğru çözüldüğünü doğrular.

package com.aykerme.klarivision.web

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class PlaybackSnapshotTest {
    @Test
    fun parsesFullSnapshotWithLoopBounds() {
        val raw = """
            {"time":12.5,"duration":90.0,"isPlaying":true,"rate":1.25,
             "loopA":5.0,"loopB":20.0,"loopEnabled":true,"followsCurve":false}
        """.trimIndent()

        val snapshot = PlaybackSnapshot.parse(raw)

        assertNotNull(snapshot)
        assertEquals(12.5, snapshot!!.time, 0.0)
        assertEquals(90.0, snapshot.duration, 0.0)
        assertEquals(true, snapshot.isPlaying)
        assertEquals(1.25, snapshot.rate, 0.0)
        assertEquals(5.0, snapshot.loopA)
        assertEquals(20.0, snapshot.loopB)
        assertEquals(true, snapshot.loopEnabled)
        assertEquals(false, snapshot.followsCurve)
    }

    @Test
    fun parsesNullLoopBoundsWhenNoLoopMarked() {
        val raw = """
            {"time":0.0,"duration":30.0,"isPlaying":false,"rate":1.0,
             "loopA":null,"loopB":null,"loopEnabled":false,"followsCurve":true}
        """.trimIndent()

        val snapshot = PlaybackSnapshot.parse(raw)

        assertNotNull(snapshot)
        assertNull(snapshot!!.loopA)
        assertNull(snapshot.loopB)
        assertEquals(false, snapshot.loopEnabled)
    }

    @Test
    fun missingOptionalFieldsFallBackToDefaults() {
        val raw = """{"time":1.0,"duration":2.0,"isPlaying":false,"rate":1.0}"""

        val snapshot = PlaybackSnapshot.parse(raw)

        assertNotNull(snapshot)
        assertNull(snapshot!!.loopA)
        assertNull(snapshot.loopB)
        assertEquals(false, snapshot.loopEnabled)
        assertEquals(true, snapshot.followsCurve)
    }

    @Test
    fun malformedJsonReturnsNullInsteadOfThrowing() {
        assertNull(PlaybackSnapshot.parse("not json"))
        assertNull(PlaybackSnapshot.parse("{\"time\":\"oops\"}"))
        assertNull(PlaybackSnapshot.parse(""))
    }
}
