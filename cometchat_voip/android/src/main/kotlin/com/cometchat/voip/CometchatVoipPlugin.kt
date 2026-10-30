package com.cometchat.voip

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.TimeZone

/**
 * The Android half of `cometchat_voip`.
 *
 * Nearly everything happens without it: a call rings, is answered or declined
 * and times out through notification actions, a receiver, an alarm and a
 * service, none of which need a Flutter engine. This class hands pushes in,
 * persists the configuration, and tells Dart what the user did.
 *
 * It does not claim `FirebaseMessagingService`. An app has one, and taking it
 * would break every app that already does; the app forwards call pushes.
 */
class CometchatVoipPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context

    /**
     * This engine's end of the event channel.
     *
     * One per plugin instance, and Flutter makes one instance per engine, so
     * an event can be sent to the engine that owns the activity rather than
     * process-wide — which on a killed app would reach the background isolate
     * that handled the push and nowhere else.
     */
    private val events = CallEvents.EngineEvents()

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    /** The [MethodChannel.Result] waiting on the notification permission dialog. */
    private var pendingPermissionResult: MethodChannel.Result? = null

    /** The [MethodChannel.Result] waiting on the microphone and camera dialogs. */
    private var pendingCallPermissionResult: MethodChannel.Result? = null

    /** Whether the activity is showing over the lock screen for an answered call. */
    private var showingOverLockScreen = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "cometchat_voip")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "cometchat_voip/events")
        eventChannel.setStreamHandler(events)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    // ── Method channel ──

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(call, result)
            "handlePushNotification" -> handlePushNotification(call, result)
            "getVoipToken" -> result.success(null) // PushKit is iOS-only.
            "getTimeZone" -> result.success(TimeZone.getDefault().id)
            "answer" -> {
                answer(call.argument<String>("sessionId"))
                result.success(null)
            }
            "permissionsToAnswer" -> {
                val incoming = call.argument<Map<String, String>>("call")?.let(IncomingCall::fromMap)
                result.success(incoming?.let { missingPermissionNames(it) } ?: emptyList<String>())
            }
            "requestCallPermissions" -> requestCallPermissions(call, result)
            "decline" -> {
                RingController.decline(
                    context,
                    call.argument<String>("sessionId"),
                    busy = call.argument<Boolean>("busy") ?: false,
                )
                result.success(null)
            }
            "dismissRinging" -> {
                call.argument<String>("sessionId")?.let {
                    RingController.dismissRinging(context, it, call.argument<Boolean>("answered") ?: false)
                }
                result.success(null)
            }
            "getActiveCall" -> result.success(CallStore.get(context)?.call?.toMap())
            // CallKit's caller side has no Android counterpart. Neither has
            // naming the callee of one, which only a CallKit call shows.
            "reportOutgoingCall", "reportCallConnected", "reportRemoteParticipant" ->
                result.success(null)
            "reportCallEnded" -> {
                call.argument<String>("sessionId")?.let(::callEnded)
                result.success(null)
            }
            "checkRingReadiness" -> result.success(RingReadiness.check(context))
            "openSettings" -> result.success(openSettings(call.argument<String>("readiness")))
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "getDiagnostics" -> result.success(
                RingReadiness.diagnostics(context) + mapOf(
                    // The lock-screen decline on a killed app needs this. Without
                    // it the decline waits for the app instead, silently.
                    "backgroundEntryPointRegistered" to DartBridge.hasCallbackHandle(context)
                )
            )
            "verifyPushSetup" -> result.success(verifyPushSetup())
            "lastWakeTiming" -> result.success(WakeVerifier.lastTiming())

            // ── MANUAL mode: everything AUTO does, a piece at a time ──
            // The native SDK exposes these as CometChatCallNotifications.Calls.
            "ringSurface.showIncomingNotification" -> withCall(call, result) {
                RingController.startRinging(context, it)
            }
            "ringSurface.stopRinging" -> {
                call.argument<String>("sessionId")?.let {
                    RingController.stopRinging(context, it, answered = false)
                }
                result.success(null)
            }
            "ringSurface.verify" -> withCall(call, result) {
                WakeVerifier.start(context, it)
            }
            "ringSurface.keepAlive" -> withCall(call, result) {
                RingingForegroundService.connecting(context, it)
            }
            "ringSurface.showMissedCall" -> withCall(call, result) {
                IncomingCallNotifier.showMissedCall(context, it)
            }

            // ── The gate and the ledger, which persist across processes ──
            "markTerminal" -> {
                val sessionId = call.argument<String>("sessionId")
                val reason = call.argument<String>("reason") ?: "app"
                if (sessionId == null) {
                    result.error("invalid_arguments", "markTerminal needs a sessionId", null)
                } else {
                    CallStore.markTerminal(context, sessionId, reason)
                    result.success(null)
                }
            }
            "wasTerminal" -> {
                val sessionId = call.argument<String>("sessionId")
                result.success(sessionId != null && CallStore.wasTerminal(context, sessionId))
            }
            "terminalReason" -> result.success(
                call.argument<String>("sessionId")?.let { CallStore.terminalReason(context, it) }
            )
            "setLoggedInUid" -> {
                val uid = call.argument<String>("uid")
                CallStore.setUid(context, uid)
                SessionState.setLoggedIn(context, uid != null)
                if (uid == null) {
                    // Logged out: a call still ringing is for a user who is gone.
                    CallStore.get(context)?.let {
                        RingController.remoteEnded(
                            context, it.call.sessionId, CallEndReason.FAILED, "logout"
                        )
                    }
                }
                result.success(null)
            }

            // Dart relaying the Calls SDK ending a ringing call. A caller's
            // cancel usually reaches this device this way — through the
            // prepared session closing — before the push does, if a push comes
            // at all. The ringer cannot hear the SDK itself any more.
            "sdkEndedCall" -> {
                val sessionId = call.argument<String>("sessionId")
                if (sessionId == null) {
                    result.error("invalid_arguments", "sdkEndedCall needs a sessionId", null)
                } else {
                    RingController.sdkEnded(
                        context,
                        sessionId,
                        call.argument<String>("reason") ?: "ended"
                    )
                    result.success(null)
                }
            }

            // No CallKit on Android, so there is no call UI to mirror a mute or
            // a video pause onto. Accepted and ignored rather than left to
            // report notImplemented on every toggle.
            "setSessionMuted", "setSessionVideoPaused" -> result.success(null)

            // CallKit is iOS's, so there is no audio handoff to record here.
            // Accepted so Dart can report what it found without branching on
            // the platform.
            "setCallKitAudioHandoff" -> result.success(null)

            // The ring screen's and the call notifications' colours; null
            // clears them. Read from disk on every ring, so a killed app's next
            // ring uses it.
            "setIncomingCallTheme" -> {
                IncomingCallTheme.save(context, call.arguments as? Map<*, *>)
                result.success(null)
            }

            // Dart telling us what the Calls session is doing. The ringer reads
            // this synchronously, on threads that cannot wait for a round trip.
            "setSessionState" -> {
                val active = call.argument<Boolean>("active") ?: false
                SessionState.update(
                    context,
                    active = active,
                    joined = call.argument<Boolean>("joined") ?: false,
                    sessionId = call.argument<String>("sessionId")
                )
                // The answered call's screen stops showing over the lock screen
                // when its session ends — what a native session listener used
                // to tell us.
                if (!active) stopShowingOverLockScreen()
                result.success(null)
            }

            // An isolate announcing it can serve the ringer's Calls SDK work.
            "dartReady" -> {
                DartBridge.onDartReady(channel)
                result.success(null)
            }

            // What Dart needs to bring the Calls SDK up on a cold isolate.
            "storedConfig" -> result.success(
                VoipConfig.restore(context)?.let {
                    mapOf(
                        "appId" to it.appId,
                        "region" to it.region,
                        "clientHost" to it.clientHost
                    )
                }
            )
            "enqueueDecline" -> {
                val sessionId = call.argument<String>("sessionId")
                val status = call.argument<String>("status") ?: CallsConstants.CALL_STATUS_REJECTED
                if (sessionId == null) {
                    result.error("invalid_arguments", "enqueueDecline needs a sessionId", null)
                } else {
                    DeclineQueue.enqueue(context, sessionId, status)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Runs [body] with the call the Dart side sent, or fails the call.
     *
     * Every MANUAL-mode surface takes a whole [IncomingCall] rather than a
     * session id: the app may be driving a ring for a call this process never
     * saw, so there is nothing on disk to look it up by.
     */
    private fun withCall(
        call: MethodCall,
        result: MethodChannel.Result,
        body: (IncomingCall) -> Unit
    ) {
        val map = call.argument<Map<String, String>>("call")
        val incoming = map?.let(IncomingCall::fromMap)
        if (incoming == null) {
            result.error("invalid_arguments", "${call.method} needs a call with a sessionId", null)
            return
        }
        body(incoming)
        result.success(null)
    }

    /**
     * What this device can tell about its own push setup, without a test push.
     *
     * The Dart side adds what it knows about the token and the login; this is
     * the half that needs the OS.
     */
    private fun verifyPushSetup(): String = when {
        VoipConfig.restore(context) == null -> "notInitialized"
        !IncomingCallNotifier.canPost(context) -> "notificationsBlocked"
        RingReadiness.check(context) != RingReadiness.READY -> "ringNotReady"
        else -> "ok"
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val config = (call.arguments as? Map<*, *>)?.let(VoipConfig::fromMap)
        if (config == null) {
            result.error("invalid_arguments", "initialize needs an appId and a region", null)
            return
        }
        VoipConfig.save(context, config)
        // Only a theme that is there replaces the saved one: the background
        // message handler calls init again on every push, without a theme, and
        // must not wipe the one the app set.
        (call.argument<Map<*, *>>("incomingCallTheme"))?.let { IncomingCallTheme.save(context, it) }
        NotificationChannels.ensureAll(context)

        // The ring gates run before any SDK is up, so they read the uid from
        // disk. Dart watches the Calls login and pushes it with setLoggedInUid,
        // because the SDK itself is out of reach from here.
        call.argument<Number>("backgroundCallbackHandle")?.let {
            DartBridge.saveCallbackHandle(context, it.toLong())
        }
        result.success(null)
    }

    private fun handlePushNotification(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<Map<*, *>>("data")
        if (raw == null) {
            result.success(false)
            return
        }
        val data = raw.entries
            .filter { it.key is String && it.value != null }
            .associate { it.key as String to it.value.toString() }
        val sentTimeMs = (call.argument<Any>("sentTimeMs") as? Number)?.toLong()
        result.success(RingingCallHandler.handle(context, data, sentTimeMs))
    }

    /** The app ended the answered call: it is no longer the store's, nor the lock screen's. */
    private fun callEnded(sessionId: String) {
        CallStore.forgetAnswered(context, sessionId)
        // Ended while another call rang over it: it is not coming back.
        CallStore.dropHeld(context, sessionId)
        if (CallStore.get(context)?.let { it.call.sessionId == sessionId && it.state == CallStore.State.ANSWERED } == true) {
            CallStore.clear(context, sessionId, "ended")
        }
        stopShowingOverLockScreen()
    }

    /**
     * The app answered in its own ring screen — `autoCustomScreen`, or an app
     * ringing in its own UI in `auto`.
     *
     * Routed through the ring's own Answer whenever a permission is missing,
     * so an in-app answer asks for the microphone exactly as the notification
     * does: the trampoline records the answer, asks, opens the app and tells
     * Dart. A denial never fails the call — it joins muted — so nothing here
     * waits for the user.
     */
    private fun answer(sessionId: String?) {
        val ringing = CallStore.get(context)?.call
            ?.takeIf { sessionId == null || it.sessionId == sessionId }
        val activity = activity
        if (ringing != null && activity != null &&
            VoipConfig.restore(context)?.requestCallPermissions != false &&
            AnswerTrampolineActivity.missingPermissions(context, ringing).isNotEmpty()
        ) {
            val started = runCatching {
                activity.startActivity(AnswerTrampolineActivity.intent(context, ringing))
            }.onFailure {
                Log.e("could not ask for the call permissions on answer: ${it.message}")
            }.isSuccess
            // The trampoline answers and reports it; only its failure leaves
            // that to us.
            if (started) return
        }
        RingController.answer(context, sessionId)?.let { CallEvents.answered(it.call) }
    }

    /** What answering [call] needs and this device has not granted. */
    private fun missingPermissionNames(call: IncomingCall): List<String> =
        AnswerTrampolineActivity.missingPermissions(context, call).mapNotNull {
            when (it) {
                android.Manifest.permission.RECORD_AUDIO -> "microphone"
                android.Manifest.permission.CAMERA -> "camera"
                else -> null
            }
        }

    /**
     * Asks for the microphone, and the camera for a video call, from the app's
     * own ring screen.
     *
     * The dialog cannot show over the keyguard, so a locked device is asked to
     * unlock first; a user who does not is answered with what is granted
     * already, and the call still goes through muted.
     */
    private fun requestCallPermissions(call: MethodCall, result: MethodChannel.Result) {
        val incoming = call.argument<Map<String, String>>("call")?.let(IncomingCall::fromMap)
        if (incoming == null) {
            result.error("invalid_arguments", "requestCallPermissions needs a call with a sessionId", null)
            return
        }
        val missing = AnswerTrampolineActivity.missingPermissions(context, incoming)
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        val activity = activity
        if (activity == null) {
            result.error("no_activity", "requestCallPermissions() needs a foreground activity", null)
            return
        }
        // A second ask while one is in flight: answer the first with what is
        // granted now.
        pendingCallPermissionResult?.success(false)
        pendingCallPermissionResult = result
        if (android.Manifest.permission.RECORD_AUDIO in missing) {
            RingReadiness.recordMicrophoneAsked(context)
        }
        val keyguard = activity.getSystemService(KeyguardManager::class.java)
        if (keyguard != null && keyguard.isKeyguardLocked) {
            keyguard.requestDismissKeyguard(activity, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() =
                    activity.requestPermissions(missing, CALL_PERMISSION_REQUEST_CODE)

                override fun onDismissCancelled() = finishCallPermissions(incoming)

                override fun onDismissError() = finishCallPermissions(incoming)
            })
        } else {
            activity.requestPermissions(missing, CALL_PERMISSION_REQUEST_CODE)
        }
    }

    /** Answers the waiting ask with whether everything is granted now. */
    private fun finishCallPermissions(call: IncomingCall) {
        val result = pendingCallPermissionResult ?: return
        pendingCallPermissionResult = null
        result.success(AnswerTrampolineActivity.missingPermissions(context, call).isEmpty())
    }

    private fun openSettings(readiness: String?): Boolean {
        val intent = readiness?.let { RingReadiness.settingsIntent(context, it) } ?: return false
        return runCatching { (activity ?: context).startActivity(intent) }.isSuccess
    }

    // ── Notification permission ──

    /**
     * Prompts for POST_NOTIFICATIONS on API 33+, without which nothing rings.
     * Below 33 the permission does not exist, and the current state is the
     * honest answer.
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val granted = NotificationManagerCompat.from(context).areNotificationsEnabled()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || granted) {
            result.success(granted)
            return
        }
        val activity = activity
        if (activity == null) {
            result.error("no_activity", "requestNotificationPermission() needs a foreground activity", null)
            return
        }
        // A second call while one is in flight: answer the first with the standing value.
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = result
        activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST_CODE)
    }

    /**
     * Registered for as long as an activity is attached, and never added or
     * removed from inside the callback: Flutter dispatches this while
     * iterating its listeners, and changing that set mid-iteration takes the
     * app down.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == CALL_PERMISSION_REQUEST_CODE) {
            val result = pendingCallPermissionResult ?: return false
            pendingCallPermissionResult = null
            result.success(
                grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            )
            return true
        }
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingPermissionResult ?: return false
        pendingPermissionResult = null
        result.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return true
    }

    // ── ActivityAware ──

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attach(binding)

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    override fun onNewIntent(intent: Intent): Boolean {
        captureRingScreen(intent)
        captureAnswer(intent)
        // Never claim the intent: the app's own handling must still run.
        return false
    }

    private fun attach(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        binding.addRequestPermissionsResultListener(this)
        captureRingScreen(binding.activity.intent)
        captureAnswer(binding.activity.intent)
    }

    private fun detach() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activity = null
        activityBinding = null
        pendingPermissionResult?.let {
            pendingPermissionResult = null
            it.success(NotificationManagerCompat.from(context).areNotificationsEnabled())
        }
        pendingCallPermissionResult?.let {
            pendingCallPermissionResult = null
            it.success(false)
        }
    }

    /**
     * The app was opened *to ring* — `autoCustomScreen`'s full-screen alert,
     * or its tap — so the app's own screen draws the ring.
     *
     * It shows over the keyguard for as long as the call rings, and the
     * request is handed to Dart, which holds it until the app's screen
     * subscribes: on a cold start nothing is listening yet. A ring that ends
     * elsewhere — cancelled, answered on another device, rung out — stops the
     * lock-screen window through [RingSurfaces], which the notification's
     * cancellation does not do by itself.
     */
    private fun captureRingScreen(intent: Intent?) {
        if (intent == null || !intent.getBooleanExtra(CallBundles.EXTRA_RING_SCREEN, false)) return
        val call = CallBundles.getCall(intent) ?: return
        val endsActiveCall = intent.getBooleanExtra(CallBundles.EXTRA_ENDS_ACTIVE_CALL, false)
        CallBundles.strip(intent)
        activity?.let { showOverKeyguard(it) }
        showingOverLockScreen = true
        RingSurfaces.register(call.sessionId) {
            // An answered call keeps the lock-screen window: the call screen
            // is next, and Dart reporting the session over is what closes it.
            // Every other end is the ring going away for good.
            val answered = CallStore.get(context)?.let {
                it.call.sessionId == call.sessionId && it.state == CallStore.State.ANSWERED
            } == true
            // Back on the main thread: RingSurfaces is finished from wherever
            // the ring ended.
            if (!answered) activity?.runOnUiThread { stopShowingOverLockScreen() }
        }
        // This engine's, not process-wide: its Dart is seconds behind the
        // activity on a cold start, and a listening background isolate would
        // take the request and draw nothing.
        events.send(CallEvents.ringScreenEvent(call, endsActiveCall))
    }

    /**
     * The app was opened for an answered call, possibly on a locked device.
     *
     * Dart already has the answer from the trampoline; what is left here is
     * letting the call screen show over the keyguard, so a lock-screen answer
     * does not end on the lock screen with the call running out of sight. It
     * stops when the session is left.
     */
    private fun captureAnswer(intent: Intent?) {
        if (intent == null || !intent.getBooleanExtra(CallBundles.EXTRA_ANSWERED, false)) return
        val call = CallBundles.getCall(intent)
        CallBundles.strip(intent)

        // The answer, again, to the engine that owns this activity. The
        // trampoline already emitted it process-wide, which is what reaches an
        // app that was merely in the background — but on a killed app that
        // emit lands in the isolate the push started, which has no UI and
        // joins nothing. Sent again here, held until this engine's Dart
        // listens. Dart takes each session's answer once, so the app that got
        // both is unaffected.
        //
        // Only while the store still has the call answered: one cancelled
        // between the tap and the launch must not be joined.
        if (call != null &&
            CallStore.get(context)?.let {
                it.call.sessionId == call.sessionId && it.state == CallStore.State.ANSWERED
            } == true
        ) {
            events.send(CallEvents.answeredEvent(call))
        }

        val activity = activity ?: return
        showOverKeyguard(activity)
        // Stops when Dart reports the session over, through setSessionState.
        showingOverLockScreen = true
    }

    private fun stopShowingOverLockScreen() {
        if (!showingOverLockScreen) return
        showingOverLockScreen = false
        activity?.let { showOverKeyguard(it, show = false) }
    }

}

private const val PERMISSION_REQUEST_CODE = 0x0C7D
private const val CALL_PERMISSION_REQUEST_CODE = 0x0C7E
