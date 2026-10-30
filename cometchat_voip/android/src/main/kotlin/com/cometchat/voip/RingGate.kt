package com.cometchat.voip

import android.content.Context

/**
 * Whether a call push deserves to ring at all.
 *
 * Every gate reads persisted state only. This runs on a process the system
 * started to deliver the push, where no SDK is logged in yet, so "who am I"
 * cannot be asked of the Calls SDK.
 */
internal object RingGate {

    sealed interface Decision {
        object Ring : Decision

        /**
         * [markTerminal] records the session so a later duplicate cannot
         * revive it. [declineAs] is the status sent to the caller — `busy` for
         * a call refused because this device already has two — and null for a
         * drop the caller is told nothing about.
         */
        data class Drop(
            val reason: String,
            val markTerminal: Boolean = false,
            val missed: Boolean = false,
            val declineAs: String? = null
        ) : Decision
    }

    fun decide(context: Context, call: IncomingCall, now: Long = System.currentTimeMillis()): Decision {
        val myUid = CallStore.uid(context)

        // The backend fans a call out to every device of every participant,
        // the caller's own included. Ringing the caller for their own call is
        // the most visible bug there is.
        if (myUid != null && call.callerUid == myUid) {
            return Decision.Drop("self-ring: the caller is this user")
        }

        // Addressed to someone else. Only when both sides are known: a missing
        // receiver or an unknown local uid is not evidence of a mismatch.
        if (myUid != null && call.receiverUid != null && call.isPeerCall && call.receiverUid != myUid) {
            return Decision.Drop("addressed to ${call.receiverUid}, not this user")
        }

        // A terminal push overtook its initiated, or this is a redelivery.
        if (CallStore.wasTerminal(context, call.sessionId)) {
            return Decision.Drop("already over (${CallStore.terminalReason(context, call.sessionId)})")
        }

        // FCM holds pushes while a device dozes, so one can arrive long after
        // the caller gave up. Ringing then calls a phone nobody is waiting on.
        if (now >= call.expiresAtMs) {
            return Decision.Drop("expired ${now - call.expiresAtMs}ms ago", markTerminal = true, missed = true)
        }

        // A call already rings here and the user has not acted on it: the new
        // one is refused as busy without ringing, and shown as a missed call.
        // A ring is only ever ended by the user, its caller or its own expiry,
        // never replaced by the next push — replacing it dropped the first
        // call silently (no end reported, so the app went on treating it as
        // ringing) while its caller rang on. This holds with a live call too:
        // one live and one ringing over it are as many as the user can act on
        // (answering the second ends the first, so a third has nowhere to go),
        // and the live call can be one this device placed, which the answered
        // marker does not know. A ring record past its expiry is stale (a
        // process killed mid-ring) and does not count.
        val active = CallStore.get(context)
        val ringing = active?.takeIf {
            it.state == CallStore.State.RINGING && it.call.sessionId != call.sessionId && now < it.call.expiresAtMs
        }
        if (ringing != null) {
            val live = RingController.liveSession(context, call.sessionId)
            return Decision.Drop(
                if (live != null) {
                    "busy: a call is live and ${ringing.call.sessionId} is already ringing over it"
                } else {
                    "busy: ${ringing.call.sessionId} is already ringing"
                },
                markTerminal = true,
                missed = true,
                declineAs = CallsConstants.CALL_STATUS_BUSY
            )
        }

        // A call this user placed is still ringing: the Calls SDK holds a
        // session nobody has joined that is not the ringing call's own
        // connect-while-ringing. Refused as busy rather than rung, because
        // answering it would end the call being placed.
        //
        // Three things have to agree, because each on its own is wrong:
        // `active`, since the session id outlives the session it named; not
        // `joined`, since a live call is the second-call case above, which
        // rings; and a *fresh* report, since a process killed mid-call never
        // says the session went, and an old `active` would make every later
        // call busy for ever.
        // A session left behind by a ring that ended while it was still
        // connecting is not a call being placed: release it and ring.
        if (RingController.releaseLeftoverSession(context, call.sessionId)) {
            return Decision.Ring
        }

        val owned = CallsSdk.ownedSessionId(context)
        val age = SessionState.reportedAgeMs(context, now)
        if (owned != null && CallsSdk.isSessionActive(context) && !CallsSdk.isSessionJoined(context) &&
            owned != call.sessionId && owned != active?.call?.sessionId &&
            age != null && age <= CallsConstants.OUTGOING_RING_FRESHNESS_MS
        ) {
            return Decision.Drop(
                "busy: this device is placing $owned",
                markTerminal = true,
                missed = true,
                declineAs = CallsConstants.CALL_STATUS_BUSY
            )
        }

        return Decision.Ring
    }
}
