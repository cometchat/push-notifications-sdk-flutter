import Flutter
import Foundation

/// The ringer's way into Dart.
///
/// This package links **only** `cometchat_calls_sdk`, never the native Calls
/// SDK, so nothing here can ring, connect or decline by itself. Dart does it,
/// and this is the way across.
///
/// iOS needs no background isolate, unlike Android: a VoIP push launches the
/// app, and CallKit will not deliver an action to a process that is not
/// running. So the app's own isolate is always the one that answers — it may
/// just not be up *yet*, on a push that launched a killed app. A request that
/// arrives first is queued and sent the moment Dart says it is ready.
final class DartCallsBridge {

    static let shared = DartCallsBridge()

    private let lock = NSLock()
    private var channel: FlutterMethodChannel?
    private var queue: [(method: String, args: [String: Any], completion: ((Any?) -> Void)?)] = []

    private init() {}

    // MARK: - Wiring, from the plugin

    /// Dart announcing it can serve requests. Flushes whatever was waiting.
    func dartIsReady(_ channel: FlutterMethodChannel) {
        lock.lock()
        self.channel = channel
        let waiting = queue
        queue.removeAll()
        lock.unlock()
        waiting.forEach { send($0.method, $0.args, $0.completion) }
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return channel != nil
    }

    // MARK: - Calling Dart

    /// Invokes `method` in Dart, queueing it when Dart is not up yet.
    /// `completion` runs on the main queue, with nil when nothing answered.
    func invoke(
        _ method: String,
        _ args: [String: Any] = [:],
        completion: ((Any?) -> Void)? = nil
    ) {
        lock.lock()
        let live = channel
        if live == nil {
            queue.append((method, args, completion))
        }
        lock.unlock()
        if live != nil { send(method, args, completion) }
    }

    /// Invokes `method` and gives Dart up to `timeout` to answer.
    ///
    /// For the one place that has to wait: a VoIP push must be answered with a
    /// reported call before its completion handler returns, and the Calls SDK
    /// is what reports it. Runs `completion` exactly once, on the main queue.
    func invoke(
        _ method: String,
        _ args: [String: Any] = [:],
        timeout: TimeInterval,
        completion: @escaping (Any?) -> Void
    ) {
        var settled = false
        let settle: (Any?) -> Void = { reply in
            guard !settled else { return }
            settled = true
            completion(reply)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !settled {
                VoipLog.w("\(method) got no reply from Dart in \(timeout)s")
            }
            settle(nil)
        }
        invoke(method, args) { settle($0) }
    }

    private func send(
        _ method: String,
        _ args: [String: Any],
        _ completion: ((Any?) -> Void)?
    ) {
        DispatchQueue.main.async {
            self.lock.lock()
            let live = self.channel
            self.lock.unlock()
            guard let live = live else {
                // Lost between the check and the hop; queue it again.
                self.lock.lock()
                self.queue.append((method, args, completion))
                self.lock.unlock()
                return
            }
            live.invokeMethod(method, arguments: args) { reply in
                if let error = reply as? FlutterError {
                    VoipLog.w("\(method) failed in Dart: \(error.code) \(error.message ?? "")")
                    completion?(nil)
                } else if reply is NSNull {
                    completion?(nil)
                } else {
                    completion?(reply)
                }
            }
        }
    }
}

/// The ringer's view of the Calls SDK, served by Dart.
///
/// `CallsSdkPort` as the ring machinery expects it, but every call crosses to
/// `NativeCallsBridge` in Dart instead of into a linked SDK — this package
/// depends on `cometchat_calls_sdk` and names no native SDK.
///
/// The synchronous members of the port cannot be round trips: CallKit's
/// callbacks arrive on the main thread and blocking it would deadlock. Those
/// read `SessionSnapshot`, which Dart pushes whenever the session changes.
final class DartCallsSdk: CallsSdkPort {

    static let shared = DartCallsSdk()
    private let bridge = DartCallsBridge.shared
    let snapshot = SessionSnapshot(defaults: VoipConfig.defaults)

    private init() {}

    // MARK: - Bringing Dart up

    /// Waits for an isolate to be able to serve, which is the nearest thing to
    /// "the SDK is up" from here: `NativeCallsBridge` initialises the Calls SDK
    /// itself before answering.
    func ensureInitialised(config: VoipConfig, completion: @escaping (Bool) -> Void) {
        if bridge.isReady {
            completion(true)
            return
        }
        bridge.invoke("calls.loggedInUid", timeout: 10) { _ in
            completion(self.bridge.isReady)
        }
    }

    // MARK: - Snapshot reads

    var isLoggedIn: Bool { snapshot.isLoggedIn }
    var loggedInUid: String? { VoipCore.shared.store.uid }
    var isSessionActive: Bool { snapshot.isActive }
    var ownedSessionId: String? { snapshot.ownedSessionId }
    var isSessionJoined: Bool { snapshot.isJoined }

