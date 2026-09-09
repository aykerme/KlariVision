package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveLifecycleTest {

    @Test
    fun `initial phase is idle`() {
        val lifecycle = LiveLifecycle()
        assertEquals(LivePhase.Idle, lifecycle.phase)
    }

    @Test
    fun `requestStart moves to requesting permission`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        assertEquals(LivePhase.RequestingPermission, lifecycle.phase)
    }

    @Test
    fun `started moves to running from requesting permission`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        lifecycle.started()
        assertEquals(LivePhase.Running, lifecycle.phase)
    }

    @Test
    fun `failed moves to failed with message from any phase`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        lifecycle.started()
        lifecycle.failed("boom")
        assertEquals(LivePhase.Failed("boom"), lifecycle.phase)
    }

    @Test
    fun `stopped with reason moves to interrupted`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        lifecycle.started()
        lifecycle.stopped("route changed")
        assertEquals(LivePhase.Interrupted("route changed"), lifecycle.phase)
    }

    @Test
    fun `stopped without reason moves to idle`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        lifecycle.started()
        lifecycle.stopped(null)
        assertEquals(LivePhase.Idle, lifecycle.phase)
    }

    @Test
    fun `stop is idempotent when already idle`() {
        val lifecycle = LiveLifecycle()
        lifecycle.stopped(null)
        assertEquals(LivePhase.Idle, lifecycle.phase)
        lifecycle.stopped(null)
        assertEquals(LivePhase.Idle, lifecycle.phase)
    }

    @Test
    fun `stop is idempotent when already interrupted with same reason`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        lifecycle.started()
        lifecycle.stopped("route changed")
        lifecycle.stopped("route changed")
        assertEquals(LivePhase.Interrupted("route changed"), lifecycle.phase)
    }

    @Test
    fun `stop after failure still transitions cleanly`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        lifecycle.failed("engine error")
        lifecycle.stopped(null)
        assertEquals(LivePhase.Idle, lifecycle.phase)
    }

    @Test
    fun `restart after stop works`() {
        val lifecycle = LiveLifecycle()
        lifecycle.requestStart()
        lifecycle.started()
        lifecycle.stopped(null)
        lifecycle.requestStart()
        lifecycle.started()
        assertTrue(lifecycle.phase == LivePhase.Running)
    }
}
