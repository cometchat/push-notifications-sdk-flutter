package com.cometchat.voip

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * A `PendingIntent` is identified by its request code and `Intent.filterEquals`,
 * which ignores extras — so the intent that opens the app, which carries no
 * per-session data URI, needs a request code of its own or two ringing calls
 * share one PendingIntent and the first ring opens the second call.
 */
internal class RingRequestCodeTest {

    /** The kinds `IncomingCallNotifier` uses, which must never collide. */
    private val kinds = 101..107

    @Test
    fun `two sessions never share a request code`() {
        val codes = (1..500).map { CallsConstants.ringRequestCode(101, "v1.us.session-$it") }
        assertEquals(codes.size, codes.distinct().size)
    }

    @Test
    fun `the same session and kind is always the same code`() {
        assertEquals(
            CallsConstants.ringRequestCode(101, "v1.us.a"),
            CallsConstants.ringRequestCode(101, "v1.us.a")
        )
    }

    @Test
    fun `one session's kinds differ, and no kind reaches into another`() {
        val session = "v1.us.a"
        val codes = kinds.map { CallsConstants.ringRequestCode(it, session) }
        assertEquals(codes.size, codes.distinct().size)

        // Every kind's whole range stays its own, whatever the session hashes to.
        for (kind in kinds) {
            val all = (1..200).map { CallsConstants.ringRequestCode(kind, "session-$it") }
            assertTrue(all.all { it in (kind shl 20)..((kind shl 20) + (1 shl 20) - 1) })
        }
    }

    @Test
    fun `a request code is never negative`() {
        // Session ids hash negative about half the time, and a negative code
        // is a different PendingIntent namespace than intended.
        assertTrue(
            (1..500).all { CallsConstants.ringRequestCode(101, "session-$it") >= 0 }
        )
    }
}
