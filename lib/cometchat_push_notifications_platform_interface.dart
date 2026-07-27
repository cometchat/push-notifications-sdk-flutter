import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'cometchat_push_notifications_method_channel.dart';

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
  /// platform-specific class that extends [CometchatPushNotificationsPlatform] when
  /// they register themselves.
  static set instance(CometchatPushNotificationsPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// Shows a full-screen incoming call notification.
  Future<bool> showCallNotification({
    required String callId,
    required String callerName,
    required bool isVideo,
    String? callerAvatar,
  }) {
    throw UnimplementedError(
      'showCallNotification() has not been implemented.',
    );
  }

  /// Cancels an incoming call notification by call ID.
  Future<bool> cancelCallNotification(String callId) {
    throw UnimplementedError(
      'cancelCallNotification() has not been implemented.',
    );
  }

  /// Dismisses the dedicated full-screen incoming-call activity (Android),
  /// e.g. when the caller cancels/ends the call before it is answered.
  /// No-op on platforms without a dedicated call activity.
  Future<bool> dismissIncomingCallActivity() async => false;

  /// Returns the pending call details captured from the launch intent
  /// (if the app was launched by tapping an incoming call notification).
  ///
  /// Returns `null` if the app was not launched from a call notification.
  /// The buffer is cleared after reading.
  Future<Map<String, dynamic>?> getLaunchCallDetails() {
    throw UnimplementedError(
      'getLaunchCallDetails() has not been implemented.',
    );
  }

  /// Registers a handler for call notification taps that occur while the
  /// app is already running (e.g., tapping a call notification after
  /// putting the app in background).
  void setIncomingCallLaunchHandler(
    void Function(Map<String, dynamic> details) handler,
  ) {
    throw UnimplementedError(
      'setIncomingCallLaunchHandler() has not been implemented.',
    );
  }

  /// Registers a handler for silent decline broadcasts.
  ///
  /// Fires when the user taps the Decline action on the call
  /// notification. The handler should call `CometChat.rejectCall()`
  /// on the SDK side.
  void setDeclineCallHandler(void Function(String sessionId) handler) {
    throw UnimplementedError(
      'setDeclineCallHandler() has not been implemented.',
    );
  }

  /// Returns the current state of OEM permissions that affect whether
  /// call notifications can show a full-screen UI on locked / background
  /// devices.
  ///
  /// Map keys:
  /// - `fullScreenIntent`: Android 14+ full-screen intent permission
  /// - `overlay`: SYSTEM_ALERT_WINDOW (required on Xiaomi / MIUI)
  /// - `batteryOptimized`: whether the app is exempt from Doze
  Future<Map<String, bool>> checkCallPermissions() {
    throw UnimplementedError(
      'checkCallPermissions() has not been implemented.',
    );
  }

  /// Opens the OEM-specific Autostart permission screen (Xiaomi, Oppo,
  /// Vivo, Huawei, Samsung). Falls back to the app details page on
  /// stock Android.
  Future<bool> openAutoStartSettings() {
    throw UnimplementedError(
      'openAutoStartSettings() has not been implemented.',
    );
  }

  /// Opens Android 14+ full-screen intent permission screen.
  Future<bool> openFullScreenIntentSettings() {
    throw UnimplementedError(
      'openFullScreenIntentSettings() has not been implemented.',
    );
  }

  /// Opens the "Display over other apps" permission screen.
  Future<bool> openOverlaySettings() {
    throw UnimplementedError('openOverlaySettings() has not been implemented.');
  }

  /// Opens the battery optimization exemption request.
  Future<bool> openBatteryOptimizationSettings() {
    throw UnimplementedError(
      'openBatteryOptimizationSettings() has not been implemented.',
    );
  }
}
