package com.cometchat.voip

import android.os.Process
import android.util.Log as AndroidLog
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.mockito.MockedStatic
import org.mockito.Mockito

/**
 * An answered call whose process died mid-call stays in the store with nothing
 * left to report its end. Before the next call rings, one the Calls SDK is not
 * in a session for, and that was answered longer ago than a join takes, is
 * dropped — otherwise every later call rang over it, and it came back into the
 * active slot each time that call ended. Mirrors the native iOS SDK's
 * `CallWaitingTests` (push-notifications-sdk-ios #6).
 */
internal class StaleAnsweredCallTest {

    private val android = FakeAndroid()
    private val context get() = android.context
    private lateinit var log: MockedStatic<AndroidLog>
    private lateinit var process: MockedStatic<Process>

    private val now = 1_700_000_000_000L

    @BeforeTest
    fun setUp() {
        // android.util.Log and android.os.Process are stubs on the unit-test
        // classpath; SessionState.update records Process.myPid().
        log = Mockito.mockStatic(AndroidLog::class.java)
        process = Mockito.mockStatic(Process::class.java)
        CallStore.resetCacheForTesting()
    }

    @AfterTest
    fun tearDown() {
        log.close()
        process.close()
        CallStore.resetCacheForTesting()
    }

    private fun call(sessionId: String) = IncomingCall(
        sessionId = sessionId,
        callerUid = "alice",
        callerName = "Alice Demo",
        callerAvatarUrl = null,
        callType = IncomingCall.TYPE_AUDIO,
        receiverType = IncomingCall.RECEIVER_TYPE_USER,
        receiverUid = "bob",
        conversationId = null,
        initiatedAtMs = now,
        ringTimeoutMs = CallsConstants.DEFAULT_RING_TIMEOUT_MS
    )

    /** What `startRinging` does to the store for [sessionId], without the ring itself. */
    private fun ring(sessionId: String, joined: Set<String> = emptySet()) {
        RingController.dropAnsweredCallsNoLongerInASession(context, now) { it in joined }
        assertTrue(CallStore.setRinging(context, call(sessionId)))
    }

    /** `s1` was answered a minute ago by a process that has since ended: no session, no end event. */
    private fun answeredByAnEndedProcess() {
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now - 60_000)
    }

    @Test
    fun `an answered call no longer in a session is dropped when another rings`() {
        answeredByAnEndedProcess()
        ring("s2")
        assertTrue(CallStore.isRinging(context, "s2"))
        assertNull(CallStore.held(context))
        assertFalse(CallStore.isActive(context, "s1"))
        assertNull(CallStore.answeredSessionOtherThan(context, "s2"))
        assertEquals("no_session", CallStore.terminalReason(context, "s1"))
    }

    @Test
    fun `the dropped call does not come back when the next call ends`() {
        answeredByAnEndedProcess()
        ring("s2")
        CallStore.markAnswered(context, "s2", now = now)
        CallStore.clear(context, "s2", "ended")
        assertNull(CallStore.get(context))
        assertNull(CallStore.held(context))
    }

    @Test
    fun `a call answered moments ago is still held while it joins`() {
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now - 1_000)
        ring("s2")
        assertEquals("s1", CallStore.held(context)?.call?.sessionId)
        assertNull(CallStore.terminalReason(context, "s1"))
    }

    @Test
    fun `a held call that is no longer in a session is dropped when a third rings`() {
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now - 60_000)
        ring("s2", joined = setOf("s1"))
        assertEquals("s1", CallStore.held(context)?.call?.sessionId)
        ring("s3")
        assertTrue(CallStore.isRinging(context, "s3"))
        assertNull(CallStore.held(context))
        assertEquals("no_session", CallStore.terminalReason(context, "s1"))
    }

    @Test
    fun `an answered call the Calls SDK is in a session for is kept`() {
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now - 60_000)
        ring("s2", joined = setOf("s1"))
        assertEquals("s1", CallStore.held(context)?.call?.sessionId)
        assertEquals("s1", CallStore.answeredSessionOtherThan(context, "s2"))
    }

    @Test
    fun `an answered call written without answeredAt is over`() {
        // Written by an older build: answered, with no `answeredAt`. Nothing
        // says it is still joining.
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now)
        context.getSharedPreferences("cometchat_voip_call_store", 0).edit().remove("answeredAt").apply()
        CallStore.resetCacheForTesting()
        assertNull(CallStore.get(context)?.answeredAt)
        ring("s2")
        assertTrue(CallStore.isRinging(context, "s2"))
        assertNull(CallStore.held(context))
    }

    @Test
    fun `the default session check reads what Dart reported`() {
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now - 60_000)

        // Joined, and the Calls SDK names the session: in progress.
        SessionState.update(context, active = true, joined = true, sessionId = "s1")
        RingController.dropAnsweredCallsNoLongerInASession(context, now)
        assertTrue(CallStore.isActive(context, "s1"))

        // Joined without a prepare, so the Calls SDK has no id for it: still in progress.
        SessionState.update(context, active = true, joined = true, sessionId = null)
        RingController.dropAnsweredCallsNoLongerInASession(context, now)
        assertTrue(CallStore.isActive(context, "s1"))

        // Joined to some other session: s1 is over.
        SessionState.update(context, active = true, joined = true, sessionId = "s9")
        RingController.dropAnsweredCallsNoLongerInASession(context, now)
        assertFalse(CallStore.isActive(context, "s1"))
        assertEquals("no_session", CallStore.terminalReason(context, "s1"))
    }

    @Test
    fun `a held call whose session ended is dropped and does not come back`() {
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now - 1_000)
        ring("s2")
        assertEquals("s1", CallStore.held(context)?.call?.sessionId)
        // The app reported s1 over while s2 rang (reportCallEnded).
        CallStore.dropHeld(context, "s1")
        CallStore.clear(context, "s2", "declined")
        assertNull(CallStore.get(context))
        assertNull(CallStore.held(context))
    }

    @Test
    fun `the held call and when it was answered survive a relaunch`() {
        ring("s1")
        CallStore.markAnswered(context, "s1", now = now - 5_000)
        ring("s2")

        CallStore.resetCacheForTesting()
        assertEquals("s2", CallStore.get(context)?.call?.sessionId)
        assertEquals("s1", CallStore.held(context)?.call?.sessionId)
        assertEquals(now - 5_000, CallStore.held(context)?.answeredAt)
    }
}
