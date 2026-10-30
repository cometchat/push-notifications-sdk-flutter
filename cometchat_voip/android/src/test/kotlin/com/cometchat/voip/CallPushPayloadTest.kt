package com.cometchat.voip

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The parser runs on every call push, and every way it can be wrong is silent:
 * the phone simply does not ring. The payloads here are the ones CometChat
 * sends.
 */
internal class CallPushPayloadTest {

    private val initiated = mapOf(
        "type" to "call",
        "callAction" to "initiated",
        "callType" to "video",
        "sessionId" to "v1.in.278538a17a6a73bf.1788767702",
        "sender" to "cometchat-uid-1",
        "senderName" to "Andrew Joseph",
        "senderAvatar" to "https://assets.cometchat.io/sampleapp/v2/users/cometchat-uid-1.webp",
        "receiver" to "ppqphj8mpktv7ulely6xy5degda2",
        "receiverType" to "user",
        "conversationId" to "cometchat-uid-1_user_ppqphj8mpktv7ulely6xy5degda2",
        "sentAt" to "1788767702000",
        "title" to "Andrew Joseph",
        "body" to "VIDEO CALL"
    )

    private fun parse(data: Map<String, String?>): CallPushPayload =
        assertIs<CallPushPayload.Result.Call>(CallPushPayload.parse(data)).payload

    @Test
    fun `the push CometChat sends parses into a ringable call`() {
        val payload = parse(initiated)
        assertEquals(CallPushPayload.Action.INITIATED, payload.action)

        val call = payload.toIncomingCall(receivedAtMs = 0)
        assertEquals("v1.in.278538a17a6a73bf.1788767702", call.sessionId)
        assertEquals("cometchat-uid-1", call.callerUid)
        assertEquals("Andrew Joseph", call.callerName)
        assertTrue(call.isVideo)
        assertTrue(call.isPeerCall)
        assertEquals(1788767702000, call.initiatedAtMs)
        assertEquals(CallsConstants.DEFAULT_RING_TIMEOUT_MS, call.ringTimeoutMs)
    }

    @Test
    fun `sentAt in seconds is read as seconds`() {
        // Read as millis, the deadline lands in 1970 and every call is dropped
        // as expired.
        val call = parse(initiated + ("sentAt" to "1788767702")).toIncomingCall(receivedAtMs = 0)
        assertEquals(1788767702000, call.initiatedAtMs)
    }

    @Test
    fun `initiatedAt and ringTimeout win over sentAt when the backend sends them`() {
        val call = parse(initiated + mapOf("initiatedAt" to "1788767700000", "ringTimeout" to "30000"))
            .toIncomingCall(receivedAtMs = 0)
        assertEquals(1788767700000, call.initiatedAtMs)
        assertEquals(30000, call.ringTimeoutMs)
    }

    @Test
    fun `a ring timeout outside the sane range is ignored`() {
        val call = parse(initiated + ("ringTimeout" to "5")).toIncomingCall(receivedAtMs = 0)
        assertEquals(CallsConstants.DEFAULT_RING_TIMEOUT_MS, call.ringTimeoutMs)
    }

    @Test
    fun `without any timestamp the deadline counts from arrival`() {
        val call = parse(initiated - "sentAt").toIncomingCall(receivedAtMs = 1234)
        assertEquals(1234, call.initiatedAtMs)
    }

    @Test
    fun `keys match whatever their case`() {
        val payload = parse(
            mapOf("TYPE" to "call", "CallAction" to "Cancelled", "SESSIONID" to "s1", "callType" to "AUDIO")
        )
        assertEquals(CallPushPayload.Action.CANCELLED, payload.action)
        assertEquals(IncomingCall.TYPE_AUDIO, payload.callType)
    }

    @Test
    fun `the legacy extension's nested message parses too`() {
        val payload = parse(
            mapOf(
                "message" to """
                    {"category":"call","action":"initiated","sessionid":"legacy-1","type":"audio",
                     "sender":{"uid":"alex","name":"Alex Okonjo","avatar":"https://a.example/a.png"},
                     "receiver":"cameron","receiverType":"user"}
                """.trimIndent()
            )
        )
        assertEquals("legacy-1", payload.sessionId)
        assertEquals("alex", payload.senderUid)
        assertEquals("Alex Okonjo", payload.senderName)
        assertEquals("cameron", payload.receiverUid)
    }

    @Test
    fun `a chat push is not a call`() {
        assertIs<CallPushPayload.Result.Ignored>(CallPushPayload.parse(mapOf("type" to "chat", "sender" to "alex")))
    }

    @Test
    fun `a call push without a session cannot ring`() {
        assertIs<CallPushPayload.Result.Ignored>(CallPushPayload.parse(initiated - "sessionId"))
    }

    @Test
    fun `an unnamed caller is shown by uid, then as unknown`() {
        assertEquals("cometchat-uid-1", parse(initiated - "senderName" - "title").displayName)
        assertEquals("Unknown caller", parse(initiated - "senderName" - "title" - "sender").displayName)
    }

    @Test
    fun `an action this build does not know neither rings nor ends a call`() {
        val action = parse(initiated + ("callAction" to "transferred")).action
        assertEquals(CallPushPayload.Action.UNKNOWN, action)
        assertEquals(false, action.isTerminal)
    }

    @Test
    fun `terminal actions end the ring with the reason the user expects`() {
        assertEquals(CallEndReason.CANCELLED, CallEndReason.of(CallPushPayload.Action.CANCELLED))
        assertEquals(CallEndReason.TIMED_OUT, CallEndReason.of(CallPushPayload.Action.UNANSWERED))
        assertEquals(CallEndReason.TIMED_OUT, CallEndReason.of(CallPushPayload.Action.TIMED_OUT))
        assertEquals(CallEndReason.ANSWERED_ELSEWHERE, CallEndReason.of(CallPushPayload.Action.ONGOING))
        // `ended` while still ringing is the caller's device saying it is over:
        // not a missed call.
        assertEquals(CallEndReason.DECLINED, CallEndReason.of(CallPushPayload.Action.ENDED))
        assertTrue(CallEndReason.CANCELLED.isMissed)
        assertEquals(false, CallEndReason.DECLINED.isMissed)
    }
}
