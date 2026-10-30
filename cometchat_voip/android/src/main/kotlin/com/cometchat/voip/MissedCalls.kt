package com.cometchat.voip

import android.content.Context

/**
 * Whether a missed call was really missed, once. Several terminal signals can
 * report the same call — the push, the Calls SDK, the alarm — and the user
 * should see one notification.
 */
internal object MissedCalls {

    private const val MAX_REMEMBERED = 20
    private val notified = LinkedHashSet<String>()

    fun shouldNotify(context: Context, call: IncomingCall): Boolean {
        // A call answered on this device is not missed, whatever ends it.
        if (CallStore.get(context)?.let {
                it.call.sessionId == call.sessionId && it.state == CallStore.State.ANSWERED
            } == true
        ) {
            return false
        }
        synchronized(notified) {
            if (!notified.add(call.sessionId)) return false
            while (notified.size > MAX_REMEMBERED) notified.remove(notified.first())
        }
        return true
    }
}
