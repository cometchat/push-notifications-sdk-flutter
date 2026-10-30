package com.cometchat.push_notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Builds and posts chat notifications.
 *
 * One notification per conversation, expanding into the recent messages rather
 * than stacking, with the sender's avatar and a summary that collapses several
 * conversations into one entry. This mirrors
 * what the native Android push SDK does, because the two should be
 * indistinguishable to a user with both apps installed.
 *
 * Every id is derived from the conversation key, so a second message finds and
 * replaces the first notification instead of posting beside it.
 */
internal class NotificationRenderer(
    private val context: Context,
    private val config: NotificationConfig
) {

    private companion object {
        const val GROUP_KEY_PREFIX = "cometchat_group_"
    }

    private val manager = NotificationManagerCompat.from(context)

    init {
        createChannel()
    }

    /** The notification id for [conversationKey]. */
    fun notificationIdFor(conversationKey: String): Int = conversationKey.hashCode()

    /**
     * Posts a notification for one message.
     *
     * Blocking — it downloads the avatar — so call it off the main thread.
     */
    fun show(message: PushMessage) {
        val conversationKey = message.conversationKey
        val notificationId = notificationIdFor(conversationKey)
        val groupKey = GROUP_KEY_PREFIX + conversationKey

        // A group message says who sent it; a 1:1 message's title already does.
        val line = if (message.isGroup) {
            "${message.senderName.ifBlank { message.sender }}: ${message.body}"
        } else {
            message.body
        }
        val lines = NotificationStore.addLine(conversationKey, line)

        val icon = config.resolveSmallIcon(context)
        val style = NotificationCompat.InboxStyle()
        lines.forEach { style.addLine(it) }
        if (lines.size > 1) style.setSummaryText("${lines.size} messages")

        val builder = NotificationCompat.Builder(context, config.channelId)
            .setSmallIcon(icon)
            .setContentTitle(message.title)
            .setContentText(line)
            .setStyle(style)
            .setAutoCancel(true)
            .setGroup(groupKey)
            .setNumber(lines.size)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)

        AvatarLoader.load(message.senderAvatar)?.let { builder.setLargeIcon(it) }
        tapIntent(message, notificationId)?.let { builder.setContentIntent(it) }

        if (!post(notificationId, builder.build())) return
        post(groupKey.hashCode(), summary(groupKey, icon))
        NotificationStore.rememberPosted(groupKey.hashCode())
    }

    /** Cancels [conversationKey]'s notification and forgets its messages. */
    fun cancel(conversationKey: String) {
        val id = notificationIdFor(conversationKey)
        manager.cancel(id)
        NotificationStore.forgetPosted(id)
        NotificationStore.clearConversation(conversationKey)
    }

    /**
     * Cancels every notification this package posted.
     *
     * Deliberately not `cancelAll()`, which would also take down notifications
     * the host app posted for its own reasons.
     */
    fun cancelAll() {
        NotificationStore.takeAllPostedIds().forEach { manager.cancel(it) }
    }

    // ── Internals ──

    /**
     * Posts [notification], returning whether it went out.
     *
     * `notify` throws when the POST_NOTIFICATIONS permission is missing on
     * API 33+, which is a state the app can legitimately be in; a dropped
     * notification is the correct outcome there, not a crash.
     */
    private fun post(id: Int, notification: android.app.Notification): Boolean = try {
        manager.notify(id, notification)
        NotificationStore.rememberPosted(id)
        true
    } catch (e: SecurityException) {
        Log.w("Notification not posted — POST_NOTIFICATIONS is not granted")
        false
    }

    private fun summary(groupKey: String, icon: Int): android.app.Notification =
        NotificationCompat.Builder(context, config.channelId)
            .setSmallIcon(icon)
            .setStyle(NotificationCompat.InboxStyle().setSummaryText("New messages"))
            .setGroup(groupKey)
            .setGroupSummary(true)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

    /**
     * The tap intent: the host app's own launcher activity, carrying the
     * conversation as extras.
     *
     * Reusing the launcher activity rather than shipping one of our own means
     * the app's existing task, theme and back stack behaviour all apply, and
     * the tap lands wherever the app normally starts.
     */
    private fun tapIntent(message: PushMessage, notificationId: Int): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (launch == null) {
            Log.w("No launcher activity — notification posted without a tap action")
            return null
        }
        launch.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(Extras.IS_COMETCHAT, true)
            putExtra(Extras.CONVERSATION_ID, message.conversationKey)
            putExtra(Extras.RECEIVER_TYPE, message.receiverType)
            putExtra(Extras.SENDER, message.sender)
            putExtra(Extras.SENDER_NAME, message.senderName)
            putExtra(Extras.SENDER_AVATAR, message.senderAvatar)
            putExtra(Extras.MESSAGE_ID, message.messageId)
            putExtra(Extras.NOTIFICATION_ID, notificationId)
        }
        return PendingIntent.getActivity(context, notificationId, launch, immutableFlags())
    }

    private fun immutableFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

    /**
     * Creates the channel if it is missing.
     *
     * Android freezes a channel's importance, sound and vibration at creation
     * and ignores every later change, because a user who has tuned the channel
     * outranks the app. Changing any of them therefore needs a new channel id.
     */
    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (manager == null) {
            Log.e("NotificationManager unavailable — channel not created")
            return
        }
        val channel = NotificationChannel(
            config.channelId,
            config.channelName,
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = config.channelDescription
            enableVibration(true)
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)
    }
}
