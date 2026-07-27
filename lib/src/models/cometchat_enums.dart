/// The type of a CometChat push payload.
enum CometChatPayloadType {
  /// A chat message notification.
  chat,

  /// A call notification.
  call,

  /// An unrecognized payload type.
  unknown;

  /// Parses a string value into a [CometChatPayloadType].
  ///
  /// Returns [CometChatPayloadType.unknown] for `null` or unrecognized values.
  static CometChatPayloadType fromString(String? value) {
    switch (value) {
      case 'chat':
        return CometChatPayloadType.chat;
      case 'call':
        return CometChatPayloadType.call;
      default:
        return CometChatPayloadType.unknown;
    }
  }
}

/// The type of receiver.
enum CometChatReceiverType {
  /// A direct user receiver.
  user,

  /// A group receiver.
  group,

  /// An unrecognized receiver type.
  unknown;

  /// Parses a string value into a [CometChatReceiverType].
  ///
  /// Returns [CometChatReceiverType.unknown] for `null` or unrecognized values.
  static CometChatReceiverType fromString(String? value) {
    switch (value) {
      case 'user':
        return CometChatReceiverType.user;
      case 'group':
        return CometChatReceiverType.group;
      default:
        return CometChatReceiverType.unknown;
    }
  }
}

/// Call action from the push payload.
enum CometChatCallAction {
  /// The call has been initiated (incoming call).
  initiated,

  /// The call was cancelled by the caller.
  cancelled,

  /// The call went unanswered.
  unanswered,

  /// The call is ongoing (connected).
  ongoing,

  /// The call was rejected by the receiver.
  rejected,

  /// The call has ended.
  ended,

  /// The receiver is busy on another call.
  busy,

  /// An unrecognized call action.
  unknown;

  /// Parses a string value into a [CometChatCallAction].
  ///
  /// Returns [CometChatCallAction.unknown] for `null` or unrecognized values.
  static CometChatCallAction fromString(String? value) {
    switch (value) {
      case 'initiated':
        return CometChatCallAction.initiated;
      case 'cancelled':
        return CometChatCallAction.cancelled;
      case 'unanswered':
        return CometChatCallAction.unanswered;
      case 'ongoing':
        return CometChatCallAction.ongoing;
      case 'rejected':
        return CometChatCallAction.rejected;
      case 'ended':
        return CometChatCallAction.ended;
      case 'busy':
        return CometChatCallAction.busy;
      default:
        return CometChatCallAction.unknown;
    }
  }
}

/// Call type (audio or video).
enum CometChatCallType {
  /// An audio-only call.
  audio,

  /// A video call.
  video,

  /// An unrecognized call type.
  unknown;

  /// Parses a string value into a [CometChatCallType].
  ///
  /// Returns [CometChatCallType.unknown] for `null` or unrecognized values.
  static CometChatCallType fromString(String? value) {
    switch (value) {
      case 'audio':
        return CometChatCallType.audio;
      case 'video':
        return CometChatCallType.video;
      default:
        return CometChatCallType.unknown;
    }
  }
}

/// Push platform type for token registration.
///
/// The consumer explicitly specifies which platform token to register.
/// The plugin retrieves the corresponding token internally via
/// [NotificationVoipPlugin] and registers it with CometChat servers
/// via [CometChatNotifications.registerPushToken].
///
/// These values map to the CometChat SDK's [PushPlatforms] enum.
// ignore: constant_identifier_names
enum PushPlatform {
  /// FCM token for Android (Flutter).
  ///
  /// Internally retrieves FCM token via NVP and registers with CometChat.
  // ignore: constant_identifier_names
  FCM_FLUTTER_ANDROID,

  /// APNs device token for iOS (Flutter).
  ///
  /// Internally retrieves APNs token via NVP and registers with CometChat.
  // ignore: constant_identifier_names
  APNS_FLUTTER_DEVICE,

  /// VoIP (PushKit) token for iOS (Flutter).
  ///
  /// Internally retrieves VoIP token via NVP and registers with CometChat.
  // ignore: constant_identifier_names
  APNS_FLUTTER_VOIP,
}

/// Call event types emitted on the call event stream.
enum CometChatCallEventType {
  /// The call was accepted by the user.
  accepted,

  /// The call was declined by the user.
  declined,

  /// The call has ended.
  ended,

  /// An incoming call is being received.
  incoming,

  /// The call timed out without being answered.
  timeoutEnded,
}
