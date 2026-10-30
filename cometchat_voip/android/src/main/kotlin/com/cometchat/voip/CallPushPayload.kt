package com.cometchat.voip

import org.json.JSONObject

/**
 * The CometChat call push, parsed. Never throws: a crash here costs a ring.
 *
 * Two shapes are in the field and both have to work:
 *  - **Flat keys**, from Push Notifications (enhanced): `type=call`,
 *    `callAction`, `sessionId`, `callType`, `sender`, `senderName`,
 *    `senderAvatar`, `receiver`, `receiverType`, `conversationId`, `sentAt`.
 *  - **The legacy extension**, which wraps the whole message in a `message`
 *    JSON string (`category=call`, `action`, `sessionid`, `type`, `sender`).
 *
 * Keys match case-insensitively and through a few aliases, so a template tweak
 * on the dashboard cannot silently stop calls ringing. `initiatedAt` and
 * `ringTimeout` are read when the backend sends them; until then the deadline
 * falls back to `sentAt`, then to when the push arrived, and the 45 s default.
 */
internal data class CallPushPayload(
    val action: Action,
    /** The action as received, for logs and for actions this build does not know. */
    val rawAction: String,
    val sessionId: String,
    /** [IncomingCall.TYPE_AUDIO] or [IncomingCall.TYPE_VIDEO]. */
    val callType: String,
    val senderUid: String?,
    val senderName: String?,
    val senderAvatar: String?,
    val receiverUid: String?,
    val receiverType: String?,
    val conversationId: String?,
    val sentAtMs: Long?,
    val initiatedAtMs: Long?,
    val ringTimeoutMs: Long?
) {

    enum class Action(val wire: String) {
        INITIATED("initiated"),
        /** Answered, possibly on another of this user's devices: stop ringing, not missed. */
        ONGOING("ongoing"),
        ENDED("ended"),
        UNANSWERED("unanswered"),
        /** The server's name for a ring that expired; v1 sends `unanswered`. */
        TIMED_OUT("timed_out"),
        REJECTED("rejected"),
        BUSY("busy"),
        CANCELLED("cancelled"),
        UNKNOWN("unknown");

        /** Whether this ends the ringing on the callee's side. */
        val isTerminal: Boolean get() = this != INITIATED && this != UNKNOWN

        companion object {
            fun from(raw: String?): Action {
                val v = raw?.trim()?.lowercase() ?: return UNKNOWN
                return entries.firstOrNull { it.wire == v } ?: UNKNOWN
            }
        }
    }

    /** What the ring shows as the caller. Never empty. */
    val displayName: String
        get() = senderName?.takeIf { it.isNotBlank() }
            ?: senderUid?.takeIf { it.isNotBlank() }
            ?: "Unknown caller"

    /**
     * @param receivedAtMs the last fallback for the ring deadline.
     * @param defaultRingTimeoutMs the window for a push without its own
     *   `ringTimeout`: the app's `defaultRingTimeout`.
     */
    fun toIncomingCall(
        receivedAtMs: Long,
        defaultRingTimeoutMs: Long = CallsConstants.DEFAULT_RING_TIMEOUT_MS
    ): IncomingCall = IncomingCall(
        sessionId = sessionId,
        callerUid = senderUid,
        callerName = displayName,
        callerAvatarUrl = senderAvatar,
        callType = callType,
        receiverType = receiverType ?: IncomingCall.RECEIVER_TYPE_USER,
        receiverUid = receiverUid,
        conversationId = conversationId,
        initiatedAtMs = initiatedAtMs ?: sentAtMs ?: receivedAtMs,
        ringTimeoutMs = ringTimeoutMs ?: defaultRingTimeoutMs
    )

    sealed class Result {
        data class Call(val payload: CallPushPayload) : Result()
        /** A push, but not a call to act on: a chat message, or malformed. */
        data class Ignored(val reason: String) : Result()
    }

    companion object {
        private const val CALL_TYPE = "call"

        /**
         * `sentAt` arrives in seconds, and sometimes in millis. Anything below
         * this is seconds. Reading seconds as millis puts the deadline in 1970,
         * which silently drops every call.
         */
        private const val SECONDS_MILLIS_THRESHOLD = 100_000_000_000L

        fun parse(data: Map<String, String?>): Result {
            if (data.isEmpty()) return Result.Ignored("empty data payload")
            val flat = Lookup(data)

            val nested = flat["message"]?.let(::parseJsonObject)
            val nestedSender = nested?.get("sender")?.let(::parseJsonObject)

            val type = flat["type", "category"] ?: nested?.get("category")
            val isCall = type?.trim()?.lowercase() == CALL_TYPE ||
                (type == null && flat["callAction", "callaction", "call_action"] != null)
            if (!isCall) return Result.Ignored("not a call push (type=${type ?: "?"})")

            val rawAction = flat["callAction", "callaction", "call_action", "action"]
                ?: nested?.get("action")
                ?: return Result.Ignored("call push without callAction")

            val sessionId = (
                flat["sessionId", "sessionid", "session_id"]
                    ?: nested?.get("sessionid")
                    ?: nested?.get("sessionId")
                ).blankToNull()
                ?: return Result.Ignored("call push without sessionId (action=$rawAction)")

            val callTypeRaw = flat["callType", "calltype", "call_type"] ?: nested?.get("type")
            val callType =
                if (callTypeRaw?.trim().equals(IncomingCall.TYPE_VIDEO, ignoreCase = true)) {
                    IncomingCall.TYPE_VIDEO
                } else {
                    IncomingCall.TYPE_AUDIO
                }

            return Result.Call(
                CallPushPayload(
                    action = Action.from(rawAction),
                    rawAction = rawAction.trim(),
                    sessionId = sessionId,
                    callType = callType,
                    senderUid = (flat["sender", "senderUid", "sender_uid"] ?: nestedSender?.get("uid")).blankToNull(),
                    senderName = (
                        flat["senderName", "sendername", "sender_name"]
                            ?: nestedSender?.get("name")
                            ?: flat["title"]
                        ).blankToNull(),
                    senderAvatar = (
                        flat["senderAvatar", "senderavatar", "sender_avatar"]
                            ?: nestedSender?.get("avatar")
                        ).blankToNull(),
                    receiverUid = (flat["receiver", "receiverUid", "receiver_uid"] ?: nested?.get("receiver")).blankToNull(),
                    receiverType = (
                        flat["receiverType", "receivertype", "receiver_type"]
                            ?: nested?.get("receiverType")
                        ).blankToNull(),
                    conversationId = (
                        flat["conversationId", "conversationid", "conversation_id"]
                            ?: nested?.get("conversationId")
                        ).blankToNull(),
                    sentAtMs = normaliseEpoch(flat["sentAt", "sentat", "sent_at"] ?: nested?.get("sentAt")),
                    initiatedAtMs = normaliseEpoch(
                        flat["initiatedAt", "initiatedat", "initiated_at"] ?: nested?.get("initiatedAt")
                    ),
                    ringTimeoutMs = (flat["ringTimeout", "ringtimeout", "ring_timeout"] ?: nested?.get("ringTimeout"))
                        ?.trim()?.toLongOrNull()
                        ?.takeIf { it in CallsConstants.MIN_RING_TIMEOUT_MS..CallsConstants.MAX_RING_TIMEOUT_MS }
                )
            )
        }

        /** An epoch in seconds or millis, as millis. */
        private fun normaliseEpoch(raw: String?): Long? {
            val value = raw?.trim()?.toLongOrNull() ?: return null
            if (value <= 0L) return null
            return if (value < SECONDS_MILLIS_THRESHOLD) value * 1000 else value
        }

        private fun String?.blankToNull(): String? = this?.trim()?.takeIf { it.isNotEmpty() }

        /** A JSON object as strings; nested objects stay JSON text. */
        private fun parseJsonObject(text: String): Map<String, String>? {
            val trimmed = text.trim()
            if (!trimmed.startsWith("{")) return null
            return try {
                val json = JSONObject(trimmed)
                json.keys().asSequence().associateWith { key ->
                    when (val value = json.opt(key)) {
                        null, JSONObject.NULL -> ""
                        else -> value.toString()
                    }
                }
            } catch (_: Throwable) {
                null
            }
        }

        /** Case-insensitive lookup through aliases, listed at each use. */
        private class Lookup(source: Map<String, String?>) {
            private val map = HashMap<String, String>()

            init {
                for ((k, v) in source) if (v != null) map[k.lowercase()] = v
            }

            operator fun get(vararg keys: String): String? {
                for (k in keys) map[k.lowercase()]?.let { return it }
                return null
            }
        }
    }
}
