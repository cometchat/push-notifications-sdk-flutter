package com.cometchat.voip

import java.util.concurrent.ConcurrentHashMap

/**
 * Open ring screens, by session, so each can be closed when its ring ends
 * elsewhere. Cancelling a notification does not close the activity it
 * launched; without this a cancelled call would leave an Answer button on the
 * lock screen for a call that no longer exists.
 */
internal object RingSurfaces {

    private val surfaces = ConcurrentHashMap<String, () -> Unit>()

    fun register(sessionId: String, close: () -> Unit) {
        surfaces[sessionId] = close
    }

    fun unregister(sessionId: String) {
        surfaces.remove(sessionId)
    }

    fun finish(sessionId: String) {
        surfaces.remove(sessionId)?.let { runCatching(it) }
    }
}
