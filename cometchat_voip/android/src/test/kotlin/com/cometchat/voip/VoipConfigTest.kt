package com.cometchat.voip

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The call mode decides whose screen the ring's full-screen alert opens, and
 * it is read on a process the app never ran in — so it has to survive
 * `CometChatVoipConfig.toMap`, and a value this build does not know has to
 * fall back to the mode that always works.
 */
internal class VoipConfigTest {

    private fun config(vararg extra: Pair<String, Any?>): VoipConfig? =
        VoipConfig.fromMap(mapOf("appId" to "APP", "region" to "us") + extra.toMap())

    @Test
    fun `the default mode rings the package's own screen`() {
        val parsed = config()
        assertEquals(VoipConfig.MODE_AUTO, parsed?.callMode)
        assertFalse(parsed!!.opensAppRingScreen)
    }

    @Test
    fun `autoCustomScreen opens the app's screen`() {
        val parsed = config("callMode" to VoipConfig.MODE_AUTO_CUSTOM_SCREEN)
        assertEquals(VoipConfig.MODE_AUTO_CUSTOM_SCREEN, parsed?.callMode)
        assertTrue(parsed!!.opensAppRingScreen)
    }

    @Test
    fun `manual is carried through, and rings nothing of ours`() {
        val parsed = config("callMode" to "manual")
        assertEquals("manual", parsed?.callMode)
        assertFalse(parsed!!.opensAppRingScreen)
    }

    @Test
    fun `a mode this build does not know rings our own screen`() {
        // Never the app's: the alert would open an app that does not know it
        // is meant to draw a ring, which is a call that rings nowhere.
        assertFalse(config("callMode" to "telepathy")!!.opensAppRingScreen)
        assertFalse(config("callMode" to "")!!.opensAppRingScreen)
    }

    @Test
    fun `a config without an app id or a region is no config at all`() {
        assertNull(VoipConfig.fromMap(mapOf("region" to "us")))
        assertNull(VoipConfig.fromMap(mapOf("appId" to "APP")))
    }
}
