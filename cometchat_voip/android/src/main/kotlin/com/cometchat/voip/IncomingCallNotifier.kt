package com.cometchat.voip

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.service.notification.StatusBarNotification
import android.text.SpannableString
import android.text.style.ForegroundColorSpan
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat

/**
 * Builds and posts the ring and the missed-call notifications.
 *
 * - **API 31+**: `CallStyle.forIncomingCall` — system-drawn Answer and
 *   Decline, ranked like a phone call, and exempt from Android 14 letting the
 *   user swipe ongoing notifications away.
 * - **API 26–30**: a classic notification with two actions, `CATEGORY_CALL`,
 *   ongoing, `FLAG_INSISTENT` to loop the ringtone, and a full-screen intent.
 *
 * The full-screen intent opens the ring screen on a locked device; unlocked,
 * the same notification appears as a heads-up. When Android 14+ has revoked
 * full-screen intents the heads-up is all there is, so the screen is woken
 * briefly to make it seen.
 */
internal object IncomingCallNotifier {

    private const val REQ_FULL_SCREEN = 101
    private const val REQ_CONTENT = 102
    private const val REQ_ANSWER = 103
    private const val REQ_DECLINE = 104
    private const val REQ_DELETE = 105
    private const val REQ_MISSED = 106
    private const val REQ_MISSED_SUMMARY = 107
    private const val EXTRA_MISSED_CALLER = "com.cometchat.voip.missedCaller"
    private const val WAKE_LOCK_MS = 10_000L

    fun showIncoming(context: Context, call: IncomingCall) {
        if (!canPost(context)) {
            Log.w("notifications are off — cannot ring ${call.sessionId}")
            return
        }
        NotificationChannels.ensureAll(context)
        try {
            NotificationManagerCompat.from(context)
                .notify(CallsConstants.incomingNotificationId(call.sessionId), buildIncoming(context, call))
        } catch (se: SecurityException) {
            Log.e("could not post the ring", se)
            return
        }
        wakeIfNoFullScreen(context)
    }

    /** Whether this session's ring is in the tray, whoever posted it. */
    fun isShowing(context: Context, sessionId: String): Boolean {
        val id = CallsConstants.incomingNotificationId(sessionId)
        return activeNotifications(context).any { it.id == id && it.tag == null }
    }

    /** No effect while the keep-alive service holds the ring; stopping it removes it then. */
    fun cancelIncoming(context: Context, sessionId: String) {
        NotificationManagerCompat.from(context).cancel(CallsConstants.incomingNotificationId(sessionId))
    }

    /** Without a full-screen intent the lock-screen heads-up is the only signal. */
    fun wakeIfNoFullScreen(context: Context) {
        if (!RingReadiness.canUseFullScreenIntent(context)) wakeScreenBriefly(context)
    }

    fun showMissedCall(context: Context, call: IncomingCall) {
        if (!canPost(context)) return
        NotificationChannels.ensureAll(context)
        val open = launchIntent(context)?.let {
            PendingIntent.getActivity(context, REQ_MISSED, it, pendingIntentFlags())
        }
        val notification = NotificationCompat.Builder(context, CallsConstants.MISSED_CHANNEL_ID)
            .setSmallIcon(R.drawable.cometchat_voip_ic_notification_call_missed)
            .setColor(IncomingCallTheme.resolve(context).declineButton)
            .setContentTitle(context.getString(R.string.cometchat_voip_missed_call_title))
            .setContentText(
                context.getString(R.string.cometchat_voip_missed_call_text, call.callerName, callTypeLabel(context, call))
            )
            .setLargeIcon(initialsBitmap(context, call.initials))
            .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setAutoCancel(true)
            .setGroup(CallsConstants.MISSED_GROUP_KEY)
            // Read back by the summary, which is rebuilt from the tray rather than remembered.
            .addExtras(Bundle().apply { putString(EXTRA_MISSED_CALLER, call.callerName) })
            .apply { if (open != null) setContentIntent(open) }
            .build()
        try {
            NotificationManagerCompat.from(context)
                .notify(call.sessionId, CallsConstants.MISSED_NOTIFICATION_ID, notification)
        } catch (se: SecurityException) {
            Log.e("could not post the missed call", se)
            return
        }
        updateMissedSummary(context, call)
    }

