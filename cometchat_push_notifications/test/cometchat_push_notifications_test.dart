import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:cometchat_push_notifications/cometchat_push_notifications.dart';
import 'package:cometchat_push_notifications/cometchat_push_notifications_method_channel.dart';
import 'package:cometchat_push_notifications/cometchat_push_notifications_platform_interface.dart';
import 'package:cometchat_push_notifications/src/errors/cometchat_notification_exception.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_enums.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_notification_config.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_notification_details.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_notification_response.dart';

/// Records what the facade asked the platform to do.
///
/// Extends rather than implements, so it inherits the interface's defaults and
/// a method added later does not silently become a no-op here.
class _RecordingPlatform extends CometchatPushNotificationsPlatform
    with MockPlatformInterfaceMixin {
  final List<CometChatNotificationDetails> shown = [];
  final List<String?> cancelled = [];
  CometChatNotificationConfig? initializedWith;

  final _responses =
      StreamController<CometChatNotificationResponse>.broadcast();

  @override
  Future<String?> getPlatformVersion() async => '42';

  @override
  Future<String?> getApnsToken() async => 'apns-device-token';

  @override
  Future<void> initialize(CometChatNotificationConfig config) async {
    initializedWith = config;
  }

  @override
  Future<void> showNotification(CometChatNotificationDetails details) async {
    shown.add(details);
  }

  @override
  Future<void> cancelNotifications({String? conversationId}) async {
    cancelled.add(conversationId);
  }

  @override
  Future<void> setActiveConversation({
    String? id,
    String? receiverType,
  }) async {}

  @override
  Stream<CometChatNotificationResponse> get onNotificationTap =>
      _responses.stream;
}

