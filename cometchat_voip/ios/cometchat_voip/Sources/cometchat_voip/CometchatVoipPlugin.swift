import Flutter
import UIKit
import UserNotifications

/// The iOS half of `cometchat_voip`.
///
/// Calls ring through PushKit and CallKit, which the package owns in
/// `VoipCore` and which work whether or not Dart is running. This class hands
/// Dart the configuration, what the user did, and the VoIP token.
public class CometchatVoipPlugin: NSObject, FlutterPlugin {

    private let core = VoipCore.shared

    /// Kept so `dartReady` can hand it to the bridge: this is the channel the
    /// ringer calls Dart back on for everything the Calls SDK owns.
    private var channel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CometchatVoipPlugin()
        let channel = FlutterMethodChannel(name: "cometchat_voip", binaryMessenger: registrar.messenger())
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterEventChannel(name: "cometchat_voip/events", binaryMessenger: registrar.messenger())
            .setStreamHandler(instance.core.events.makeStreamHandler())

        // Apple requires the PushKit registry to exist by the end of
        // didFinishLaunching, which is where plugins register.
        instance.core.start()
    }

    /// Whether the call in `arguments` is a video call, read from the call map
    /// Dart sends.
    private static func isVideo(_ arguments: [String: Any]) -> Bool {
        guard let map = arguments["call"] as? [String: String] else { return false }
        return IncomingCall.fromMap(map)?.isVideo ?? false
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let sessionId = (arguments["sessionId"] as? String)?.nonBlank

        switch call.method {
        case "initialize":
            guard let config = VoipConfig(map: arguments) else {
                result(FlutterError(code: "invalid_arguments", message: "initialize needs an appId and a region", details: nil))
                return
            }
            core.configure(config)
            result(nil)
        case "handlePushNotification":
            // Calls reach iOS through PushKit, which the package owns.
            result(false)
        case "getVoipToken":
            core.waitForVoipToken { token in result(token) }
        case "getTimeZone":
            result(TimeZone.current.identifier)
        case "answer":
            if let sessionId = sessionId { core.answer(sessionId: sessionId) }
            result(nil)
        case "permissionsToAnswer":
            result(CallPermissions.missing(video: Self.isVideo(arguments)))
        case "requestCallPermissions":
            // The prompt needs the app in front. A VoIP push can wake it in
            // the background, so a call made from there is answered with what
            // is granted already rather than left hanging.
            guard UIApplication.shared.applicationState == .active else {
                result(CallPermissions.missing(video: Self.isVideo(arguments)).isEmpty)
                return
            }
            CallPermissions.request(video: Self.isVideo(arguments)) { granted in result(granted) }
        case "decline":
            if let sessionId = sessionId {
                core.decline(sessionId: sessionId, busy: arguments["busy"] as? Bool ?? false)
            }
            result(nil)
        case "getActiveCall":
            result(core.store.get()?.call.toMap())
        case "reportOutgoingCall":
            if let sessionId = sessionId {
                core.reportOutgoingCall(
                    sessionId: sessionId,
                    calleeName: arguments["calleeName"] as? String ?? "",
                    hasVideo: arguments["hasVideo"] as? Bool ?? false
                )
            }
            result(nil)
        case "reportCallConnected":
            if let sessionId = sessionId { core.sync.sessionJoined(sessionId: sessionId) }
            result(nil)
        case "reportCallEnded":
            if let sessionId = sessionId {
                let reason = (arguments["reason"] as? String)
                    .flatMap(CallEndReason.init(rawValue:)) ?? .remoteEnded
                core.reportCallEnded(sessionId: sessionId, reason: reason)
            }
            result(nil)
        case "checkRingReadiness":
            result(RingReadinessChecker.readiness())
        case "openSettings":
            openSettings(arguments["readiness"] as? String, result: result)
        case "requestNotificationPermission":
            // CallKit needs no notification permission; report the standing one.
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                DispatchQueue.main.async { result(granted) }
            }
        case "dismissRinging":
            if let sessionId = sessionId {
                core.dismissRinging(
                    sessionId: sessionId,
                    answered: arguments["answered"] as? Bool ?? false
                )
            }
            result(nil)
        case "verifyPushSetup":
            result(verifyPushSetup())
        case "lastWakeTiming":
            result([
                "sdkReadyMs": core.verifier.sdkReadyMs as Any,
                "connectMs": core.verifier.connectMs as Any
            ])

        // ── The gate and the ledger, which persist across processes ──
        case "markTerminal":
            if let sessionId = sessionId {
                core.store.markTerminal(
                    sessionId: sessionId,
                    reason: arguments["reason"] as? String ?? "app"
                )
            }
            result(nil)
        case "wasTerminal":
            result(sessionId.map { core.store.wasTerminal(sessionId: $0) } ?? false)
        case "terminalReason":
            result(sessionId.flatMap { core.store.terminalReason(sessionId: $0) })
        case "setCallKitAudioHandoff":
            core.callKitAudioHandoffChanged(
                arguments["available"] as? Bool ?? false
            )
            result(nil)
        case "setLoggedInUid":
            core.loggedInUidChanged(arguments["uid"] as? String)
            result(nil)
        case "enqueueDecline":
            if let sessionId = sessionId {
                core.declines.enqueue(
                    sessionId: sessionId,
                    status: arguments["status"] as? String ?? "rejected"
                )
            }
            result(nil)

        // ── What Dart pushes in, now that the Calls SDK lives there ──
        case "setSessionState":
            core.sessionStateChanged(
                active: arguments["active"] as? Bool ?? false,
                joined: arguments["joined"] as? Bool ?? false,
                sessionId: arguments["sessionId"] as? String
            )
            result(nil)
        case "setSessionMuted":
            core.sessionAudioMutedChanged(arguments["muted"] as? Bool ?? false)
            result(nil)
        case "setSessionVideoPaused":
            core.sessionVideoPausedChanged(arguments["paused"] as? Bool ?? false)
            result(nil)
        case "reportRemoteParticipant":
            // Names an outgoing call this package reported on its own: the
            // Calls SDK says who is called only once they are in the room.
            core.remoteParticipantSeen(
                uid: arguments["uid"] as? String,
                name: arguments["name"] as? String
            )
            result(nil)
        case "sdkEndedCall":
            if let sessionId = sessionId {
                core.incomingCallEndedBySdk(
                    sessionId: sessionId,
                    reason: arguments["reason"] as? String ?? "ended"
                )
            }
            result(nil)

        // An isolate announcing it can serve the ringer's Calls SDK work.
        case "dartReady":
            if let channel = channel { DartCallsBridge.shared.dartIsReady(channel) }
            result(nil)
        // What Dart needs to bring the Calls SDK up on a cold isolate.
        case "storedConfig":
            result(VoipConfig.restore().map {
                ["appId": $0.appId, "region": $0.region, "clientHost": $0.clientHost as Any]
            })

        // CallKit is all or nothing: reporting a call to CXProvider IS the
        // ring, so there are no à-la-carte pieces. Android-only.
        case "ringSurface.showIncomingNotification",
             "ringSurface.stopRinging",
             "ringSurface.verify",
             "ringSurface.keepAlive",
             "ringSurface.showMissedCall":
            result(FlutterError(
                code: "unsupported_platform",
                message: "\(call.method) is Android-only: on iOS CallKit owns the ring and cannot be driven a piece at a time.",
                details: nil
            ))

        case "getDiagnostics":
            var out = RingReadinessChecker.diagnostics(
                store: core.store,
                sdk: core.sdk,
                voipTokenReceived: core.voipToken != nil
            )
            out["callKitAudioRequested"] = core.callKitAudioRequested
            // The failure this names — an enabled flag with no handoff — makes
            // a connected call silent, and has no other symptom.
            out["callKitAudioHandoff"] = core.callKitAudioHandoffAvailable
                .map { $0 ? "available" : "unavailable: Calls SDK too old" }
                ?? "unknown: not checked — callKitAudio was never asked for"
            // The lock-screen audio ordering. `audio.activatedBeforeJoin` true
            // is the condition that leaves the caller in silence without the
            // re-assert: audio was enabled while the session had no local
            // track yet.
            if let answered = core.answeredAtMs {
                if let joined = core.joinedAtMs { out["answer_to_joined_ms"] = joined - answered }
                if let activated = core.audioActivatedAtMs {
                    out["answer_to_audio_activated_ms"] = activated - answered
                    if let joined = core.joinedAtMs {
                        out["audio.activateToJoinedMs"] = joined - activated
                        out["audio.activatedBeforeJoin"] = activated <= joined
                    }
                }
                out["audio.reassertedAfterJoin"] = core.audioReassertedAfterJoin
            }
            result(out)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Only the microphone has a settings page; the rest are fixed in the build.
    private func openSettings(_ readiness: String?, result: @escaping FlutterResult) {
        guard readiness == "microphoneDenied", let url = URL(string: UIApplication.openSettingsURLString) else {
            result(false)
            return
        }
        UIApplication.shared.open(url) { opened in result(opened) }
    }

    /// What this device can tell about its own push setup, without a test push.
    ///
    /// The Dart side adds what it knows about the token and the login; this is
    /// the half that needs the OS.
    private func verifyPushSetup() -> String {
        guard VoipConfig.restore() != nil else { return "notInitialized" }
        switch RingReadinessChecker.readiness() {
        case "ready": return core.voipToken == nil ? "noVoipToken" : "ok"
        case "backgroundModeMissing": return "backgroundModeMissing"
        case "voipEntitlementMissing": return "voipEntitlementMissing"
        default: return "ringNotReady"
        }
    }
}
