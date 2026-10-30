package com.cometchat.voip

import android.content.Context

/**
 * The ringer's view of the Calls SDK — reached through Dart, never linked.
 *
 * This package depends on `cometchat_calls_sdk` and nothing else: no
 * `com.cometchat:calls-sdk-android` here. So every call that needs the SDK goes
 * over [DartBridge] to `NativeCallsBridge` in Dart, which drives
 * `CometChatCalls` and replies.
 *
 * Two kinds of operation, and the difference matters:
 *
 *  - **Asking the SDK to do something** — connect, decline, hand a call over.
 *    These cross to Dart, and will start a background isolate when the app is
 *    gone. Background threads only; they block.
 *  - **Asking what the session is doing** — joined? which one? These read
 *    [SessionState], the snapshot Dart pushes whenever it changes, because the
 *    ringer needs them on the main thread where a round trip would deadlock.
 *    They are advice, never permission to end a call.
 */
internal object CallsSdk {

    /** The outcome of a pre-join [connect]. */
    sealed interface ConnectResult {
        /** The conference took us: the call is alive and the caller sees it ring. */
        object Connected : ConnectResult

        /** [retryable] marks the SDK not being ready yet, as opposed to a real refusal. */
        data class Failed(val code: String, val message: String?, val retryable: Boolean) : ConnectResult
    }

    /**
     * Brings Dart up, which brings the Calls SDK with it.
     *
     * [config] is unused now — Dart reads the same persisted configuration
     * itself — but the signature is kept so the ring path reads the same.
     * Call from a background thread.
     */
    @Suppress("UNUSED_PARAMETER")
    fun ensureInitialised(context: Context, config: VoipConfig): Boolean =
        DartBridge.awaitDart(context)

    /** Whether anyone is logged in, as Dart last reported. */
    fun isLoggedIn(context: Context): Boolean = SessionState.isLoggedIn(context)

    /**
     * Joins the conference without media while the phone rings: answering then
     * only adds media, and the caller's `onParticipantConnected` fires, which is
     * how they know it is ringing.
     *
     * The session type travels with the request, because the Calls SDK keeps
     * the settings a session is prepared with — a default would open the camera
     * for an audio call.
     */
    fun connect(context: Context, call: IncomingCall, onResult: (ConnectResult) -> Unit) {
        DartBridge.invoke(
            context,
            "calls.connect",
            mapOf(
                "sessionId" to call.sessionId,
                "isVideo" to call.isVideo,
                "isPeerCall" to call.isPeerCall
            )
        ) { reply ->
            onResult(parseConnect(reply))
        }
    }

    private fun parseConnect(reply: Any?): ConnectResult {
        val map = reply as? Map<*, *>
            ?: return ConnectResult.Failed("NO_REPLY", "Dart did not answer", retryable = true)
        return if (map["status"] == "connected") {
            ConnectResult.Connected
        } else {
            ConnectResult.Failed(
                map["code"] as? String ?: "UNKNOWN",
                map["message"] as? String,
                map["retryable"] as? Boolean ?: false
            )
        }
    }

    /**
     * Declines ([CallsConstants.CALL_STATUS_REJECTED] or `busy`) before joining.
     *
     * The one call that regularly reaches a background isolate: a Decline
     * tapped on a notification that outlived its process.
     */
    fun endCall(context: Context, sessionId: String, status: String, onResult: (Boolean) -> Unit) {
        DartBridge.invoke(
            context,
            "calls.endCall",
            mapOf("sessionId" to sessionId, "status" to status)
        ) { reply ->
            onResult(reply as? Boolean ?: false)
        }
    }

    /** Preparing, prepared, joining or joined: anything a connect would disturb. */
    fun isSessionActive(context: Context): Boolean = SessionState.isActive(context)

    /** The session the SDK prepared, if any. */
    fun ownedSessionId(context: Context): String? = SessionState.ownedSessionId(context)

    fun isSessionJoined(context: Context): Boolean = SessionState.isJoined(context)

    /** Releases a session prepared by [connect] that nobody joined. */
    fun leaveSession(context: Context) {
        DartBridge.invoke(context, "calls.leaveSession")
    }

    /**
     * Hands the call to the Calls SDK, whose `IncomingCallListener` — in Dart,
     * and through it in the app — then hears it exactly as it hears any other
     * incoming call.
     */
    fun injectIncomingCall(context: Context, call: IncomingCall) {
        DartBridge.invoke(
            context,
            "calls.injectIncomingCall",
            mapOf("payload" to payload(call, "initiated"))
        )
    }

    fun injectIncomingCallEnded(context: Context, call: IncomingCall, reason: String) {
        DartBridge.invoke(
            context,
            "calls.injectIncomingCallEnded",
            mapOf("payload" to payload(call, reason), "reason" to reason)
        )
    }

    /**
     * The call in the key names the Calls SDK parses. The two name the same
     * fields differently — `callerUid` here is `sender` there — so passing
     * [IncomingCall.toMap] would fill in a session id and nothing else.
     */
    internal fun payload(call: IncomingCall, callAction: String): Map<String, String> = buildMap {
        put("sessionId", call.sessionId)
        call.callerUid?.let { put("sender", it) }
        put("senderName", call.callerName)
        call.callerAvatarUrl?.let { put("senderAvatar", it) }
        call.receiverUid?.let { put("receiver", it) }
        put("receiverType", call.receiverType)
        put("callType", call.callType)
        put("callAction", callAction)
        call.conversationId?.let { put("conversationId", it) }
        put("initiatedAt", call.initiatedAtMs.toString())
    }
}
