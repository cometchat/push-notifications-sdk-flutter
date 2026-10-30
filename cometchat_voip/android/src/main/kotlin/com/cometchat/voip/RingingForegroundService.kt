package com.cometchat.voip

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process alive from the ring until the answered call has joined.
 *
 * A process started by a full-screen intent is reclaimed a few seconds later.
 * Stopping the keep-alive when the call screen opens kills the process before
 * WebRTC has connected, so answering appears to work and then the call dies.
 * So it starts with the ring, is carried through Answer, and is released when
 * the ring genuinely ends, when the answered session joins, or at a hard cap.
 *
 * **It posts the ring.** A foreground service needs a notification, and a
 * separate one would put two entries in the tray for every call. Taking over a
 * ring posted by someone else silences it — taking over is an update, and an
 * alert-once update to a looping ring stops the ringtone. So the ring's one and
 * only post is this service's `startForeground`. On Answer the same entry
 * becomes a quiet "Connecting call…".
 *
 * Two consequences the rest of the package relies on:
 * - An app cannot cancel a foreground service's notification, so every end of
 *   the ring except Answer stops this service.
 * - The system ignores `setTimeoutAfter` on it, and the backup alarm is
 *   inexact, so while it holds the ring it also enforces the deadline itself.
 */
internal class RingingForegroundService : Service() {

    private val handler = Handler(Looper.getMainLooper())

    /** The session whose notification this service holds. */
    private var heldSessionId: String? = null
    private var connecting = false
    /** A poll since Answer saw the SDK not joined: any earlier call has been left. */
    private var sawNotJoined = false
    private var lastStartId = 0

    private val capRunnable = Runnable { onCap() }
    private val deadlineRunnable = Runnable { onDeadline() }

