import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cometchat_push_notifications/cometchat_push_notifications_method_channel.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_enums.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_notification_config.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_notification_details.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_notification_response.dart';

/// What actually crosses the method channel.
///
/// The native side reads these argument maps by key, and a renamed or dropped
/// key fails silently there — the notification simply never appears — so the
/// wire shape is worth pinning down from this side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelCometchatPushNotifications();
  const channel = MethodChannel('cometchat_push_notifications');

  late List<MethodCall> calls;
  Object? reply;

  setUp(() {
    calls = [];
    reply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return reply;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<Object?, Object?> argumentsOf(String method) =>
      calls.singleWhere((c) => c.method == method).arguments
          as Map<Object?, Object?>;

  test('getPlatformVersion returns what the platform reports', () async {
    reply = 'iOS 18.0';
    expect(await platform.getPlatformVersion(), 'iOS 18.0');
  });

  test('initialize sends every field the native side reads', () async {
    await platform.initialize(
      const CometChatNotificationConfig(
        appId: 'app',
        region: 'us',
        showInAppNotifications: true,
        androidSmallIcon: 'ic_notification',
        androidChannelId: 'messages_v2',
      ),
    );

    final arguments = argumentsOf('initialize');
    expect(arguments['showInAppNotifications'], isTrue);
    expect(arguments['androidSmallIcon'], 'ic_notification');
    expect(arguments['androidChannelId'], 'messages_v2');
    // The app id and region are the Chat SDK's business, not the renderer's.
    expect(arguments.containsKey('appId'), isFalse);
  });

  test('showNotification sends the receiver type as a bare string', () async {
    await platform.showNotification(
      const CometChatNotificationDetails(
        title: 'Engineering',
        body: 'ship it',
        sender: 'alex',
        senderName: 'Alex Okonjo',
        senderAvatar: 'https://example.test/a.png',
        receiver: 'engineering',
        receiverName: 'Engineering',
        receiverType: CometChatPushReceiverType.group,
        tag: '42',
        conversationId: 'group_engineering',
        type: CometChatPayloadType.chat,
        sentAt: '1758499200',
      ),
    );

    final arguments = argumentsOf('showNotification');
    // Native compares this against "group"; an enum's toString would not match.
    expect(arguments['receiverType'], 'group');
    expect(arguments['messageId'], '42');
    expect(arguments['senderAvatar'], 'https://example.test/a.png');
  });

  test('cancelNotifications passes a null id through for "cancel all"', () async {
    await platform.cancelNotifications();

    // The key must be present and null — native reads its absence the same way,
    // but being explicit keeps the two ends from drifting.
    expect(argumentsOf('cancelNotifications')['conversationId'], isNull);
  });

  test('setActiveConversation carries the type alongside the id', () async {
    await platform.setActiveConversation(id: 'alex', receiverType: 'user');

    final arguments = argumentsOf('setActiveConversation');
    expect(arguments['id'], 'alex');
    // Without the type, a user and a group sharing an id would suppress each
    // other's notifications.
    expect(arguments['receiverType'], 'user');
  });

  test('getBadgeCount falls back to zero when native answers null', () async {
    reply = null;
    expect(await platform.getBadgeCount(), 0);
  });

  test('permission checks read false rather than null', () async {
    reply = null;
    expect(await platform.isPermissionGranted(), isFalse);
    expect(await platform.requestPermission(), isFalse);
  });

  group('onNotificationTap backlog', () {
    // The native side releases whatever it captured from the launch intent the
    // instant anything listens. A plain broadcast stream hands that to whoever
    // is subscribed at that moment and to nobody else, so a cold-start tap was
    // being delivered before the app could possibly have subscribed and then
    // dropped — the notification opened the conversation list instead of the
    // conversation. It has to be held until a listener is actually there.
    const events = EventChannel('cometchat_push_notifications/responses');

    Future<void> emit(Map<String, Object?> event) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            events.name,
            const StandardMethodCodec().encodeSuccessEnvelope(event),
            (_) {},
          );
    }

    test(
      'a tap that arrives before anyone listens is still delivered',
      () async {
        // A fresh instance: the backlog is per-instance, and the point is what
        // happens on the very first listen.
        final cold = MethodChannelCometchatPushNotifications();
        final stream = cold.onNotificationTap;

        // Nothing is listening yet — this is the cold-start case.
        await emit({
          'conversationId': 'alex',
          'receiverType': 'user',
          'sender': 'alex',
          'senderName': 'Alex Okonjo',
          'messageId': '42',
        });

        final taps = <CometChatNotificationResponse>[];
        final subscription = stream.listen(taps.add);
        await pumpEventQueue();

        expect(
          taps.map((t) => t.conversationId),
          ['alex'],
          reason: 'the tap must survive until the app subscribes',
        );
        await subscription.cancel();
      },
    );
  });
}
