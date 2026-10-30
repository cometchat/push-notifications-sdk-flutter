package com.cometchat.voip

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The ring's non-screen actions: Decline, the backup expiry alarm, and the
 * notification going away — its delete intent fires on a swipe and when
 * `setTimeoutAfter` expires.
 */
internal class ActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val call = CallBundles.getCall(intent) ?: return
        when (intent.action) {
            CallsConstants.ACTION_DECLINE -> RingController.decline(context, call.sessionId)
            // The alarm and the dismissal mean the same: the window closed unanswered.
            CallsConstants.ACTION_TIMEOUT,
            CallsConstants.ACTION_DISMISS -> if (CallStore.isRinging(context, call.sessionId)) {
                RingController.timeout(context, call.sessionId)
            } else {
                RingController.stopRinging(context, call.sessionId, answered = CallStore.isActive(context, call.sessionId))
            }
        }
    }

    companion object {
        /**
         * A per-session data URI, so PendingIntents never collide across
         * sessions and an alarm can be cancelled by rebuilding its intent.
         */
        fun intent(context: Context, action: String, call: IncomingCall): Intent =
            Intent(context, ActionReceiver::class.java)
                .setAction(action)
                .setData(CallBundles.sessionUri(action.substringAfterLast('_').lowercase(), call.sessionId))
                .also { CallBundles.putCall(it, call) }
    }
}
