import 'package:notification_voip_plugin/notification_voip_plugin.dart';

import '../models/cometchat_call_details.dart';
import '../models/cometchat_enums.dart';
import '../models/cometchat_notification_details.dart';

/// Maps CometChat domain models to `notification_voip_plugin` models.
///
/// Supports optional overrides for title, icon, and notification grouping.
/// Used internally by [CometChatPushNotifications] to bridge between
/// parsed CometChat payloads and the underlying NVP display layer.
class CometChatMapper {
  CometChatMapper._();

  /// Maps [CometChatNotificationDetails] to [NvpNotification].
  ///
  /// Optional overrides:
  /// - [titleOverride]: replaces the payload title if provided.
  /// - [iconOverride]: replaces the notification image/icon if provided.
  /// - [groupKeyOverride]: replaces the default `conversationId` grouping
  ///   if provided (derived from `uid` or `guid` parameter in
  ///   `handlePushNotification`).
  ///
  /// When no [iconOverride] is given, the avatar is chosen based on
  /// receiver type: group payloads use `receiverAvatar`, user payloads
  /// use `senderAvatar`.
  ///
  /// The [data] map is populated with navigation-relevant fields so they
  /// survive the Android PendingIntent round-trip (intent extras → tap →
  /// EventChannel → Dart). The native NotificationHandler copies `data`
  /// entries as intent extras on the notification's content intent.
  static NvpNotification toNvpNotification(
    CometChatNotificationDetails details, {
    String? titleOverride,
    String? iconOverride,
    String? groupKeyOverride,
  }) {
    return NvpNotification(
      title: titleOverride ?? details.title,
      body: details.body,
      tag: details.tag,
      imageUrl:
          iconOverride ??
          (details.receiverType == CometChatReceiverType.group
              ? details.receiverAvatar
              : details.senderAvatar),
      senderId: details.sender,
      senderName: details.senderName,
      senderAvatar: details.senderAvatar,
      receiverId: details.receiver,
      receiverName: details.receiverName,
      receiverType: details.receiverType.name,
      conversationId: details.conversationId,
      groupKey: groupKeyOverride ?? details.conversationId,
      // Include navigation metadata in `data` so it survives the
      // Android PendingIntent → intent extras → EventChannel round-trip.
      // The native NotificationHandler puts `data` entries as extras on the
      // launch intent, and handleNotificationIntent reads them back.
      data: {
        'senderId': details.sender,
        'senderName': details.senderName,
        'senderAvatar': details.senderAvatar ?? '',
        'receiverId': details.receiver,
        'receiverName': details.receiverName,
        'receiverType': details.receiverType.name,
        'conversationId': details.conversationId,
        'tag': details.tag,
        'title': titleOverride ?? details.title,
        'body': details.body,
      },
    );
  }

  /// Maps [CometChatCallDetails] to [NvpCallConfig].
  ///
  /// Always configures for custom Flutter call screen (never native).
  /// On iOS, NVP handles CallKit reporting internally for PushKit compliance.
  ///
  /// Uses `useNativeScreen: false` — always shows the custom Flutter call screen.
  /// For background/killed state on Android, a high-priority full-screen
  /// notification is shown to wake the device and launch the app.
  static NvpCallConfig toNvpCallConfig(CometChatCallDetails callDetails) {
    return NvpCallConfig(
      callId: callDetails.sessionId,
      callerName: callDetails.callerName,
      callerAvatar: callDetails.callerAvatar,
      isVideo: callDetails.isVideo,
      useNativeScreen: false,
    );
  }
}
