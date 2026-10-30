import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'cometchat_push_notifications_method_channel.dart';
import 'src/models/cometchat_notification_config.dart';
import 'src/models/cometchat_notification_details.dart';
import 'src/models/cometchat_notification_response.dart';

/// The contract every platform implementation of this plugin fulfils.
///
/// Only the work Dart cannot do itself lives here: posting and cancelling OS
/// notifications, the iOS foreground presentation decision, the badge, and the
/// permission prompt. Everything that talks to CometChat — token registration,
/// delivery receipts — stays in Dart on top of `cometchat_sdk`,
/// so there is exactly one implementation of it rather than one per platform.
abstract class CometchatPushNotificationsPlatform extends PlatformInterface {
  /// Constructs a CometchatPushNotificationsPlatform.
  CometchatPushNotificationsPlatform() : super(token: _token);

  static final Object _token = Object();

  static CometchatPushNotificationsPlatform _instance =
      MethodChannelCometchatPushNotifications();

  /// The default instance of [CometchatPushNotificationsPlatform] to use.
  ///
  /// Defaults to [MethodChannelCometchatPushNotifications].
  static CometchatPushNotificationsPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [CometchatPushNotificationsPlatform]
  /// when they register themselves.
  static set instance(CometchatPushNotificationsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// The OS name and version, for diagnostics.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  /// Hands the native side the settings it needs before the first notification
  /// arrives: the Android channel and small icon, and whether the badge is on.
  Future<void> initialize(CometChatNotificationConfig config) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Prompts for notification permission, returning whether it was granted.
  Future<bool> requestPermission() {
    throw UnimplementedError('requestPermission() has not been implemented.');
  }

  /// Whether notifications are currently permitted.
  Future<bool> isPermissionGranted() {
    throw UnimplementedError('isPermissionGranted() has not been implemented.');
  }

  /// Registers with APNs and returns the device token as lowercase hex.
  ///
  /// iOS only; returns null elsewhere. Android tokens come from FCM, which
  /// this package deliberately does not depend on.
  Future<String?> getApnsToken() {
    throw UnimplementedError('getApnsToken() has not been implemented.');
  }

  /// Posts a chat notification for [details].
  ///
  /// Android renders it here; iOS already showed the APNs alert, so this is a
  /// no-op there.
  Future<void> showNotification(CometChatNotificationDetails details) {
    throw UnimplementedError('showNotification() has not been implemented.');
  }

  /// Cancels the notification for [conversationId], or every notification this
  /// package posted when it is null.
  ///
  /// Only ever touches notifications this package posted; an integrator's own
  /// notifications are left alone.
  Future<void> cancelNotifications({String? conversationId}) {
    throw UnimplementedError('cancelNotifications() has not been implemented.');
  }

  /// Tells the native side which conversation is on screen, so pushes for it
  /// are suppressed rather than shown behind the open chat.
  ///
  /// Pass null for both when leaving the chat.
  Future<void> setActiveConversation({String? id, String? receiverType}) {
    throw UnimplementedError(
      'setActiveConversation() has not been implemented.',
    );
  }

  /// Sets the app icon badge. iOS only; a no-op elsewhere.
  Future<void> setBadgeCount(int count) {
    throw UnimplementedError('setBadgeCount() has not been implemented.');
  }

  /// Reads the app icon badge. iOS only; returns 0 elsewhere.
  Future<int> getBadgeCount() {
    throw UnimplementedError('getBadgeCount() has not been implemented.');
  }

  /// Notification taps, in the order the OS delivered them.
  ///
  /// A tap that launched the app from a cold start is replayed onto this stream
  /// once a listener attaches, so it is not lost to the race between the launch
  /// intent and Dart starting up.
  Stream<CometChatNotificationResponse> get onNotificationTap {
    throw UnimplementedError('onNotificationTap has not been implemented.');
  }
}
