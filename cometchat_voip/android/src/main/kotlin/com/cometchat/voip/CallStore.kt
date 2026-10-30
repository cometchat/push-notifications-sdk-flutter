package com.cometchat.voip

import android.content.Context
import android.content.SharedPreferences

/**
 * The one active call, the ledger of sessions already over, and whose device
 * this is.
 *
 * Persisted, because the process very often dies between the push that starts
 * a call and the action that ends it. Every mutation is idempotent per session
 * id, so a duplicate push, a double-tapped Decline and a late cancel are all
 * harmless.
 */
internal object CallStore {

    private const val PREFS = "cometchat_voip_call_store"
    private const val KEY_STATE = "state"
    private const val KEY_ANSWERED_AT = "answeredAt"
    private const val KEY_CALL_PREFIX = "call."
    private const val KEY_TERMINAL_PREFIX = "terminal."
    private const val KEY_TERMINAL_ORDER = "terminal.order"
    private const val KEY_UID = "uid"
    private const val KEY_ANSWERED_SESSION = "answeredSession"
    private const val KEY_HELD_PREFIX = "held.call."
    private const val KEY_HELD_ANSWERED_AT = "held.answeredAt"

    enum class State { RINGING, ANSWERED }

    data class ActiveCall(val call: IncomingCall, val state: State, val answeredAt: Long?)

    @Volatile
    private var cache: ActiveCall? = null

    @Volatile
    private var cacheLoaded = false

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Forgets the in-memory copy, so the next read is from the preferences. Tests only. */
    @Synchronized
    internal fun resetCacheForTesting() {
        cache = null
        cacheLoaded = false
    }

    @Synchronized
    fun get(context: Context): ActiveCall? {
        if (!cacheLoaded) {
            cache = load(prefs(context))
            cacheLoaded = true
        }
        return cache
    }

    fun isRinging(context: Context, sessionId: String): Boolean =
        get(context)?.let { it.state == State.RINGING && it.call.sessionId == sessionId } ?: false

    fun isActive(context: Context, sessionId: String): Boolean =
        get(context)?.call?.sessionId == sessionId

    /**
     * An answered call other than [sessionId] — what makes a decline `busy`.
     *
     * Its own key, because a second incoming call replaces the answered one as
     * "active", and a decline of that second call must still say busy.
     */
    fun answeredSessionOtherThan(context: Context, sessionId: String): String? =
        prefs(context).getString(KEY_ANSWERED_SESSION, null)?.takeIf { it != sessionId }

    @Synchronized
    fun forgetAnswered(context: Context, sessionId: String) {
        val p = prefs(context)
        if (p.getString(KEY_ANSWERED_SESSION, null) == sessionId) {
            p.edit().remove(KEY_ANSWERED_SESSION).apply()
        }
    }

    /**
     * Starts ringing [call]. False when the session is already ringing or
     * answered (a duplicate push) or already over.
     *
     * A different ringing session is replaced. A different *answered* one is
     * not lost: it moves to the held slot while [call] rings, and takes the
     * active slot back when [call] ends without being answered here
     * ([clear]). The single slot used to be overwritten, so a second call
     * made the package forget the live one (native iOS hit and fixed the
     * same: "the single slot was overwritten by the ringing call").
     */
    @Synchronized
    fun setRinging(context: Context, call: IncomingCall): Boolean {
        val current = get(context)
        if (current != null && current.call.sessionId == call.sessionId) return false
        if (wasTerminal(context, call.sessionId)) return false
        if (current != null && current.state == State.ANSWERED) writeHeld(context, current)
        write(context, ActiveCall(call, State.RINGING, null))
        return true
    }

    /** The answered call kept while another one rings, or null. */
    @Synchronized
    fun held(context: Context): ActiveCall? {
        val p = prefs(context)
        val map = HashMap<String, String>()
        for ((k, v) in p.all) {
            if (k.startsWith(KEY_HELD_PREFIX)) (v as? String)?.let { map[k.removePrefix(KEY_HELD_PREFIX)] = it }
        }
        val call = IncomingCall.fromMap(map) ?: return null
        val answeredAt = if (p.contains(KEY_HELD_ANSWERED_AT)) p.getLong(KEY_HELD_ANSWERED_AT, 0L) else null
        return ActiveCall(call, State.ANSWERED, answeredAt)
    }

    /** Forgets the held call when it is [sessionId]: its session ended. */
    @Synchronized
    fun dropHeld(context: Context, sessionId: String) {
        if (held(context)?.call?.sessionId == sessionId) removeHeld(context)
    }

    /**
     * Drops the held call when it is [sessionId], recording [reason] so a
     * late push for it is refused — for a held call found to be over without
     * its session ever reporting an end. Returns what was dropped.
     */
    @Synchronized
    fun clearHeld(context: Context, sessionId: String, reason: String): ActiveCall? {
        val held = held(context)?.takeIf { it.call.sessionId == sessionId } ?: return null
        removeHeld(context)
        val p = prefs(context)
        val editor = p.edit()
        recordTerminal(p, editor, sessionId, reason)
        editor.apply()
        return held
    }

    /**
     * Marks the ringing call answered, at [now]. Null when nothing matched.
     * Answering twice keeps the first `answeredAt`.
     */
    @Synchronized
    fun markAnswered(context: Context, sessionId: String?, now: Long = System.currentTimeMillis()): ActiveCall? {
        val current = get(context) ?: return null
        if (sessionId != null && current.call.sessionId != sessionId) return null
        if (current.state == State.ANSWERED) return current
        val answered = current.copy(state = State.ANSWERED, answeredAt = now)
        write(context, answered)
        // The user took this call over the held one: the app leaves that one to
        // join this, so it is not coming back.
        removeHeld(context)
        prefs(context).edit().putString(KEY_ANSWERED_SESSION, current.call.sessionId).apply()
        return answered
    }

