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

/// Whether a conversation is with a person or a group.
///
/// Deliberately not named `CometChatReceiverType`: the Chat SDK already has one
/// of those, holding the same two values as string constants. Both land in
/// scope together in any app built on the UI Kit, which re-exports the SDK, and
/// two identical names there are an `ambiguous_import` error at the point of
/// use — a compile failure handed to every integrator.
enum CometChatPushReceiverType {
  /// A direct user receiver.
  user,

  /// A group receiver.
  group,

  /// An unrecognized receiver type.
  unknown;

  /// Parses a string value into a [CometChatPushReceiverType].
  ///
  /// Returns [CometChatPushReceiverType.unknown] for `null` or unrecognized values.
  static CometChatPushReceiverType fromString(String? value) {
    switch (value) {
      case 'user':
        return CometChatPushReceiverType.user;
      case 'group':
        return CometChatPushReceiverType.group;
      default:
        return CometChatPushReceiverType.unknown;
    }
  }
}

/// The provider a push token belongs to, mapped onto the Chat SDK's
/// `PushPlatforms`.
///
/// The provider is not the operating system. An iOS app that uses
/// `firebase_messaging` holds an FCM token, not an APNs one, and registering it
/// as [APNS_FLUTTER_DEVICE] sends CometChat to the wrong provider — pushes are
/// then accepted and never delivered.
///
/// The VoIP platform moved to `cometchat_voip` in 2.0: a chat integrator has no
/// VoIP provider to register a token against.
// ignore: constant_identifier_names
enum PushPlatform {
  /// An FCM token from an Android app.
  // ignore: constant_identifier_names
  FCM_FLUTTER_ANDROID,

  /// An FCM token from an iOS app — what `firebase_messaging` gives you there.
  // ignore: constant_identifier_names
  FCM_FLUTTER_IOS,

  /// An APNs device token, from an iOS app talking to APNs directly.
  // ignore: constant_identifier_names
  APNS_FLUTTER_DEVICE,

  /// An FCM token from a web app.
  // ignore: constant_identifier_names
  FCM_WEB;

  /// Whether this platform's token is an FCM token rather than an APNs one.
  ///
  /// The two go into different fields on the registration call, and the server
  /// ignores the one it was not expecting.
  bool get isFcm => this != APNS_FLUTTER_DEVICE;
}
