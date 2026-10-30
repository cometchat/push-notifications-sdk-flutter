import 'dart:async';
import 'dart:convert';

import '../token/push_token_client.dart';

/// Tells CometChat a ringing call was answered on this device.
///
/// In the Calls SDK 5.1 ringing flow joining the session is the answer, and
/// nothing else needs sending. A caller still on the Chat SDK's calling — a
/// UI Kit, web or React app — works differently: it waits for the call's
/// status to become `ongoing`, which the Chat SDK's `acceptCall` sets, before
/// it joins. Without it that caller rings on while the answerer sits alone in
/// the session. This sets the status the same way, with the Calls SDK's auth
/// token, so the caller joins whichever flow it is on.
///
///     PUT https://{appId}.apiclient-{region}.cometchat.io/v3.0/calls/{sessionId}
///     {"status": "ongoing"}
class CallAcceptClient {
  /// Creates a [CallAcceptClient]. [transport] defaults to `dart:io`.
  CallAcceptClient({PushTokenTransport? transport})
    : _transport = transport ?? PushTokenClient.httpTransport;

  final PushTokenTransport _transport;

  /// The status the Chat SDK's `acceptCall` sets.
  static const acceptedStatus = 'ongoing';

  /// The call's endpoint.
  static Uri endpoint(
    String appId,
    String region,
    String sessionId, {
    String? clientHost,
  }) => Uri.parse(
    '${PushTokenClient.apiBase(appId, region, clientHost: clientHost)}'
    '/calls/${Uri.encodeComponent(sessionId)}',
  );

  /// Marks [sessionId] answered. Returns the HTTP status and body; never
  /// throws, because a caller on the ringing flow does not need this and the
  /// answer must go ahead either way.
  Future<(int, String)> accept({
    required String appId,
    required String region,
    required String authToken,
    required String sessionId,
    String? clientHost,
  }) async {
    try {
      return await _transport(
        'PUT',
        endpoint(appId, region, sessionId, clientHost: clientHost),
        {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'appId': appId,
          'authToken': authToken,
          'chatApiVersion': PushTokenClient.chatApiVersion,
        },
        jsonEncode({'status': acceptedStatus}),
      );
    } catch (e) {
      return (0, '$e');
    }
  }
}
