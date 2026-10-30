import Foundation

/// What `CometChatVoip.init` configured, persisted.
///
/// PushKit can launch a killed app and demand a CallKit report before any Dart
/// has run, so everything the ring needs is read from here.
struct VoipConfig: Equatable {

    struct CallKitOptions: Equatable {
        var iconTemplateImageName: String?
        var ringtoneSound: String?
        var includesCallsInRecents = true
        var supportsVideo = true
    }

    let appId: String
    let region: String
    let clientHost: String?
    let requestCallPermissions: Bool
    let callKit: CallKitOptions
    /// `CometChatVoipConfig.defaultRingTimeout`: how long a push without its own
    /// `ringTimeout` rings. It used to be serialised and never read, so every
    /// such push rang for 45 s whatever the app configured.
    let defaultRingTimeoutMs: Int64

    /// The package's own defaults suite, never `.standard`.
    static let defaults = UserDefaults(suiteName: "com.cometchat.voip") ?? .standard
    private static let key = "config"

    init?(map: [String: Any]) {
        guard let appId = (map["appId"] as? String)?.nonBlank,
              let region = (map["region"] as? String)?.nonBlank else { return nil }
        self.appId = appId
        self.region = region
        clientHost = (map["clientHost"] as? String)?.nonBlank
        requestCallPermissions = map["requestCallPermissions"] as? Bool ?? true
        let timeout = (map["defaultRingTimeoutMs"] as? NSNumber)?.int64Value
        if let timeout = timeout,
           timeout >= RingConstants.minRingTimeoutMs, timeout <= RingConstants.maxRingTimeoutMs {
            defaultRingTimeoutMs = timeout
        } else {
            defaultRingTimeoutMs = RingConstants.defaultRingTimeoutMs
        }
        let callKit = map["callKit"] as? [String: Any] ?? [:]
        self.callKit = CallKitOptions(
            iconTemplateImageName: (callKit["iconTemplateImageName"] as? String)?.nonBlank,
            ringtoneSound: (callKit["ringtoneSound"] as? String)?.nonBlank,
            includesCallsInRecents: callKit["includesCallsInRecents"] as? Bool ?? true,
            supportsVideo: callKit["supportsVideo"] as? Bool ?? true
        )
    }

    private var map: [String: Any] {
        var callKitMap: [String: Any] = [
            "includesCallsInRecents": callKit.includesCallsInRecents,
            "supportsVideo": callKit.supportsVideo,
        ]
        callKitMap["iconTemplateImageName"] = callKit.iconTemplateImageName
        callKitMap["ringtoneSound"] = callKit.ringtoneSound
        var map: [String: Any] = [
            "appId": appId,
            "region": region,
            "requestCallPermissions": requestCallPermissions,
            "callKit": callKitMap,
            "defaultRingTimeoutMs": NSNumber(value: defaultRingTimeoutMs),
        ]
        map["clientHost"] = clientHost
        return map
    }

    func save() {
        VoipConfig.defaults.set(map, forKey: VoipConfig.key)
    }

    /// Nil when `init` has never run on this install.
    static func restore() -> VoipConfig? {
        guard let map = defaults.dictionary(forKey: key) else { return nil }
        return VoipConfig(map: map)
    }
}
