import Flutter
import UIKit

/// Nothing to add for VoIP.
///
/// In `CometChatCallMode.auto` — the default — `cometchat_voip` creates the
/// `PKPushRegistry` inside its own plugin registration, which runs here in
/// `didFinishLaunching`, where Apple requires the registry to exist. The
/// generated `AppDelegate` is already right.
///
/// **Do not add a `PKPushRegistry` of your own.** There is one per app: a
/// second one takes the VoIP pushes, and those calls never ring, with no error
/// anywhere. An app that wants to own PushKit itself sets
/// `CometChatCallMode.manual` and forwards the token with
/// `CometChatVoip.setPushToken` and each push with
/// `CometChatVoip.handlePushNotification`.
@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
