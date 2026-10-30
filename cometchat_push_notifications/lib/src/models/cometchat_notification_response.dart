import 'cometchat_enums.dart';

/// A notification tap.
///
/// Carries enough of the originating payload to open the right conversation
/// without another round trip: which conversation it was, and who it was with.
class CometChatNotificationResponse {
  /// The conversation the notification belongs to — the sender's UID for a
  /// 1:1 chat, the GUID for a group.
  final String conversationId;

  /// Whether [conversationId] names a user or a group.
  final CometChatPushReceiverType receiverType;

  /// The sender's UID.
  final String sender;

  /// The sender's display name.
  final String senderName;

  /// The sender's avatar URL, if the payload carried one.
  final String? senderAvatar;

  /// The ID of the message that triggered the notification.
  final String messageId;

  /// Creates a [CometChatNotificationResponse].
  const CometChatNotificationResponse({
    required this.conversationId,
    required this.receiverType,
    required this.sender,
    required this.senderName,
    this.senderAvatar,
    required this.messageId,
  });

  /// Rebuilds a response from the map the native side sends over the channel.
  factory CometChatNotificationResponse.fromMap(Map<Object?, Object?> map) {
    String str(String key) => map[key] as String? ?? '';
    return CometChatNotificationResponse(
      conversationId: str('conversationId'),
      receiverType: CometChatPushReceiverType.fromString(
        map['receiverType'] as String?,
      ),
      sender: str('sender'),
      senderName: str('senderName'),
      senderAvatar: map['senderAvatar'] as String?,
      messageId: str('messageId'),
    );
  }
}
