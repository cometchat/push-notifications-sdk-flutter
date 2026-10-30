import Flutter
import UIKit
import UserNotifications

/// The iOS half of `cometchat_push_notifications`.
///
/// iOS draws the notification itself from the APNs alert, so there is nothing
/// here that corresponds to Android's renderer. What this owns instead is the
/// decisions iOS asks the app to make — whether to show a notification while the
/// app is in the foreground, what the badge says — plus APNs registration and
/// reporting taps back to Dart.
///
/// It never talks to CometChat. Token registration and delivery receipts
/// happen in Dart on `cometchat_sdk`.
public class CometchatPushNotificationsPlugin: NSObject, FlutterPlugin {

    private var config = NotificationConfig(map: [:])
    private var activeConversationId: String?
    private var activeReceiverType: String?

    private let responses = ResponseStreamHandler()

    /// The APNs device token, once iOS has issued one.
    private var deviceToken: String?
    /// Callers of `getApnsToken` waiting for that token to arrive.
    private var tokenWaiters: [(String?) -> Void] = []

    /// Whoever held the notification-centre delegate before this plugin did.
    ///
    /// Several Flutter packages want this delegate. Rather than taking it away,
    /// anything that is not a CometChat payload is passed straight through to
    /// the previous holder, so both keep working.
    private weak var previousDelegate: UNUserNotificationCenterDelegate?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = CometchatPushNotificationsPlugin()

        let channel = FlutterMethodChannel(
            name: "cometchat_push_notifications",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: channel)

        FlutterEventChannel(
            name: "cometchat_push_notifications/responses",
            binaryMessenger: registrar.messenger()
        ).setStreamHandler(instance.responses)

