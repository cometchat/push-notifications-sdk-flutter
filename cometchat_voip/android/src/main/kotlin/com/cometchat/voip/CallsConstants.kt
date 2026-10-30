package com.cometchat.voip

/**
 * Every shared value of the ringer, in one place.
 *
 * Channel ids carry a version suffix because Android freezes a channel's
 * importance and sound when it is created: changing a default means a `_v2`,
 * never editing `_v1`.
 */
internal object CallsConstants {

    const val INCOMING_CHANNEL_ID = "cometchat_voip_incoming_calls_v1"
    const val MISSED_CHANNEL_ID = "cometchat_voip_missed_calls_v1"
    /** Low importance: moving an answered ring onto it is what stops the ringtone. */
    const val ONGOING_CHANNEL_ID = "cometchat_voip_ongoing_calls_v1"

    // The ring is posted untagged under an id derived from its session: a
    // foreground service can take over a notification only by id, and the
    // keep-alive taking the ring over is what keeps the tray to one entry per
    // call. Missed calls share one id, tagged with the session.
    private const val INCOMING_NOTIFICATION_ID_BASE = 0x5643_0000
    private const val INCOMING_NOTIFICATION_ID_SPAN = 0x1_0000
    const val MISSED_NOTIFICATION_ID = 0x5643_F001
    const val MISSED_SUMMARY_NOTIFICATION_ID = 0x5643_F000
    /** Missed calls group under their own summary, not Android's app-wide one. */
    const val MISSED_GROUP_KEY = "com.cometchat.voip.MISSED_CALLS"

    fun incomingNotificationId(sessionId: String): Int =
        INCOMING_NOTIFICATION_ID_BASE + Math.floorMod(sessionId.hashCode(), INCOMING_NOTIFICATION_ID_SPAN)

    /** How many low bits of a request code name the session. */
    private const val REQUEST_SESSION_BITS = 20

    /**
     * A request code for [kind] that is this session's alone.
     *
     * A `PendingIntent` is identified by its request code and
     * `Intent.filterEquals` — which ignores extras — and ours are built with
     * `FLAG_UPDATE_CURRENT`. So two calls whose intents compare equal share
     * one PendingIntent, and the second call's extras replace the first's:
     * the first ring's alert would open the second call. Every intent that
     * carries a per-session data URI is already distinct; this is for the one
     * that cannot have one, the intent that opens the **app** — Flutter reads
     * a data URI on it as a deep link and pushes it as a route the app does
     * not have.
     */
    fun ringRequestCode(kind: Int, sessionId: String): Int =
        (kind shl REQUEST_SESSION_BITS) +
            Math.floorMod(sessionId.hashCode(), 1 shl REQUEST_SESSION_BITS)

    private const val PREFIX = "com.cometchat.voip"
    const val ACTION_DECLINE = "$PREFIX.ACTION_DECLINE"
    const val ACTION_TIMEOUT = "$PREFIX.ACTION_TIMEOUT"
    const val ACTION_DISMISS = "$PREFIX.ACTION_DISMISS"
    const val EXTRA_PREFIX = "$PREFIX.call."

    // Timings, all milliseconds.
    /** How long a call rings when the push does not say. */
    const val DEFAULT_RING_TIMEOUT_MS = 45_000L
    /** Added to the expiry alarm, so an inexact alarm still fires after the deadline. */
    const val RING_ALARM_SLACK_MS = 5_000L
    /** How long connect-while-ringing may take before the ring carries on unverified. */
    const val VERIFY_BUDGET_MS = 5_000L
    const val VERIFY_RETRY_INTERVAL_MS = 1_000L
    const val VERIFY_MAX_RETRIES = 5
    /** The longest the keep-alive service may run. */
    const val KEEP_ALIVE_CAP_MS = 60_000L
    /** How often the keep-alive checks whether an answered call has joined. */
    const val JOIN_POLL_INTERVAL_MS = 500L
    /**
     * How long after Answer an answered call may still be joining. Past it,
     * one the Calls SDK is not in a session for is over — its process died
     * mid-call and nothing is left to report its end. Same window as iOS's
     * `answerToJoinedCapMs`.
     */
    const val ANSWER_TO_JOINED_CAP_MS = 20_000L
    /** The decline waits this long, polling, for the Calls login to come back. */
    const val DECLINE_POLL_INTERVAL_MS = 250L
    const val DECLINE_POLL_BUDGET_MS = 3_000L
    /** Attempts before a decline is dropped; with a 10 s exponential backoff the last is minutes out. */
    const val DECLINE_MAX_ATTEMPTS = 5
    /** How long the Calls SDK may take to initialise on a cold process. */
    const val SDK_INIT_TIMEOUT_MS = 10_000L

    /**
     * The longest an unjoined session is believed to be a call still ringing.
     *
     * Past it the snapshot Dart pushed is treated as stale — a process that
     * died mid-call — rather than as this user being busy, because the cost of
     * believing it is every later call being refused.
     */
    const val OUTGOING_RING_FRESHNESS_MS = 60_000L

    /** Sessions remembered as over, so a late push for one never rings. */
    const val TERMINAL_LEDGER_SIZE = 20

    /** A ring window outside this range is a malformed payload, not an instruction. */
    const val MIN_RING_TIMEOUT_MS = 1_000L
    const val MAX_RING_TIMEOUT_MS = 600_000L

    // The statuses CometChatCalls.endCall accepts.
    const val CALL_STATUS_REJECTED = "rejected"
    const val CALL_STATUS_BUSY = "busy"
    const val CALL_STATUS_CANCELLED = "cancelled"
    const val CALL_STATUS_UNANSWERED = "unanswered"
}
