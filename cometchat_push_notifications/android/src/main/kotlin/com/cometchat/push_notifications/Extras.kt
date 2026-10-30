package com.cometchat.push_notifications

/**
 * The intent extra keys carried from a posted notification back to Dart.
 *
 * Prefixed with the package name so they cannot collide with the host app's
 * own extras on the launch intent they ride in on.
 */
internal object Extras {
    private const val PREFIX = "com.cometchat.push_notifications."

    const val IS_COMETCHAT = PREFIX + "is_cometchat"
    const val CONVERSATION_ID = PREFIX + "conversation_id"
    const val RECEIVER_TYPE = PREFIX + "receiver_type"
    const val SENDER = PREFIX + "sender"
    const val SENDER_NAME = PREFIX + "sender_name"
    const val SENDER_AVATAR = PREFIX + "sender_avatar"
    const val MESSAGE_ID = PREFIX + "message_id"
    const val NOTIFICATION_ID = PREFIX + "notification_id"

}
