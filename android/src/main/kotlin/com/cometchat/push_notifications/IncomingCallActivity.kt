package com.cometchat.push_notifications

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Dedicated full-screen activity for an incoming call on the lock screen.
 *
 * It runs the host app's `incomingCallMain` Dart entrypoint in a CACHED
 * FlutterEngine (built once, reused for every call). A fresh engine per call
 * is fragile — a re-created secondary FlutterActivity engine frequently fails
 * to run its entrypoint and shows a black screen on the 2nd+ call. Caching the
 * engine fixes that and makes subsequent calls faster.
 *
 * Only the minimal call UI is shown over the keyguard (showWhenLocked) so the
 * full app is never exposed on a locked device. On each new call the activity
 * sends a `reload` so the Dart side refreshes the call + resets to ringing; on
 * `finish` (declined / ended) the activity finishes but the engine stays cached.
 */
class IncomingCallActivity : FlutterActivity() {

    companion object {
        /** Spawns fresh, robust engines for each call (shared resources). */
        private var engineGroup: FlutterEngineGroup? = null

        /**
         * Call details stashed by [CometchatPushNotificationsPlugin.showCallNotification]
         * when the call notification is posted. Read here because intent extras
         * delivered via the full-screen PendingIntent can arrive null on some
         * OEMs/Android versions. Same-process, so this is reliable for the
         * single active incoming call.
         */
        @JvmStatic
        var pendingCallDetails: Map<String, Any?>? = null

        /** Call IDs the user has already accepted/declined. A duplicate
         * "incoming" FCM for a handled call must NOT re-post the notification
         * (which would re-start the INSISTENT ringtone during the call). */
        @JvmStatic
        private val handledCallIds =
            java.util.Collections.synchronizedSet(mutableSetOf<String>())

        @JvmStatic
        fun markHandled(callId: String?) {
            if (callId != null) handledCallIds.add(callId)
        }

        @JvmStatic
        fun isHandled(callId: String): Boolean = handledCallIds.contains(callId)

        /** The currently-shown activity, so it can be dismissed remotely when
         * the caller cancels/ends the call before it's answered. */
        @JvmStatic
        private var current: IncomingCallActivity? = null

        /** Finish the live locked-call activity (caller cancelled/ended). */
        @JvmStatic
        fun dismiss() {
            current?.let { act ->
                pendingCallDetails = null
                act.runOnUiThread { act.finishAndRemoveTask() }
            }
        }

        /**
         * Provides a FRESH engine per call, spawned from a shared
         * [FlutterEngineGroup]. A fresh engine is required because CometChat's
         * call view (React Native) binds to the hosting Activity and can't be
         * reused across activity recreations (a cached engine joins the 1st
         * call then times out on the 2nd). The group makes spawning fresh
         * engines fast + robust (shared VM/snapshot) — plain `FlutterEngine`
         * per call goes black on the 2nd launch.
         */
        @JvmStatic
        fun provideEngine(context: Context): FlutterEngine {
            val app = context.applicationContext
            val loader = FlutterInjector.instance().flutterLoader()
            if (!loader.initialized()) {
                loader.startInitialization(app)
                loader.ensureInitializationComplete(app, null)
            }
            val group = engineGroup ?: FlutterEngineGroup(app).also { engineGroup = it }
            return group.createAndRunEngine(
                app,
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "incomingCallMain"),
            )
        }
    }

    private val channelName = "cometchat_locked_call"
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        super.onCreate(savedInstanceState)
        current = this
        // Tell the (reused) Dart side to refresh for this call + reset to ringing.
        channel?.invokeMethod("reload", null)
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        channel?.invokeMethod("reload", null)
    }

    /** Fresh engine per call (spawned from the shared group). */
    override fun provideFlutterEngine(context: Context): FlutterEngine = provideEngine(context)

    /** Destroy this call's engine when the activity finishes (fresh per call). */
    override fun shouldDestroyEngineWithHost(): Boolean = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getCallDetails" -> {
                    val intentCallId = intent.getStringExtra("callId")
                    val details = if (intentCallId != null) {
                        mapOf(
                            "callId" to intentCallId,
                            "callerName" to intent.getStringExtra("callerName"),
                            "callerAvatar" to intent.getStringExtra("callerAvatar"),
                            "isVideo" to intent.getBooleanExtra("isVideo", false),
                            "callAction" to intent.getStringExtra("callAction"),
                        )
                    } else {
                        pendingCallDetails ?: emptyMap<String, Any?>()
                    }
                    result.success(details)
                }
                "cancelNotification" -> {
                    // Stop the ringing notification as soon as the user acts
                    // (accept/decline). The call channel is INSISTENT, so the
                    // ringtone loops until the notification is gone.
                    cancelCallNotification(
                        (call.arguments as? Map<*, *>)?.get("callId") as? String,
                    )
                    result.success(null)
                }
                "finish" -> {
                    cancelCallNotification(
                        (call.arguments as? Map<*, *>)?.get("callId") as? String,
                    )
                    pendingCallDetails = null
                    // Return to the lock screen without revealing the app. Keep
                    // the cached engine alive for the next call.
                    finishAndRemoveTask()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Cancel the incoming-call notification (stops its INSISTENT ringtone)
     * and mark the call handled so a duplicate FCM won't re-post/re-ring it. */
    private fun cancelCallNotification(callIdArg: String?) {
        val callId = callIdArg ?: pendingCallDetails?.get("callId") as? String ?: return
        markHandled(callId)
        val nm = getSystemService(Context.NOTIFICATION_SERVICE)
            as android.app.NotificationManager
        nm.cancel(callId.hashCode())
    }
}
