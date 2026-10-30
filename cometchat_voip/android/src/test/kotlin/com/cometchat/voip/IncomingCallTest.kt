package com.cometchat.voip

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

/**
 * [IncomingCall.toMap] is what the store persists and Dart reads, so a call
 * written by the process that rang it must read back whole in the process
 * that answers it.
 */
internal class IncomingCallTest {

    private val call = IncomingCall(
        sessionId = "s1",
        callerUid = "alex",
        callerName = "Alex Okonjo",
        callerAvatarUrl = null,
        callType = IncomingCall.TYPE_AUDIO,
        receiverType = IncomingCall.RECEIVER_TYPE_GROUP,
        receiverUid = "engineering",
        conversationId = null,
        initiatedAtMs = 1_000,
        ringTimeoutMs = 45_000
    )

    @Test
    fun `a call survives the round trip through its map`() {
        assertEquals(call, IncomingCall.fromMap(call.toMap()))
    }

    @Test
    fun `a map without a session is no call`() {
        assertNull(IncomingCall.fromMap(call.toMap() - "sessionId"))
    }

    @Test
    fun `the deadline is absolute`() {
        assertEquals(46_000, call.expiresAtMs)
    }

    @Test
    fun `a group call is not a peer call`() {
        assertFalse(call.isPeerCall)
    }

    @Test
    fun `initials come from the first and last names`() {
        assertEquals("AO", call.initials)
        assertEquals("B", call.copy(callerName = "bob").initials)
        assertEquals("?", call.copy(callerName = "  ").initials)
    }

    @Test
    fun `the Calls SDK gets the payload in its own key names`() {
        val payload = CallsSdk.payload(call, "initiated")
        assertEquals("alex", payload["sender"])
        assertEquals("Alex Okonjo", payload["senderName"])
        assertEquals("engineering", payload["receiver"])
        assertEquals("initiated", payload["callAction"])
        assertEquals("1000", payload["initiatedAt"])
    }
}
