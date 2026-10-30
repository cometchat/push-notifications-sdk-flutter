package com.cometchat.voip

import android.content.Context
import android.os.Process

/**
 * What the Calls SDK's session is doing, as last reported by Dart.
 *
 * The ringer has to decide things synchronously, on the main thread, at moments
 * it cannot wait for anything: whether answering a second call would disturb a
 * live one, whether a prepared session is still unjoined and can be released,
 * whether the keep-alive may stop. The Calls SDK lives behind Dart now, and a
 * channel round trip from the main thread would deadlock — so Dart pushes the
 * state here whenever it changes and the ringer reads this.
 *
 * Persisted, because the decisions are made on processes that started for a
 * notification action and never ran the app.
 *
 * The cost is staleness: a session joined in the millisecond before the read
 * looks unjoined. Every reader treats this as advice, never as permission to
 * end a call — the worse failure by far is tearing down a live call.
 */
internal object SessionState {

    private const val PREFS = "cometchat_voip_session"
    private const val KEY_ACTIVE = "active"
    private const val KEY_JOINED = "joined"
    private const val KEY_SESSION_ID = "sessionId"
    private const val KEY_LOGGED_IN = "loggedIn"
    private const val KEY_UPDATED_AT = "updatedAt"
    private const val KEY_PID = "pid"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Dart reporting the session it sees. */
    fun update(
        context: Context,
        active: Boolean,
        joined: Boolean,
        sessionId: String?
    ) {
        prefs(context).edit()
            .putBoolean(KEY_ACTIVE, active)
            .putBoolean(KEY_JOINED, joined)
            .putString(KEY_SESSION_ID, sessionId)
            .putLong(KEY_UPDATED_AT, System.currentTimeMillis())
            .putInt(KEY_PID, Process.myPid())
            .apply()
    }

    /** Dart reporting whether anyone is logged in to the Calls SDK. */
    fun setLoggedIn(context: Context, loggedIn: Boolean) {
        prefs(context).edit().putBoolean(KEY_LOGGED_IN, loggedIn).apply()
    }

    /** Preparing, prepared, joining or joined. */
    fun isActive(context: Context): Boolean = prefs(context).getBoolean(KEY_ACTIVE, false)

    fun isJoined(context: Context): Boolean = prefs(context).getBoolean(KEY_JOINED, false)

    /** The session the SDK prepared or joined, if any. */
    fun ownedSessionId(context: Context): String? =
        prefs(context).getString(KEY_SESSION_ID, null)

    /**
     * Whether this process wrote the last report. A joined session does not
     * outlive its process, so a "joined" written by a process that has since
     * died (killed mid-call, nothing reported) is stale, however recent.
     */
    fun reportedByThisProcess(context: Context): Boolean =
        prefs(context).getInt(KEY_PID, -1) == Process.myPid()

    fun isLoggedIn(context: Context): Boolean = prefs(context).getBoolean(KEY_LOGGED_IN, false)

    /**
     * How long ago Dart last reported, or null before it ever has.
     *
     * The one thing that makes this snapshot safe to refuse a call on. A
     * process killed mid-call reports nothing, so `active` stays true for
     * ever, and an unjoined session that old is stale state rather than a call
     * still ringing — refusing on it would make every later call busy.
     */
    fun reportedAgeMs(context: Context, now: Long = System.currentTimeMillis()): Long? {
        val at = prefs(context).getLong(KEY_UPDATED_AT, 0L)
        return if (at <= 0L) null else (now - at).coerceAtLeast(0L)
    }

    /** Forgotten on logout, so a stale uid cannot gate the next user's calls. */
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
    }
}
