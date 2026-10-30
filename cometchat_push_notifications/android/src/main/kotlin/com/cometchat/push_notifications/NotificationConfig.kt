package com.cometchat.push_notifications

import android.content.Context

/**
 * The Dart-side configuration, as the native side needs it.
 *
 * Built from the map [CometchatPushNotificationsPlugin] receives from
 * `initialize`, so the defaults here only apply to a field Dart omitted.
 */
internal data class NotificationConfig(
    val channelId: String,
    val channelName: String,
    val channelDescription: String,
    val smallIconName: String?,
    val showInAppNotifications: Boolean
) {
    companion object {
        fun fromMap(map: Map<*, *>): NotificationConfig = NotificationConfig(
            channelId = map["androidChannelId"] as? String ?: "cometchat_messages",
            channelName = map["androidChannelName"] as? String ?: "Chat Messages",
            channelDescription = map["androidChannelDescription"] as? String
                ?: "New message notifications",
            smallIconName = map["androidSmallIcon"] as? String,
            showInAppNotifications = map["showInAppNotifications"] as? Boolean ?: false
        )
    }

    /**
     * The drawable to use as the small icon.
     *
     * Falls back to the app's launcher icon when no drawable named
     * [smallIconName] exists. Android draws the small icon as a flat
     * silhouette, so a launcher icon becomes a grey blob — which is ugly, but
     * still better than the notification failing to post, which is what
     * passing an invalid resource id does.
     */
    fun resolveSmallIcon(context: Context): Int {
        if (!smallIconName.isNullOrBlank()) {
            val id = context.resources.getIdentifier(
                smallIconName, "drawable", context.packageName
            )
            if (id != 0) return id
            Log.w("No drawable named '$smallIconName'; falling back to the launcher icon")
        }
        return context.applicationInfo.icon
    }
}
