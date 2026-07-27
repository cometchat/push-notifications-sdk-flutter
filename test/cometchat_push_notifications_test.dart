import 'package:flutter_test/flutter_test.dart';
import 'package:cometchat_push_notifications/cometchat_push_notifications.dart';
import 'package:cometchat_push_notifications/cometchat_push_notifications_platform_interface.dart';
import 'package:cometchat_push_notifications/cometchat_push_notifications_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockCometchatPushNotificationsPlatform
    with MockPlatformInterfaceMixin
    implements CometchatPushNotificationsPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> showCallNotification({
    required String callId,
    required String callerName,
    required bool isVideo,
    String? callerAvatar,
  }) =>
      Future.value(true);

  @override
  Future<bool> cancelCallNotification(String callId) => Future.value(true);

  @override
  Future<bool> dismissIncomingCallActivity() => Future.value(true);

  @override
  Future<Map<String, dynamic>?> getLaunchCallDetails() => Future.value(null);

  @override
  void setIncomingCallLaunchHandler(
    void Function(Map<String, dynamic> details) handler,
  ) {}

  @override
  void setDeclineCallHandler(void Function(String sessionId) handler) {}

  @override
  Future<Map<String, bool>> checkCallPermissions() async => const {
        'fullScreenIntent': true,
        'overlay': true,
        'batteryOptimized': true,
      };

  @override
  Future<bool> openAutoStartSettings() async => true;

  @override
  Future<bool> openFullScreenIntentSettings() async => true;

  @override
  Future<bool> openOverlaySettings() async => true;

  @override
  Future<bool> openBatteryOptimizationSettings() async => true;
}

void main() {
  final CometchatPushNotificationsPlatform initialPlatform =
      CometchatPushNotificationsPlatform.instance;

  test('$MethodChannelCometchatPushNotifications is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelCometchatPushNotifications>());
  });

  test('getPlatformVersion', () async {
    final plugin = CometChatPushNotifications();
    final fakePlatform = MockCometchatPushNotificationsPlatform();
    CometchatPushNotificationsPlatform.instance = fakePlatform;

    expect(await plugin.getPlatformVersion(), '42');
  });
}
