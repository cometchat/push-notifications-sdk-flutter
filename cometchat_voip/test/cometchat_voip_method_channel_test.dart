import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:cometchat_voip/cometchat_voip_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What actually crosses the method channel.
///
/// The native side reads these maps by key, and a renamed key fails silently
/// there — the call simply never rings on a cold start — so the wire shape is
/// pinned from this side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelCometchatVoip();
  const channel = MethodChannel('cometchat_voip');

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

  test('initialize sends what a killed app needs to ring', () async {
    await platform.initialize(
      const CometChatVoipConfig(
        appId: 'app',
        region: 'eu',
        providerId: 'provider',
        authToken: 'secret',
        clientHost: 'app.apiclient-eu.example.com',
        showMissedCallNotification: false,
        defaultRingTimeout: Duration(seconds: 30),
      ),
    );

    final arguments = argumentsOf('initialize');
    expect(arguments['appId'], 'app');
    expect(arguments['region'], 'eu');
    expect(arguments['clientHost'], 'app.apiclient-eu.example.com');
    expect(arguments['showMissedCallNotification'], isFalse);
    expect(arguments['requestCallPermissions'], isTrue);
    expect(arguments['defaultRingTimeoutMs'], 30000);
    expect(arguments['callMode'], 'auto');
    // CallKit presentation is ours again: we own the CXProvider.
    final callKit = arguments['callKit'] as Map<Object?, Object?>;
    expect(callKit['includesCallsInRecents'], isTrue);
    expect(callKit['supportsVideo'], isTrue);
  });

  test('initialize never hands credentials to the native side', () async {
    await platform.initialize(
      const CometChatVoipConfig(
        appId: 'app',
        region: 'us',
        providerId: 'provider',
        authToken: 'secret',
      ),
    );

    final arguments = argumentsOf('initialize');
    expect(arguments.containsKey('authToken'), isFalse);
    expect(arguments.values, isNot(contains('secret')));
  });

  test('handlePushNotification sends the data and the sent time', () async {
    reply = true;
    final handled = await platform.handlePushNotification({
      'type': 'call',
    }, sentTimeMs: 1234);

    expect(handled, isTrue);
    final arguments = argumentsOf('handlePushNotification');
    expect(arguments['data'], {'type': 'call'});
    expect(arguments['sentTimeMs'], 1234);
  });

  test('a native side with nothing to say reads as not handled', () async {
    expect(await platform.handlePushNotification({'type': 'call'}), isFalse);
  });

  test('answer and decline name their session', () async {
    await platform.answer('s1');
    await platform.decline('s2');

    expect(argumentsOf('answer')['sessionId'], 's1');
    expect(argumentsOf('decline')['sessionId'], 's2');
  });

  test('dismissRinging says whether the app answered', () async {
    await platform.dismissRinging('s1', answered: true);
    expect(argumentsOf('dismissRinging'), {
      'sessionId': 's1',
      'answered': true,
    });
  });

  test('getActiveCall reads the native call map', () async {
    reply = {
      'sessionId': 's1',
      'callerName': 'Alex Okonjo',
      'callType': 'video',
      'receiverType': 'user',
      'initiatedAtMs': '1000',
      'ringTimeoutMs': '45000',
    };

    final call = await platform.getActiveCall();
    expect(call?.sessionId, 's1');
    expect(call?.isVideo, isTrue);
  });

  test('checkRingReadiness maps the native name', () async {
    reply = 'fullScreenIntentDenied';
    expect(
      await platform.checkRingReadiness(),
      CometChatRingReadiness.fullScreenIntentDenied,
    );
  });

  test('openSettings names the readiness it fixes', () async {
    reply = true;
    expect(
      await platform.openSettings(CometChatRingReadiness.channelMuted),
      isTrue,
    );
    expect(argumentsOf('openSettings')['readiness'], 'channelMuted');
  });

  test('reportOutgoingCall sends everything CallKit shows', () async {
    await platform.reportOutgoingCall(
      sessionId: 's1',
      calleeName: 'Alex',
      hasVideo: true,
    );
    expect(argumentsOf('reportOutgoingCall'), {
      'sessionId': 's1',
      'calleeName': 'Alex',
      'hasVideo': true,
    });
  });
}
