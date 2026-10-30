package com.cometchat.push_notifications

/**
 * One chat message, as Dart hands it over for display.
 *
 * Dart has already parsed the push payload and decided this is a chat message
 * worth showing, so nothing here re-derives that.
 */
internal data class PushMessage(
    val title: String,
    val body: String,
    val sender: String,
    val senderName: String,
    val senderAvatar: String?,
    val receiver: String,
    val receiverType: String,
    val messageId: String
) {
    /** Whether this went to a group rather than a person. */
    val isGroup: Boolean get() = receiverType.equals("group", ignoreCase = true)

    /**
     * What identifies the conversation: the other person for a 1:1 chat, the
     * group for a group chat. Every notification id is derived from this, so
     * messages in one conversation collapse into one notification.
     */
    val conversationKey: String
        get() = (if (isGroup) receiver else sender).ifBlank { messageId }

    companion object {
        fun fromMap(map: Map<*, *>): PushMessage {
            fun str(key: String) = map[key] as? String ?: ""
            return PushMessage(
                title = str("title"),
                body = str("body"),
                sender = str("sender"),
                senderName = str("senderName"),
                senderAvatar = map["senderAvatar"] as? String,
                receiver = str("receiver"),
                receiverType = str("receiverType"),
                messageId = str("messageId")
            )
        }
    }
}