    /**
     * Clears the active call when it is [sessionId] (or whatever it is, for
     * null), recording [reason] so a late duplicate is refused. Returns what
     * was cleared.
     */
    @Synchronized
    fun clear(context: Context, sessionId: String?, reason: String): ActiveCall? {
        val current = get(context) ?: return null
        if (sessionId != null && current.call.sessionId != sessionId) return null
        val p = prefs(context)
        val editor = p.edit()
        editor.remove(KEY_STATE).remove(KEY_ANSWERED_AT)
        for (k in p.all.keys) if (k.startsWith(KEY_CALL_PREFIX)) editor.remove(k)
        if (p.getString(KEY_ANSWERED_SESSION, null) == current.call.sessionId) {
            editor.remove(KEY_ANSWERED_SESSION)
        }
        recordTerminal(p, editor, current.call.sessionId, reason)
        editor.apply()
        cache = null
        cacheLoaded = true
        // A call that rang over a live one ended: the live one is active again.
        held(context)?.takeIf { it.call.sessionId != current.call.sessionId }?.let {
            write(context, it)
        }
        removeHeld(context)
        return current
    }

    private fun writeHeld(context: Context, active: ActiveCall) {
        val p = prefs(context)
        val editor = p.edit()
        for (k in p.all.keys) if (k.startsWith(KEY_HELD_PREFIX)) editor.remove(k)
        for ((k, v) in active.call.toMap()) editor.putString(KEY_HELD_PREFIX + k, v)
        if (active.answeredAt != null) {
            editor.putLong(KEY_HELD_ANSWERED_AT, active.answeredAt)
        } else {
            editor.remove(KEY_HELD_ANSWERED_AT)
        }
        editor.apply()
    }

    private fun removeHeld(context: Context) {
        val p = prefs(context)
        val editor = p.edit()
        for (k in p.all.keys) if (k.startsWith(KEY_HELD_PREFIX)) editor.remove(k)
        editor.remove(KEY_HELD_ANSWERED_AT)
        editor.apply()
    }

    /**
     * Remembers [sessionId] is over without it ever having been active — a
     * cancel that overtook its initiated, or an initiated that came too late.
     */
    @Synchronized
    fun markTerminal(context: Context, sessionId: String, reason: String) {
        val current = get(context)
        if (current != null && current.call.sessionId == sessionId) {
            clear(context, sessionId, reason)
            return
        }
        val p = prefs(context)
        val editor = p.edit()
        recordTerminal(p, editor, sessionId, reason)
        editor.apply()
    }

    fun wasTerminal(context: Context, sessionId: String): Boolean =
        prefs(context).contains(KEY_TERMINAL_PREFIX + sessionId)

    fun terminalReason(context: Context, sessionId: String): String? =
        prefs(context).getString(KEY_TERMINAL_PREFIX + sessionId, null)

    /**
     * Who is logged in. The self-ring and recipient gates run on a cold
     * process woken by a push, before any SDK is up, so this has to have been
     * written down earlier.
     */
    fun setUid(context: Context, uid: String?) {
        val editor = prefs(context).edit()
        if (uid.isNullOrBlank()) editor.remove(KEY_UID) else editor.putString(KEY_UID, uid)
        editor.apply()
    }

    fun uid(context: Context): String? = prefs(context).getString(KEY_UID, null)

    private fun write(context: Context, active: ActiveCall) {
        val p = prefs(context)
        val editor = p.edit()
        for (k in p.all.keys) if (k.startsWith(KEY_CALL_PREFIX)) editor.remove(k)
        for ((k, v) in active.call.toMap()) editor.putString(KEY_CALL_PREFIX + k, v)
        editor.putString(KEY_STATE, active.state.name)
        if (active.answeredAt != null) {
            editor.putLong(KEY_ANSWERED_AT, active.answeredAt)
        } else {
            editor.remove(KEY_ANSWERED_AT)
        }
        editor.apply()
        cache = active
        cacheLoaded = true
    }

    private fun load(p: SharedPreferences): ActiveCall? {
        val stateName = p.getString(KEY_STATE, null) ?: return null
        val map = HashMap<String, String>()
        for ((k, v) in p.all) {
            if (k.startsWith(KEY_CALL_PREFIX)) (v as? String)?.let { map[k.removePrefix(KEY_CALL_PREFIX)] = it }
        }
        val call = IncomingCall.fromMap(map) ?: return null
        val state = runCatching { State.valueOf(stateName) }.getOrNull() ?: return null
        val answeredAt = if (p.contains(KEY_ANSWERED_AT)) p.getLong(KEY_ANSWERED_AT, 0L) else null
        return ActiveCall(call, state, answeredAt)
    }

    /** Session to reason, in insertion order, bounded; re-recording moves one to the back. */
    private fun recordTerminal(
        p: SharedPreferences,
        editor: SharedPreferences.Editor,
        sessionId: String,
        reason: String
    ) {
        val order = (p.getString(KEY_TERMINAL_ORDER, "") ?: "")
            .split(',').filter { it.isNotEmpty() }.toMutableList()
        order.remove(sessionId)
        order.add(sessionId)
        while (order.size > CallsConstants.TERMINAL_LEDGER_SIZE) {
            editor.remove(KEY_TERMINAL_PREFIX + order.removeAt(0))
        }
        editor.putString(KEY_TERMINAL_PREFIX + sessionId, reason)
        editor.putString(KEY_TERMINAL_ORDER, order.joinToString(","))
    }
}
