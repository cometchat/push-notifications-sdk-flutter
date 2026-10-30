package com.cometchat.voip

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Color
import android.media.AudioAttributes
import android.media.RingtoneManager

/**
 * The ring, what it becomes once answered, and missed calls.
 *
 * A channel belongs to the user once it exists — its importance, sound and
 * vibration can no longer be changed by the app — so each id carries a
 * version suffix, and changing a default means a new id.
 */
internal object NotificationChannels {

    /** Ring-like: wait, buzz, pause, buzz. */
    private val INCOMING_CALL_VIBRATION = longArrayOf(0, 1000, 1000, 1000, 1000, 1000)

    /** Idempotent; cheap enough to run before every post. */
    fun ensureAll(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (nm.getNotificationChannel(CallsConstants.INCOMING_CHANNEL_ID) == null) {
            val audio = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            nm.createNotificationChannel(
                NotificationChannel(
                    CallsConstants.INCOMING_CHANNEL_ID,
                    context.getString(R.string.cometchat_voip_channel_incoming_name),
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = context.getString(R.string.cometchat_voip_channel_incoming_description)
                    setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE), audio)
                    enableVibration(true)
                    vibrationPattern = INCOMING_CALL_VIBRATION
                    enableLights(true)
                    lightColor = Color.GREEN
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(false)
                }
            )
        }

        // Low importance on purpose. The keep-alive service holds the ring, and
        // an app cannot cancel a foreground service's notification; moving it
        // to a channel that does not alert is what stops the ringtone.
        if (nm.getNotificationChannel(CallsConstants.ONGOING_CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CallsConstants.ONGOING_CHANNEL_ID,
                    context.getString(R.string.cometchat_voip_channel_ongoing_name),
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = context.getString(R.string.cometchat_voip_channel_ongoing_description)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(false)
                }
            )
        }

        if (nm.getNotificationChannel(CallsConstants.MISSED_CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CallsConstants.MISSED_CHANNEL_ID,
                    context.getString(R.string.cometchat_voip_channel_missed_name),
                    NotificationManager.IMPORTANCE_DEFAULT
                ).apply {
                    description = context.getString(R.string.cometchat_voip_channel_missed_description)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(true)
                }
            )
        }
    }
}
