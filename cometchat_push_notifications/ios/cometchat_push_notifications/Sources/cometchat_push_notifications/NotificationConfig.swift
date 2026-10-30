import Foundation

/// The Dart-side configuration, as the iOS side needs it.
///
/// The Android channel and icon fields are ignored here; they arrive in the
/// same map because one `initialize` call configures both platforms.
struct NotificationConfig {

    let showInAppNotifications: Bool
    let enableBadgeCount: Bool

    init(map: [String: Any]) {
        showInAppNotifications = map["showInAppNotifications"] as? Bool ?? false
        enableBadgeCount = map["enableBadgeCount"] as? Bool ?? true
    }
}
