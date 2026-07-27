import Flutter
import UIKit

/// CometChat Push Notifications plugin for iOS.
///
/// Handles method channel calls from the Dart side. Methods that are
/// Android-specific (OEM permissions, system notification-based call UI)
/// return safe no-op defaults on iOS since CallKit handles incoming calls
/// natively.
public class CometchatPushNotificationsPlugin: NSObject, FlutterPlugin {

    private var channel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "cometchat_push_notifications",
            binaryMessenger: registrar.messenger()
        )
        let instance = CometchatPushNotificationsPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        case "showCallNotification":
            // On iOS, incoming calls are presented via CallKit (handled by
            // the VoIP push / notification_voip_plugin layer). No system
            // notification needed.
            result(true)

        case "cancelCallNotification":
            // No system notification to cancel on iOS.
            result(true)

        case "getLaunchCallDetails":
            // iOS doesn't use intent-based launch details. CallKit handles
            // the call answer/decline flow natively.
            result(nil)

        case "checkCallPermissions":
            // iOS doesn't have the OEM permission issues that Android has
            // (full-screen intent, overlay, battery optimization). All
            // permissions are effectively granted by default.
            result([
                "fullScreenIntent": true,
                "overlay": true,
                "batteryOptimized": true
            ])

        case "openAutoStartSettings",
             "openFullScreenIntentSettings",
             "openOverlaySettings",
             "openBatteryOptimizationSettings":
            // These are Android-only OEM permission screens. No-op on iOS.
            result(false)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
