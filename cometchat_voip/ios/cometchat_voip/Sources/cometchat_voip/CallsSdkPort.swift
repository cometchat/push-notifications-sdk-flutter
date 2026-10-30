import Foundation

/// The outcome of a pre-join `connect`.
enum ConnectResult: Equatable {
    /// The conference took us: the call is alive and the caller sees it ring.
    case connected
    /// `retryable` marks the SDK not being ready yet on a cold process, as
    /// opposed to a real refusal.
    case failed(code: String, message: String?, retryable: Bool)
}

/// The ringer's view of the Calls SDK. `CometChatCallsSdkAdapter` is the only
/// implementation, and the only file that names `CometChatCalls`.
protocol CallsSdkPort: AnyObject {

    /// Brings the Calls SDK up on a cold process. Completes on the main queue.
    func ensureInitialised(config: VoipConfig, completion: @escaping (Bool) -> Void)

    var isLoggedIn: Bool { get }
    var loggedInUid: String? { get }

    /// Joins the conference without media while the phone rings.
    func connect(_ call: IncomingCall, completion: @escaping (ConnectResult) -> Void)

    /// Declines (`rejected` or `busy`) before joining.
    func endCall(sessionId: String, status: String, completion: @escaping (Bool) -> Void)

    /// Preparing, prepared, joining or joined.
    var isSessionActive: Bool { get }
    var ownedSessionId: String? { get }
    var isSessionJoined: Bool { get }

    /// Releases a session prepared while ringing that nobody joined.
    func leaveSession()

    /// Hands the call to the Calls SDK's `IncomingCallListener`s.
    func injectIncomingCall(_ call: IncomingCall)
    func injectIncomingCallEnded(_ call: IncomingCall, reason: CallEndReason)

    /// Hands the terminal push for a call this user placed to the Calls SDK,
    /// with the push's own action (`rejected`, `busy`, `cancelled`,
    /// `unanswered`) as the reason, so the caller's `IncomingCallListener`
    /// hears how its call ended.
    func injectOwnCallEnded(_ call: IncomingCall, action: String)
}
