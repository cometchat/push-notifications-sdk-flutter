package com.cometchat.voip

import android.content.Context

/**
 * The one funnel every ring transition goes through.
 *
 * Answer arrives from the notification, the ring screen and Dart; decline from
 * those and the timeout; an end from a terminal push or the Calls SDK. Routing
 * them all through here is what makes the behaviour the same whichever the
 * user touched, and why every operation is idempotent per session: a
 * duplicate push, a double-tapped Decline and an answer racing the timeout are
 * all harmless.
 *
 * This decides when the ring starts and stops. What it looks like belongs to
 * [IncomingCallNotifier]; what happens to the call session happens in the
 * side effects at the bottom.
 */
internal object RingController {
    /**
     * What [liveSession] returns for a session joined without an id (a
     * meeting): callers only ask whether there is a live call.
     */
    const val JOINED_WITHOUT_ID = "joined-session-without-id"


    /** A call reached the device: ring it, unless it is already known or already over. */
    fun startRinging(context: Context, call: IncomingCall) {
        dropAnsweredCallsNoLongerInASession(context)
        val previous = CallStore.get(context)

        if (!CallStore.setRinging(context, call)) {
            // A duplicate, or a session already over. Re-post only when the ring
            // is missing: posting over a showing ring is an update, and an
            // alert-once update to a looping ring stops its ringtone.
            if (CallStore.isRinging(context, call.sessionId) &&
                !IncomingCallNotifier.isShowing(context, call.sessionId)
            ) {
                post(context, call)
            }
            return
        }

        // One ring at a time: a replaced *ringing* session's ring and alarm have
        // to go, or it would keep ringing behind the new one. An answered call
        // is the user's live call and is left alone — CallStore holds it while
        // this one rings. Tearing it down here stopped its keep-alive and lost
        // its slot (native iOS: "a second call ended the live call").
        if (previous != null && previous.call.sessionId != call.sessionId &&
            previous.state == CallStore.State.RINGING
        ) {
            stopRinging(context, previous.call.sessionId, answered = false)
        }

        post(context, call)
        // After the ring is up, never before: nothing may delay it.
        onRingStarted(context, call)
    }

    /**
     * An answered call is in progress only while the Calls SDK is in its
     * session, or within the answer-to-joined window while it is still
     * joining. The store outlives the process, so a call whose process died
     * mid-call is still recorded as answered with nothing left to report its
     * end. Kept, it would make every later call ring over it, and come back
     * into the active slot each time that call ended (native iOS hit and
     * fixed the same, push-notifications-sdk-ios #6).
     *
     * [hasJoined] is what says the Calls SDK is in a session for a call; the
     * default reads the session state Dart reports.
     */
    fun dropAnsweredCallsNoLongerInASession(
        context: Context,
        now: Long = System.currentTimeMillis(),
        hasJoined: (String) -> Boolean = { hasJoined(context, it) }
    ) {
        fun over(active: CallStore.ActiveCall): Boolean {
            if (hasJoined(active.call.sessionId)) return false
            val answeredAt = active.answeredAt ?: return true
            return now - answeredAt >= CallsConstants.ANSWER_TO_JOINED_CAP_MS
        }
        CallStore.held(context)?.takeIf(::over)?.let {
            Log.d("startRinging: ${it.call.sessionId} was answered but is no longer in a session; dropping it")
            CallStore.forgetAnswered(context, it.call.sessionId)
            CallStore.clearHeld(context, it.call.sessionId, "no_session")
        }
        CallStore.get(context)?.takeIf { it.state == CallStore.State.ANSWERED && over(it) }?.let {
            Log.d("startRinging: ${it.call.sessionId} was answered but is no longer in a session; dropping it")
            CallStore.forgetAnswered(context, it.call.sessionId)
            CallStore.clear(context, it.call.sessionId, "no_session")
        }
    }

    /**
     * Whether the answered call [sessionId] has joined, by what Dart last
     * reported. A session joined without a prepare — a call answered over a
     * live one — has no id in the Calls SDK, so a join reported with no id
     * counts for it too.
     */
    private fun hasJoined(context: Context, sessionId: String): Boolean {
        if (!CallsSdk.isSessionJoined(context)) return false
        val owned = CallsSdk.ownedSessionId(context)
        return owned == null || owned == sessionId
    }