void main() {
  late _RecordingPlatform platform;

  setUp(() async {
    platform = _RecordingPlatform();
    CometchatPushNotificationsPlatform.instance = platform;
    // Receipts reach into cometchat_sdk, which needs a logged-in session;
    // these tests are about routing, so they stay off.
    await CometChatPushNotifications.init(
      const CometChatNotificationConfig(
        appId: 'app',
        region: 'us',
        sendDeliveryReceipts: false,
      ),
    );
  });

  tearDown(() => CometChatPushNotifications.dispose());

  test('the default platform is the method channel one', () {
    CometchatPushNotificationsPlatform.instance =
        MethodChannelCometchatPushNotifications();
    expect(
      CometchatPushNotificationsPlatform.instance,
      isInstanceOf<MethodChannelCometchatPushNotifications>(),
    );
  });

  group('handlePushNotification', () {
    Map<String, dynamic> chatPayload({String type = 'chat'}) => {
      'data': {
        'to': {'uid': 'cameron'},
        'notificationDetails': {
          'type': type,
          'title': 'Alex Okonjo',
          'body': 'Are we still on for 3?',
          'sender': 'alex',
          'senderName': 'Alex Okonjo',
          'receiver': 'cameron',
          'receiverType': 'user',
          'tag': '42',
        },
      },
    };

    test('shows a chat push and reports it handled', () async {
      expect(
        await CometChatPushNotifications.handlePushNotification(chatPayload()),
        isTrue,
      );
      expect(platform.shown.single.sender, 'alex');
      expect(platform.shown.single.body, 'Are we still on for 3?');
    });

    test('leaves a call push alone', () async {
      // Calling lives in its own package now. Claiming the payload here would
      // leave the integrator no way to pass it on.
      expect(
        await CometChatPushNotifications.handlePushNotification(
          chatPayload(type: 'call'),
        ),
        isFalse,
      );
      expect(platform.shown, isEmpty);
    });

    test(
      'reports an unparseable payload unhandled rather than throwing',
      () async {
        // A push from another sender lands here too; it must pass straight
        // through, not take down whatever is forwarding it.
        expect(
          await CometChatPushNotifications.handlePushNotification({
            'hello': 'world',
          }),
          isFalse,
        );
        expect(platform.shown, isEmpty);
      },
    );

    test('throws before init, naming init as the fix', () async {
      await CometChatPushNotifications.dispose();

      expect(
        () => CometChatPushNotifications.handlePushNotification(chatPayload()),
        throwsA(
          isA<CometChatNotificationException>().having(
            (e) => e.code,
            'code',
            CometChatErrorCode.notInitialized,
          ),
        ),
      );
    });
  });

  test('init hands the config to the platform', () {
    expect(platform.initializedWith?.appId, 'app');
    expect(platform.initializedWith?.sendDeliveryReceipts, isFalse);
  });

  test('clearNotifications with no argument means all of them', () async {
    await CometChatPushNotifications.clearNotifications();
    await CometChatPushNotifications.clearNotifications(conversationId: 'alex');

    expect(platform.cancelled, [null, 'alex']);
  });

  group('onNotificationTap', () {
    test('passes taps through to the listener', () async {
      final taps = <CometChatNotificationResponse>[];
      final subscription = CometChatPushNotifications.onNotificationTap.listen(
        taps.add,
      );

      platform._responses.add(_response());
      await pumpEventQueue();

      expect(taps.map((t) => t.conversationId), ['alex']);
      await subscription.cancel();
    });
  });

  group('registerPushToken', () {
    late List<
      ({String method, Uri url, Map<String, String> headers, String? body})
    >
    sent;
    final zone = CometChatPushNotifications.timeZoneFor(
      DateTime.now().timeZoneName,
      DateTime.now().timeZoneOffset,
    );

    void respondWith(int status, String response) {
      CometChatPushNotifications.debugSetTokenTransport(
        send: (method, url, headers, body) async {
          sent.add((method: method, url: url, headers: headers, body: body));
          return (status, response);
        },
        authToken: () async => 'chat-auth',
      );
    }

    setUp(() {
      sent = [];
      respondWith(200, '{"data":{"success":true}}');
    });

    tearDown(() => CometChatPushNotifications.debugSetTokenTransport());

    Map<String, dynamic> bodyOf(int i) =>
        jsonDecode(sent[i].body!) as Map<String, dynamic>;

    test('the device token declares the v2 ringing flow', () async {
      await CometChatPushNotifications.registerPushToken(
        platform: PushPlatform.APNS_FLUTTER_DEVICE,
        providerId: 'apns-provider',
      );

      expect(sent.single.method, 'POST');
      expect(
        sent.single.url.toString(),
        'https://app.apiclient-us.cometchat.io/v3.0/notifications/push/v1/tokens',
      );
      expect(sent.single.headers['authToken'], 'chat-auth');
      expect(sent.single.headers['chatApiVersion'], 'v3.0');
      expect(bodyOf(0), {
        'deviceToken': 'apns-device-token',
        'platform': 'apns_flutter_device',
        'timezone': zone,
        'providerId': 'apns-provider',
        'ringingFlowVersion': 'v2',
      });
    });

    test('an FCM token goes in fcmToken, with ringingFlowVersion', () async {
      await CometChatPushNotifications.registerPushToken(
        token: 'fcm-token',
        platform: PushPlatform.FCM_FLUTTER_ANDROID,
      );

      expect(bodyOf(0), {
        'fcmToken': 'fcm-token',
        'platform': 'fcm_flutter_android',
        'timezone': zone,
        'ringingFlowVersion': 'v2',
      });
    });

    test('unregister deletes the token that was registered', () async {
      await CometChatPushNotifications.registerPushToken(
        token: 'fcm-token',
        platform: PushPlatform.FCM_FLUTTER_IOS,
      );
      await CometChatPushNotifications.unregisterPushToken();

      expect(sent.map((s) => s.method), ['POST', 'DELETE']);
      expect(bodyOf(1), bodyOf(0));
    });

    test(
      'unregister with nothing registered deletes the session token',
      () async {
        await CometChatPushNotifications.unregisterPushToken();

        expect(sent.single.method, 'DELETE');
        expect(sent.single.body, isNull);
      },
    );

    test(
      'nobody logged in to the Chat SDK is an error, not a request',
      () async {
        CometChatPushNotifications.debugSetTokenTransport(
          send: (method, url, headers, body) async => (200, '{}'),
          authToken: () async => null,
        );

        await expectLater(
          CometChatPushNotifications.registerPushToken(token: 'fcm-token'),
          throwsA(
            isA<CometChatNotificationException>().having(
              (e) => e.code,
              'code',
              CometChatErrorCode.tokenRegistrationFailed,
            ),
          ),
        );
      },
    );

    test('a refusal says what the server said', () async {
      respondWith(400, '{"error":"invalid provider"}');

      await expectLater(
        CometChatPushNotifications.registerPushToken(token: 'fcm-token'),
        throwsA(
          isA<CometChatNotificationException>().having(
            (e) => e.message,
            'message',
            contains('invalid provider'),
          ),
        ),
      );
    });

    test('the time zone is the IANA name, or a fixed-offset zone', () {
      String zoneFor(String name, Duration offset) =>
          CometChatPushNotifications.timeZoneFor(name, offset);

      expect(zoneFor('Asia/Kolkata', Duration.zero), 'Asia/Kolkata');
      // POSIX inverts the sign: Etc/GMT-1 is UTC+1.
      expect(zoneFor('CET', const Duration(hours: 1)), 'Etc/GMT-1');
      expect(zoneFor('EST', const Duration(hours: -5)), 'Etc/GMT+5');
      expect(zoneFor('GMT', Duration.zero), 'UTC');
      // No fixed-offset zone for a half hour.
      expect(zoneFor('IST', const Duration(hours: 5, minutes: 30)), 'UTC');
    });
  });

  group('PushPlatform', () {
    test('every platform but the APNs one carries an FCM token', () {
      // The two go into different fields on the registration call, and the
      // server ignores whichever it was not expecting.
      expect(PushPlatform.FCM_FLUTTER_ANDROID.isFcm, isTrue);
      expect(PushPlatform.FCM_FLUTTER_IOS.isFcm, isTrue);
      expect(PushPlatform.FCM_WEB.isFcm, isTrue);
      expect(PushPlatform.APNS_FLUTTER_DEVICE.isFcm, isFalse);
    });
  });

  group('CometChatNotificationResponse.fromMap', () {
    test('fills absent keys rather than letting them read as null', () {
      final response = CometChatNotificationResponse.fromMap({
        'conversationId': 'alex',
        'receiverType': 'user',
        'sender': 'alex',
        'messageId': '42',
      });

      expect(response.conversationId, 'alex');
      expect(response.receiverType, CometChatPushReceiverType.user);
      // Native omits keys it has nothing for; absent must not become "null".
      expect(response.senderName, '');
      expect(response.senderAvatar, isNull);
    });

    test('reads a group conversation', () {
      final response = CometChatNotificationResponse.fromMap({
        'conversationId': 'engineering',
        'receiverType': 'group',
        'sender': 'alex',
        'messageId': '42',
      });

      expect(response.receiverType, CometChatPushReceiverType.group);
      expect(response.conversationId, 'engineering');
    });
  });
}

CometChatNotificationResponse _response() =>
    const CometChatNotificationResponse(
      conversationId: 'alex',
      receiverType: CometChatPushReceiverType.user,
      sender: 'alex',
      senderName: 'Alex Okonjo',
      messageId: '42',
    );
