import Foundation

/// What the Calls SDK's session and login are doing, as Dart last reported.
///
/// The ring machinery asks these synchronously, in places that cannot wait: a
/// `CXAnswerCallAction` has to be fulfilled promptly, and the gates run on a
/// process PushKit just started. The Calls SDK lives behind Dart now, so a
/// round trip would mean blocking the main thread — and CallKit's callbacks
/// arrive there. Dart pushes the state instead, and this is what gets read.
///
/// Persisted, because PushKit can launch the app for a call and the first read
/// happens before Dart has said anything.
///
/// The cost is staleness: a session joined in the millisecond before a read
/// looks unjoined. Every reader treats it as advice, never as permission to
/// end a call — tearing down a live call is the worse failure by far.
struct SessionSnapshot {

    private static let keyActive = "session.active"
    private static let keyJoined = "session.joined"
    private static let keySessionId = "session.id"
    private static let keyLoggedIn = "session.loggedIn"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Dart reporting the session it sees.
    func update(active: Bool, joined: Bool, sessionId: String?) {
        defaults.set(active, forKey: Self.keyActive)
        defaults.set(joined, forKey: Self.keyJoined)
        if let sessionId = sessionId {
            defaults.set(sessionId, forKey: Self.keySessionId)
        } else {
            defaults.removeObject(forKey: Self.keySessionId)
        }
    }

    /// Dart reporting whether anyone is logged in to the Calls SDK.
    var isLoggedIn: Bool {
        get { defaults.bool(forKey: Self.keyLoggedIn) }
        nonmutating set { defaults.set(newValue, forKey: Self.keyLoggedIn) }
    }

    /// Preparing, prepared, joining or joined.
    var isActive: Bool { defaults.bool(forKey: Self.keyActive) }

    var isJoined: Bool { defaults.bool(forKey: Self.keyJoined) }

    /// The session the SDK prepared or joined, if any.
    var ownedSessionId: String? { defaults.string(forKey: Self.keySessionId) }
}
