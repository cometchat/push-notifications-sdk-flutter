package com.cometchat.push_notifications

import android.util.Log as AndroidLog

/**
 * The package's log tag, in one place.
 *
 * Nothing here ever logs a push token or message body: a token is a live
 * credential for the device, and a body is the user's private conversation.
 */
internal object Log {
    private const val TAG = "CometChatPN"

    fun d(message: String) = AndroidLog.d(TAG, message)
    fun w(message: String) = AndroidLog.w(TAG, message)
    fun e(message: String, error: Throwable? = null) = AndroidLog.e(TAG, message, error)
}