    /**
     * The user answered. Stopping the ring is unconditional for a known
     * session, even one the store has lost, so an answered call's ring can
     * never outlive it and be answered twice.
     */
    fun answer(context: Context, sessionId: String?): CallStore.ActiveCall? {
        val answered = CallStore.markAnswered(context, sessionId)
        if (answered == null) {
            Log.w("answer: no active call for $sessionId")
            (sessionId ?: CallStore.get(context)?.call?.sessionId)?.let {
                stopRinging(context, it, answered = false)
            }
            return null
        }
        stopRinging(context, answered.call.sessionId, answered = true)
        // Carry the keep-alive through the join; the ring becomes "Connecting call…".
        RingingForegroundService.connecting(context, answered.call)
        return answered
    }

    /**
     * The user declined. `busy` only while another answered call is still
     * joined — the one legitimate source of that status. The package never
     * decides on its own that the user is busy.
     */
    /**
     * Declines [sessionId]. It is sent as `busy` rather than `rejected` when
     * the user is on another call, placed or answered ([callStillLive]), or
     * when the app passes [busy].
     */
    fun decline(context: Context, sessionId: String?, busy: Boolean = false) {
        val active = CallStore.get(context)
        val target = sessionId ?: active?.call?.sessionId
        if (target.isNullOrBlank()) {
            Log.w("decline: no session to decline")
            return
        }
        if (CallStore.wasTerminal(context, target)) {
            // A double-tapped Decline, or one racing the timeout.
            stopRinging(context, target, answered = false)
            return
        }

        // A group call is declined here only: the ring stops and the session
        // prepared while ringing is left, but nothing is sent, so the call
        // carries on for everyone else. Both native SDKs do this; an endCall
        // on a group session can end it for every member.
        val ringing = active?.call?.takeIf { it.sessionId == target }
        if (ringing != null && !ringing.isPeerCall) {
            stopRinging(context, target, answered = false)
            val cleared = CallStore.clear(context, target, "declined")
            cleared?.let { ended(context, it.call, CallEndReason.DECLINED, sdkReason = CallsConstants.CALL_STATUS_REJECTED) }
            return
        }

        val status = if (busy || callStillLive(context, target)) {
            CallsConstants.CALL_STATUS_BUSY
        } else {
            CallsConstants.CALL_STATUS_REJECTED
        }
        stopRinging(context, target, answered = false)
        val cleared = CallStore.clear(context, target, "declined")
        DeclineQueue.enqueue(context, target, status)
        cleared?.let { ended(context, it.call, CallEndReason.DECLINED, sdkReason = status) }
    }

    /**
     * Whether a call other than [declining] is live on this device, which makes
     * its decline `busy`: the user is on another call. Any joined session
     * counts, one this device placed as much as one it answered; only counting
     * answered calls sent `rejected` for a decline during a call this device
     * placed.
     *
     * The answered marker outlives its call: the hang-up happens in the app
     * and is never reported here. Whether the Calls SDK is still joined is the
     * truth, and a marker that fails the check is dropped ([liveSession] goes
     * through [liveAnsweredSession]) so it cannot make the next decline `busy`
     * either.
     */
    private fun callStillLive(context: Context, declining: String): Boolean =
        liveSession(context, declining) != null

    /**
     * The answered call still live on this device, other than [otherThan], or
     * null.
     *
     * The answered half of [liveSession].
     */
    fun liveAnsweredSession(context: Context, otherThan: String?): String? {
        val answered = CallStore.answeredSessionOtherThan(context, otherThan ?: "") ?: return null
        val live = CallsSdk.isSessionJoined(context) && CallsSdk.ownedSessionId(context) == answered
        if (!live) CallStore.forgetAnswered(context, answered)
        return if (live) answered else null
    }

