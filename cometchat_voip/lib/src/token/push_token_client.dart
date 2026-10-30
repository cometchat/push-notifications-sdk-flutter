import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors/cometchat_voip_exception.dart';

/// Where a push token comes from, which decides the platform it is registered
/// under and the body field that carries it.
enum PushTokenKind {
  /// The PushKit token on iOS. Calls ring through it.
  apnsVoip('apns_flutter_voip', 'voipToken'),

  /// The FCM token on Android. Call pushes arrive as FCM data messages.
  fcmAndroid('fcm_flutter_android', 'fcmToken');

  const PushTokenKind(this.platform, this.bodyField);

  /// The backend's `platform` value — the one the Chat SDK's `PushPlatforms`
  /// sends for the same token.
  final String platform;

  /// The body field the token goes in.
  final String bodyField;
}

/// One registration or unregistration.
class PushTokenRequest {
  /// The CometChat app ID.
  final String appId;

  /// The CometChat region.
  final String region;

  /// The logged-in user's auth token.
  final String authToken;

  /// The push token.
  final String token;

  /// What [token] is.
  final PushTokenKind kind;

  /// The dashboard's push provider ID.
  final String? providerId;

  /// The device's IANA time zone, which the backend uses for quiet hours.
  final String? timezone;

  /// A host replacing `{appId}.apiclient-{region}.cometchat.io/v3.0`.
  final String? clientHost;

  /// Creates a [PushTokenRequest].
  const PushTokenRequest({
    required this.appId,
    required this.region,
    required this.authToken,
    required this.token,
    required this.kind,
    this.providerId,
    this.timezone,
    this.clientHost,
  });
}

/// Sends one HTTP request and returns the status code and body. Swapped out in
/// tests.
typedef PushTokenTransport =
    Future<(int, String)> Function(
      String method,
      Uri url,
      Map<String, String> headers,
      String body,
    );

/// Registers push tokens with CometChat directly.
///
/// The Chat SDK's registration needs a Chat SDK login, which a calls-only app
/// does not have. This speaks the same endpoint with the Calls SDK's auth
/// token instead, so calls ring whichever SDK the user logged in to.
///
///     POST/DELETE https://{appId}.apiclient-{region}.cometchat.io/v3.0/notifications/push/v1/tokens
class PushTokenClient {
  /// Creates a [PushTokenClient]. [transport] defaults to `dart:io`.
  PushTokenClient({PushTokenTransport? transport})
    : _transport = transport ?? _httpTransport;

  final PushTokenTransport _transport;

  /// The backend refuses every request without it, before it even looks at
  /// the auth token. `v3.0` is what both the Chat and Calls SDKs report.
  static const chatApiVersion = 'v3.0';

  /// The ringing flow this package speaks, sent with every token so the
  /// backend knows which flow to drive the device with. 2.0 is the Ringing
  /// Flow v2 package — the Calls SDK owns the signalling and the callee
  /// prepares the session while it rings — so it is always `v2`, as in the
  /// native Android and iOS SDKs.
  static const ringingFlowVersion = 'v2';

  /// The REST API base for [appId] in [region], or [clientHost].
  static String apiBase(String appId, String region, {String? clientHost}) {
    final host = clientHost?.trim().replaceAll(RegExp(r'/+$'), '');
    return host == null || host.isEmpty
        ? 'https://$appId.apiclient-$region.cometchat.io/v3.0'
        : (host.contains('://') ? host : 'https://$host');
  }

  /// The token endpoint for [appId] in [region], or under [clientHost].
  static Uri endpoint(String appId, String region, {String? clientHost}) =>
      Uri.parse(
        '${apiBase(appId, region, clientHost: clientHost)}'
        '/notifications/push/v1/tokens',
      );

  /// Sends a request over `dart:io`.
  static const PushTokenTransport httpTransport = _httpTransport;

  /// The request headers.
  static Map<String, String> headers(PushTokenRequest request) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'appId': request.appId,
    'authToken': request.authToken,
    'chatApiVersion': chatApiVersion,
  };

  /// The request body.
  ///
  /// `timezone` is always sent, as the native SDKs always send it: the
  /// device's IANA zone when the request has one, otherwise [fallbackTimeZone].
  static Map<String, Object> body(PushTokenRequest request) => {
    request.kind.bodyField: request.token,
    'platform': request.kind.platform,
    'timezone': _nonEmpty(request.timezone) ?? fallbackTimeZone(),
    'providerId': ?_nonEmpty(request.providerId),
    'ringingFlowVersion': ringingFlowVersion,
  };

  /// A time zone for when the device could not name its own.
  ///
  /// Dart reads only the UTC offset, not the IANA name, so this is the
  /// fixed-offset zone for a whole-hour offset — `Etc/GMT-1` for UTC+1, the
  /// sign inverted as POSIX names it — and `UTC` for anything else (UTC+5:30
  /// has no fixed-offset zone). It ignores daylight saving; the native
  /// plugins answer with the real zone, so this is the last resort.
  static String fallbackTimeZone([Duration? offset]) {
    final minutes = (offset ?? DateTime.now().timeZoneOffset).inMinutes;
    if (minutes == 0 || minutes % 60 != 0) return 'UTC';
    final hours = minutes ~/ 60;
    if (hours < -12 || hours > 14) return 'UTC';
    return hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  /// Registers the token in [request].
  Future<void> register(PushTokenRequest request) => _send('POST', request);

  /// Unregisters the token in [request].
  Future<void> unregister(PushTokenRequest request) => _send('DELETE', request);

  Future<void> _send(String method, PushTokenRequest request) async {
    final url = endpoint(
      request.appId,
      request.region,
      clientHost: request.clientHost,
    );
    final int status;
    final String response;
    try {
      (status, response) = await _transport(
        method,
        url,
        headers(request),
        jsonEncode(body(request)),
      );
    } catch (e) {
      throw CometChatVoipException(
        code: CometChatVoipErrorCode.networkError,
        message: '$method ${request.kind.platform} token failed: $e',
        cause: e,
      );
    }
    if (status < 200 || status >= 300) {
      final detail = response.length > 500
          ? response.substring(0, 500)
          : response;
      throw CometChatVoipException(
        code: CometChatVoipErrorCode.tokenRegistrationFailed,
        message:
            'HTTP $status from the push token endpoint for '
            '${request.kind.platform}'
            '${request.providerId == null ? '' : " (provider '${request.providerId}')"}'
            '${detail.isEmpty ? '' : ': $detail'}',
      );
    }
  }

  /// A token described without being revealed: enough to tell a rotated one
  /// from the same one in a log, and nothing a reader could use.
  static String describe(String token) =>
      'len=${token.length} prefix=${token.length > 6 ? token.substring(0, 6) : token}…';
}

Future<(int, String)> _httpTransport(
  String method,
  Uri url,
  Map<String, String> headers,
  String body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.openUrl(method, url);
    headers.forEach(
      (name, value) =>
          request.headers.set(name, value, preserveHeaderCase: true),
    );
    request.add(utf8.encode(body));
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await response.transform(utf8.decoder).join();
    return (response.statusCode, text);
  } finally {
    client.close(force: true);
  }
}
