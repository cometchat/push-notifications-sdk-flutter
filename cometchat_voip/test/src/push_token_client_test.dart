import 'dart:convert';

import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:cometchat_voip/src/token/push_token_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const request = PushTokenRequest(
    appId: 'app',
    region: 'us',
    authToken: 'auth',
    token: 'abcdef123456',
    kind: PushTokenKind.apnsVoip,
    providerId: 'provider',
    timezone: 'Asia/Kolkata',
  );

  test('the endpoint is the per-app, per-region host', () {
    expect(
      PushTokenClient.endpoint('app', 'eu').toString(),
      'https://app.apiclient-eu.cometchat.io/v3.0/notifications/push/v1/tokens',
    );
  });

  test('a client host replaces the whole base, with or without a scheme', () {
    expect(
      PushTokenClient.endpoint(
        'app',
        'eu',
        clientHost: 'app.apiclient-eu.example.com/v3.0/',
      ).toString(),
      'https://app.apiclient-eu.example.com/v3.0/notifications/push/v1/tokens',
    );
    expect(
      PushTokenClient.endpoint(
        'app',
        'eu',
        clientHost: 'http://localhost:8080',
      ).toString(),
      'http://localhost:8080/notifications/push/v1/tokens',
    );
  });

  test('every request carries the chat API version', () {
    // Without it the backend refuses the request before reading the token.
    expect(PushTokenClient.headers(request)['chatApiVersion'], 'v3.0');
    expect(PushTokenClient.headers(request)['authToken'], 'auth');
  });

  test('a VoIP token goes in voipToken, under the Flutter VoIP platform', () {
    expect(PushTokenClient.body(request), {
      'voipToken': 'abcdef123456',
      'platform': 'apns_flutter_voip',
      'timezone': 'Asia/Kolkata',
      'providerId': 'provider',
      'ringingFlowVersion': 'v2',
    });
  });

  test('an FCM token goes in fcmToken, and an empty provider is left out', () {
    const fcm = PushTokenRequest(
      appId: 'app',
      region: 'us',
      authToken: 'auth',
      token: 'fcm',
      kind: PushTokenKind.fcmAndroid,
      providerId: '',
    );
    expect(PushTokenClient.body(fcm), {
      'fcmToken': 'fcm',
      'platform': 'fcm_flutter_android',
      // Always sent, as the native SDKs send it.
      'timezone': PushTokenClient.fallbackTimeZone(),
      'ringingFlowVersion': 'v2',
    });
  });

  test('every body declares the v2 ringing flow', () {
    expect(PushTokenClient.body(request)['ringingFlowVersion'], 'v2');
  });

  test('the fallback time zone is a fixed-offset zone, or UTC', () {
    // POSIX inverts the sign: Etc/GMT-1 is UTC+1.
    expect(
      PushTokenClient.fallbackTimeZone(const Duration(hours: 1)),
      'Etc/GMT-1',
    );
    expect(
      PushTokenClient.fallbackTimeZone(const Duration(hours: -5)),
      'Etc/GMT+5',
    );
    expect(PushTokenClient.fallbackTimeZone(Duration.zero), 'UTC');
    // No fixed-offset zone for a half hour.
    expect(
      PushTokenClient.fallbackTimeZone(const Duration(hours: 5, minutes: 30)),
      'UTC',
    );
  });

  test('register posts and unregister deletes the same body', () async {
    final sent = <(String, Uri, String)>[];
    final client = PushTokenClient(
      transport: (method, url, headers, body) async {
        sent.add((method, url, body));
        return (200, '{}');
      },
    );

    await client.register(request);
    await client.unregister(request);

    expect(sent.map((s) => s.$1), ['POST', 'DELETE']);
    expect(jsonDecode(sent.first.$3), PushTokenClient.body(request));
  });

  test('a refusal says what the server said', () async {
    final client = PushTokenClient(
      transport: (method, url, headers, body) async =>
          (400, '{"error":"invalid provider"}'),
    );

    await expectLater(
      client.register(request),
      throwsA(
        isA<CometChatVoipException>()
            .having(
              (e) => e.code,
              'code',
              CometChatVoipErrorCode.tokenRegistrationFailed,
            )
            .having((e) => e.message, 'message', contains('invalid provider')),
      ),
    );
  });

  test('an unreachable server is a network error', () async {
    final client = PushTokenClient(
      transport: (method, url, headers, body) async =>
          throw Exception('no route to host'),
    );

    await expectLater(
      client.register(request),
      throwsA(
        isA<CometChatVoipException>().having(
          (e) => e.code,
          'code',
          CometChatVoipErrorCode.networkError,
        ),
      ),
    );
  });

  test('a token is described without being revealed', () {
    expect(PushTokenClient.describe('abcdef123456'), 'len=12 prefix=abcdef…');
  });
}
