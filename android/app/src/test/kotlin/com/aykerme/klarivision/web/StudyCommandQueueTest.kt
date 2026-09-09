// KlariVision Android — StudyCommandQueue kuyruklama testleri.
// Sayfa onPageFinished olana kadar komutların sırayla saklandığını, hazır
// olunca sırayla boşaldığını ve ikinci kez boşalmadığını doğrular.

package com.aykerme.klarivision.web

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StudyCommandQueueTest {
    @Test
    fun commandsQueuedBeforeReadyAreKeptInOrder() {
        val queue = StudyCommandQueue()
        assertTrue(queue.isEmpty())

        queue.enqueue(StudyCommand.PlayPause)
        queue.enqueue(StudyCommand.Seek(3.0))
        queue.enqueue(StudyCommand.MarkA)

        assertTrue(!queue.isEmpty())

        val drained = queue.drainWhenReady()
        assertEquals(listOf(StudyCommand.PlayPause, StudyCommand.Seek(3.0), StudyCommand.MarkA), drained)
    }

    @Test
    fun drainingTwiceInARowYieldsEmptyListSecondTime() {
        val queue = StudyCommandQueue()
        queue.enqueue(StudyCommand.Loop)

        val first = queue.drainWhenReady()
        val second = queue.drainWhenReady()

        assertEquals(listOf(StudyCommand.Loop), first)
        assertEquals(emptyList<StudyCommand>(), second)
        assertTrue(queue.isEmpty())
    }

    @Test
    fun commandsEnqueuedAfterADrainAreKeptForTheNextDrain() {
        val queue = StudyCommandQueue()
        queue.enqueue(StudyCommand.Pause)
        queue.drainWhenReady()

        queue.enqueue(StudyCommand.Follow)
        val secondBatch = queue.drainWhenReady()

        assertEquals(listOf(StudyCommand.Follow), secondBatch)
    }
}
