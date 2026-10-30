import Foundation

/// Every timing and size the ringer uses, in one place.
enum RingConstants {

    /// How long a call rings when the push does not say. The push's value wins.
    static let defaultRingTimeoutMs: Int64 = 45_000

    /// How long connect-while-ringing may take before the ring carries on unverified.
    static let verifyBudgetMs = 5_000
    static let verifyRetryIntervalMs = 1_000
    static let verifyMaxRetries = 5

    /// Added to the ring deadline before the expiry fires, absorbing delivery jitter.
    static let expirySlackMs: Int64 = 2_000

    /// How long a decline may hold a background task before it is kept for replay.
    static let declineBudgetMs = 12_000

    /// Sessions remembered as over, so a late push for one never rings.
    static let terminalLedgerSize = 20

    /// A ring window outside this range is a malformed payload, not an instruction.
    static let minRingTimeoutMs: Int64 = 1_000
    static let maxRingTimeoutMs: Int64 = 600_000

    /// An answered call that has not joined by then is ended, rather than left
    /// as a silent live call in CallKit.
    static let answerToJoinedCapMs = 20_000

    /// How long `getVoipToken` waits for PushKit to issue a token.
    static let voipTokenWaitMs = 10_000

    /// The statuses `CometChatCalls.endCall` accepts.
    enum Status {
        static let rejected = "rejected"
        static let busy = "busy"
        static let cancelled = "cancelled"
        static let unanswered = "unanswered"
    }

    /// The terminal actions that tell a caller its call ended before anyone
    /// joined. Not `ongoing` (the callee answered: the caller hears that in the
    /// room) and not `ended` (a joined call ends with its session).
    static let callerEndActions: Set<String> = [
        Status.rejected, Status.busy, Status.cancelled, Status.unanswered,
    ]

    /// The terminal actions the *other* side of a one-to-one call sends about a
    /// call this user placed. The backend puts whoever acted in `sender` — the
    /// callee — and the caller in `receiver`. Not `cancelled` or `unanswered`:
    /// with this user as `receiver` those mean the caller gave up on a call
    /// ringing here, which must still stop the ring.
    static let declinedByCallee: Set<String> = [Status.rejected, Status.busy]
}
