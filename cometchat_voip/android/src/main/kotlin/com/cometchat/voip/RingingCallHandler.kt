package com.cometchat.voip

import android.content.Context

/** Every call push lands here: parsed, gated, then rung or ended. */
internal object RingingCallHandler {

    /**
     * The terminal actions that tell a caller its call ended before anyone
     * joined. Not `ongoing` (the callee answered: the caller hears that in the
     * room) and not `ended` (a call that was joined ends with its session).
     */
    private val CALLER_END_ACTIONS = setOf(
        CallsConstants.CALL_STATUS_REJECTED,
        CallsConstants.CALL_STATUS_BUSY,
        CallsConstants.CALL_STATUS_CANCELLED,
        CallsConstants.CALL_STATUS_UNANSWERED
    )

    /**
     * The terminal actions the *other* side of a one-to-one call sends about a
     * call this user placed. The backend puts whoever acted in `sender` — the
     * callee — and the caller in `receiver`. Not `cancelled` or `unanswered`:
     * with this user as `receiver` those mean the caller gave up on a call
     * ringing here, which must still stop the ring.
     */
    private val DECLINED_BY_CALLEE = setOf(
        CallsConstants.CALL_STATUS_REJECTED,
        CallsConstants.CALL_STATUS_BUSY
    )

    /** False when [data] is not a call push, so the app can handle it. */
    fun handle(context: Context, data: Map<String, String>, sentTimeMs: Long?): Boolean {
        val parsed = CallPushPayload.parse(data)
        if (parsed !is CallPushPayload.Result.Call) {
            Log.d("ignored: ${(parsed as CallPushPayload.Result.Ignored).reason}")
            return false
        }
        val payload = parsed.payload
        val receivedAt = sentTimeMs?.takeIf { it > 0 } ?: System.currentTimeMillis()
        val defaultTimeout = VoipConfig.restore(context)?.defaultRingTimeoutMs
            ?: CallsConstants.DEFAULT_RING_TIMEOUT_MS
        val call = payload.toIncomingCall(receivedAt, defaultTimeout)

        when {
            payload.action.isTerminal -> handleTerminal(context, payload, call)
            payload.action == CallPushPayload.Action.INITIATED -> handleInitiated(context, call)
            // An action this build does not know neither rings nor silences a call.
            else -> Log.w("unknown call action '${payload.rawAction}' for ${call.sessionId} — ignoring")
        }
        return true
    }

    private fun handleInitiated(context: Context, call: IncomingCall) {
        if (VoipConfig.restore(context) == null) {
            Log.e(
                "cannot ring ${call.sessionId}: CometChatVoip.init has never run on this device. " +
                    "It is remembered once it has."
            )
            return
        }
        when (val decision = RingGate.decide(context, call)) {
            is RingGate.Decision.Drop -> {
                Log.d("not ringing ${call.sessionId}: ${decision.reason}")
                if (decision.markTerminal) CallStore.markTerminal(context, call.sessionId, decision.reason)
                // Durably, so the caller hears `busy` even from a process that
                // dies before the Calls SDK is up.
                decision.declineAs?.let { DeclineQueue.enqueue(context, call.sessionId, it) }
                if (decision.missed) RingController.showMissedCall(context, call)
            }
            RingGate.Decision.Ring -> {
                Log.d("ringing ${call.sessionId}")
                RingController.startRinging(context, call)
            }
        }
    }

    private fun handleTerminal(context: Context, payload: CallPushPayload, call: IncomingCall) {
        val action = payload.action
        val ledger = payload.rawAction.lowercase()

        // The backend fans terminal events out to the caller's own devices too.
        // Recorded as over, so a user who rang someone and hung up is not told
        // they missed a call they made — and nothing rings or is shown.
        //
        // But the push is how the caller learns how its call ended: a callee
        // that declines before its ringer is in the room can only leave locally,
        // so the caller's prepared session never closes, and without this the
        // caller rings to its timeout. Handed to the Calls SDK, whose
        // IncomingCallListener reports it on the caller too (once per session,
        // though it never rang here), which is what the UI Kit's outgoing call
        // screen listens for. Android's Push SDK does the same. Not
        // CallEvents.ended: onCallEnded means a call that rang on this device.
        val myUid = CallStore.uid(context)
        if (myUid != null && call.callerUid == myUid) {
            CallStore.markTerminal(context, call.sessionId, ledger)
            if (ledger in CALLER_END_ACTIONS) {
                CallsSdk.injectIncomingCallEnded(context.applicationContext, call, ledger)
            }
            return
        }

        // The callee declined (or was busy for) a call this user placed: the
        // push carries the callee as `sender` and this user as `receiver`, so
        // the check above never matches it. Same handling: over, nothing rings
        // or is shown, and the Calls SDK tells the caller's UI.
        if (myUid != null && call.isPeerCall && call.receiverUid == myUid &&
            call.callerUid != myUid && ledger in DECLINED_BY_CALLEE
        ) {
            Log.d("${call.sessionId}: the callee says $ledger — telling this caller")
            CallStore.markTerminal(context, call.sessionId, ledger)
            CallsSdk.injectIncomingCallEnded(context.applicationContext, call, ledger)
            return
        }

        // Answered here: the call is the app's now, and the joined session —
        // not a push — says when it is over.
        if (CallStore.get(context)?.let {
                it.call.sessionId == call.sessionId && it.state == CallStore.State.ANSWERED
            } == true
        ) {
            return
        }

        // `ongoing`: someone answered. Another participant of a group call:
        // keep ringing.
        if (action == CallPushPayload.Action.ONGOING && !concernsThisUser(context, call)) return

        val reason = CallEndReason.of(action)
        val wasKnown = CallStore.isActive(context, call.sessionId)
        RingController.remoteEnded(context, call.sessionId, reason, ledger)
        // A terminal push can overtake its initiated, or the initiated can be
        // lost altogether. The user still missed the call.
        if (!wasKnown && reason.isMissed) RingController.showMissedCall(context, call)
    }

    /**
     * Whether the event concerns this device's user. Without a known uid,
     * yes: acting is safer than ignoring, because a missed dismissal leaves a
     * phone ringing for a call that is over.
     */
    private fun concernsThisUser(context: Context, call: IncomingCall): Boolean {
        val myUid = CallStore.uid(context) ?: return true
        return call.receiverUid == null || call.receiverUid == myUid
    }
}
