import 'cometchat_notification_details.dart';

/// Represents a parsed CometChat push notification payload.
///
/// The raw payload has the structure:
/// ```json
/// {
///   "trigger": "push-notification-payload-generated",
///   "data": {
///     "to": { "uid": "..." },
///     "notificationDetails": { ... }
///   }
/// }
/// ```
///
/// This model represents the parsed `notificationDetails` with the `to` uid.
class CometChatPushPayload {
  /// The UID of the intended recipient.
  final String toUid;

  /// The notification details extracted from the payload.
  final CometChatNotificationDetails notificationDetails;

  /// The raw payload map for fallback access.
  final Map<String, dynamic> rawPayload;

  /// Creates a [CometChatPushPayload] instance.
  const CometChatPushPayload({
    required this.toUid,
    required this.notificationDetails,
    required this.rawPayload,
  });
}