    private val joinCheck = object : Runnable {
        override fun run() {
            val held = heldSessionId ?: return
            if (hasJoined(held)) {
                Log.d("$held joined — releasing the keep-alive")
                release(remove = true)
            } else {
                handler.postDelayed(this, CallsConstants.JOIN_POLL_INTERVAL_MS)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        if (intent == null) {
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        val call = CallBundles.getCall(intent)
        when {
            intent.action == ACTION_STOP -> stop(intent.getStringExtra(EXTRA_SESSION_ID))
            call == null -> {
                // A service started for the foreground that never enters it
                // crashes the app, so enter it before leaving.
                if (heldSessionId == null) {
                    if (enterForeground(PLACEHOLDER_NOTIFICATION_ID, placeholder())) {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                    }
                    stopSelfResult(startId)
                }
            }
            intent.action == ACTION_CONNECTING -> connect(call)
            else -> hold(call)
        }
        // Not sticky: a redelivered start after the process died would bring
        // back a keep-alive for a call long over.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun hold(call: IncomingCall) {
        if (heldSessionId == call.sessionId) return
        NotificationChannels.ensureAll(this)
        val ring = IncomingCallNotifier.buildIncoming(this, call)
        if (!enterForeground(CallsConstants.incomingNotificationId(call.sessionId), ring)) {
            // Losing the keep-alive degrades the call; losing the ring loses it.
            IncomingCallNotifier.showIncoming(this, call)
            release(remove = false)
            return
        }
        IncomingCallNotifier.wakeIfNoFullScreen(this)
        heldSessionId = call.sessionId
        connecting = false
        restartCap()
        handler.removeCallbacks(joinCheck)
        handler.removeCallbacks(deadlineRunnable)
        handler.postDelayed(deadlineRunnable, (call.expiresAtMs - System.currentTimeMillis()).coerceAtLeast(0L))
        Log.d("keep-alive holding the ring for ${call.sessionId}")
    }

    /** Answer: the ring becomes "Connecting call…" and the window runs on through the join. */
    private fun connect(call: IncomingCall) {
        if (!enterForeground(CallsConstants.incomingNotificationId(call.sessionId), connectingNotification(call))) {
            release(remove = false)
            return
        }
        heldSessionId = call.sessionId
        connecting = true
        // Answered while another call is joined: that one has to be left first,
        // so a "joined" seen before any "not joined" is still the old call.
        sawNotJoined = !CallsSdk.isSessionJoined(this)
        restartCap()
        handler.removeCallbacks(deadlineRunnable)
        handler.removeCallbacks(joinCheck)
        handler.post(joinCheck)
    }

    /** A stop names its session, so a late stop for a replaced call cannot end the next one. */
    private fun stop(sessionId: String?) {
        val held = heldSessionId
        if (held != null && sessionId != null && sessionId != held) return
        release(remove = true)
    }

    /**
     * Leaves the foreground and stops — unless a newer start is queued, which
     * re-enters the foreground for the next call; stopping under it would crash.
     */
    private fun release(remove: Boolean) {
        handler.removeCallbacks(capRunnable)
        handler.removeCallbacks(joinCheck)
        handler.removeCallbacks(deadlineRunnable)
        if (heldSessionId != null) {
            stopForeground(if (remove) STOP_FOREGROUND_REMOVE else STOP_FOREGROUND_DETACH)
        }
        heldSessionId = null
        connecting = false
        stopSelfResult(lastStartId)
    }

    private fun restartCap() {
        handler.removeCallbacks(capRunnable)
        handler.postDelayed(capRunnable, CallsConstants.KEEP_ALIVE_CAP_MS)
    }

    private fun onDeadline() {
        val held = heldSessionId ?: return
        if (connecting || !CallStore.isRinging(this, held)) return
        Log.d("ring window closed for $held")
        RingController.timeout(this, held)
    }

    private fun onCap() {
        val held = heldSessionId
        // Still ringing only when the ring window outlasts the cap. Leave the
        // ring up then: its alarm ends it, and detached it can be cancelled.
        val stillRinging = held != null && !connecting && CallStore.isRinging(this, held)
        Log.w("keep-alive reached its cap — releasing")
        release(remove = !stillRinging)
    }

    /**
     * The SDK records a session id only for a session it prepared. A call
     * answered while another was active was never prepared, so once joined it
     * reports no id at all — and the only session it can be is this one,
     * provided the earlier call was seen to go first.
     */
    private fun hasJoined(sessionId: String): Boolean {
        if (!CallsSdk.isSessionJoined(this)) {
            sawNotJoined = true
            return false
        }
        val owned = CallsSdk.ownedSessionId(this)
        return owned == sessionId || (owned == null && sawNotJoined)
    }

    private fun enterForeground(id: Int, notification: Notification): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        } else {
            startForeground(id, notification)
        }
        true
    } catch (t: Throwable) {
        // Android 12+ refuses a foreground start from the background without
        // an allowance, which a high-priority FCM message grants.
        Log.e("could not enter the foreground: ${t.message}")
        false
    }

    /** Low importance, which is what silences the ring it replaces. Tapping it returns to the app. */
    private fun connectingNotification(call: IncomingCall): Notification {
        NotificationChannels.ensureAll(this)
        val open = IncomingCallNotifier.launchIntent(this)?.let {
            PendingIntent.getActivity(this, REQ_OPEN_APP, it, pendingIntentFlags())
        }
        return NotificationCompat.Builder(this, CallsConstants.ONGOING_CHANNEL_ID)
            .setSmallIcon(R.drawable.cometchat_voip_ic_notification_call)
            .setColor(IncomingCallTheme.resolve(this).acceptButton)
            .setContentTitle(call.callerName)
            .setContentText(getString(R.string.cometchat_voip_connecting_call_text))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .apply { if (open != null) setContentIntent(open) }
            .build()
    }

    private fun placeholder(): Notification {
        NotificationChannels.ensureAll(this)
        return NotificationCompat.Builder(this, CallsConstants.ONGOING_CHANNEL_ID)
            .setSmallIcon(R.drawable.cometchat_voip_ic_notification_call)
            .setContentText(getString(R.string.cometchat_voip_channel_incoming_name))
            .setSilent(true)
            .build()
    }

    companion object {
        private const val EXTRA_SESSION_ID = "sessionId"
        private const val ACTION_RING = "ring"
        private const val ACTION_CONNECTING = "connecting"
        private const val ACTION_STOP = "stop"
        private const val REQ_OPEN_APP = 108
        private const val PLACEHOLDER_NOTIFICATION_ID = 0x5643_F002

        /** Posts [call]'s ring as this service's notification. False when the service cannot start. */
        fun ring(context: Context, call: IncomingCall): Boolean = start(context, intent(context, call, ACTION_RING))

        fun connecting(context: Context, call: IncomingCall) {
            start(context, intent(context, call, ACTION_CONNECTING))
        }

        /** Releases the keep-alive and its notification, only if it holds [sessionId]. */
        fun stop(context: Context, sessionId: String) {
            try {
                context.startService(
                    Intent(context, RingingForegroundService::class.java)
                        .setAction(ACTION_STOP)
                        .putExtra(EXTRA_SESSION_ID, sessionId)
                )
            } catch (t: Throwable) {
                // Not running, or the app may not start a service right now.
                // Either way nothing is left holding the ring.
            }
        }

        private fun intent(context: Context, call: IncomingCall, action: String): Intent =
            CallBundles.putCall(Intent(context, RingingForegroundService::class.java).setAction(action), call)

        private fun start(context: Context, intent: Intent): Boolean = try {
            ContextCompat.startForegroundService(context, intent)
            true
        } catch (t: Throwable) {
            Log.e("could not start the keep-alive: ${t.message}")
            false
        }
    }
}
