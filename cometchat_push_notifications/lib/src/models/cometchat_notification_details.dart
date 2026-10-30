import 'cometchat_enums.dart';

/// Parsed `notificationDetails` from a CometChat push payload.
///
/// Call pushes still reach this package and still parse — [isCall] identifies
/// them — but ringing them is the job of `cometchat_voip`, the package beside
/// this one.
class CometChatNotificationDetails {
  /// The notification display title.
  final String title;

  /// The notification display body.
  final String body;

  /// The sender UID.
  final String sender;

  /// The sender display name.
  final String senderName;

  /// The sender avatar URL, if available.
  final String? senderAvatar;

  /// The receiver UID or GUID.
  final String receiver;

  /// The receiver display name.
  final String receiverName;

  /// The receiver avatar URL, if available.
  final String? receiverAvatar;

  /// The type of receiver (user or group).
  final CometChatPushReceiverType receiverType;

  /// The message/notification ID used as a notification tag.
  final String tag;

  /// The conversation identifier.
  final String conversationId;

  /// The payload type (chat or call).
  final CometChatPayloadType type;

  /// The timestamp in milliseconds as a string.
  final String sentAt;

  /// The full CometChat message object, if enabled (chat-specific).
  final Map<String, dynamic>? message;

  /// Custom JSON data, if configured.
  final Map<String, dynamic>? custom;

  /// Creates a [CometChatNotificationDetails] instance.
  const CometChatNotificationDetails({
    required this.title,
    required this.body,
    required this.sender,
    required this.senderName,
    this.senderAvatar,
    required this.receiver,
    required this.receiverName,
    this.receiverAvatar,
    required this.receiverType,
    required this.tag,
    required this.conversationId,
    required this.type,
    required this.sentAt,
    this.message,
    this.custom,
  });

  /// Whether this payload represents a call.
  bool get isCall => type == CometChatPayloadType.call;

  /// Whether this payload represents a chat message.
  bool get isChat => type == CometChatPayloadType.chat;
}
