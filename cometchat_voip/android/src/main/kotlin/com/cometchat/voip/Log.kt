package com.cometchat.voip

import android.util.Log as AndroidLog

/**
 * The package's log tag, in one place.
 *
 * Nothing here ever logs a push token, an auth token or a payload: the first
 * two are live credentials, and the Calls SDK already logs auth headers.
 */
internal object Log {
    private const val TAG = "CometChatVoip"

    fun d(message: String) = AndroidLog.d(TAG, message).let { }
    fun w(message: String) = AndroidLog.w(TAG, message).let { }
    fun e(message: String, error: Throwable? = null) = AndroidLog.e(TAG, message, error).let { }
}
