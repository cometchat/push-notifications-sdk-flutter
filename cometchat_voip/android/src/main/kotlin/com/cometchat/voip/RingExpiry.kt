package com.cometchat.voip

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * The backup ring deadline, for when the process holding the ring is gone.
 *
 * Armed at the call's own deadline (`initiatedAt + ringTimeout`), not "now
 * plus the timeout": FCM delivers late while a device dozes, and a relative
 * timer would restart the whole window on a call the caller gave up on.
 *
 * Inexact and allowed while idle, so it needs no SCHEDULE_EXACT_ALARM, which
 * Android 14 no longer grants freely. A few seconds late to stop a ring is
 * harmless; being unable to schedule at all would not be.
 */
internal object RingExpiry {

    private const val REQ_TIMEOUT_ALARM = 9001

    fun arm(context: Context, call: IncomingCall) {
        val remaining = call.expiresAtMs - System.currentTimeMillis()
        if (remaining <= 0L) return
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.setAndAllowWhileIdle(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + remaining + CallsConstants.RING_ALARM_SLACK_MS,
            pendingIntent(context, ActionReceiver.intent(context, CallsConstants.ACTION_TIMEOUT, call))
        )
    }

    /** Stateless: extras are ignored by `filterEquals`, so rebuilding the intent finds the alarm. */
    fun cancel(context: Context, sessionId: String) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, ActionReceiver::class.java)
            .setAction(CallsConstants.ACTION_TIMEOUT)
            .setData(CallBundles.sessionUri("timeout", sessionId))
        am.cancel(pendingIntent(context, intent))
    }

    private fun pendingIntent(context: Context, intent: Intent): PendingIntent =
        PendingIntent.getBroadcast(context, REQ_TIMEOUT_ALARM, intent, pendingIntentFlags())
}
