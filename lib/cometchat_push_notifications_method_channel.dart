import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cometchat_push_notifications_platform_interface.dart';

/// An implementation of [CometchatPushNotificationsPlatform] that uses method channels.
class MethodChannelCometchatPushNotifications
    extends CometchatPushNotificationsPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('cometchat_push_notifications');

  void Function(Map<String, dynamic>)? _incomingCallLaunchHandler;
  void Function(String)? _declineCallHandler;
  bool _callbackHandlerSet = false;

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Future<bool> showCallNotification({
    required String callId,
    required String callerName,
    required bool isVideo,
    String? callerAvatar,
  }) async {
    final result = await methodChannel
        .invokeMethod<bool>('showCallNotification', {
          'callId': callId,
          'callerName': callerName,
          'isVideo': isVideo,
          'callerAvatar': callerAvatar,
        });
    return result ?? false;
  }

  @override
  Future<bool> cancelCallNotification(String callId) async {
    final result = await methodChannel.invokeMethod<bool>(
      'cancelCallNotification',
      {'callId': callId},
    );
    return result ?? false;
  }

  @override
  Future<bool> dismissIncomingCallActivity() async {
    final result = await methodChannel.invokeMethod<bool>(
      'dismissIncomingCallActivity',
    );
    return result ?? false;
  }

  @override
  Future<Map<String, dynamic>?> getLaunchCallDetails() async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'getLaunchCallDetails',
    );
    return result;
  }

  @override
  void setIncomingCallLaunchHandler(
    void Function(Map<String, dynamic> details) handler,
  ) {
    _incomingCallLaunchHandler = handler;
    _ensureMethodCallHandlerSet();
  }

  @override
  void setDeclineCallHandler(void Function(String sessionId) handler) {
    _declineCallHandler = handler;
    _ensureMethodCallHandlerSet();
  }

  @override
  Future<Map<String, bool>> checkCallPermissions() async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
      'checkCallPermissions',
    );
    if (result == null) return const {};
    return result.map((k, v) => MapEntry(k, v as bool));
  }

  @override
  Future<bool> openAutoStartSettings() async {
    final result = await methodChannel.invokeMethod<bool>(
      'openAutoStartSettings',
    );
    return result ?? false;
  }

  @override
  Future<bool> openFullScreenIntentSettings() async {
    final result = await methodChannel.invokeMethod<bool>(
      'openFullScreenIntentSettings',
    );
    return result ?? false;
  }

  @override
  Future<bool> openOverlaySettings() async {
    final result = await methodChannel.invokeMethod<bool>(
      'openOverlaySettings',
    );
    return result ?? false;
  }

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    final result = await methodChannel.invokeMethod<bool>(
      'openBatteryOptimizationSettings',
    );
    return result ?? false;
  }

  void _ensureMethodCallHandlerSet() {
    if (_callbackHandlerSet) return;
    _callbackHandlerSet = true;
    methodChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onIncomingCallLaunch':
          final args = call.arguments;
          if (args is Map) {
            _incomingCallLaunchHandler?.call(args.cast<String, dynamic>());
          }
        case 'onDeclineCall':
          final args = call.arguments;
          if (args is Map) {
            final sessionId = args['sessionId'] as String?;
            if (sessionId != null) {
              _declineCallHandler?.call(sessionId);
            }
          }
      }
    });
  }
}
