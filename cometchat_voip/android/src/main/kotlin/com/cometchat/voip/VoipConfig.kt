package com.cometchat.voip

import android.content.Context

/**
 * What `CometChatVoip.init` configured, persisted.
 *
 * A push, a notification action or an alarm can start a process long after
 * the app that configured the package is gone, so nothing the ringer needs can
 * live only in memory.
 */
internal data class VoipConfig(
    val appId: String,
    val region: String,
    val clientHost: String?,
    val showMissedCallNotification: Boolean,
    val requestCallPermissions: Boolean,
    /**
     * `CometChatVoipConfig.callMode`: `auto`, `autoCustomScreen` or `manual`.
     *
     * Only `autoCustomScreen` changes anything here — the ring's full-screen
     * intent and its tap open the app instead of [IncomingCallActivity]. The
     * ringer never runs at all in `manual`, where Dart does not hand it the
     * push.
     */
    val callMode: String = MODE_AUTO,
    /**
     * `CometChatVoipConfig.defaultRingTimeout`: how long a push without its
     * own `ringTimeout` rings. It used to be serialised and never read, so
     * every such push rang for 45 s whatever the app configured.
     */
    val defaultRingTimeoutMs: Long = CallsConstants.DEFAULT_RING_TIMEOUT_MS
) {

    /** Whether the ring opens the app's own screen rather than the package's. */
    val opensAppRingScreen: Boolean get() = callMode == MODE_AUTO_CUSTOM_SCREEN

    companion object {
        const val MODE_AUTO = "auto"
        const val MODE_AUTO_CUSTOM_SCREEN = "autoCustomScreen"

        private const val PREFS = "cometchat_voip_config"
        private const val KEY_APP_ID = "appId"
        private const val KEY_REGION = "region"
        private const val KEY_CLIENT_HOST = "clientHost"
        private const val KEY_SHOW_MISSED = "showMissedCallNotification"
        private const val KEY_REQUEST_PERMISSIONS = "requestCallPermissions"
        private const val KEY_DEFAULT_RING_TIMEOUT = "defaultRingTimeoutMs"
        private const val KEY_CALL_MODE = "callMode"

        @Volatile
        private var cached: VoipConfig? = null

        fun fromMap(map: Map<*, *>): VoipConfig? {
            val appId = (map["appId"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val region = (map["region"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            return VoipConfig(
                appId = appId,
                region = region,
                clientHost = (map["clientHost"] as? String)?.takeIf { it.isNotBlank() },
                showMissedCallNotification = map["showMissedCallNotification"] as? Boolean ?: true,
                requestCallPermissions = map["requestCallPermissions"] as? Boolean ?: true,
                callMode = (map["callMode"] as? String)?.takeIf { it.isNotBlank() } ?: MODE_AUTO,
                defaultRingTimeoutMs = ringTimeout((map["defaultRingTimeoutMs"] as? Number)?.toLong())
            )
        }

        /** A configured window outside the payload's own bounds falls back to 45 s. */
        private fun ringTimeout(ms: Long?): Long =
            ms?.takeIf { it in CallsConstants.MIN_RING_TIMEOUT_MS..CallsConstants.MAX_RING_TIMEOUT_MS }
                ?: CallsConstants.DEFAULT_RING_TIMEOUT_MS

        fun save(context: Context, config: VoipConfig) {
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_APP_ID, config.appId)
                .putString(KEY_REGION, config.region)
                .putString(KEY_CLIENT_HOST, config.clientHost)
                .putBoolean(KEY_SHOW_MISSED, config.showMissedCallNotification)
                .putBoolean(KEY_REQUEST_PERMISSIONS, config.requestCallPermissions)
                .putString(KEY_CALL_MODE, config.callMode)
                .putLong(KEY_DEFAULT_RING_TIMEOUT, config.defaultRingTimeoutMs)
                .apply()
            cached = config
        }

        /** The configuration for this process, or null when `init` has never run on this install. */
        fun restore(context: Context): VoipConfig? {
            cached?.let { return it }
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val appId = prefs.getString(KEY_APP_ID, null) ?: return null
            val region = prefs.getString(KEY_REGION, null) ?: return null
            return VoipConfig(
                appId = appId,
                region = region,
                clientHost = prefs.getString(KEY_CLIENT_HOST, null),
                showMissedCallNotification = prefs.getBoolean(KEY_SHOW_MISSED, true),
                requestCallPermissions = prefs.getBoolean(KEY_REQUEST_PERMISSIONS, true),
                callMode = prefs.getString(KEY_CALL_MODE, MODE_AUTO) ?: MODE_AUTO,
                defaultRingTimeoutMs = ringTimeout(
                    prefs.getLong(KEY_DEFAULT_RING_TIMEOUT, CallsConstants.DEFAULT_RING_TIMEOUT_MS)
                )
            ).also { cached = it }
        }
    }
}
