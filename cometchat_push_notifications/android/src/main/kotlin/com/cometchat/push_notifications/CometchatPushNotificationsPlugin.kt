package com.cometchat.push_notifications

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * The Android half of `cometchat_push_notifications`.
 *
 * It renders notifications and reports what the user does with them. It never
 * talks to CometChat: token registration, delivery receipts and sending replies
 * all happen in Dart on `cometchat_sdk`, so there is one implementation of each
 * rather than one per platform.
 *
 * It also does not claim `FirebaseMessagingService`. An app can only have one,
 * and taking it would break every integrator who already has their own; the
 * app keeps ownership of Firebase and forwards payloads to Dart.
 */
class CometchatPushNotificationsPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var config: NotificationConfig? = null
    private var renderer: NotificationRenderer? = null

    /** The [MethodChannel.Result] waiting on the OS permission dialog. */
    private var pendingPermissionResult: MethodChannel.Result? = null

    private var activeConversationId: String? = null
    private var activeReceiverType: String? = null

    /** Avatar downloads and disk writes must stay off the platform thread. */
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "cometchat_push_notifications")
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(
            binding.binaryMessenger,
            "cometchat_push_notifications/responses"
        )
        eventChannel.setStreamHandler(responses)

    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        io.shutdown()
    }

    // ── Method channel ──

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
            "initialize" -> initialize(call, result)
            "requestPermission" -> requestPermission(result)
            "isPermissionGranted" -> result.success(isPermissionGranted())
            "getApnsToken" -> result.success(null) // iOS-only; no APNs here.
            "showNotification" -> showNotification(call, result)
            "cancelNotifications" -> cancelNotifications(call, result)
            "setActiveConversation" -> setActiveConversation(call, result)
            "setBadgeCount" -> result.success(null) // Android has no OS badge.
            "getBadgeCount" -> result.success(0)
            else -> result.notImplemented()
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val map = call.arguments as? Map<*, *>
        if (map == null) {
            result.error("invalid_arguments", "initialize expects a map", null)
            return
        }
        val config = NotificationConfig.fromMap(map)
        this.config = config
        (context as? android.app.Application)?.let { ForegroundTracker.register(it) }
        renderer = NotificationRenderer(context, config)
        result.success(null)
    }

    private fun showNotification(call: MethodCall, result: MethodChannel.Result) {
        val renderer = renderer
        val map = call.arguments as? Map<*, *>
        if (renderer == null || map == null) {
            result.error(
                "not_initialized",
                "initialize() must be called before showing a notification",
                null
            )
            return
        }

        val message = PushMessage.fromMap(map)
        suppressionReason(message)?.let { reason ->
            Log.d("Notification suppressed — $reason")
            result.success(null)
            return
        }

        // The avatar download blocks; the platform thread must not.
        io.execute {
            try {
                renderer.show(message)
            } catch (e: Exception) {
                Log.e("Failed to post notification", e)
            }
        }
        result.success(null)
    }

    /**
     * Why [message] should not be shown, or null to show it.
     *
     * Two reasons. The conversation is on screen, in which case the user is
     * already reading it — matched on both the id and the receiver type,
     * because a user and a group can share an id and suppressing the wrong one
     * silently loses a message. Or the app is in the foreground and the
     * integrator asked for no banners there.
     */
    private fun suppressionReason(message: PushMessage): String? {
        val activeId = activeConversationId
        if (activeId != null && activeId == message.conversationKey) {
            val activeType = activeReceiverType
            if (activeType == null || activeType.equals(message.receiverType, ignoreCase = true)) {
                return "its conversation is on screen"
            }
        }
        if (config?.showInAppNotifications == false && ForegroundTracker.isInForeground()) {
            return "the app is in the foreground"
        }
        return null
    }

    private fun cancelNotifications(call: MethodCall, result: MethodChannel.Result) {
        val renderer = renderer
        if (renderer == null) {
            result.success(null)
            return
        }
        val conversationId = (call.arguments as? Map<*, *>)?.get("conversationId") as? String
        if (conversationId == null) renderer.cancelAll() else renderer.cancel(conversationId)
        result.success(null)
    }

    private fun setActiveConversation(call: MethodCall, result: MethodChannel.Result) {
        val map = call.arguments as? Map<*, *>
        activeConversationId = map?.get("id") as? String
        activeReceiverType = map?.get("receiverType") as? String
        // The user is reading it, so anything already posted for it is stale.
        activeConversationId?.let { renderer?.cancel(it) }
        result.success(null)
    }

    // ── Permission ──

    private fun isPermissionGranted(): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled()

    /**
     * Prompts for POST_NOTIFICATIONS on API 33+.
     *
     * Below 33 the permission does not exist and notifications are allowed
     * unless the user turned them off in settings, which no prompt can undo —
     * so the current state is the honest answer there.
     */
    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(isPermissionGranted())
            return
        }
        if (isPermissionGranted()) {
            result.success(true)
            return
        }
        val binding = activityBinding
        val activity = activity
        if (binding == null || activity == null) {
            result.error(
                "no_activity",
                "requestPermission() needs a foreground activity",
                null
            )
            return
        }

        // A second call while one is in flight: answer it with the standing
        // value rather than leaving it hanging or losing the first result.
        pendingPermissionResult?.let {
            pendingPermissionResult = null
            it.success(isPermissionGranted())
        }
        pendingPermissionResult = result

        activity.requestPermissions(
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE
        )
    }

    // ── Event channel ──

    private var sink: EventChannel.EventSink? = null

    /**
     * Responses the OS delivered before Dart was listening.
     *
     * A cold-start tap always lands here: the launch intent reaches the activity
     * well before the Dart side has attached a listener, and without buffering
     * the tap would simply be lost.
     */
    private val pending = mutableListOf<Map<String, Any?>>()

    private val responses = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            sink = events
            main.post {
                val buffered = synchronized(pending) {
                    val snapshot = pending.toList()
                    pending.clear()
                    snapshot
                }
                buffered.forEach { events?.success(it) }
            }
        }

        override fun onCancel(arguments: Any?) {
            sink = null
        }
    }

    /** Sends [event] to Dart, buffering it while nothing is listening. */
    private fun emit(event: Map<String, Any?>): Boolean {
        val sink = sink
        if (sink == null) {
            synchronized(pending) { pending.add(event) }
            return true
        }
        main.post { sink.success(event) }
        return true
    }

    // ── ActivityAware ──

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        binding.addRequestPermissionsResultListener(this)
        captureTap(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() = detachActivity()

    /**
     * Answers a [requestPermission] call once the user has responded.
     *
     * This is registered for as long as an activity is attached and never
     * added or removed from inside the callback. Flutter dispatches this while
     * iterating its listener set, so a listener that unregisters itself here
     * mutates that set mid-iteration — a `ConcurrentModificationException` that
     * takes the whole app down, and only ever on a real permission prompt.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingPermissionResult ?: return false
        pendingPermissionResult = null
        result.success(
            grantResults.isNotEmpty() &&
                grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        )
        return true
    }

    override fun onNewIntent(intent: Intent): Boolean {
        captureTap(intent)
        // Never claim the intent: the host app's own handling must still run.
        return false
    }

    private fun detachActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activity = null
        activityBinding = null
        // The dialog cannot report back once the activity is gone; answering
        // with the standing value beats leaving the Dart future unresolved.
        pendingPermissionResult?.let {
            pendingPermissionResult = null
            it.success(isPermissionGranted())
        }
    }

    /**
     * Turns a launch intent from one of our notifications into a tap event.
     *
     * The extras are stripped afterwards so a configuration change, which
     * redelivers the same intent, does not report the tap a second time.
     */
    private fun captureTap(intent: Intent?) {
        if (intent == null || !intent.getBooleanExtra(Extras.IS_COMETCHAT, false)) return

        val conversationId = intent.getStringExtra(Extras.CONVERSATION_ID) ?: return
        emit(
            mapOf(
                "conversationId" to conversationId,
                "receiverType" to intent.getStringExtra(Extras.RECEIVER_TYPE),
                "sender" to intent.getStringExtra(Extras.SENDER),
                "senderName" to intent.getStringExtra(Extras.SENDER_NAME),
                "senderAvatar" to intent.getStringExtra(Extras.SENDER_AVATAR),
                "messageId" to intent.getStringExtra(Extras.MESSAGE_ID)
            )
        )

        renderer?.cancel(conversationId)
        intent.removeExtra(Extras.IS_COMETCHAT)
    }
}

private const val PERMISSION_REQUEST_CODE = 0x0C7C
