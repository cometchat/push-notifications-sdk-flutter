import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cometchat_voip_platform_interface.dart';
import 'src/models/cometchat_voip_call.dart';
import 'src/models/cometchat_voip_config.dart';
import 'src/models/cometchat_voip_enums.dart';

/// The default implementation, over a method channel and an event channel.
class MethodChannelCometchatVoip extends CometchatVoipPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('cometchat_voip');

  /// The event channel carrying answered calls, ended calls and token changes.
  @visibleForTesting
  final eventChannel = const EventChannel('cometchat_voip/events');

  Stream<Map<Object?, Object?>>? _events;

  @override
  Future<void> initialize(
    CometChatVoipConfig config, {
    int? backgroundCallbackHandle,
  }) => methodChannel.invokeMethod<void>('initialize', {
    ...config.toMap(),
    'backgroundCallbackHandle': backgroundCallbackHandle,
  });

  @override
  Future<bool> handlePushNotification(
    Map<String, String> data, {
    int? sentTimeMs,
  }) async =>
      await methodChannel.invokeMethod<bool>('handlePushNotification', {
        'data': data,
        'sentTimeMs': sentTimeMs,
      }) ??
      false;

  @override
  Future<String?> getVoipToken() =>
      methodChannel.invokeMethod<String>('getVoipToken');

  @override
  Future<String?> getTimeZone() =>
      methodChannel.invokeMethod<String>('getTimeZone');

  @override
  Future<void> answer(String sessionId) =>
      methodChannel.invokeMethod<void>('answer', {'sessionId': sessionId});

  @override
  Future<List<CometChatCallPermission>> permissionsToAnswer(
    CometChatVoipCall call,
  ) async {
    final missing = await methodChannel.invokeListMethod<String>(
      'permissionsToAnswer',
      {'call': call.toMap()},
    );
    return [
      for (final name in missing ?? const <String>[])
        ?CometChatCallPermission.fromWire(name),
    ];
  }

  @override
  Future<bool> requestCallPermissions(CometChatVoipCall call) async =>
      await methodChannel.invokeMethod<bool>('requestCallPermissions', {
        'call': call.toMap(),
      }) ??
      false;

  @override
  Future<void> decline(String sessionId, {bool busy = false}) => methodChannel
      .invokeMethod<void>('decline', {'sessionId': sessionId, 'busy': busy});

  @override
  Future<void> dismissRinging(String sessionId, {required bool answered}) =>
      methodChannel.invokeMethod<void>('dismissRinging', {
        'sessionId': sessionId,
        'answered': answered,
      });

  @override
  Future<CometChatVoipCall?> getActiveCall() async {
    final map = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getActiveCall',
    );
    return map == null ? null : CometChatVoipCall.fromMap(map);
  }

  @override
  Future<void> reportOutgoingCall({
    required String sessionId,
    required String calleeName,
    required bool hasVideo,
  }) => methodChannel.invokeMethod<void>('reportOutgoingCall', {
    'sessionId': sessionId,
    'calleeName': calleeName,
    'hasVideo': hasVideo,
  });

  @override
  Future<void> reportRemoteParticipant({String? uid, String? name}) =>
      methodChannel.invokeMethod<void>('reportRemoteParticipant', {
        'uid': uid,
        'name': name,
      });

  @override
  Future<void> reportCallConnected(String sessionId) => methodChannel
      .invokeMethod<void>('reportCallConnected', {'sessionId': sessionId});

  @override
  Future<void> reportCallEnded(
    String sessionId, {
    CometChatCallEndReason reason = CometChatCallEndReason.remoteEnded,
  }) => methodChannel.invokeMethod<void>('reportCallEnded', {
    'sessionId': sessionId,
    'reason': reason.wireName,
  });

  @override
  Future<CometChatRingReadiness> checkRingReadiness() async =>
      CometChatRingReadiness.fromWire(
        await methodChannel.invokeMethod<String>('checkRingReadiness'),
      );

  @override
  Future<bool> openSettings(CometChatRingReadiness readiness) async =>
      await methodChannel.invokeMethod<bool>('openSettings', {
        'readiness': readiness.wireName,
      }) ??
      false;

  @override
  Future<bool> requestNotificationPermission() async =>
      await methodChannel.invokeMethod<bool>('requestNotificationPermission') ??
      false;

  @override
  Future<String> verifyPushSetup() async =>
      await methodChannel.invokeMethod<String>('verifyPushSetup') ?? 'unknown';

  @override
  Future<Map<String, Object?>> lastWakeTiming() async =>
      await methodChannel.invokeMapMethod<String, Object?>('lastWakeTiming') ??
      const {};

  @override
  Future<void> showIncomingNotification(CometChatVoipCall call) =>
      methodChannel.invokeMethod<void>('ringSurface.showIncomingNotification', {
        'call': call.toMap(),
      });

  @override
  Future<void> stopRinging(String sessionId) => methodChannel
      .invokeMethod<void>('ringSurface.stopRinging', {'sessionId': sessionId});

  @override
  Future<void> verifyCall(CometChatVoipCall call) => methodChannel
      .invokeMethod<void>('ringSurface.verify', {'call': call.toMap()});

  @override
  Future<void> keepAlive(CometChatVoipCall call) => methodChannel
      .invokeMethod<void>('ringSurface.keepAlive', {'call': call.toMap()});

  @override
  Future<void> showMissedCall(CometChatVoipCall call) => methodChannel
      .invokeMethod<void>('ringSurface.showMissedCall', {'call': call.toMap()});

  @override
  Future<void> markTerminal(String sessionId, String reason) =>
      methodChannel.invokeMethod<void>('markTerminal', {
        'sessionId': sessionId,
        'reason': reason,
      });

  @override
  Future<bool> wasTerminal(String sessionId) async =>
      await methodChannel.invokeMethod<bool>('wasTerminal', {
        'sessionId': sessionId,
      }) ??
      false;

  @override
  Future<String?> terminalReason(String sessionId) => methodChannel
      .invokeMethod<String>('terminalReason', {'sessionId': sessionId});

  @override
  MethodChannel get bridgeChannel => methodChannel;

  @override
  Future<void> setSessionState({
    required bool active,
    required bool joined,
    String? sessionId,
  }) => methodChannel.invokeMethod<void>('setSessionState', {
    'active': active,
    'joined': joined,
    'sessionId': sessionId,
  });

  @override
  Future<void> setSessionMuted(bool muted) =>
      methodChannel.invokeMethod<void>('setSessionMuted', {'muted': muted});

  @override
  Future<void> setSessionVideoPaused(bool paused) => methodChannel
      .invokeMethod<void>('setSessionVideoPaused', {'paused': paused});

  @override
  Future<void> sdkEndedCall(String sessionId, String reason) =>
      methodChannel.invokeMethod<void>('sdkEndedCall', {
        'sessionId': sessionId,
        'reason': reason,
      });

  @override
  Future<void> setCallKitAudioHandoff(bool available) => methodChannel
      .invokeMethod<void>('setCallKitAudioHandoff', {'available': available});

  @override
  Future<void> setIncomingCallTheme(Map<String, Object?>? theme) =>
      methodChannel.invokeMethod<void>('setIncomingCallTheme', theme);

  @override
  Future<void> setLoggedInUid(String? uid) =>
      methodChannel.invokeMethod<void>('setLoggedInUid', {'uid': uid});

  @override
  Future<void> enqueueDecline(String sessionId, String status) =>
      methodChannel.invokeMethod<void>('enqueueDecline', {
        'sessionId': sessionId,
        'status': status,
      });

  @override
  Future<Map<String, Object?>> getDiagnostics() async =>
      await methodChannel.invokeMapMethod<String, Object?>('getDiagnostics') ??
      const {};

  @override
  Stream<Map<Object?, Object?>> get events => _events ??= eventChannel
      .receiveBroadcastStream()
      .map((event) => (event as Map).cast<Object?, Object?>());
}
