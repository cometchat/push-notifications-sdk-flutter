package com.cometchat.voip

import android.content.Context
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Connects to the call while the phone rings.
 *
 * Two jobs. Speed: answering then only adds media. And truth: a connect that
 * succeeds proves the call is alive, and fires `onParticipantConnected` on the
 * caller, so they know it is ringing.
 *
 * Dismissing a live call is far worse than ringing a dead one a little longer,
 * so nothing here ends the ring on an inconclusive result — a failed connect,
 * an unreachable server or a timeout all leave it ringing to its deadline.
 * Only a conclusive "this call is over" would, and the backend cannot say that
 * yet, so for now this only prepares.
 */
internal object WakeVerifier {

    private val io = Executors.newCachedThreadPool { r ->
        Thread(r, "cometchat-voip-verify").apply { isDaemon = true }
    }

    /** Sessions being verified, so a duplicate push cannot start a second attempt. */
    private val inFlight = ConcurrentHashMap.newKeySet<String>()

    /**
     * How long the last wake took, in milliseconds: bringing the Calls SDK up,
     * and the connect that followed. Null until a push has woken this process.
     *
     * The same pair iOS reports as `lastWakeTiming`. It is the one number that
     * tells a slow ring from a ring that never started.
     */
    @Volatile private var sdkReadyMs: Long? = null
    @Volatile private var connectMs: Long? = null

    fun lastTiming(): Map<String, Any?> = mapOf(
        "sdkReadyMs" to sdkReadyMs,
        "connectMs" to connectMs
    )

    fun start(context: Context, call: IncomingCall) {
        if (!inFlight.add(call.sessionId)) return
        val appContext = context.applicationContext
        io.execute {
            try {
                verify(appContext, call)
            } catch (t: Throwable) {
                Log.e("verify threw for ${call.sessionId}: ${t.message}")
            } finally {
                inFlight.remove(call.sessionId)
            }
        }
    }

    /** Answered, declined or ended: stop. The ring's exit releases the session. */
    fun cancel(sessionId: String) {
        inFlight.remove(sessionId)
    }

    private fun verify(context: Context, call: IncomingCall) {
        val config = VoipConfig.restore(context) ?: return
        val sdkStart = System.currentTimeMillis()
        if (!CallsSdk.ensureInitialised(context, config)) {
            Log.w("Calls SDK unavailable — ${call.sessionId} rings on to its deadline")
            return
        }
        sdkReadyMs = System.currentTimeMillis() - sdkStart

        // Another call already holds the SDK's one session. Connecting would
        // disturb it, and the user is plainly reachable. A session left behind
        // by a ring that already ended is released first, and this call is
        // prepared once the SDK reports it gone.
        if (RingController.releaseLeftoverSession(context, call.sessionId)) {
            waitForSessionReleased(context, call.sessionId)
        }
        val owned = CallsSdk.ownedSessionId(context)
        if (owned != null && owned != call.sessionId && CallsSdk.isSessionActive(context)) {
            Log.d("session $owned is active — not preparing ${call.sessionId}")
            return
        }

        val connectStart = System.currentTimeMillis()
        var attempt = 0
        while (attempt <= CallsConstants.VERIFY_MAX_RETRIES) {
            if (!inFlight.contains(call.sessionId)) return
            if (System.currentTimeMillis() >= call.expiresAtMs) return

            connectMs = System.currentTimeMillis() - connectStart
            when (val result = connectOnce(context, call)) {
                is CallsSdk.ConnectResult.Connected -> {
                    Log.d("${call.sessionId} is alive and prepared")
                    // The ring ended while this connect was in flight (the
                    // caller cancelled): nobody will join, so let it go now.
                    RingController.releaseLeftoverSession(context, otherThan = null)
                    return
                }

                is CallsSdk.ConnectResult.Failed -> {
                    if (result.retryable && attempt < CallsConstants.VERIFY_MAX_RETRIES) {
                        // A cold process: the login is still being restored.
                        attempt++
                        Thread.sleep(CallsConstants.VERIFY_RETRY_INTERVAL_MS)
                        continue
                    }
                    Log.d("connect failed for ${call.sessionId}: ${result.code} — ringing on")
                    return
                }

                null -> {
                    Log.w("connect for ${call.sessionId} did not answer — ringing on")
                    return
                }
            }
        }
    }

    /**
     * Waits, briefly, for the SDK to report the session other than [sessionId]
     * released. Dart reports it after the leave; a bounded wait keeps a stuck
     * report from holding the ring's preparation for long.
     */
    private fun waitForSessionReleased(context: Context, sessionId: String) {
        val deadline = System.currentTimeMillis() + RELEASE_WAIT_MS
        while (System.currentTimeMillis() < deadline) {
            val owned = CallsSdk.ownedSessionId(context)
            if (owned == null || owned == sessionId || !CallsSdk.isSessionActive(context)) return
            Thread.sleep(RELEASE_POLL_MS)
        }
    }

    private const val RELEASE_WAIT_MS = 2_000L
    private const val RELEASE_POLL_MS = 100L

    /** Blocks for the verify budget. Null when the SDK never called back. */
    private fun connectOnce(context: Context, call: IncomingCall): CallsSdk.ConnectResult? {
        val latch = CountDownLatch(1)
        var outcome: CallsSdk.ConnectResult? = null
        CallsSdk.connect(context, call) {
            outcome = it
            latch.countDown()
        }
        return if (latch.await(CallsConstants.VERIFY_BUDGET_MS, TimeUnit.MILLISECONDS)) outcome else null
    }
}
