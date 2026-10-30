import AVFoundation
import Foundation

/// Why a call would not ring here. Every one of these silences a call with no
/// error anywhere, which is why they are named.
enum RingReadinessChecker {

    static var hasVoipBackgroundMode: Bool {
        ((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []).contains("voip")
    }

    /// `aps-environment` from the embedded provisioning profile. A simulator
    /// has none, and reports nil — unknown — rather than missing.
    static var apsEnvironment: String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .isoLatin1) else { return nil }
        guard let range = text.range(of: "<key>aps-environment</key>") else { return "" }
        let tail = text[range.upperBound...]
        guard let open = tail.range(of: "<string>"), let close = tail.range(of: "</string>") else { return "" }
        return String(tail[open.upperBound..<close.lowerBound])
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func readiness() -> String {
        if !hasVoipBackgroundMode { return "backgroundModeMissing" }
        if !isSimulator, apsEnvironment == "" { return "voipEntitlementMissing" }
        if CallPermissions.microphoneDenied { return "microphoneDenied" }
        return "ready"
    }

    /// Redacted by construction: no token, no auth value, no payload.
    static func diagnostics(store: CallStore, sdk: CallsSdkPort, voipTokenReceived: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "platform": "ios",
            "voipBackgroundMode": hasVoipBackgroundMode,
            "apsEnvironment": apsEnvironment ?? "unknown",
            "microphone": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "camera": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
            "microphoneUsageDescription": Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
            "cameraUsageDescription": Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil,
            "voipTokenReceived": voipTokenReceived,
            "hasPersistedConfig": VoipConfig.restore() != nil,
            "hasDeviceUid": store.uid != nil,
            "callsSdkLoggedIn": sdk.isLoggedIn,
            "callsSdkReachable": DartCallsBridge.shared.isReady,
            "ringOwner": "cometchat_voip (its own CXProvider)",
            "simulator": isSimulator,
            "ringReadiness": readiness(),
        ]
        if let active = store.get() { out["activeCall"] = "\(active.call.sessionId) \(active.state.rawValue)" }
        return out
    }
}
