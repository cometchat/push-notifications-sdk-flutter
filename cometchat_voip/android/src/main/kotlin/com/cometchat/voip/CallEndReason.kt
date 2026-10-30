package com.cometchat.voip

/**
 * Why a call stopped ringing — the vocabulary Dart sees on both platforms,
 * whatever the push called it.
 */
internal enum class CallEndReason(val wire: String) {
    ANSWERED_ELSEWHERE("answeredElsewhere"),
    /** The caller hung up before anyone answered. Missed. */
    CANCELLED("cancelled"),
    DECLINED("declined"),
    /** Nobody answered in the ring window. Missed. */
    TIMED_OUT("timedOut"),
    REMOTE_ENDED("remoteEnded"),
    FAILED("failed");

    /** Whether the user missed the call, which is what posts a missed-call notification. */
    val isMissed: Boolean get() = this == CANCELLED || this == TIMED_OUT

    companion object {
        /**
         * The reason a terminal push ends the ringing with. `ended` for a call
         * still ringing is the caller's device saying it is over: not missed.
         */
        fun of(action: CallPushPayload.Action): CallEndReason = when (action) {
            CallPushPayload.Action.CANCELLED -> CANCELLED
            CallPushPayload.Action.UNANSWERED, CallPushPayload.Action.TIMED_OUT -> TIMED_OUT
            CallPushPayload.Action.ONGOING -> ANSWERED_ELSEWHERE
            CallPushPayload.Action.REJECTED,
            CallPushPayload.Action.BUSY,
            CallPushPayload.Action.ENDED -> DECLINED
            CallPushPayload.Action.INITIATED, CallPushPayload.Action.UNKNOWN -> REMOTE_ENDED
        }

        /**
         * The reason for the Calls SDK's own end signal. Android reports
         * `cancelled`, `rejected`, `busy`, `ended`, `unanswered`, or `ongoing`
         * when the call was answered on another device.
         */
        fun ofSdkReason(reason: String): CallEndReason = of(CallPushPayload.Action.from(reason))
    }
}
