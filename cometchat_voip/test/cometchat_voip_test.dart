import 'dart:convert';

import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart' as calls;
import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:cometchat_voip/src/calls/call_accept_client.dart';
import 'package:cometchat_voip/src/token/push_token_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One call the test made to the Calls SDK's platform channel.
typedef SdkCall = ({String method, Map<Object?, Object?> args});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cometchatcalls_plugin');
  const voipChannel = MethodChannel('cometchat_voip');
  final sdkCalls = <SdkCall>[];
  final nativeCalls = <SdkCall>[];
  final requests = <({String method, Map<String, Object?> body})>[];

  /// What the mocked channels reply with, per method.
  late Map<String, Object?> replies;
  late Map<String, Object?> nativeReplies;

  /// The config every test starts from.
  ///
  /// MANUAL, so the Dart path under test actually runs: in AUTO the native
  /// ringer owns the push, and there is no native ringer in a unit test. The
  /// `call mode` group covers that delegation separately.
  const config = CometChatVoipConfig(
    appId: 'APP',
    region: 'us',
    providerId: 'provider-1',
    callMode: CometChatCallMode.manual,
  );

  /// The same thing in AUTO, for the delegation tests.
  const autoConfig = CometChatVoipConfig(
    appId: 'APP',
    region: 'us',
    providerId: 'provider-1',
  );

  /// AUTO with the app's own ring screen: everything AUTO does, except that
  /// the full-screen alert and its tap open the app.
  const customScreenConfig = CometChatVoipConfig(
    appId: 'APP',
    region: 'us',
    providerId: 'provider-1',
    callMode: CometChatCallMode.autoCustomScreen,
  );

  Map<String, Object?> callMap(String sessionId, {String? status}) => {
    'sessionId': sessionId,
    'sender': 'alice',
    'callerName': 'Alice',
    'type': 'audio',
    'receiver': 'bob',
    'receiverType': 'user',
    'status': status ?? 'initiated',
    'initiatedAt': 1700000000000,
  };

  setUp(() {
    sdkCalls.clear();
    nativeCalls.clear();
    requests.clear();
    replies = {};
    nativeReplies = {
      'getTimeZone': 'Asia/Kolkata',
      'wasTerminal': false,
      'verifyPushSetup': 'ok',
      'handlePushNotification': true,
    };

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          sdkCalls.add((
            method: methodCall.method,
            args:
                (methodCall.arguments as Map?)?.cast<Object?, Object?>() ?? {},
          ));
          return replies[methodCall.method];
        });

    // The native ringer. Stubbed rather than absent, so `init` succeeds and
    // the facade's own logic is what the tests see.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(voipChannel, (methodCall) async {
          nativeCalls.add((
            method: methodCall.method,
            args:
                (methodCall.arguments as Map?)?.cast<Object?, Object?>() ?? {},
          ));
          return nativeReplies[methodCall.method];
        });

    // A transport that records what went out and always succeeds.
    Future<(int, String)> transport(
      String method,
      Uri url,
      Map<String, String> headers,
      String body,
    ) async {
      requests.add((
        method: method,
        body: (jsonDecode(body) as Map).cast<String, Object?>(),
      ));
      return (200, '{}');
    }

    CometChatVoip.resetForTesting(
      tokenClient: PushTokenClient(transport: transport),
      acceptClient: CallAcceptClient(transport: transport),
      callsAuthToken: () async => 'auth-token',
    );
    calls.CometChatCalls.resetForTesting();
    calls.CometChatCalls.initForTesting(
      (calls.CallAppSettingBuilder()
            ..appId = 'APP'
            ..region = 'us')
          .build(),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(channel, null)
      ..setMockMethodCallHandler(voipChannel, null);
    calls.CometChatCalls.resetForTesting();
  });

  SdkCall? lastCallTo(String method) {
    final matches = sdkCalls.where((c) => c.method == method);
    return matches.isEmpty ? null : matches.last;
  }

  SdkCall? lastNativeCallTo(String method) {
    final matches = nativeCalls.where((c) => c.method == method);
    return matches.isEmpty ? null : matches.last;
  }

  // ──────────────────────────────────────────────

  group('handlePushNotification', () {
    test('a non-call push is still the caller\'s', () async {
      await CometChatVoip.init(config);
      final handled = await CometChatVoip.handlePushNotification({
        'type': 'chat',
        'body': 'hello',
      });
      expect(handled, isFalse);
      expect(sdkCalls.where((c) => c.method.startsWith('inject')), isEmpty);
    });

    test('an incoming call is handed to the Calls SDK as it arrived', () async {
      await CometChatVoip.init(config);
      replies['injectIncomingCall'] = callMap('session-1');

      final handled = await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-1',
        'sender': 'alice',
        'sentAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });

      expect(handled, isTrue);
      final injected = lastCallTo('injectIncomingCall');
      expect(injected, isNotNull);
      expect((injected!.args['payload'] as Map)['sessionId'], 'session-1');
      expect((injected.args['payload'] as Map)['sender'], 'alice');
    });

    test('a terminal push ends the ringing, with the mapped reason', () async {
      await CometChatVoip.init(config);
      replies['injectIncomingCallEnded'] = callMap('session-2');

      final handled = await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'cancelled',
        'sessionId': 'session-2',
      });

      expect(handled, isTrue);
      final ended = lastCallTo('injectIncomingCallEnded');
      expect(ended, isNotNull);
      expect(ended!.args['reason'], CometChatCallEndReason.cancelled.wireName);
    });

    test('a call that arrived after its ring window is dropped', () async {
      await CometChatVoip.init(config);
      final ended = CometChatVoip.onCallEnded.first;

      final handled = await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-3',
        'ringTimeout': '30000',
      }, sentTime: DateTime.now().subtract(const Duration(minutes: 5)));

      expect(handled, isTrue);
      expect(lastCallTo('injectIncomingCall'), isNull);
      // `timedOut`, not `filtered`: the native RingGate ends an expired call
      // as a missed one, because that is what it was.
      expect((await ended).reason, CometChatCallEndReason.timedOut);
    });

    test('with the guard off, a late call still rings', () async {
      await CometChatVoip.init(
        const CometChatVoipConfig(
          appId: 'APP',
          region: 'us',
          callMode: CometChatCallMode.manual,
          dropExpiredCalls: false,
        ),
      );
      replies['injectIncomingCall'] = callMap('session-4');

      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-4',
        'ringTimeout': '30000',
      }, sentTime: DateTime.now().subtract(const Duration(minutes: 5)));

      expect(lastCallTo('injectIncomingCall'), isNotNull);
    });

    test(
      'a terminal push for a call the SDK never rang still reaches the app',
      () async {
        await CometChatVoip.init(config);
        // The SDK reports nothing back: it had no such call ringing.
        replies['injectIncomingCallEnded'] = null;
        final ended = CometChatVoip.onCallEnded.first;

        await CometChatVoip.handlePushNotification({
          'type': 'call',
          'callAction': 'unanswered',
          'sessionId': 'session-5',
          'senderName': 'Alice',
        });

        final event = await ended;
        expect(event.call.sessionId, 'session-5');
        expect(event.call.callerName, 'Alice');
        expect(event.reason, CometChatCallEndReason.timedOut);
        expect(event.reason.isMissed, isTrue);
      },
    );

    test('a Calls SDK refusal costs the push, not the isolate', () async {
      await CometChatVoip.init(config);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (methodCall) async =>
                throw PlatformException(code: 'ERROR', message: 'nope'),
          );

      await expectLater(
        CometChatVoip.handlePushNotification({
          'type': 'call',
          'callAction': 'initiated',
          'sessionId': 'session-6',
        }),
        completion(isTrue),
      );
    });
  });

  group('the ringing call', () {
    test('reaches onCallRinging, and is the active call', () async {
      await CometChatVoip.init(config);
      final ringing = CometChatVoip.onCallRinging.first;

      CometChatVoip.handleRingingForTesting(
        calls.InitiatedCall.fromMap(callMap('session-7')),
      );

      final call = await ringing;
      expect(call.sessionId, 'session-7');
      expect(call.callerName, 'Alice');
      expect(CometChatVoip.activeCall?.sessionId, 'session-7');
    });

    test('is held when it arrived before anything listened', () async {
      await CometChatVoip.init(config);
      CometChatVoip.handleRingingForTesting(
        calls.InitiatedCall.fromMap(callMap('session-8')),
      );

      final call = await CometChatVoip.onCallRinging.first;
      expect(call.sessionId, 'session-8');
    });

    test('an end clears it and says why', () async {
      await CometChatVoip.init(config);
      CometChatVoip.handleRingingForTesting(
        calls.InitiatedCall.fromMap(callMap('session-9')),
      );
      final ended = CometChatVoip.onCallEnded.first;

      CometChatVoip.handleEndedForTesting(
        calls.InitiatedCall.fromMap(callMap('session-9')),
        'rejected',
      );

      expect((await ended).reason, CometChatCallEndReason.declined);
      expect(CometChatVoip.activeCall, isNull);
    });

    test("iOS's CallKit answer is an answer, not an end", () async {
      await CometChatVoip.init(config);
      final answered = CometChatVoip.onCallAnswered.first;

      CometChatVoip.handleEndedForTesting(
        calls.InitiatedCall.fromMap(callMap('session-10')),
        'answered',
      );

      expect((await answered).sessionId, 'session-10');
    });
  });

  group('accept', () {
    test('reports the answer and marks the call ongoing', () async {
      await CometChatVoip.init(config);
      CometChatVoip.handleRingingForTesting(
        calls.InitiatedCall.fromMap(callMap('session-11')),
      );
      final answered = CometChatVoip.onCallAnswered.first;

      await CometChatVoip.accept('session-11');

      expect((await answered).sessionId, 'session-11');
      await Future<void>.delayed(Duration.zero);
      expect(requests.single.method, 'PUT');
      expect(requests.single.body['status'], 'ongoing');
    });

    test('can be turned off for an all-ringing-flow app', () async {
      await CometChatVoip.init(
        const CometChatVoipConfig(
          appId: 'APP',
          region: 'us',
          acceptOnAnswer: false,
        ),
      );
      final answered = CometChatVoip.onCallAnswered.first;

      await CometChatVoip.accept('session-12');

      expect((await answered).sessionId, 'session-12');
      await Future<void>.delayed(Duration.zero);
      expect(requests, isEmpty);
    });

    test('the same answer is never marked twice', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.accept('session-13');
      CometChatVoip.handleEndedForTesting(
        calls.InitiatedCall.fromMap(callMap('session-13')),
        'answered',
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
    });
  });

  group('decline', () {
    test('ends the call as rejected', () async {
      await CometChatVoip.init(config);
      replies['endCall'] = callMap('session-14', status: 'rejected');

      await CometChatVoip.decline('session-14');

      final ended = lastCallTo('endCall');
      expect(ended, isNotNull);
      expect(ended!.args['sessionId'], 'session-14');
      expect(ended.args['status'], calls.EndCallStatus.rejected);
    });

    test('sends busy when another call is already in progress', () async {
      await CometChatVoip.init(config);
      replies['endCall'] = callMap('session-15', status: 'busy');

      await CometChatVoip.decline('session-15', busy: true);

      expect(lastCallTo('endCall')!.args['status'], calls.EndCallStatus.busy);
    });

    test('a refusal is retried, then reported', () async {
      await CometChatVoip.init(config);
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            if (methodCall.method == 'endCall') attempts++;
            throw PlatformException(code: 'ERROR', message: 'nope');
          });

      await expectLater(
        CometChatVoip.decline('session-16'),
        throwsA(
          isA<CometChatVoipException>().having(
            (e) => e.code,
            'code',
            CometChatVoipErrorCode.callsSdkError,
          ),
        ),
      );
      // A decline that does not land leaves the caller ringing at nobody.
      expect(attempts, greaterThan(1));
    });

    test('a retry that lands does not throw', () async {
      await CometChatVoip.init(config);
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (methodCall) async {
            if (methodCall.method != 'endCall') return null;
            attempts++;
            if (attempts == 1) {
              throw PlatformException(code: 'ERROR', message: 'nope');
            }
            return callMap('session-17', status: 'rejected');
          });

      await expectLater(CometChatVoip.decline('session-17'), completes);
      expect(attempts, 2);
    });
  });

  group('registerPushToken', () {
    test('registers the token the app handed over', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'push-token');

      expect(requests.single.method, 'POST');
      expect(requests.single.body['fcmToken'], 'push-token');
      expect(requests.single.body['platform'], 'fcm_flutter_android');
      expect(requests.single.body['providerId'], 'provider-1');
    });

    test(
      'the token is remembered, so later calls need not repeat it',
      () async {
        await CometChatVoip.init(config);
        await CometChatVoip.registerPushToken(token: 'push-token');
        await CometChatVoip.registerPushToken();

        expect(requests, hasLength(2));
        expect(requests.last.body['fcmToken'], 'push-token');
      },
    );

    test('without a token it says where to get one', () async {
      await CometChatVoip.init(config);
      await expectLater(
        CometChatVoip.registerPushToken(),
        throwsA(
          isA<CometChatVoipException>().having(
            (e) => e.code,
            'code',
            CometChatVoipErrorCode.noPushToken,
          ),
        ),
      );
    });

    test('without a login there is nobody to register for', () async {
      CometChatVoip.resetForTesting(callsAuthToken: () async => null);
      await CometChatVoip.init(config);
      await expectLater(
        CometChatVoip.registerPushToken(token: 'push-token'),
        throwsA(
          isA<CometChatVoipException>().having(
            (e) => e.code,
            'code',
            CometChatVoipErrorCode.notLoggedIn,
          ),
        ),
      );
    });

    test('an explicit auth token wins over the Calls login', () async {
      Future<(int, String)> transport(
        String method,
        Uri url,
        Map<String, String> headers,
        String body,
      ) async {
        requests.add((
          method: method,
          body: {'authToken': headers['authToken']},
        ));
        return (200, '{}');
      }

      CometChatVoip.resetForTesting(
        tokenClient: PushTokenClient(transport: transport),
        callsAuthToken: () async => 'from-login',
      );
      await CometChatVoip.init(
        const CometChatVoipConfig(
          appId: 'APP',
          region: 'us',
          authToken: 'configured',
        ),
      );
      await CometChatVoip.registerPushToken(token: 'push-token');

      expect(requests.single.body['authToken'], 'configured');
    });

    test('needs init', () async {
      await expectLater(
        CometChatVoip.registerPushToken(token: 'push-token'),
        throwsA(
          isA<CometChatVoipException>().having(
            (e) => e.code,
            'code',
            CometChatVoipErrorCode.notInitialized,
          ),
        ),
      );
    });

    test('unregister deletes the token it registered', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'push-token');
      await CometChatVoip.unregisterPushToken();

      expect(requests.last.method, 'DELETE');
      expect(requests.last.body['fcmToken'], 'push-token');
    });
  });

  group('auto-registration on login', () {
    test('registers the token the app set earlier', () async {
      await CometChatVoip.init(config);
      CometChatVoip.setPushToken('push-token');

      await CometChatVoip.registerOnLoginForTesting();

      expect(requests.single.body['fcmToken'], 'push-token');
    });

    test('waits for the app when no token has arrived yet', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerOnLoginForTesting();
      expect(requests, isEmpty);
    });

    test('the same token is not registered twice', () async {
      await CometChatVoip.init(config);
      CometChatVoip.setPushToken('push-token');
      await CometChatVoip.registerOnLoginForTesting();
      await CometChatVoip.registerOnLoginForTesting();

      expect(requests, hasLength(1));
    });

    test('with it off, registration waits for the app to ask', () async {
      await CometChatVoip.init(
        const CometChatVoipConfig(
          appId: 'APP',
          region: 'us',
          autoRegisterPushToken: false,
        ),
      );
      CometChatVoip.setPushToken('push-token');
      await CometChatVoip.registerOnLoginForTesting();

      expect(requests, isEmpty);
    });

    test('a failure is logged rather than thrown', () async {
      Future<(int, String)> failing(
        String method,
        Uri url,
        Map<String, String> headers,
        String body,
      ) async => (401, 'nope');

      CometChatVoip.resetForTesting(
        tokenClient: PushTokenClient(transport: failing),
        callsAuthToken: () async => 'auth-token',
      );
      await CometChatVoip.init(config);
      CometChatVoip.setPushToken('push-token');

      await expectLater(CometChatVoip.registerOnLoginForTesting(), completes);
    });
  });

  group('the PushKit token from launch (iOS)', () {
    // PushKit delivers the token in didFinishLaunching, before Dart listens,
    // and the native side does not hold it for a late listener. Unless init
    // asks for it, it is never registered and no call ever rings.
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    String? authToken;

    void useAuth(String? value) {
      authToken = value;
      CometChatVoip.resetForTesting(
        tokenClient: PushTokenClient(
          transport: (method, url, headers, body) async {
            requests.add((
              method: method,
              body: (jsonDecode(body) as Map).cast<String, Object?>(),
            ));
            return (200, '{}');
          },
        ),
        callsAuthToken: () async => authToken,
      );
    }

    test('init registers it when somebody is logged in', () async {
      useAuth('auth-token');
      nativeReplies['getVoipToken'] = 'voip-token';

      await CometChatVoip.init(autoConfig);
      await pumpEventQueue();

      expect(requests.single.method, 'POST');
      expect(requests.single.body['voipToken'], 'voip-token');
      expect(requests.single.body['platform'], 'apns_flutter_voip');
    });

    test('otherwise the next login registers it', () async {
      useAuth(null);
      nativeReplies['getVoipToken'] = 'voip-token';

      await CometChatVoip.init(autoConfig);
      await pumpEventQueue();
      expect(requests, isEmpty);

      authToken = 'auth-token';
      await CometChatVoip.registerOnLoginForTesting();

      expect(requests.single.body['voipToken'], 'voip-token');
    });

    test('MANUAL does not ask: the app owns PushKit', () async {
      useAuth('auth-token');
      nativeReplies['getVoipToken'] = 'voip-token';

      await CometChatVoip.init(config);
      await pumpEventQueue();

      expect(nativeCalls.where((c) => c.method == 'getVoipToken'), isEmpty);
      expect(requests, isEmpty);
    });
  });

  group('token refresh and failure', () {
    test('a rotated token is registered in place of the old one', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'old-token');
      await CometChatVoip.handleTokenRefresh('new-token');

      expect(requests, hasLength(2));
      expect(requests.last.body['fcmToken'], 'new-token');
    });

    test('the same token is not registered again', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'token');
      await CometChatVoip.handleTokenRefresh('token');
      expect(requests, hasLength(1));
    });

    test('a failure is reported, not thrown', () async {
      CometChatVoip.resetForTesting(
        tokenClient: PushTokenClient(
          transport: (m, u, h, b) async => (401, 'nope'),
        ),
        callsAuthToken: () async => 'auth-token',
      );
      await CometChatVoip.init(config);

      await expectLater(CometChatVoip.handleTokenRefresh('t'), completes);
      final diagnostics = await CometChatVoip.getDiagnostics();
      expect(diagnostics['lastTokenError'], contains('401'));
    });

    test('throwOnError surfaces it instead', () async {
      CometChatVoip.resetForTesting(
        tokenClient: PushTokenClient(
          transport: (m, u, h, b) async => (401, 'nope'),
        ),
        callsAuthToken: () async => 'auth-token',
      );
      await CometChatVoip.init(config);
      await expectLater(
        CometChatVoip.handleTokenRefresh('t', throwOnError: true),
        throwsA(isA<CometChatVoipException>()),
      );
    });

    test('a registration refusal by the OS is recorded', () async {
      await CometChatVoip.init(config);
      CometChatVoip.handleRegistrationFailure('no aps-environment');

      final diagnostics = await CometChatVoip.getDiagnostics();
      expect(diagnostics['lastTokenError'], 'no aps-environment');
    });
  });

  group('verifyPushSetup', () {
    test('needs init', () async {
      expect(
        await CometChatVoip.verifyPushSetup(),
        CometChatPushSetupResult.notInitialized,
      );
    });

    test('needs a login', () async {
      CometChatVoip.resetForTesting(callsAuthToken: () async => null);
      await CometChatVoip.init(config);
      expect(
        await CometChatVoip.verifyPushSetup(),
        CometChatPushSetupResult.notLoggedIn,
      );
    });

    test('needs a token', () async {
      await CometChatVoip.init(config);
      expect(
        await CometChatVoip.verifyPushSetup(),
        CometChatPushSetupResult.tokenNotRegistered,
      );
    });

    test('reports a token that never registered', () async {
      await CometChatVoip.init(config);
      CometChatVoip.setPushToken('token');
      expect(
        await CometChatVoip.verifyPushSetup(),
        CometChatPushSetupResult.tokenRegistrationFailed,
      );
    });

    test('is ok once everything is in place', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'token');
      expect(
        await CometChatVoip.verifyPushSetup(),
        CometChatPushSetupResult.ok,
      );
    });
  });

  group('getDiagnostics', () {
    test('never reveals the token, only its shape', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'super-secret-token');

      final d = await CometChatVoip.getDiagnostics();
      expect(d.toString(), isNot(contains('super-secret-token')));
      expect(d['pushToken'], contains('len=18'));
      expect(d['pushTokenRegistered'], isTrue);
    });

    test('counts what became of each push', () async {
      await CometChatVoip.init(config);
      replies['injectIncomingCall'] = callMap('session-a');
      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-a',
        'sentAt': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      });
      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-b',
        'ringTimeout': '30000',
      }, sentTime: DateTime.now().subtract(const Duration(minutes: 5)));

      final d = await CometChatVoip.getDiagnostics();
      expect(d['pushesSeen'], 2);
      expect(d['pushesRung'], 1);
      expect(d['pushesDropped'], 1);
    });

    test('nests the native ringer\'s own snapshot', () async {
      nativeReplies['getDiagnostics'] = {'ringerInstalled': true};
      nativeReplies['checkRingReadiness'] = 'channelMuted';
      nativeReplies['lastWakeTiming'] = {'sdkReadyMs': 120, 'connectMs': 340};

      await CometChatVoip.init(config);
      final d = await CometChatVoip.getDiagnostics();
      final native = d['native']! as Map<String, Object?>;

      expect(native['ringerInstalled'], isTrue);
      expect(native['ringReadiness'], 'channelMuted');
      expect(native['lastWakeTiming'], {'sdkReadyMs': 120, 'connectMs': 340});
      expect(d['callMode'], 'manual');
    });

    test(
      'says why there is no native snapshot, rather than omitting it',
      () async {
        await CometChatVoip.init(config);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(voipChannel, null);

        final d = await CometChatVoip.getDiagnostics();
        final native = d['native']! as Map<String, Object?>;
        expect(native['available'], isFalse);
        expect(native['reason'], contains('no ringer'));
      },
    );
  });

  group('the duplicate gate, end to end', () {
    test(
      'a redelivered initiated for an ended session does not ring',
      () async {
        await CometChatVoip.init(config);
        replies['injectIncomingCallEnded'] = callMap('session-dup');

        await CometChatVoip.handlePushNotification({
          'type': 'call',
          'callAction': 'cancelled',
          'sessionId': 'session-dup',
        });
        sdkCalls.clear();

        await CometChatVoip.handlePushNotification({
          'type': 'call',
          'callAction': 'initiated',
          'sessionId': 'session-dup',
          'sentAt': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        });

        expect(lastCallTo('injectIncomingCall'), isNull);
      },
    );

    test('a declined session is remembered too', () async {
      await CometChatVoip.init(config);
      replies['endCall'] = callMap('session-dec', status: 'rejected');
      await CometChatVoip.decline('session-dec');
      sdkCalls.clear();

      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-dec',
        'sentAt': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      });

      expect(lastCallTo('injectIncomingCall'), isNull);
    });
  });

  group('call mode', () {
    test(
      'AUTO hands the push to the native ringer, not the Calls SDK',
      () async {
        await CometChatVoip.init(autoConfig);

        final handled = await CometChatVoip.handlePushNotification({
          'type': 'call',
          'callAction': 'initiated',
          'sessionId': 'session-auto',
        }, sentTime: DateTime.now());

        expect(handled, isTrue);
        final native = lastNativeCallTo('handlePushNotification');
        expect(native, isNotNull);
        expect((native!.args['data'] as Map)['sessionId'], 'session-auto');
        // The native ringer owns the gates and the inject in AUTO.
        expect(lastCallTo('injectIncomingCall'), isNull);
      },
    );

    test('AUTO still returns false for a non-call push', () async {
      nativeReplies['handlePushNotification'] = false;
      await CometChatVoip.init(autoConfig);

      final handled = await CometChatVoip.handlePushNotification({
        'type': 'chat',
        'body': 'hello',
      });
      expect(handled, isFalse);
    });

    test('MANUAL gates in Dart and injects into the Calls SDK', () async {
      await CometChatVoip.init(config);
      replies['injectIncomingCall'] = callMap('session-manual');

      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-manual',
      }, sentTime: DateTime.now());

      expect(lastCallTo('injectIncomingCall'), isNotNull);
      expect(lastNativeCallTo('handlePushNotification'), isNull);
    });

    test('AUTO declines through the native queue, which is durable', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.decline('session-d');

      expect(lastNativeCallTo('decline')!.args['sessionId'], 'session-d');
      expect(lastCallTo('endCall'), isNull);
    });

    test('MANUAL declines through the Calls SDK', () async {
      await CometChatVoip.init(config);
      replies['endCall'] = callMap('session-e', status: 'rejected');
      await CometChatVoip.decline('session-e');

      expect(lastCallTo('endCall'), isNotNull);
      expect(lastNativeCallTo('decline'), isNull);
    });

    test('AUTO + custom screen is still the ringer\'s push', () async {
      await CometChatVoip.init(customScreenConfig);

      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-cs1',
      }, sentTime: DateTime.now());

      // The mode changes whose screen the ring opens, nothing else: the
      // ringer still owns the gates, the ring and the inject.
      expect(lastNativeCallTo('handlePushNotification'), isNotNull);
      expect(lastCallTo('injectIncomingCall'), isNull);
    });

    test('AUTO + custom screen declines through the native queue', () async {
      await CometChatVoip.init(customScreenConfig);
      await CometChatVoip.decline('session-cs2');

      expect(lastNativeCallTo('decline')!.args['sessionId'], 'session-cs2');
      expect(lastCallTo('endCall'), isNull);
    });

    test('the mode reaches the ringer, which decides on it alone', () async {
      await CometChatVoip.init(customScreenConfig);
      expect(
        lastNativeCallTo('initialize')!.args['callMode'],
        'autoCustomScreen',
      );
    });
  });

  group('the native ringer\'s events', () {
    /// Pushes one event down the native event channel.
    Future<void> emit(Map<String, Object?> event) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'cometchat_voip/events',
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
    }

    test('the native ringer reports no ringing of its own: onCallRinging '
        'comes through the inject path', () async {
      await CometChatVoip.init(autoConfig);
      final rings = <CometChatVoipCall>[];
      final sub = CometChatVoip.onCallRinging.listen(rings.add);

      await emit({
        'event': 'ringing',
        'call': {'sessionId': 'session-n1', 'callerName': 'Alex'},
      });
      await pumpEventQueue();

      expect(rings, isEmpty);
      expect(CometChatVoip.activeCall, isNull);
      await sub.cancel();
    });

    test('an answer from CallKit reaches onCallAnswered', () async {
      await CometChatVoip.init(autoConfig);
      final answered = CometChatVoip.onCallAnswered.first;

      await emit({
        'event': 'answered',
        'call': {'sessionId': 'session-n2', 'callerName': 'Alex'},
      });

      expect((await answered).sessionId, 'session-n2');
    });

    test('an end carries the reason the ringer gave', () async {
      await CometChatVoip.init(autoConfig);
      final ended = CometChatVoip.onCallEnded.first;

      await emit({
        'event': 'ended',
        'reason': 'timedOut',
        'call': {'sessionId': 'session-n3'},
      });

      final event = await ended;
      expect(event.reason, CometChatCallEndReason.timedOut);
      expect(event.reason.isMissed, isTrue);
    });

    test('a rotated VoIP token registers itself', () async {
      await CometChatVoip.init(autoConfig);
      await emit({'event': 'voipToken', 'token': 'rotated-token'});
      await Future<void>.delayed(Duration.zero);

      expect(
        requests.single.body['voipToken'] ?? requests.single.body['fcmToken'],
        'rotated-token',
      );
    });
  });

  group('the platform-backed methods', () {
    test('each one reaches its native method', () async {
      await CometChatVoip.init(autoConfig);
      nativeReplies['getVoipToken'] = 'abc123';
      nativeReplies['checkRingReadiness'] = 'doNotDisturb';
      nativeReplies['openSettings'] = true;
      nativeReplies['requestNotificationPermission'] = true;
      nativeReplies['getActiveCall'] = {'sessionId': 'session-x'};

      expect(await CometChatVoip.getVoipToken(), 'abc123');
      expect(
        await CometChatVoip.checkRingReadiness(),
        CometChatRingReadiness.doNotDisturb,
      );
      expect(
        await CometChatVoip.openSettings(CometChatRingReadiness.doNotDisturb),
        isTrue,
      );
      expect(await CometChatVoip.requestNotificationPermission(), isTrue);
      expect((await CometChatVoip.getActiveCall())?.sessionId, 'session-x');

      await CometChatVoip.answer('s1');
      await CometChatVoip.dismissRinging('s2', answered: true);
      await CometChatVoip.reportOutgoingCall(
        sessionId: 's3',
        calleeName: 'Alex',
        hasVideo: true,
      );
      await CometChatVoip.reportCallConnected('s3');
      await CometChatVoip.reportCallEnded('s3');

      expect(lastNativeCallTo('answer')!.args['sessionId'], 's1');
      expect(lastNativeCallTo('dismissRinging')!.args['answered'], isTrue);
      expect(lastNativeCallTo('reportOutgoingCall')!.args['hasVideo'], isTrue);
      expect(lastNativeCallTo('reportCallConnected'), isNotNull);
      expect(
        lastNativeCallTo('reportCallEnded')!.args['reason'],
        'remoteEnded',
      );
    });

    test('reportCallEnded carries the reason CallKit should record', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.reportCallEnded(
        's4',
        reason: CometChatCallEndReason.declined,
      );
      expect(lastNativeCallTo('reportCallEnded')!.args['reason'], 'declined');
    });

    test('verifyPushSetup folds in what only the OS can see', () async {
      nativeReplies['verifyPushSetup'] = 'notificationsBlocked';
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'token');

      expect(
        await CometChatVoip.verifyPushSetup(),
        CometChatPushSetupResult.notificationsBlocked,
      );
    });

    test(
      'the timezone comes from the device when none is configured',
      () async {
        await CometChatVoip.init(config);
        await CometChatVoip.registerPushToken(token: 'token');
        expect(requests.single.body['timezone'], 'Asia/Kolkata');
      },
    );

    test('the token is registered for the v2 ringing flow', () async {
      await CometChatVoip.init(config);
      await CometChatVoip.registerPushToken(token: 'token');
      expect(requests.single.body['ringingFlowVersion'], 'v2');
    });
  });

  group('ringSurfaces', () {
    test('each one reaches its native method with the whole call', () async {
      await CometChatVoip.init(config);
      final call = CometChatVoipCall(
        sessionId: 'session-r',
        callerName: 'Alex',
        callType: 'audio',
        receiverType: 'user',
        initiatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ringTimeout: const Duration(seconds: 45),
      );

      await CometChatVoip.ringSurfaces.showIncomingNotification(call);
      await CometChatVoip.ringSurfaces.verify(call);
      await CometChatVoip.ringSurfaces.keepAlive(call);
      await CometChatVoip.ringSurfaces.showMissedCall(call);
      await CometChatVoip.ringSurfaces.stopRinging('session-r');

      for (final method in [
        'ringSurface.showIncomingNotification',
        'ringSurface.verify',
        'ringSurface.keepAlive',
        'ringSurface.showMissedCall',
      ]) {
        final native = lastNativeCallTo(method);
        expect(native, isNotNull, reason: method);
        expect((native!.args['call'] as Map)['sessionId'], 'session-r');
      }
      expect(
        lastNativeCallTo('ringSurface.stopRinging')!.args['sessionId'],
        'session-r',
      );
    });

    test("iOS's refusal becomes an unsupportedPlatform exception", () async {
      await CometChatVoip.init(config);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            voipChannel,
            (methodCall) async => throw PlatformException(
              code: 'unsupported_platform',
              message: 'Android-only',
            ),
          );

      await expectLater(
        CometChatVoip.ringSurfaces.stopRinging('s'),
        throwsA(
          isA<CometChatVoipException>().having(
            (e) => e.code,
            'code',
            CometChatVoipErrorCode.unsupportedPlatform,
          ),
        ),
      );
    });
  });

  group('the terminal ledger across processes', () {
    test('a session an earlier process ended does not ring now', () async {
      // The native store remembers it; this process has an empty ledger.
      nativeReplies['wasTerminal'] = true;
      nativeReplies['terminalReason'] = 'cancelled';
      await CometChatVoip.init(config);
      final ended = CometChatVoip.onCallEnded.first;

      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-cold',
      }, sentTime: DateTime.now());

      expect(lastCallTo('injectIncomingCall'), isNull);
      expect((await ended).reason, CometChatCallEndReason.filtered);
    });

    test('a terminal push is written to the native store too', () async {
      await CometChatVoip.init(config);
      replies['injectIncomingCallEnded'] = callMap('session-t');

      await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'cancelled',
        'sessionId': 'session-t',
      });

      final marked = lastNativeCallTo('markTerminal');
      expect(marked, isNotNull);
      expect(marked!.args['sessionId'], 'session-t');
    });
  });

  group('the Dart-backed Calls bridge', () {
    /// Simulates the native ringer calling Dart, the way it does when it needs
    /// the Calls SDK it no longer links.
    Future<Object?> fromNative(
      String method, [
      Map<String, Object?>? args,
    ]) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      ByteData? envelope;
      await messenger.handlePlatformMessage(
        'cometchat_voip',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (data) => envelope = data,
      );
      // Decoded out here, so an error envelope throws to the caller rather
      // than inside the reply callback where nothing would see it.
      if (envelope == null) return null;
      return const StandardMethodCodec().decodeEnvelope(envelope!);
    }

    test('init hands native the background entry point', () async {
      await CometChatVoip.init(autoConfig);
      final initialize = lastNativeCallTo('initialize');
      expect(initialize, isNotNull);
      // Non-null on a platform with a callback registry; the key is always sent.
      expect(initialize!.args.containsKey('backgroundCallbackHandle'), isTrue);
    });

    test('init announces this isolate can serve the ringer', () async {
      await CometChatVoip.init(autoConfig);
      expect(lastNativeCallTo('dartReady'), isNotNull);
    });

    test('it serves a decline, which is what a killed app needs', () async {
      await CometChatVoip.init(autoConfig);
      replies['endCall'] = callMap('session-b1', status: 'rejected');

      final served = await fromNative('calls.endCall', {
        'sessionId': 'session-b1',
        'status': 'rejected',
      });

      expect(served, isTrue);
      expect(lastCallTo('endCall')!.args['sessionId'], 'session-b1');
    });

    test('it serves an inject, which is what rings the call', () async {
      await CometChatVoip.init(autoConfig);
      replies['injectIncomingCall'] = callMap('session-b2');

      final served = await fromNative('calls.injectIncomingCall', {
        'payload': {'sessionId': 'session-b2', 'sender': 'alice'},
      });

      expect(served, isTrue);
      final injected = lastCallTo('injectIncomingCall');
      expect((injected!.args['payload'] as Map)['sessionId'], 'session-b2');
    });

    test(
      'an inject with no session is refused rather than guessed at',
      () async {
        await CometChatVoip.init(autoConfig);
        final served = await fromNative('calls.injectIncomingCall', {
          'payload': <String, Object?>{},
        });
        expect(served, isFalse);
        expect(lastCallTo('injectIncomingCall'), isNull);
      },
    );

    test('it serves the session state the ringer reads', () async {
      await CometChatVoip.init(autoConfig);
      replies['getActiveSession'] = {'sessionId': 'session-b3'};

      final state =
          await fromNative('calls.sessionState') as Map<Object?, Object?>;
      expect(state.containsKey('active'), isTrue);
      expect(state.containsKey('joined'), isTrue);
    });

    test('an unknown bridge method comes back notImplemented', () async {
      await CometChatVoip.init(autoConfig);
      // The handler throws MissingPluginException, which Flutter turns into a
      // notImplemented reply — an empty envelope, so null here. The native
      // side logs that and carries on rather than failing the ring.
      expect(await fromNative('calls.teleport'), isNull);
    });
  });

  group('our own CXProvider, with no native SDK', () {
    test('answer reaches the ringer, which stops the ring', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.answer('session-c1');
      expect(lastNativeCallTo('answer')!.args['sessionId'], 'session-c1');
    });

    test(
      'answer falls back to reporting it where there is no ringer',
      () async {
        await CometChatVoip.init(autoConfig);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(voipChannel, null);
        final answered = CometChatVoip.onCallAnswered.first;

        await CometChatVoip.answer('session-c2');

        expect((await answered).sessionId, 'session-c2');
      },
    );

    test('dismissRinging reaches the ringer', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.dismissRinging('session-c3', answered: true);
      expect(lastNativeCallTo('dismissRinging')!.args['answered'], isTrue);
    });

    test('reportOutgoingCall reaches CallKit again', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.reportOutgoingCall(
        sessionId: 'session-c4',
        calleeName: 'Alex',
        hasVideo: true,
      );
      expect(lastNativeCallTo('reportOutgoingCall')!.args['hasVideo'], isTrue);
    });

    test(
      'reportCallConnected pushes the session state and reports it',
      () async {
        await CometChatVoip.init(autoConfig);
        await CometChatVoip.reportCallConnected('session-c5');

        final state = lastNativeCallTo('setSessionState');
        expect(state!.args['joined'], isTrue);
        expect(state.args['sessionId'], 'session-c5');
        expect(lastNativeCallTo('reportCallConnected'), isNotNull);
      },
    );

    test(
      'reportCallEnded clears the state and ends the CallKit call',
      () async {
        await CometChatVoip.init(autoConfig);
        await CometChatVoip.reportCallEnded(
          'session-c6',
          reason: CometChatCallEndReason.declined,
        );

        expect(lastNativeCallTo('setSessionState')!.args['active'], isFalse);
        expect(lastNativeCallTo('reportCallEnded')!.args['reason'], 'declined');
      },
    );

    test('a mute made in the app is reported, so CallKit shows it', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.reportMuted(true);
      await CometChatVoip.reportVideoPaused(true);

      expect(lastNativeCallTo('setSessionMuted')!.args['muted'], isTrue);
      expect(lastNativeCallTo('setSessionVideoPaused')!.args['paused'], isTrue);
    });

    test("the Calls SDK's end is forwarded, so the ring stops", () async {
      await CometChatVoip.init(autoConfig);

      CometChatVoip.handleEndedForTesting(
        calls.InitiatedCall.fromMap(callMap('session-c7')),
        'cancelled',
      );
      await Future<void>.delayed(Duration.zero);

      final forwarded = lastNativeCallTo('sdkEndedCall');
      expect(forwarded, isNotNull);
      expect(forwarded!.args['sessionId'], 'session-c7');
      expect(forwarded.args['reason'], 'cancelled');
    });

    test('callKitAudio is off by default — on, the call would be silent', () {
      const config = CometChatVoipConfig(appId: 'APP', region: 'us');
      expect(config.callKitAudio, isFalse);
    });
  });

  group('the gaps against the native SDKs', () {
    /// Simulates the native ringer calling Dart.
    Future<Object?> fromNative(
      String method, [
      Map<String, Object?>? args,
    ]) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      ByteData? envelope;
      await messenger.handlePlatformMessage(
        'cometchat_voip',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (data) => envelope = data,
      );
      if (envelope == null) return null;
      return const StandardMethodCodec().decodeEnvelope(envelope!);
    }

    test('the CallKit audio handoff is forwarded to the Calls SDK', () async {
      await CometChatVoip.init(autoConfig);
      replies['notifyCallKitAudioActivated'] = null;

      final took = await fromNative('calls.callKitAudioActivated');

      expect(took, isTrue);
      expect(lastCallTo('notifyCallKitAudioActivated'), isNotNull);
    });

    test(
      'a Calls SDK without the handoff reports false, not silence',
      () async {
        await CometChatVoip.init(autoConfig);
        // An older SDK: the method is not implemented on its channel.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (methodCall) async {
              sdkCalls.add((
                method: methodCall.method,
                args:
                    (methodCall.arguments as Map?)?.cast<Object?, Object?>() ??
                    {},
              ));
              if (methodCall.method.startsWith('notifyCallKitAudio')) {
                throw MissingPluginException('too old');
              }
              return replies[methodCall.method];
            });

        // False is what stops `callKitAudio` being turned on, which is what
        // would make the call silent.
        expect(await fromNative('calls.callKitAudioActivated'), isFalse);
      },
    );

    test('deactivation is forwarded too', () async {
      await CometChatVoip.init(autoConfig);
      await fromNative('calls.callKitAudioDeactivated');
      expect(lastCallTo('notifyCallKitAudioDeactivated'), isNotNull);
    });

    test('callKitAudio is still off by default', () {
      const config = CometChatVoipConfig(appId: 'APP', region: 'us');
      expect(config.callKitAudio, isFalse);
    });
  });

  group('callKitAudio goes on only when the handoff is there', () {
    // The gate exists because the failure it prevents is invisible:
    // `setCallKitAudioEnabled(true)` makes WebRTC wait to be told the audio
    // session is live, and on an SDK without `notifyCallKitAudioActivated`
    // nothing can tell it — the call rings, connects, and nobody hears
    // anything, with no error raised anywhere.
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    const wantsCallKitAudio = CometChatVoipConfig(
      appId: 'APP',
      region: 'us',
      providerId: 'provider-1',
      callMode: CometChatCallMode.manual,
      callKitAudio: true,
    );

    test('an SDK that can take the session gets the flag', () async {
      replies['notifyCallKitAudioDeactivated'] = null;

      await CometChatVoip.init(wantsCallKitAudio);

      expect(lastCallTo('setCallKitAudioEnabled'), isNotNull);
      expect(
        lastNativeCallTo('setCallKitAudioHandoff')?.args['available'],
        isTrue,
        reason: 'getDiagnostics is where an integrator looks for this',
      );
    });

    test(
      'an SDK that cannot never gets the flag, so the call has sound',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (methodCall) async {
              sdkCalls.add((
                method: methodCall.method,
                args:
                    (methodCall.arguments as Map?)?.cast<Object?, Object?>() ??
                    {},
              ));
              if (methodCall.method.startsWith('notifyCallKitAudio')) {
                throw MissingPluginException('too old');
              }
              return replies[methodCall.method];
            });

        await CometChatVoip.init(wantsCallKitAudio);

        expect(
          lastCallTo('setCallKitAudioEnabled'),
          isNull,
          reason: 'the flag with no handoff is exactly the silent call',
        );
        expect(
          lastNativeCallTo('setCallKitAudioHandoff')?.args['available'],
          isFalse,
        );
      },
    );

    test('a config that never asked for it probes nothing', () async {
      await CometChatVoip.init(config);

      expect(lastCallTo('notifyCallKitAudioDeactivated'), isNull);
      expect(lastCallTo('setCallKitAudioEnabled'), isNull);
    });
  });

  test('init reports itself initialized, and dispose undoes it', () async {
    expect(CometChatVoip.isInitialized, isFalse);
    await CometChatVoip.init(config);
    expect(CometChatVoip.isInitialized, isTrue);
    expect(CometChatVoip.config?.appId, 'APP');
    await CometChatVoip.dispose();
    expect(CometChatVoip.isInitialized, isFalse);
  });

  /// Each of these rang true on a read of the code and passed the whole suite
  /// before it was fixed, so each one is pinned here.
  group('regressions', () {
    /// `markTerminal` is sent without being awaited, so let its invocation
    /// reach the mock handler before the order is read.
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    int firstIndexOf(String method) =>
        nativeCalls.indexWhere((c) => c.method == method);

    test('AUTO: the ringer is told to decline before the session is marked '
        'terminal', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.decline('session-order');
      await settle();

      final decline = firstIndexOf('decline');
      final marked = firstIndexOf('markTerminal');
      expect(decline, isNonNegative, reason: 'the ringer was never told');
      expect(marked, isNonNegative, reason: 'the session was never marked');
      // Marked first, the ringer reads the session as an already-handled
      // double tap and returns without sending the endCall, leaving the
      // caller ringing at nobody.
      expect(
        decline,
        lessThan(marked),
        reason: 'markTerminal overtook decline',
      );
    });

    test('AUTO: a busy decline reaches the ringer as busy', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.decline('session-busy', busy: true);

      expect(lastNativeCallTo('decline')!.args['busy'], isTrue);
    });

    test('AUTO: an ordinary decline is not busy', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.decline('session-plain');

      expect(lastNativeCallTo('decline')!.args['busy'], isFalse);
    });

    test('init never writes a null uid, which the ringer reads as a logout '
        'and ends the ringing call on', () async {
      await CometChatVoip.init(config);
      await settle();

      final uids = nativeCalls
          .where((c) => c.method == 'setLoggedInUid')
          .map((c) => c.args['uid'])
          .toList();
      expect(uids, everyElement(isNotNull));
    });

    test('init asks for notification permission, which Android 13+ needs '
        'before a call can ring', () async {
      await CometChatVoip.init(config);
      await settle();

      expect(lastNativeCallTo('requestNotificationPermission'), isNotNull);
    });

    test('a config that turns it off is not asked', () async {
      await CometChatVoip.init(
        const CometChatVoipConfig(
          appId: 'APP',
          region: 'us',
          providerId: 'provider-1',
          callMode: CometChatCallMode.manual,
          requestNotificationPermission: false,
        ),
      );
      await settle();

      expect(lastNativeCallTo('requestNotificationPermission'), isNull);
    });

    test('an action this build does not know neither rings nor silences the '
        'call', () async {
      await CometChatVoip.init(config);

      final handled = await CometChatVoip.handlePushNotification({
        'type': 'call',
        'callAction': 'teleported',
        'sessionId': 'session-unknown',
        'sentAt': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      });

      // Handled, so the app does not also treat it as a chat push, but the
      // ring is neither started nor ended — what the native ringer does.
      expect(handled, isTrue);
      expect(lastCallTo('injectIncomingCall'), isNull);
      expect(lastCallTo('injectIncomingCallEnded'), isNull);
    });
  });

  group("the app's own ring screen", () {
    /// Pushes one event down the native event channel.
    Future<void> emit(Map<String, Object?> event) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'cometchat_voip/events',
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
    }

    CometChatVoipCall videoCall(String sessionId) => CometChatVoipCall(
      sessionId: sessionId,
      callerName: 'Alex',
      callType: CometChatVoipCall.typeVideo,
      receiverType: CometChatVoipCall.receiverTypeUser,
      initiatedAt: DateTime.now(),
      ringTimeout: const Duration(seconds: 45),
    );

    test('the ringer opening the app reaches onRingScreenRequested', () async {
      await CometChatVoip.init(customScreenConfig);
      final request = CometChatVoip.onRingScreenRequested.first;

      await emit({
        'event': 'ringScreen',
        'call': {'sessionId': 'session-r1', 'callerName': 'Alex'},
        'endsActiveCall': false,
      });

      final received = await request;
      expect(received.call.sessionId, 'session-r1');
      expect(received.answerEndsActiveCall, isFalse);
    });

    test('a ring over a live call says answering ends it', () async {
      await CometChatVoip.init(customScreenConfig);
      final request = CometChatVoip.onRingScreenRequested.first;

      await emit({
        'event': 'ringScreen',
        'call': {'sessionId': 'session-r2', 'callerName': 'Alex'},
        'endsActiveCall': true,
      });

      expect((await request).answerEndsActiveCall, isTrue);
    });

    test('a request that arrived before anything listened is still '
        'delivered', () async {
      await CometChatVoip.init(customScreenConfig);

      // The full-screen alert on a cold start: the screen subscribes after
      // the engine is up, which is after the ringer has already asked.
      await emit({
        'event': 'ringScreen',
        'call': {'sessionId': 'session-r3', 'callerName': 'Alex'},
      });
      await pumpEventQueue();

      final received = await CometChatVoip.onRingScreenRequested.first;
      expect(received.call.sessionId, 'session-r3');
    });

    test('permissionsToAnswer reports what the ringer found missing', () async {
      await CometChatVoip.init(customScreenConfig);
      nativeReplies['permissionsToAnswer'] = <String>['microphone', 'camera'];

      final missing = await CometChatVoip.permissionsToAnswer(
        videoCall('session-r4'),
      );

      expect(missing, [
        CometChatCallPermission.microphone,
        CometChatCallPermission.camera,
      ]);
      expect(
        (lastNativeCallTo('permissionsToAnswer')!.args['call']
            as Map)['sessionId'],
        'session-r4',
      );
    });

    test(
      'a permission this version does not know is dropped, not thrown',
      () async {
        await CometChatVoip.init(customScreenConfig);
        nativeReplies['permissionsToAnswer'] = <String>[
          'microphone',
          'telepathy',
        ];

        expect(
          await CometChatVoip.permissionsToAnswer(videoCall('session-r5')),
          [CometChatCallPermission.microphone],
        );
      },
    );

    test(
      'requestCallPermissions asks the ringer and reports the grant',
      () async {
        await CometChatVoip.init(customScreenConfig);
        nativeReplies['requestCallPermissions'] = true;

        expect(
          await CometChatVoip.requestCallPermissions(videoCall('session-r6')),
          isTrue,
        );
        expect(lastNativeCallTo('requestCallPermissions'), isNotNull);
      },
    );

    test(
      'a platform with no ringer reports nothing missing and grants',
      () async {
        await CometChatVoip.init(customScreenConfig);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(voipChannel, null);

        expect(
          await CometChatVoip.permissionsToAnswer(videoCall('session-r7')),
          isEmpty,
        );
        expect(
          await CometChatVoip.requestCallPermissions(videoCall('session-r7')),
          isTrue,
        );
      },
    );
  });

  group('answering a second call', () {
    Future<void> emit(Map<String, Object?> event) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'cometchat_voip/events',
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
    }

    test(
      'ends the live call first — the Calls SDK holds one session',
      () async {
        await CometChatVoip.init(autoConfig);
        await CometChatVoip.reportCallConnected('session-live');
        final answered = CometChatVoip.onCallAnswered.first;

        await emit({
          'event': 'answered',
          'call': {'sessionId': 'session-second', 'callerName': 'Alex'},
        });

        // The answer still arrives — the user tapped Answer — but only after
        // the live call is gone, so the two never race for the session.
        expect((await answered).sessionId, 'session-second');
        final ended = lastNativeCallTo('reportCallEnded');
        expect(ended!.args['sessionId'], 'session-live');
        final state = lastNativeCallTo('setSessionState');
        expect(state!.args['joined'], isFalse);
        // Named: without an id the ringer ends the call it tracks, which by
        // now is the one just answered (iOS: "The session has ended.").
        expect(state.args['sessionId'], 'session-live');
      },
    );

    test(
      'a second time too: a join without an id keeps the live call',
      () async {
        // The call joined by the first "End & accept" rang over a live one, so
        // it was never prepared, and the Calls SDK reports its join with no id.
        // That join used to forget the live call, so the second "End & accept"
        // left nothing and joined on top of it.
        await CometChatVoip.init(autoConfig);
        await CometChatVoip.reportCallConnected('session-b');
        await CometChatVoip.sessionChangedForTesting(
          active: true,
          joined: true,
        );
        final answered = CometChatVoip.onCallAnswered.first;

        await emit({
          'event': 'answered',
          'call': {'sessionId': 'session-c', 'callerName': 'Alex'},
        });

        expect((await answered).sessionId, 'session-c');
        expect(
          lastNativeCallTo('reportCallEnded')!.args['sessionId'],
          'session-b',
        );
      },
    );

    test('a call the app ends is named to the ringer', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.reportCallEnded('session-x');

      final state = lastNativeCallTo('setSessionState');
      expect(state!.args['active'], isFalse);
      expect(state.args['sessionId'], 'session-x');
    });

    test('the same answer twice is answered once', () async {
      // The ringer sends the answer that opened the app to that engine as
      // well as process-wide, because on a killed app the process-wide one is
      // taken by the isolate that handled the push and joins nothing. An app
      // that was merely in the background gets both.
      await CometChatVoip.init(autoConfig);
      final answers = <CometChatVoipCall>[];
      final sub = CometChatVoip.onCallAnswered.listen(answers.add);

      const event = {
        'event': 'answered',
        'call': {'sessionId': 'session-twice', 'callerName': 'Alex'},
      };
      await emit(event);
      await emit(event);
      await pumpEventQueue();

      expect(answers.map((c) => c.sessionId), ['session-twice']);
      // And the call is marked answered with CometChat once, not twice.
      expect(
        requests.where((r) => r.method == 'PUT').length,
        lessThanOrEqualTo(1),
      );
      await sub.cancel();
    });

    test('the first answer ends nothing', () async {
      await CometChatVoip.init(autoConfig);
      final answered = CometChatVoip.onCallAnswered.first;

      await emit({
        'event': 'answered',
        'call': {'sessionId': 'session-only', 'callerName': 'Alex'},
      });

      expect((await answered).sessionId, 'session-only');
      expect(lastNativeCallTo('reportCallEnded'), isNull);
    });

    test('answering the call that is already live ends nothing', () async {
      await CometChatVoip.init(autoConfig);
      await CometChatVoip.reportCallConnected('session-same');
      final answered = CometChatVoip.onCallAnswered.first;

      await emit({
        'event': 'answered',
        'call': {'sessionId': 'session-same', 'callerName': 'Alex'},
      });

      expect((await answered).sessionId, 'session-same');
      expect(lastNativeCallTo('reportCallEnded'), isNull);
    });
  });
}
