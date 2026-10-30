import Foundation

/// Why CallKit refused to report a call.
enum ReportError: Error, Equatable {
    /// Do Not Disturb or a Focus filtered it. No ring, no missed call.
    case filteredByDoNotDisturb
    /// The caller is blocked. Same.
    case filteredByBlockList
    /// A call with this UUID is already reported: a duplicate.
    case callUUIDAlreadyExists
    /// The app is not entitled to VoIP calls — a setup error.
    case unentitled
    case unknown(String)
}

/// The ringing surface the state machine drives: CallKit, on the device.
protocol IncomingCallUi: AnyObject {

    /// Rings for `call`. `completion` runs once CallKit accepted or refused the
    /// report; on the VoIP path it is PushKit's acknowledgement, which must not
    /// run any earlier.
    func reportIncomingCall(_ call: IncomingCall, completion: @escaping (ReportError?) -> Void)

    /// Reports a call and ends it at once, for a push that has to be answered
    /// with a report but must not ring.
    func reportAndEndImmediately(callerName: String, hasVideo: Bool, reason: CallEndReason, completion: @escaping () -> Void)

    /// Answers a push about a call that is still showing with a report of that
    /// same call, which CallKit refuses as a duplicate and so draws nothing.
    /// `then` runs on the main queue once the report is made. False, and
    /// `then` never runs, when nothing is showing for `sessionId`.
    func reportAgain(sessionId: String, then: @escaping () -> Void) -> Bool

    /// Ends the call shown for `sessionId`. A no-op for one it does not know.
    func endCall(sessionId: String, reason: CallEndReason)

    func isShowing(sessionId: String) -> Bool
}
