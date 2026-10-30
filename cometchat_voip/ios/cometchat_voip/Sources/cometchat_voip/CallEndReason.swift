import CallKit
import Foundation

/// Why a call stopped ringing or ended — the vocabulary Dart sees on both
/// platforms, independent of CallKit's and the Calls SDK's own.
enum CallEndReason: String, CaseIterable {
    /// Answered on this device. Never reported to Dart as an end.
    case answered
    /// Answered on another of this user's devices.
    case answeredElsewhere
    /// The caller hung up before anyone answered. Missed.
    case cancelled
    /// Declined on this device.
    case declined
    /// Nobody answered in the ring window. Missed.
    case timedOut
    /// The other side ended a live call, or the caller's device reported it over.
    case remoteEnded
    /// The call could not be set up or kept going.
    case failed
    /// Dropped before ringing, or filtered by the system.
    case filtered

    /// The one place these meet CallKit. It decides whether the call leaves a
    /// missed call in Recents: only `.unanswered` and `.remoteEnded` do.
    var cxReason: CXCallEndedReason {
        switch self {
        case .cancelled, .remoteEnded: return .remoteEnded
        case .timedOut: return .unanswered
        case .declined: return .declinedElsewhere
        case .answeredElsewhere, .answered, .filtered: return .answeredElsewhere
        case .failed: return .failed
        }
    }

    /// Whether ending a call that never rang with this reason should still
    /// leave a missed call, because the user did miss it.
    var leavesMissedCall: Bool {
        switch self {
        case .cancelled, .timedOut, .remoteEnded: return true
        case .answered, .answeredElsewhere, .declined, .failed, .filtered: return false
        }
    }
}
