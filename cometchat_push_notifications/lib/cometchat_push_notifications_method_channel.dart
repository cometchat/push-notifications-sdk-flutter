import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cometchat_push_notifications_platform_interface.dart';
import 'src/models/cometchat_notification_config.dart';
import 'src/models/cometchat_notification_details.dart';
import 'src/models/cometchat_notification_response.dart';

/// The default implementation, over a method channel and an event channel.
class MethodChannelCometchatPushNotifications
    extends CometchatPushNotificationsPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('cometchat_push_notifications');

  /// The event channel carrying notification taps.
  @visibleForTesting
  final eventChannel = const EventChannel(
    'cometchat_push_notifications/responses',
  );

  StreamController<CometChatNotificationResponse>? _taps;

  /// Taps that arrived before anything was listening — a cold start always
  /// produces one before the app is ready for it.
  final List<CometChatNotificationResponse> _backlog = [];

  @override
  Future<String?> getPlatformVersion() =>
      methodChannel.invokeMethod<String>('getPlatformVersion');

  @override
  Future<void> initialize(CometChatNotificationConfig config) =>
      methodChannel.invokeMethod<void>('initialize', config.toMap());

  @override
  Future<bool> requestPermission() async =>
      await methodChannel.invokeMethod<bool>('requestPermission') ?? false;

  @override
  Future<bool> isPermissionGranted() async =>
      await methodChannel.invokeMethod<bool>('isPermissionGranted') ?? false;

  @override
  Future<String?> getApnsToken() =>
      methodChannel.invokeMethod<String>('getApnsToken');

  @override
  Future<void> showNotification(CometChatNotificationDetails details) =>
      methodChannel.invokeMethod<void>('showNotification', {
        'title': details.title,
        'body': details.body,
        'sender': details.sender,
        'senderName': details.senderName,
        'senderAvatar': details.senderAvatar,
        'receiver': details.receiver,
        'receiverName': details.receiverName,
        'receiverType': details.receiverType.name,
        'conversationId': details.conversationId,
        'messageId': details.tag,
        'sentAt': details.sentAt,
      });

  @override
  Future<void> cancelNotifications({String? conversationId}) =>
      methodChannel.invokeMethod<void>('cancelNotifications', {
        'conversationId': conversationId,
      });

  @override
  Future<void> setActiveConversation({String? id, String? receiverType}) =>
      methodChannel.invokeMethod<void>('setActiveConversation', {
        'id': id,
        'receiverType': receiverType,
      });

  @override
  Future<void> setBadgeCount(int count) =>
      methodChannel.invokeMethod<void>('setBadgeCount', {'count': count});

  @override
  Future<int> getBadgeCount() async =>
      await methodChannel.invokeMethod<int>('getBadgeCount') ?? 0;

  @override
  Stream<CometChatNotificationResponse> get onNotificationTap {
    final existing = _taps;
    if (existing != null) return existing.stream;

    // The native side releases the tap it captured from the launch intent the
    // moment anything listens. A broadcast stream hands that to whoever is
    // subscribed at that instant and to nobody else, so it is held here until
    // the app subscribes rather than falling on the floor.
    final controller =
        StreamController<CometChatNotificationResponse>.broadcast(
          onListen: _flushBacklog,
        );
    _taps = controller;

    eventChannel.receiveBroadcastStream().listen((event) {
      final response = CometChatNotificationResponse.fromMap(
        (event as Map).cast<Object?, Object?>(),
      );
      if (controller.hasListener) {
        controller.add(response);
      } else {
        _backlog.add(response);
      }
    }, onError: controller.addError);

    return controller.stream;
  }

  /// Hands the held taps to the listener that has just arrived.
  ///
  /// Scheduled rather than delivered inline: `onListen` runs before the
  /// subscription is wired up, so adding here would drop every one of them.
  void _flushBacklog() {
    if (_backlog.isEmpty) return;
    final held = List<CometChatNotificationResponse>.from(_backlog);
    _backlog.clear();
    scheduleMicrotask(() {
      for (final response in held) {
        _taps?.add(response);
      }
    });
  }
}
