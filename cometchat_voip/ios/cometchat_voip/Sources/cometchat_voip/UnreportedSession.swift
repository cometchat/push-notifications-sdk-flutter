import Foundation

/// Outgoing calls reach CallKit without the app's help.
///
/// Incoming calls are on CallKit from the push. An outgoing call — the session
/// `initiateCall` prepares, or a plain `joinSession` — is on CallKit only if
/// the app called `reportOutgoingCall`, and an app that did not got a call
/// with no native screen: nothing to hang up from the lock screen, nothing in
/// Recents, and nothing to survive a cellular interruption. So when the Calls
/// SDK owns a session that CallKit has not heard of, and that session is not
/// an incoming call, this package reports it as outgoing itself.
///
/// Pure: the inputs are the store and what Dart reports about the session, so
/// the decision is testable on fakes. Ported from the native iOS SDK's
/// `UnreportedSession`.
enum UnreportedSession {

    /// The session to report to CallKit as an outgoing call, or nil when there
    /// is none.
    ///
    /// - Parameters:
    ///   - ownedSessionId: The session the Calls SDK holds.
    ///   - trackedSessionId: The session the CallKit sync already tracks — an
    ///     answered incoming call, or an outgoing one the app or this package
    ///     reported.
    ///   - isOnCallKit: Whether CallKit already shows `sessionId`.
    ///   - store: The incoming-call store. A session it holds, ringing or
    ///     answered, is an incoming call; one in its terminal ledger was an
    ///     incoming call that is over — a decline leaves its prepared session
    ///     open until `endCall` has announced the status from inside it.
    static func outgoingSessionToReport(ownedSessionId: String?,
                                        trackedSessionId: String?,
                                        isOnCallKit: (String) -> Bool,
                                        store: CallStore) -> String? {
        guard let sessionId = ownedSessionId?.nonBlank else { return nil }
        guard trackedSessionId == nil else { return nil }
        guard !isOnCallKit(sessionId) else { return nil }
        guard !store.isActive(sessionId: sessionId) else { return nil }
        guard !store.wasTerminal(sessionId: sessionId) else { return nil }
        return sessionId
    }
}
