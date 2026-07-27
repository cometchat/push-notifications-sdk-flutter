package com.cometchat.push_notifications

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Handles the Decline action from the call notification WITHOUT
 * launching the host app's UI.
 *
 * Flow:
 * 1. Dismiss the local call notification.
 * 2. If the Flutter engine is alive (app in background or running),
 *    invoke a method on the plugin's channel to ask Dart to reject the
 *    call via the CometChat SDK.
 * 3. If no engine is alive (app fully killed), the notification is just
 *    dismissed and the call times out on the server.
 */
class CallActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_DECLINE = "com.cometchat.push_notifications.ACTION_DECLINE"
        const val EXTRA_SESSION_ID = "sessionId"
        private const val TAG = "CometChatNotifs"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DECLINE) return

        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: return
        Log.d(TAG, "CallActionReceiver: decline session=$sessionId")

        // Dismiss the notification immediately.
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(sessionId.hashCode())

        // Forward the decline to Dart via the plugin's method channel.
        // The Dart side will call CometChat.rejectCall(). This only works
        // if the Flutter engine is alive (app running or backgrounded).
        // If the app is fully killed, this is a no-op and the server will
        // time out the call.
        Handler(Looper.getMainLooper()).post {
            CometchatPushNotificationsPlugin.staticChannel
                ?.invokeMethod("onDeclineCall", mapOf("sessionId" to sessionId))
        }
    }
}