        // Needed for didRegisterForRemoteNotificationsWithDeviceToken.
        registrar.addApplicationDelegate(instance)
    }

    // MARK: - Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
        case "initialize":
            initialize(call.arguments as? [String: Any] ?? [:])
            result(nil)
        case "requestPermission":
            requestPermission(result)
        case "isPermissionGranted":
            isPermissionGranted(result)
        case "getApnsToken":
            getApnsToken(result)
        case "showNotification":
            // The APNs alert already showed one; a second would duplicate it.
            result(nil)
        case "cancelNotifications":
            let conversationId = (call.arguments as? [String: Any])?["conversationId"] as? String
            cancelNotifications(conversationId: conversationId)
            result(nil)
        case "setActiveConversation":
            let arguments = call.arguments as? [String: Any]
            activeConversationId = arguments?["id"] as? String
            activeReceiverType = arguments?["receiverType"] as? String
            if let conversationId = activeConversationId {
                cancelNotifications(conversationId: conversationId)
            }
            result(nil)
        case "setBadgeCount":
            let count = (call.arguments as? [String: Any])?["count"] as? Int ?? 0
            setBadgeCount(count)
            result(nil)
        case "getBadgeCount":
            result(UIApplication.shared.applicationIconBadgeNumber)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func initialize(_ map: [String: Any]) {
        config = NotificationConfig(map: map)

        let center = UNUserNotificationCenter.current()
        if center.delegate !== self {
            previousDelegate = center.delegate
            center.delegate = self
        }
    }

    // MARK: - Permission and token

    private func requestPermission(_ result: @escaping FlutterResult) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted {
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
                DispatchQueue.main.async { result(granted) }
            }
    }

    private func isPermissionGranted(_ result: @escaping FlutterResult) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            var granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            if #available(iOS 14.0, *) {
                granted = granted || settings.authorizationStatus == .ephemeral
            }
            DispatchQueue.main.async { result(granted) }
        }
    }

    /// Returns the APNs device token, registering for one if needed.
    ///
    /// APNs issues no token without notification permission, so an unauthorized
    /// app resolves to nil rather than waiting for something that will never
    /// arrive. A registration that fails or stalls also resolves to nil, on a
    /// timeout, so a caller is never left hanging.
    private func getApnsToken(_ result: @escaping FlutterResult) {
        if let token = deviceToken {
            result(token)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else {
                result(nil)
                return
            }
            guard settings.authorizationStatus != .denied,
                  settings.authorizationStatus != .notDetermined else {
                DispatchQueue.main.async { result(nil) }
                return
            }

            DispatchQueue.main.async {
                var settled = false
                self.tokenWaiters.append { token in
                    guard !settled else { return }
                    settled = true
                    result(token)
                }
                UIApplication.shared.registerForRemoteNotifications()

                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    guard !settled else { return }
                    settled = true
                    result(self.deviceToken)
                }
            }
        }
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken token: Data
    ) {
        // Never log this: it is a live credential for the device.
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        let waiters = tokenWaiters
        tokenWaiters = []
        waiters.forEach { $0(deviceToken) }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("CometChatPN: APNs registration failed — \(error.localizedDescription)")
        let waiters = tokenWaiters
        tokenWaiters = []
        waiters.forEach { $0(nil) }
    }

    // MARK: - Notification management

    /// Removes delivered notifications for [conversationId], or every CometChat
    /// notification when it is nil.
    ///
    /// Matching is on the payload, so notifications the app posted for its own
    /// reasons are never removed.
    private func cancelNotifications(conversationId: String?) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered.compactMap { notification -> String? in
                let userInfo = notification.request.content.userInfo
                guard let payload = CometChatPayload(userInfo: userInfo) else { return nil }
                guard let conversationId else { return notification.request.identifier }
                return payload.conversationId == conversationId
                    ? notification.request.identifier
                    : nil
            }
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    private func setBadgeCount(_ count: Int) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = count
            }
        }
    }

    /// Mirrors the payload's unread count onto the app icon.
    private func applyBadge(from payload: CometChatPayload) {
        guard config.enableBadgeCount, let count = payload.unreadCount, count >= 0 else { return }
        setBadgeCount(count)
    }

    /// Whether [payload] belongs to the conversation the user is looking at.
    ///
    /// Both the id and the receiver type have to match: a user and a group can
    /// share an id, and suppressing the wrong one silently loses a message.
    private func isSuppressed(_ payload: CometChatPayload) -> Bool {
        guard let activeId = activeConversationId, activeId == payload.conversationId else {
            return false
        }
        guard let activeType = activeReceiverType else { return true }
        return activeType == payload.receiverType
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension CometchatPushNotificationsPlugin: UNUserNotificationCenterDelegate {

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        guard let payload = CometChatPayload(userInfo: userInfo), payload.isChat else {
            forwardWillPresent(center, notification, completionHandler)
            return
        }

        applyBadge(from: payload)

        // The user is already reading this conversation, or has asked for no
        // banners while the app is open.
        if isSuppressed(payload) || !config.showInAppNotifications {
            completionHandler([])
            return
        }
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let payload = CometChatPayload(userInfo: userInfo), payload.isChat else {
            forwardDidReceive(center, response, completionHandler)
            return
        }

        applyBadge(from: payload)

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            responses.send(payload.responseMap())
        }
        completionHandler()
    }

    private func forwardWillPresent(
        _ center: UNUserNotificationCenter,
        _ notification: UNNotification,
        _ completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard let previous = previousDelegate,
              previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)))
        else {
            completionHandler([])
            return
        }
        previous.userNotificationCenter?(
            center,
            willPresent: notification,
            withCompletionHandler: completionHandler
        )
    }

    private func forwardDidReceive(
        _ center: UNUserNotificationCenter,
        _ response: UNNotificationResponse,
        _ completionHandler: @escaping () -> Void
    ) {
        guard let previous = previousDelegate,
              previous.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)))
        else {
            completionHandler()
            return
        }
        previous.userNotificationCenter?(
            center,
            didReceive: response,
            withCompletionHandler: completionHandler
        )
    }
}