    /**
     * Keeps the missed-call summary in step with the tray. It is counted from
     * the tray, so it survives the process dying between calls, and posted from
     * the first missed call: a group without a summary is folded into the app's
     * other notifications as soon as another one arrives.
     */
    private fun updateMissedSummary(context: Context, posted: IncomingCall) {
        val callers = LinkedHashMap<String, String>()
        activeNotifications(context)
            .filter {
                it.id == CallsConstants.MISSED_NOTIFICATION_ID && it.tag != null &&
                    it.notification.group == CallsConstants.MISSED_GROUP_KEY
            }
            .forEach { callers[it.tag] = it.notification.extras.getString(EXTRA_MISSED_CALLER).orEmpty() }
        // The tray updates asynchronously, so the call just posted may not be in it yet.
        callers[posted.sessionId] = posted.callerName

        val count = callers.size
        val names = callers.values.filter { it.isNotBlank() }.distinct().joinToString(", ")
        val open = launchIntent(context)?.let {
            PendingIntent.getActivity(context, REQ_MISSED_SUMMARY, it, pendingIntentFlags())
        }
        val summary = NotificationCompat.Builder(context, CallsConstants.MISSED_CHANNEL_ID)
            .setSmallIcon(R.drawable.cometchat_voip_ic_notification_call_missed)
            .setColor(IncomingCallTheme.resolve(context).declineButton)
            .setContentTitle(
                context.resources.getQuantityString(R.plurals.cometchat_voip_missed_calls_summary, count, count)
            )
            .apply { if (names.isNotEmpty()) setContentText(names) }
            .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setGroup(CallsConstants.MISSED_GROUP_KEY)
            .setGroupSummary(true)
            // The missed call itself already alerted.
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .apply { if (open != null) setContentIntent(open) }
            .build()
        try {
            NotificationManagerCompat.from(context).notify(CallsConstants.MISSED_SUMMARY_NOTIFICATION_ID, summary)
        } catch (se: SecurityException) {
            Log.e("could not post the missed-call summary", se)
        }
    }

    fun canPost(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    /** The ring itself, posted here or as the keep-alive service's own notification. */
    fun buildIncoming(context: Context, call: IncomingCall): Notification {
        // Answering while another call is live leaves that call: the Calls SDK
        // holds one session at a time. The ring is the only place the user can
        // be told before they tap.
        val endsActiveCall = RingController.liveSession(context, call.sessionId) != null

        // In `autoCustomScreen` the full-screen alert and its tap open the
        // app, which draws its own ring screen; everything else about the ring
        // — this notification, its Answer and Decline, the ringtone, the
        // expiry — stays ours.
        fun ringScreen(): Intent = (
            if (VoipConfig.restore(context)?.opensAppRingScreen == true) {
                appRingScreen(context, call, endsActiveCall)
            } else {
                null
            }
            ) ?: IncomingCallActivity.intent(context, call)

        // Per session, because the intent that opens the app carries no data
        // URI to tell two calls apart. See CallsConstants.ringRequestCode.
        val fullScreen = PendingIntent.getActivity(
            context,
            CallsConstants.ringRequestCode(REQ_FULL_SCREEN, call.sessionId),
            ringScreen(),
            pendingIntentFlags()
        )
        // Tapping the body opens the same screen a locked device shows.
        val content = PendingIntent.getActivity(
            context,
            CallsConstants.ringRequestCode(REQ_CONTENT, call.sessionId),
            ringScreen(),
            pendingIntentFlags()
        )
        // Answer goes through the trampoline, which records the answer and asks
        // for permissions before opening the app. An activity hop from a
        // notification is allowed on Android 12+; a broadcast hop is not.
        // NO_USER_ACTION stops an app already in a call from dropping into
        // picture-in-picture as the user answers the next one.
        val answer = PendingIntent.getActivity(
            context,
            REQ_ANSWER,
            AnswerTrampolineActivity.intent(context, call)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_USER_ACTION),
            pendingIntentFlags()
        )
        val decline = PendingIntent.getBroadcast(
            context, REQ_DECLINE, ActionReceiver.intent(context, CallsConstants.ACTION_DECLINE, call), pendingIntentFlags()
        )
        // Fires on a swipe-away and when setTimeoutAfter expires.
        val delete = PendingIntent.getBroadcast(
            context, REQ_DELETE, ActionReceiver.intent(context, CallsConstants.ACTION_DISMISS, call), pendingIntentFlags()
        )

        val avatar = initialsBitmap(context, call.initials)
        val person = Person.Builder()
            .setName(call.callerName)
            .setIcon(IconCompat.createWithBitmap(avatar))
            .setImportant(true)
            .build()

        val builder = NotificationCompat.Builder(context, CallsConstants.INCOMING_CHANNEL_ID)
            .setSmallIcon(R.drawable.cometchat_voip_ic_notification_call)
            .setColor(IncomingCallTheme.resolve(context).acceptButton)
            .setContentTitle(call.callerName)
            .setContentText(
                if (endsActiveCall) {
                    context.getString(R.string.cometchat_voip_answer_ends_current_call)
                } else {
                    context.getString(R.string.cometchat_voip_incoming_call_text, callTypeLabel(context, call))
                }
            )
            .setLargeIcon(avatar)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            // A redelivered duplicate must not restart the ringtone.
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            // The last resort: the system retires it even if every timer of ours is killed.
            .setTimeoutAfter((call.expiresAtMs - System.currentTimeMillis()).coerceAtLeast(1L))
            .setContentIntent(content)
            .setDeleteIntent(delete)
            .setFullScreenIntent(fullScreen, true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setStyle(
                NotificationCompat.CallStyle.forIncomingCall(person, decline, answer)
                    .setIsVideo(call.isVideo)
                    // Hints: some system UIs keep their own colours.
                    .setAnswerButtonColorHint(IncomingCallTheme.resolve(context).acceptButton)
                    .setDeclineButtonColorHint(IncomingCallTheme.resolve(context).declineButton)
            )
            builder.addPerson(person)
        } else {
            builder.addAction(
                NotificationCompat.Action.Builder(
                    IconCompat.createWithResource(context, R.drawable.cometchat_voip_ic_call_end),
                    colored(
                        context.getString(R.string.cometchat_voip_action_decline),
                        IncomingCallTheme.resolve(context).declineButton
                    ),
                    decline
                ).build()
            )
            builder.addAction(
                NotificationCompat.Action.Builder(
                    IconCompat.createWithResource(context, R.drawable.cometchat_voip_ic_call),
                    colored(
                        context.getString(R.string.cometchat_voip_action_answer),
                        IncomingCallTheme.resolve(context).acceptButton
                    ),
                    answer
                ).build()
            )
        }

        val notification = builder.build()
        // Loop the ringtone and vibration until the notification goes.
        notification.flags = notification.flags or Notification.FLAG_INSISTENT
        return notification
    }

