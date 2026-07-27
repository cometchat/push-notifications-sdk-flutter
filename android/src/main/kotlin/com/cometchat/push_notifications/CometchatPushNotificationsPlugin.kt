package com.cometchat.push_notifications

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/** CometchatPushNotificationsPlugin */
class CometchatPushNotificationsPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    /** Buffered call intent data — consumed once via getLaunchCallDetails. */
    private var pendingCallDetails: Map<String, Any?>? = null

    companion object {
        private const val CALL_CHANNEL_ID = "cometchat_incoming_calls_v3"
        private const val CALL_CHANNEL_NAME = "Incoming Calls"

        /** Static reference to the plugin's method channel so the */
        /** [CallActionReceiver] can invoke Dart methods. */
        var staticChannel: MethodChannel? = null
            private set
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "cometchat_push_notifications")
        channel.setMethodCallHandler(this)
        staticChannel = channel
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "showCallNotification" -> showCallNotification(call, result)
            "cancelCallNotification" -> cancelCallNotification(call, result)
            "dismissIncomingCallActivity" -> {
                // Caller cancelled/ended before answer → close the locked
                // call screen (if showing) so the device returns to the lock
                // screen. Does NOT run for the connected/ongoing case.
                IncomingCallActivity.dismiss()
                result.success(true)
            }
            "getLaunchCallDetails" -> getLaunchCallDetails(result)
            "checkCallPermissions" -> checkCallPermissions(result)
            "openAutoStartSettings" -> openAutoStartSettings(result)
            "openFullScreenIntentSettings" -> openFullScreenIntentSettings(result)
            "openOverlaySettings" -> openOverlaySettings(result)
            "openBatteryOptimizationSettings" -> openBatteryOptimizationSettings(result)
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        if (staticChannel === channel) staticChannel = null
    }

    // ── ActivityAware ──

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        captureCallDetailsFromIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeOnNewIntentListener(this)
        activity = null
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activity = null
        activityBinding = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        captureCallDetailsFromIntent(intent)
        val details = pendingCallDetails
        if (details != null) {
            channel.invokeMethod("onIncomingCallLaunch", details)
            pendingCallDetails = null
        }
        return false
    }

    private fun captureCallDetailsFromIntent(intent: Intent?) {
        val extras = intent?.extras ?: return
        val isIncomingCall = extras.getString("incoming_call") == "true"
        if (!isIncomingCall) return

        pendingCallDetails = mapOf(
            "callId" to extras.getString("callId"),
            "callerName" to extras.getString("callerName"),
            "callerAvatar" to extras.getString("callerAvatar"),
            "isVideo" to extras.getBoolean("isVideo", false),
            "callAction" to extras.getString("callAction"),
        )

        intent.removeExtra("incoming_call")
        intent.removeExtra("callId")
        intent.removeExtra("callerName")
        intent.removeExtra("callerAvatar")
        intent.removeExtra("isVideo")
        intent.removeExtra("callAction")
    }

    private fun getLaunchCallDetails(result: Result) {
        val details = pendingCallDetails
        pendingCallDetails = null
        result.success(details)
    }

    private fun showCallNotification(call: MethodCall, result: Result) {
        try {
            val callerName = call.argument<String>("callerName") ?: "Unknown"
            val callId = call.argument<String>("callId") ?: ""
            val isVideo = call.argument<Boolean>("isVideo") ?: false
            val callerAvatar = call.argument<String>("callerAvatar")

            // CometChat can send duplicate "incoming" FCMs. If the user already
            // accepted/declined this call, don't re-post — that would restart
            // the INSISTENT ringtone during the connected call.
            if (callId.isNotEmpty() && IncomingCallActivity.isHandled(callId)) {
                result.success(false)
                return
            }

            // Stash details for IncomingCallActivity (same process) — the
            // full-screen PendingIntent's extras can arrive null on some
            // OEMs/Android versions, so the activity reads this as a fallback.
            IncomingCallActivity.pendingCallDetails = mapOf(
                "callId" to callId,
                "callerName" to callerName,
                "callerAvatar" to (callerAvatar ?: ""),
                "isVideo" to isVideo,
                "callAction" to "incoming",
            )

            val notificationManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            createCallNotificationChannel(notificationManager)

            val notificationId = callId.hashCode()

            val fullScreenPendingIntent = buildLaunchPendingIntent(
                callId, callerName, isVideo, callerAvatar, notificationId, "incoming"
            )
            val answerPendingIntent = buildLaunchPendingIntent(
                callId, callerName, isVideo, callerAvatar,
                notificationId + 1, "answer"
            )
            val declinePendingIntent = buildDeclineBroadcastIntent(callId, notificationId + 2)

            // Lock / screen state decides presentation:
            //  - Locked or screen-off → force-launch the custom full-screen
            //    call screen over the keyguard (startActivity below).
            //  - Unlocked & interactive → status-bar heads-up notification only.
            val keyguardManager =
                context.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
            val powerManager =
                context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            val shouldShowFullScreen =
                keyguardManager.isKeyguardLocked || !powerManager.isInteractive

            // On Android 14+ (UPSIDE_DOWN_CAKE) the full-screen-intent permission
            // can be revoked. When it is, the system STRIPS the full-screen
            // intent before validating, which makes a CallStyle notification fail
            // to post. Use CallStyle (native look) + full-screen intent only when
            // the permission is granted; otherwise fall back to a plain call
            // notification with Answer/Decline actions (no foreground service,
            // no phone-account — Android VoIP is custom-screen only).
            val canUseFullScreen =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    notificationManager.canUseFullScreenIntent()
                } else {
                    true
                }

            val caller = Person.Builder()
                .setName(callerName)
                .setImportant(true)
                .build()

            val builder = NotificationCompat.Builder(context, CALL_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_call)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setAutoCancel(false)
                .setOnlyAlertOnce(false)
                // Tap opens the full-screen incoming call screen.
                .setContentIntent(fullScreenPendingIntent)

            if (canUseFullScreen) {
                builder.setFullScreenIntent(fullScreenPendingIntent, true)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && canUseFullScreen) {
                builder.setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(
                        caller,
                        declinePendingIntent,
                        answerPendingIntent
                    )
                )
            } else {
                val callTypeText = if (isVideo) "Incoming Video Call" else "Incoming Audio Call"
                builder
                    .setContentTitle(callerName)
                    .setContentText(callTypeText)
                    .addAction(
                        android.R.drawable.ic_menu_close_clear_cancel,
                        "Decline",
                        declinePendingIntent
                    )
                    .addAction(
                        android.R.drawable.ic_menu_call,
                        "Answer",
                        answerPendingIntent
                    )
            }

            val notification = builder.build()
            notification.flags = notification.flags or
                android.app.Notification.FLAG_NO_CLEAR or
                android.app.Notification.FLAG_ONGOING_EVENT or
                android.app.Notification.FLAG_INSISTENT

            notificationManager.notify(notificationId, notification)

            // Locked / screen-off → launch the full-screen custom call screen.
            //
            // Only use an explicit startActivity when the full-screen intent
            // CANNOT fire (no USE_FULL_SCREEN_INTENT permission). When the FSI
            // is available it auto-launches the activity over the keyguard, so a
            // second startActivity here would cause a DOUBLE launch — the second
            // arrives as onNewIntent, which consumes & clears the launch details
            // before the cold-started Dart side registers its handler, so the
            // call screen never shows (only the app cold-starts). One launch only.
            if (shouldShowFullScreen && !canUseFullScreen) {
                val launchIntent = buildCallActivityIntent(
                    callId, callerName, isVideo, callerAvatar, "incoming"
                ).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_NO_USER_ACTION
                    )
                }
                try {
                    context.startActivity(launchIntent)
                } catch (e: Exception) {
                    android.util.Log.w(
                        "CometChatNotifs",
                        "Direct startActivity failed (${e.message}), " +
                            "trying full-screen PendingIntent"
                    )
                    try {
                        fullScreenPendingIntent.send()
                    } catch (e2: Exception) {
                        android.util.Log.e(
                            "CometChatNotifs",
                            "Full-screen PendingIntent also failed: ${e2.message}"
                        )
                    }
                }
            }

            result.success(true)
        } catch (e: Exception) {
            result.error("CALL_NOTIFICATION_ERROR", e.message, null)
        }
    }

    private fun cancelCallNotification(call: MethodCall, result: Result) {
        try {
            val callId = call.argument<String>("callId") ?: ""
            val notificationManager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.cancel(callId.hashCode())
            result.success(true)
        } catch (e: Exception) {
            result.error("CANCEL_ERROR", e.message, null)
        }
    }

    private fun createCallNotificationChannel(notificationManager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val channel = NotificationChannel(
            CALL_CHANNEL_ID,
            CALL_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming call notifications"
            setSound(Settings.System.DEFAULT_RINGTONE_URI, audioAttributes)
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 1000, 500, 1000, 500, 1000)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            setBypassDnd(true)
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildLaunchPendingIntent(
        callId: String,
        callerName: String,
        isVideo: Boolean,
        callerAvatar: String?,
        requestCode: Int,
        action: String
    ): PendingIntent {
        // Target the dedicated IncomingCallActivity (NOT the host app's
        // MainActivity) so the lock screen only ever shows the minimal call UI
        // — the full app is never exposed on a locked device.
        val intent = buildCallActivityIntent(callId, callerName, isVideo, callerAvatar, action)

        return PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** Builds an explicit intent for the dedicated [IncomingCallActivity]. */
    private fun buildCallActivityIntent(
        callId: String,
        callerName: String,
        isVideo: Boolean,
        callerAvatar: String?,
        action: String
    ): Intent {
        return Intent(context, IncomingCallActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("incoming_call", "true")
            putExtra("callId", callId)
            putExtra("callerName", callerName)
            putExtra("isVideo", isVideo)
            putExtra("callerAvatar", callerAvatar ?: "")
            putExtra("callAction", action)
        }
    }

    private fun buildDeclineBroadcastIntent(
        callId: String,
        requestCode: Int
    ): PendingIntent {
        val intent = Intent(context, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_DECLINE
            putExtra(CallActionReceiver.EXTRA_SESSION_ID, callId)
        }

        return PendingIntent.getBroadcast(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // ──────────────────────────────────────────────
    // OEM Permissions
    // ──────────────────────────────────────────────

    /**
     * Returns a map of permission states that affect call-screen visibility
     * on locked / background devices.
     *
     * Returned keys:
     *  - fullScreenIntent: Boolean — Android 14+ full-screen intent permission
     *  - overlay: Boolean          — SYSTEM_ALERT_WINDOW (required on MIUI)
     *  - batteryOptimized: Boolean — whether the app is exempt from doze
     */
    private fun checkCallPermissions(result: Result) {
        val map = mutableMapOf<String, Boolean>()

        // Full-screen intent permission (Android 14+).
        map["fullScreenIntent"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.canUseFullScreenIntent()
        } else {
            true
        }

        // SYSTEM_ALERT_WINDOW (required on Xiaomi / MIUI to show activity
        // while screen is off or locked).
        map["overlay"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.provider.Settings.canDrawOverlays(context)
        } else {
            true
        }

        // Battery optimization exemption (Doze mode).
        map["batteryOptimized"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            pm.isIgnoringBatteryOptimizations(context.packageName)
        } else {
            true
        }

        result.success(map)
    }

    /**
     * Opens the OEM-specific Autostart permission screen.
     *
     * Falls back to generic app details if the OEM shortcut isn't available.
     */
    private fun openAutoStartSettings(result: Result) {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val intents = when {
            manufacturer.contains("xiaomi") || manufacturer.contains("redmi") ||
                manufacturer.contains("poco") -> listOf(
                Intent().setComponent(
                    android.content.ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity"
                    )
                )
            )
            manufacturer.contains("oppo") || manufacturer.contains("realme") ||
                manufacturer.contains("oneplus") -> listOf(
                Intent().setComponent(
                    android.content.ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity"
                    )
                ),
                Intent().setComponent(
                    android.content.ComponentName(
                        "com.oppo.safe",
                        "com.oppo.safe.permission.startup.StartupAppListActivity"
                    )
                )
            )
            manufacturer.contains("vivo") -> listOf(
                Intent().setComponent(
                    android.content.ComponentName(
                        "com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"
                    )
                ),
                Intent().setComponent(
                    android.content.ComponentName(
                        "com.vivo.permissionmanager",
                        "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"
                    )
                )
            )
            manufacturer.contains("huawei") -> listOf(
                Intent().setComponent(
                    android.content.ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                    )
                )
            )
            manufacturer.contains("samsung") -> listOf(
                Intent().setComponent(
                    android.content.ComponentName(
                        "com.samsung.android.lool",
                        "com.samsung.android.sm.ui.battery.BatteryActivity"
                    )
                )
            )
            else -> emptyList()
        }

        var launched = false
        for (intent in intents) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
                launched = true
                break
            } catch (_: Exception) {
                continue
            }
        }

        if (!launched) {
            // Fallback — open the app's settings page.
            openAppDetails()
        }

        result.success(launched)
    }

    /**
     * Opens Android's full-screen intent permission screen (Android 14+).
     */
    private fun openFullScreenIntentSettings(result: Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val intent = Intent(
                android.provider.Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT
            ).apply {
                data = android.net.Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                context.startActivity(intent)
                result.success(true)
            } catch (_: Exception) {
                openAppDetails()
                result.success(false)
            }
        } else {
            result.success(true)
        }
    }

    /**
     * Opens the "Display over other apps" / SYSTEM_ALERT_WINDOW settings.
     */
    private fun openOverlaySettings(result: Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION
            ).apply {
                data = android.net.Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                context.startActivity(intent)
                result.success(true)
            } catch (_: Exception) {
                openAppDetails()
                result.success(false)
            }
        } else {
            result.success(true)
        }
    }

    /**
     * Opens the battery optimization exemption screen.
     */
    private fun openBatteryOptimizationSettings(result: Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            ).apply {
                data = android.net.Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                context.startActivity(intent)
                result.success(true)
            } catch (_: Exception) {
                openAppDetails()
                result.success(false)
            }
        } else {
            result.success(true)
        }
    }

    private fun openAppDetails() {
        val intent = Intent(
            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS
        ).apply {
            data = android.net.Uri.parse("package:${context.packageName}")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            // No-op.
        }
    }
}