    // MARK: - Asking Dart to act

    /// Joins the conference without media while the phone rings, so answering
    /// only adds media and the caller's `onParticipantConnected` fires.
    func connect(_ call: IncomingCall, completion: @escaping (ConnectResult) -> Void) {
        bridge.invoke(
            "calls.connect",
            [
                "sessionId": call.sessionId,
                "isVideo": call.isVideo,
                "isPeerCall": call.isPeerCall
            ]
        ) { reply in
            guard let map = reply as? [String: Any] else {
                completion(.failed(code: "NO_REPLY", message: "Dart did not answer", retryable: true))
                return
            }
            if map["status"] as? String == "connected" {
                completion(.connected)
            } else {
                completion(.failed(
                    code: map["code"] as? String ?? "UNKNOWN",
                    message: map["message"] as? String,
                    retryable: map["retryable"] as? Bool ?? false
                ))
            }
        }
    }

    /// Declines (`rejected` or `busy`) before the call is joined.
    func endCall(sessionId: String, status: String, completion: @escaping (Bool) -> Void) {
        bridge.invoke(
            "calls.endCall",
            ["sessionId": sessionId, "status": status]
        ) { completion(($0 as? Bool) ?? false) }
    }

    /// Releases a session prepared while ringing that nobody joined.
    func leaveSession() {
        bridge.invoke("calls.leaveSession")
    }

    /// Hands the call to the Calls SDK, whose `IncomingCallListener`s then hear
    /// it exactly as they hear any other incoming call.
    ///
    /// This does **not** ring it: `injectIncomingCall` reports nothing to
    /// CallKit. `CallKitManager` here is what rings.
    func injectIncomingCall(_ call: IncomingCall) {
        bridge.invoke(
            "calls.injectIncomingCall",
            ["payload": Self.payload(call, callAction: "initiated")]
        )
    }

    func injectIncomingCallEnded(_ call: IncomingCall, reason: CallEndReason) {
        bridge.invoke(
            "calls.injectIncomingCallEnded",
            [
                "payload": Self.payload(call, callAction: reason.rawValue),
                "reason": reason.rawValue
            ]
        )
    }

    func injectOwnCallEnded(_ call: IncomingCall, action: String) {
        bridge.invoke(
            "calls.injectIncomingCallEnded",
            [
                "payload": Self.payload(call, callAction: action),
                "reason": action
            ]
        )
    }

    func loggedInUid(completion: @escaping (String?) -> Void) {
        bridge.invoke("calls.loggedInUid") { completion($0 as? String) }
    }

    /// Hands the audio session CallKit just activated to WebRTC.
    ///
    /// `completion` carries whether the Calls SDK took it. False means this
    /// Calls SDK has no way to be told — `CometChatAudioSession.activate` is
    /// native-only and its Dart binding is newer than this package — and the
    /// CallKit audio mode must stay off, or the call would be silent.
    func callKitAudioActivated(completion: @escaping (Bool) -> Void) {
        bridge.invoke("calls.callKitAudioActivated") {
            completion(($0 as? Bool) ?? false)
        }
    }

    func callKitAudioDeactivated() {
        bridge.invoke("calls.callKitAudioDeactivated")
    }

    /// The call in the key names the Calls SDK parses. The two name the same
    /// fields differently — `callerUid` here is `sender` there — so passing
    /// `IncomingCall.toMap()` would fill in a session id and nothing else.
    static func payload(_ call: IncomingCall, callAction: String) -> [String: String] {
        var map: [String: String] = [
            "sessionId": call.sessionId,
            "senderName": call.callerName,
            "receiverType": call.receiverType,
            "callType": call.callType,
            "callAction": callAction,
            "initiatedAt": String(call.initiatedAtMs)
        ]
        call.callerUid.map { map["sender"] = $0 }
        call.callerAvatarUrl.map { map["senderAvatar"] = $0 }
        call.receiverUid.map { map["receiver"] = $0 }
        call.conversationId.map { map["conversationId"] = $0 }
        return map
    }
}

/// The live session, driven through Dart for `CallKitSyncEngine`.
///
/// Mute and hold from the CallKit UI are user actions, so a round trip is fine
/// — nobody notices a few milliseconds. `isJoined` is the snapshot, because the
/// sync asks it inside CallKit callbacks.
final class DartSessionControl: SessionControl {

    private let bridge = DartCallsBridge.shared
    private let snapshot: SessionSnapshot

    init(snapshot: SessionSnapshot) {
        self.snapshot = snapshot
    }

    func muteAudio() { bridge.invoke("calls.muteAudio") }
    func unmuteAudio() { bridge.invoke("calls.unmuteAudio") }
    func pauseVideo() { bridge.invoke("calls.pauseVideo") }
    func resumeVideo() { bridge.invoke("calls.resumeVideo") }
    func leaveSession() { bridge.invoke("calls.leaveSession") }

    var isJoined: Bool { snapshot.isJoined }
}