    /**
     * The app's launcher activity, opened to ring [call] itself.
     *
     * No data URI, unlike every other intent here: Flutter's deep linking is
     * on by default, reads one on the intent that launched the activity as a
     * route, and pushes a route no app has — which throws from
     * `_WidgetsAppState._onUnknownRoute` on every ring, in every app. The
     * session travels in the extras, and the PendingIntent's request code is
     * what keeps two calls apart.
     *
     * Null when the package cannot find a launcher activity to open, which
     * leaves the ring with the package's own screen: an app with no launcher
     * activity has no Flutter screen to draw either, and a ring with no
     * full-screen alert at all would be the one failure the user cannot see
     * past.
     */
    private fun appRingScreen(context: Context, call: IncomingCall, endsActiveCall: Boolean): Intent? =
        launchIntent(context)
            ?.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            ?.let { CallBundles.putCall(it, call) }
            ?.putExtra(CallBundles.EXTRA_RING_SCREEN, true)
            ?.putExtra(CallBundles.EXTRA_ENDS_ACTIVE_CALL, endsActiveCall)

    /** The app's launcher activity, opened to the front. */
    fun launchIntent(context: Context): Intent? =
        context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    fun callTypeLabel(context: Context, call: IncomingCall): String = context.getString(
        if (call.isVideo) R.string.cometchat_voip_call_type_video else R.string.cometchat_voip_call_type_audio
    )

    @Suppress("DEPRECATION")
    private fun wakeScreenBriefly(context: Context) {
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isInteractive) return
            pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "cometchat-voip:screen_wake"
            ).acquire(WAKE_LOCK_MS)
        } catch (t: Throwable) {
            Log.w("could not wake the screen: ${t.message}")
        }
    }

    private fun activeNotifications(context: Context): List<StatusBarNotification> = runCatching {
        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).activeNotifications.toList()
    }.getOrDefault(emptyList())

    private fun colored(text: CharSequence, color: Int): CharSequence =
        SpannableString(text).apply { setSpan(ForegroundColorSpan(color), 0, length, 0) }

    /** A circle with the caller's initials: the large icon and the Person avatar. */
    fun initialsBitmap(context: Context, initials: String): Bitmap {
        val size = (96 * context.resources.displayMetrics.density).toInt().coerceAtLeast(96)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val colors = IncomingCallTheme.resolve(context)
        val background = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = colors.avatarBackground
        }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, background)
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = colors.avatarText
            textSize = size * 0.42f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val y = size / 2f - (text.descent() + text.ascent()) / 2f
        canvas.drawText(initials, size / 2f, y, text)
        return bitmap
    }
}
