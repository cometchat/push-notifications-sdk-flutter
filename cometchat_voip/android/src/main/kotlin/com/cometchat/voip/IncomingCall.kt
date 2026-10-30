package com.cometchat.voip

/**
 * A call announced to this device by a push.
 *
 * A plain value type: it crosses process boundaries in intent extras and has
 * to survive a cold start, so [toMap] and [fromMap] are the persistence
 * contract. Dart reads the same map.
 *
 * @property initiatedAtMs when the caller started ringing. Falls back to when
 *   the push was sent, then to when it arrived.
 */
internal data class IncomingCall(
    val sessionId: String,
    val callerUid: String?,
    val callerName: String,
    val callerAvatarUrl: String?,
    val callType: String,
    val receiverType: String,
    val receiverUid: String?,
    val conversationId: String?,
    val initiatedAtMs: Long,
    val ringTimeoutMs: Long
) {

    /** The instant this call stops being ringable. */
    val expiresAtMs: Long get() = initiatedAtMs + ringTimeoutMs

    /** A one-to-one call, which the Calls SDK ends for both sides when one leaves. */
    val isPeerCall: Boolean get() = receiverType.equals(RECEIVER_TYPE_USER, ignoreCase = true)

    val isVideo: Boolean get() = callType.equals(TYPE_VIDEO, ignoreCase = true)

    /** Up to two initials for the avatar: "Alice Demo" is "AD", "bob" is "B", "" is "?". */
    val initials: String
        get() {
            val parts = callerName.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            if (parts.isEmpty()) return "?"
            return buildString {
                append(parts.first().first().uppercaseChar())
                if (parts.size > 1) append(parts.last().first().uppercaseChar())
            }
        }

    fun toMap(): Map<String, String> = buildMap {
        put(KEY_SESSION_ID, sessionId)
        callerUid?.let { put(KEY_CALLER_UID, it) }
        put(KEY_CALLER_NAME, callerName)
        callerAvatarUrl?.let { put(KEY_CALLER_AVATAR, it) }
        put(KEY_CALL_TYPE, callType)
        put(KEY_RECEIVER_TYPE, receiverType)
        receiverUid?.let { put(KEY_RECEIVER_UID, it) }
        conversationId?.let { put(KEY_CONVERSATION_ID, it) }
        put(KEY_INITIATED_AT, initiatedAtMs.toString())
        put(KEY_RING_TIMEOUT, ringTimeoutMs.toString())
    }

    companion object {
        const val TYPE_AUDIO = "audio"
        const val TYPE_VIDEO = "video"
        const val RECEIVER_TYPE_USER = "user"
        const val RECEIVER_TYPE_GROUP = "group"

        private const val KEY_SESSION_ID = "sessionId"
        private const val KEY_CALLER_UID = "callerUid"
        private const val KEY_CALLER_NAME = "callerName"
        private const val KEY_CALLER_AVATAR = "callerAvatarUrl"
        private const val KEY_CALL_TYPE = "callType"
        private const val KEY_RECEIVER_TYPE = "receiverType"
        private const val KEY_RECEIVER_UID = "receiverUid"
        private const val KEY_CONVERSATION_ID = "conversationId"
        private const val KEY_INITIATED_AT = "initiatedAtMs"
        private const val KEY_RING_TIMEOUT = "ringTimeoutMs"

        /** The inverse of [toMap]. Null without a session id: nothing rings without one. */
        fun fromMap(map: Map<String, String>): IncomingCall? {
            val sessionId = map[KEY_SESSION_ID]?.takeIf { it.isNotBlank() } ?: return null
            return IncomingCall(
                sessionId = sessionId,
                callerUid = map[KEY_CALLER_UID],
                callerName = map[KEY_CALLER_NAME].orEmpty(),
                callerAvatarUrl = map[KEY_CALLER_AVATAR],
                callType = map[KEY_CALL_TYPE] ?: TYPE_AUDIO,
                receiverType = map[KEY_RECEIVER_TYPE] ?: RECEIVER_TYPE_USER,
                receiverUid = map[KEY_RECEIVER_UID],
                conversationId = map[KEY_CONVERSATION_ID],
                initiatedAtMs = map[KEY_INITIATED_AT]?.toLongOrNull() ?: 0L,
                ringTimeoutMs = map[KEY_RING_TIMEOUT]?.toLongOrNull()
                    ?: CallsConstants.DEFAULT_RING_TIMEOUT_MS
            )
        }
    }
}
