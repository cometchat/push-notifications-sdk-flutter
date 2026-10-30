package com.cometchat.voip

import android.content.Intent
import android.net.Uri
import android.os.Bundle

/** Carries an [IncomingCall] through the package's intents. */
internal object CallBundles {

    private const val URI_SCHEME = "cometchat-voip"
    const val KIND_FULL_SCREEN = "fullscreen"
    const val KIND_ANSWER = "answer"

    /** Set on the intent that opens the app for an answered call. */
    const val EXTRA_ANSWERED = "com.cometchat.voip.ANSWERED"

    /**
     * Set on the intent that opens the app *to ring*, in
     * `CometChatCallMode.autoCustomScreen`: the full-screen alert, or its tap,
     * where `auto` would open [IncomingCallActivity].
     */
    const val EXTRA_RING_SCREEN = "com.cometchat.voip.RING_SCREEN"

    /** True when answering the call in [intent] ends one that is live. */
    const val EXTRA_ENDS_ACTIVE_CALL = "com.cometchat.voip.ENDS_ACTIVE_CALL"

    fun putCall(intent: Intent, call: IncomingCall): Intent {
        for ((k, v) in call.toMap()) intent.putExtra(CallsConstants.EXTRA_PREFIX + k, v)
        return intent
    }

    fun getCall(intent: Intent?): IncomingCall? = getCall(intent?.extras)

    fun getCall(bundle: Bundle?): IncomingCall? {
        if (bundle == null) return null
        val map = HashMap<String, String>()
        for (key in bundle.keySet()) {
            if (key.startsWith(CallsConstants.EXTRA_PREFIX)) {
                bundle.getString(key)?.let { map[key.removePrefix(CallsConstants.EXTRA_PREFIX)] = it }
            }
        }
        return IncomingCall.fromMap(map)
    }

    /** Removes the call from [intent], so a redelivered intent does not act twice. */
    fun strip(intent: Intent) {
        intent.extras?.keySet()?.filter { it.startsWith(CallsConstants.EXTRA_PREFIX) }
            ?.forEach(intent::removeExtra)
        intent.removeExtra(EXTRA_ANSWERED)
        intent.removeExtra(EXTRA_RING_SCREEN)
        intent.removeExtra(EXTRA_ENDS_ACTIVE_CALL)
    }

    /**
     * A per-session data URI such as `cometchat-voip://timeout/<sessionId>`.
     *
     * `Intent.filterEquals` compares the data URI but ignores extras, so
     * PendingIntents for different sessions never collide, and an alarm can be
     * cancelled by rebuilding the same intent with nothing stored.
     */
    fun sessionUri(kind: String, sessionId: String): Uri =
        Uri.parse("$URI_SCHEME://$kind/${Uri.encode(sessionId)}")
}