    /**
     * The call live on this device, other than [otherThan], or null: the
     * answered call when there is one, otherwise any session the Calls SDK has
     * joined — a call this device placed is as live as one it answered, though
     * no answered marker names it.
     *
     * What makes the next call's ring say answering ends the current one.
     */
    fun liveSession(context: Context, otherThan: String?): String? {
        liveAnsweredSession(context, otherThan)?.let { return it }
        if (!CallsSdk.isSessionJoined(context)) return null
        // A session joined without a prepare has no id: a meeting the app joins
        // itself. It is a live call all the same, so a call declined during it
        // goes out `busy`, not `rejected`. Only while this process reported it:
        // a meeting does not outlive its process.
        val owned = CallsSdk.ownedSessionId(context)
            ?: return if (SessionState.reportedByThisProcess(context)) JOINED_WITHOUT_ID else null
        return if (owned != otherThan) owned else null
    }

    /**
     * Releases a session prepared for a call that is already over, other than
     * [otherThan], and returns whether it did.
     *
     * Connect-while-ringing can finish after its ring ended: the caller
     * cancels while the connect is still in flight, [stopRinging] finds no
     * session of its own to release yet, and the connect then completes for a
     * call nobody will join. That session looks like a call this device is
     * placing (active, not joined), so [RingGate] answered every later call
     * busy, and [WakeVerifier] stopped preparing them, until the report went
     * stale.
     *
     * Only a session whose call ended is released: never a joined one, and
     * never one recorded as answered (`ongoing` reaches a caller's own call
     * just before it joins).
     */
    fun releaseLeftoverSession(context: Context, otherThan: String?): Boolean {
        val owned = CallsSdk.ownedSessionId(context) ?: return false
        if (owned == otherThan) return false
        if (!CallsSdk.isSessionActive(context) || CallsSdk.isSessionJoined(context)) return false
        val reason = CallStore.terminalReason(context, owned) ?: return false
        if (reason in NOT_AN_END) return false
        Log.d("releasing $owned: prepared for a call that is already over ($reason)")
        CallsSdk.leaveSession(context)
        return true
    }

    /** Terminal reasons that mean the call went on, not that it ended. */
    private val NOT_AN_END = setOf(CallPushPayload.Action.ONGOING.wire, "answered")

    /** Nobody answered in time — the case that defines a missed call. */
    fun timeout(context: Context, sessionId: String?) {
        val active = CallStore.get(context)
        val target = sessionId ?: active?.call?.sessionId ?: return
        stopRinging(context, target, answered = false)

        if (active == null || active.call.sessionId != target) {
            // Nothing active to miss, but remember it so a late initiated cannot revive it.
            if (!CallStore.wasTerminal(context, target)) CallStore.markTerminal(context, target, "timeout")
            return
        }
        val wasRinging = active.state == CallStore.State.RINGING
        val cleared = CallStore.clear(context, target, "timeout") ?: return
        if (wasRinging) {
            showMissedCall(context, cleared.call)
            // A one-to-one call that rang out ends as `unanswered` on the
            // server too, durably, as on both native SDKs; it used to be told
            // to the local listeners only, so the call log kept the caller's
            // status. Nothing for a group call: it carries on for the others.
            if (cleared.call.isPeerCall) {
                DeclineQueue.enqueue(context, target, CallsConstants.CALL_STATUS_UNANSWERED)
            }
            ended(context, cleared.call, CallEndReason.TIMED_OUT, sdkReason = CallsConstants.CALL_STATUS_UNANSWERED)
        }
    }

    /**
     * The call ended on the other side: cancelled, declined on another device,
     * answered on another device, or found dead while ringing. When the session
     * is not active this still records it, so a late initiated cannot ring a
     * call that is over.
     */
    fun remoteEnded(context: Context, sessionId: String, reason: CallEndReason, ledger: String) {
        stopRinging(context, sessionId, answered = false)
        val active = CallStore.get(context)
        if (active != null && active.call.sessionId == sessionId) {
            val wasRinging = active.state == CallStore.State.RINGING
            val cleared = CallStore.clear(context, sessionId, ledger) ?: return
            if (wasRinging && reason.isMissed) showMissedCall(context, cleared.call)
            ended(context, cleared.call, reason, sdkReason = ledger)
        } else if (!CallStore.wasTerminal(context, sessionId)) {
            CallStore.markTerminal(context, sessionId, ledger)
        }
    }

