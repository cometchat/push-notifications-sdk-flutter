import Foundation

/// Whether a call push deserves to ring at all.
///
/// Every gate reads persisted state only. This runs on a process PushKit
/// started to deliver the push, where no SDK is logged in and nothing is in
/// memory.
enum RingGate {

    enum Decision: Equatable {
        case ring
        /// `endAs` is the reason the mandatory CallKit report is ended with;
        /// `markTerminal` records the session so a later duplicate cannot revive it.
        case drop(reason: String, endAs: CallEndReason, markTerminal: Bool)
    }

    static func decide(_ call: IncomingCall, store: CallStore, nowMs: Int64) -> Decision {
        let myUid = store.uid

        // The backend fans a call out to every device of every participant,
        // the caller's own included.
        if let myUid = myUid, call.callerUid == myUid {
            return .drop(reason: "self-ring: the caller is this user", endAs: .filtered, markTerminal: false)
        }

        // Addressed to someone else — only when both sides are known.
        if let myUid = myUid, let receiver = call.receiverUid, call.isPeerCall, receiver != myUid {
            return .drop(reason: "addressed to \(receiver), not this user", endAs: .filtered, markTerminal: false)
        }

        if store.wasTerminal(sessionId: call.sessionId) {
            return .drop(reason: "already over (\(store.terminalReason(sessionId: call.sessionId) ?? "?"))", endAs: .filtered, markTerminal: false)
        }

        // APNs holds pushes while a device is offline, so one can arrive long
        // after the caller gave up. `.timedOut` leaves the missed call the user
        // really did miss.
        if nowMs >= call.expiresAtMs {
            return .drop(reason: "expired \(nowMs - call.expiresAtMs)ms ago", endAs: .timedOut, markTerminal: true)
        }

        return .ring
    }
}
