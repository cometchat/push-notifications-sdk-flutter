import 'cometchat_enums.dart';
import 'cometchat_notification_details.dart';

/// Structured call details extracted from a CometChat call payload.
///
/// Used by [CometChatCallHandler] and passed to custom call screen builders.
class CometChatCallDetails {
  /// The unique call session ID.
  final String sessionId;

  /// The UID of the caller.
  final String callerUid;

  /// The display name of the caller.
  final String callerName;

  /// The avatar URL of the caller, if available.
  final String? callerAvatar;

  /// The call type (audio or video).
  final CometChatCallType callType;

  /// The receiver type (user or group).
  final CometChatReceiverType receiverType;

  /// The conversation identifier.
  final String conversationId;

  /// Whether this is a video call.
  final bool isVideo;

  /// Creates a [CometChatCallDetails] instance.
  const CometChatCallDetails({
    required this.sessionId,
    required this.callerUid,
    required this.callerName,
    this.callerAvatar,
    required this.callType,
    required this.receiverType,
    required this.conversationId,
    required this.isVideo,
  });

  /// Creates [CometChatCallDetails] from [CometChatNotificationDetails].
  factory CometChatCallDetails.fromNotificationDetails(
    CometChatNotificationDetails details,
  ) {
    return CometChatCallDetails(
      sessionId: details.sessionId ?? '',
      callerUid: details.sender,
      callerName: details.senderName,
      callerAvatar: details.senderAvatar,
      callType: details.callType ?? CometChatCallType.audio,
      receiverType: details.receiverType,
      conversationId: details.conversationId,
      isVideo: details.callType == CometChatCallType.video,
    );
  }
}