    /**
     * The Calls SDK says a ringing call is over — usually the session prepared
     * while ringing closing because the caller cancelled, which gets here
     * before the push does. Acts only while this device is still ringing: every
     * exit of our own has already stopped the ring, the SDK echoes the ends we
     * report, and once answered the call is the app's.
     */
    fun sdkEnded(context: Context, sessionId: String, sdkReason: String) {
        if (!CallStore.isRinging(context, sessionId)) return
        remoteEnded(context, sessionId, CallEndReason.ofSdkReason(sdkReason), sdkReason.lowercase())
    }

    /**
     * Removes every visible and scheduled trace of a ringing session. Idempotent.
     *
     * [answered] is the one exit that keeps the keep-alive and the prepared
     * session: the join still has to happen, and that is exactly when the
     * process would otherwise be reclaimed.
     */
    fun stopRinging(context: Context, sessionId: String, answered: Boolean) {
        IncomingCallNotifier.cancelIncoming(context, sessionId)
        RingExpiry.cancel(context, sessionId)
        // Cancelling the notification does not close the ring screen it opened.
        RingSurfaces.finish(sessionId)
        WakeVerifier.cancel(sessionId)
        if (!answered) {
            // Release the session connect-while-ringing prepared. A decline does
            // this through endCall, but when the caller cancels nobody calls
            // endCall, and the prepared connection would linger until it timed
            // out. Never a joined session: that is the user, in a call.
            if (CallsSdk.ownedSessionId(context) == sessionId && !CallsSdk.isSessionJoined(context)) {
                CallsSdk.leaveSession(context)
            }
            // The service holds the ring, and only stopping it removes it.
            RingingForegroundService.stop(context, sessionId)
        }
    }

    /**
     * The app answered or declined a ringing call in its own UI and told
     * CometChat itself: stop the ring, send nothing. The app is in front, so
     * the keep-alive goes too. An answer keeps the session prepared while
     * ringing for the app's join, and marks the call answered so a second
     * call's decline is `busy`.
     */
    fun dismissRinging(context: Context, sessionId: String, answered: Boolean) {
        if (!CallStore.isRinging(context, sessionId)) return
        if (answered) {
            CallStore.markAnswered(context, sessionId)
        } else {
            CallStore.clear(context, sessionId, "declined_in_app")
        }
        stopRinging(context, sessionId, answered = answered)
        RingingForegroundService.stop(context, sessionId)
    }

    fun showMissedCall(context: Context, call: IncomingCall) {
        if (VoipConfig.restore(context)?.showMissedCallNotification == false) return
        if (!MissedCalls.shouldNotify(context, call)) return
        IncomingCallNotifier.showMissedCall(context, call)
    }

    // ── Side effects ──

    private fun post(context: Context, call: IncomingCall) {
        // The keep-alive service posts the ring as its own notification when it
        // can, so the ring has exactly one poster and nothing updates it while
        // it rings. Otherwise it is posted here.
        if (!RingingForegroundService.ring(context, call)) {
            IncomingCallNotifier.showIncoming(context, call)
        }
        RingExpiry.arm(context, call)
    }

    private fun onRingStarted(context: Context, call: IncomingCall) {
        val appContext = context.applicationContext
        // A caller's cancel reaches this device first through the prepared
        // session closing. Dart hears that on its IncomingCallListener and
        // hands it back with `sdkEndedCall`, because the SDK is out of reach
        // from here.
        WakeVerifier.start(appContext, call)
        CallsSdk.injectIncomingCall(appContext, call)
    }

    /** Tells the Calls SDK's listeners and Dart that [call] stopped ringing. */
    private fun ended(context: Context, call: IncomingCall, reason: CallEndReason, sdkReason: String) {
        CallsSdk.injectIncomingCallEnded(context.applicationContext, call, sdkReason)
        CallEvents.ended(call, reason)
    }
}
