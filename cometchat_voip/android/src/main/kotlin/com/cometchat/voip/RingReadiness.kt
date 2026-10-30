package com.cometchat.voip

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat

/**
 * Why a call would not ring here. Every one of these silences a call with no
 * error anywhere, which is why they are named.
 */
internal object RingReadiness {

    const val READY = "ready"
    const val NOTIFICATIONS_OFF = "notificationsOff"
    const val CHANNEL_MUTED = "channelMuted"
    const val FULL_SCREEN_INTENT_DENIED = "fullScreenIntentDenied"
    const val DO_NOT_DISTURB = "doNotDisturb"
    const val MICROPHONE_DENIED = "microphoneDenied"

    fun check(context: Context): String {
        if (!IncomingCallNotifier.canPost(context)) return NOTIFICATIONS_OFF
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = nm.getNotificationChannel(CallsConstants.INCOMING_CHANNEL_ID)
        if (channel != null && channel.importance < NotificationManager.IMPORTANCE_HIGH) return CHANNEL_MUTED
        if (!canUseFullScreenIntent(context)) return FULL_SCREEN_INTENT_DENIED
        val filter = nm.currentInterruptionFilter
        if (filter != NotificationManager.INTERRUPTION_FILTER_ALL &&
            filter != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
        ) {
            return DO_NOT_DISTURB
        }
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED &&
            microphoneAskedBefore(context)
        ) {
            return MICROPHONE_DENIED
        }
        return READY
    }

    /** The settings page that fixes [readiness], or null when there is none. */
    fun settingsIntent(context: Context, readiness: String): Intent? = when (readiness) {
        NOTIFICATIONS_OFF ->
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        CHANNEL_MUTED ->
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                .putExtra(Settings.EXTRA_CHANNEL_ID, CallsConstants.INCOMING_CHANNEL_ID)
        FULL_SCREEN_INTENT_DENIED ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                    .setData(Uri.parse("package:${context.packageName}"))
            } else {
                null
            }
        // A global mode, not an app setting.
        DO_NOT_DISTURB -> Intent(Settings.ACTION_ZEN_MODE_PRIORITY_SETTINGS)
        MICROPHONE_DENIED ->
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${context.packageName}"))
        else -> null
    }?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** Below Android 14 the permission does not exist and full-screen intents always work. */
    fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return nm.canUseFullScreenIntent()
    }

    /**
     * An ungranted microphone is only a problem once the user has refused it:
     * before that, answering asks. The trampoline records the first ask.
     */
    private fun microphoneAskedBefore(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_MIC_ASKED, false)

    fun recordMicrophoneAsked(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_MIC_ASKED, true).apply()
    }

    /** Redacted by construction: no token, no auth value, no payload. */
    fun diagnostics(context: Context): Map<String, Any?> {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val config = VoipConfig.restore(context)
        val active = CallStore.get(context)
        return linkedMapOf(
            "platform" to "android",
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "hasPersistedConfig" to (config != null),
            "appId" to config?.appId,
            "region" to config?.region,
            "hasClientHost" to (config?.clientHost != null),
            "hasDeviceUid" to (CallStore.uid(context) != null),
            "callsSdkLoggedIn" to CallsSdk.isLoggedIn(context),
            "notificationsEnabled" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
            "incomingChannelImportance" to nm.getNotificationChannel(CallsConstants.INCOMING_CHANNEL_ID)?.importance,
            "canUseFullScreenIntent" to canUseFullScreenIntent(context),
            "interruptionFilter" to nm.currentInterruptionFilter,
            "microphoneGranted" to (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED),
            "activeCall" to active?.let { "${it.call.sessionId} ${it.state.name.lowercase()}" },
            "ringReadiness" to check(context)
        )
    }

    private const val PREFS = "cometchat_voip_readiness"
    private const val KEY_MIC_ASKED = "microphoneAsked"
}
