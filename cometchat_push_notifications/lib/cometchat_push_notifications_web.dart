// In order to *not* need this ignore, consider extracting the "web" version
// of your plugin as a separate package, instead of inlining it in the same
// package as the core of your plugin.
// ignore: avoid_web_libraries_in_flutter

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'cometchat_push_notifications_platform_interface.dart';
import 'src/models/cometchat_notification_config.dart';
import 'src/models/cometchat_notification_details.dart';
import 'src/models/cometchat_notification_response.dart';

/// The web implementation.
///
/// Displaying a web push is the service worker's job, not the page's: a browser
/// delivers it to the worker, which may not be running the app at all. So
/// nothing here draws a notification, and the display methods are no-ops rather
/// than errors — a web build that shares code with mobile keeps working, it
/// simply shows nothing.
///
/// What does work on web is everything that lives in Dart above this class:
/// [CometChatPushNotifications.registerPushToken] and the rest reach CometChat
/// through `cometchat_sdk`, which has no platform side. Pass the FCM web token
/// from your own messaging setup to
/// [CometChatPushNotifications.registerPushToken], which defaults to
/// `PushPlatform.FCM_WEB` here.
class CometchatPushNotificationsWeb extends CometchatPushNotificationsPlatform {
  /// Constructs a CometchatPushNotificationsWeb
  CometchatPushNotificationsWeb();

  /// Registers this class as the platform implementation on web.
  static void registerWith(Registrar registrar) {
    CometchatPushNotificationsPlatform.instance =
        CometchatPushNotificationsWeb();
  }

  /// The browser's user agent, standing in for an OS version.
  @override
  Future<String?> getPlatformVersion() async => web.window.navigator.userAgent;

  @override
  Future<void> initialize(CometChatNotificationConfig config) async {}

  /// Whether the browser has granted notification permission.
  ///
  /// Reported, not requested: a permission prompt belongs to whatever registers
  /// the service worker, and asking twice is a good way to be denied.
  @override
  Future<bool> isPermissionGranted() async =>
      web.Notification.permission == 'granted';

  @override
  Future<bool> requestPermission() => isPermissionGranted();

  /// Null: an APNs token is an iOS concept.
  @override
  Future<String?> getApnsToken() async => null;

  @override
  Future<void> showNotification(CometChatNotificationDetails details) async {}

  @override
  Future<void> cancelNotifications({String? conversationId}) async {}

  @override
  Future<void> setActiveConversation({
    String? id,
    String? receiverType,
  }) async {}

  /// A no-op: browsers have no app icon to badge.
  @override
  Future<void> setBadgeCount(int count) async {}

  @override
  Future<int> getBadgeCount() async => 0;

  /// Empty: taps arrive through the service worker, which this class cannot see.
  @override
  Stream<CometChatNotificationResponse> get onNotificationTap =>
      const Stream<CometChatNotificationResponse>.empty();
}
