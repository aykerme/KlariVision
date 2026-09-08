package com.aykerme.klarivision.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RouteChangePolicyTest {

    @Test
    fun `null reason stops capturing`() {
        val action = RouteChangePolicy.action(reasonRawValue = null, expectedOwnCategoryChange = false)
        assertTrue(action is RouteChangeAction.Stop)
    }

    @Test
    fun `unknown reason code stops capturing`() {
        val action = RouteChangePolicy.action(reasonRawValue = 999, expectedOwnCategoryChange = false)
        assertTrue(action is RouteChangeAction.Stop)
    }

    @Test
    fun `category change with expected own change continues capturing`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_CATEGORY_CHANGE,
            expectedOwnCategoryChange = true,
        )
        assertEquals(RouteChangeAction.ContinueCapturing, action)
    }

    @Test
    fun `category change without expected own change stops capturing`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_CATEGORY_CHANGE,
            expectedOwnCategoryChange = false,
        )
        assertTrue(action is RouteChangeAction.Stop)
    }

    @Test
    fun `override always continues capturing`() {
        val continues = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_OVERRIDE,
            expectedOwnCategoryChange = false,
        )
        assertEquals(RouteChangeAction.ContinueCapturing, continues)

        val stillContinues = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_OVERRIDE,
            expectedOwnCategoryChange = true,
        )
        assertEquals(RouteChangeAction.ContinueCapturing, stillContinues)
    }

    @Test
    fun `old device unavailable stops with specific message`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_OLD_DEVICE_UNAVAILABLE,
            expectedOwnCategoryChange = false,
        )
        assertTrue(action is RouteChangeAction.Stop)
        assertTrue((action as RouteChangeAction.Stop).message.contains("Mikrofon rotası kaldırıldı"))
    }

    @Test
    fun `no suitable route stops with specific message`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_NO_SUITABLE_ROUTE_FOR_CATEGORY,
            expectedOwnCategoryChange = false,
        )
        assertTrue(action is RouteChangeAction.Stop)
        assertTrue((action as RouteChangeAction.Stop).message.contains("uygun ses rotası bulunamadı"))
    }

    @Test
    fun `new device available stops capturing`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_NEW_DEVICE_AVAILABLE,
            expectedOwnCategoryChange = false,
        )
        assertTrue(action is RouteChangeAction.Stop)
    }

    @Test
    fun `wake from sleep stops capturing`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_WAKE_FROM_SLEEP,
            expectedOwnCategoryChange = false,
        )
        assertTrue(action is RouteChangeAction.Stop)
    }

    @Test
    fun `route configuration change stops capturing`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_ROUTE_CONFIGURATION_CHANGE,
            expectedOwnCategoryChange = false,
        )
        assertTrue(action is RouteChangeAction.Stop)
    }

    @Test
    fun `new device available ignores expectedOwnCategoryChange flag`() {
        val action = RouteChangePolicy.action(
            reasonRawValue = RouteChangePolicy.REASON_NEW_DEVICE_AVAILABLE,
            expectedOwnCategoryChange = true,
        )
        assertTrue(action is RouteChangeAction.Stop)
    }
}
