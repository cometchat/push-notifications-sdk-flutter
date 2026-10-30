/// Settings for [CometChatPushNotifications.init].
///
/// Chat notifications only. Calling moved to its own package in 2.0, so
/// nothing here configures a ringer, a call screen or a VoIP token.
class CometChatNotificationConfig {
  /// The CometChat app ID.
  final String appId;

  /// The CometChat region — `'us'`, `'eu'` or `'in'`.
  final String region;

  /// Whether a push that arrives while the app is in the foreground is shown.
  ///
  /// Defaults to false: an app in the foreground is usually already showing
  /// the message, and a banner over it is noise. The conversation currently on
  /// screen is suppressed either way — see
  /// [CometChatPushNotifications.setActiveConversation].
  final bool showInAppNotifications;

  /// Whether the iOS app icon badge tracks `unreadMessageCount` from the
  /// payload. Ignored on Android, which has no OS-level badge.
  final bool enableBadgeCount;

  /// Whether a delivery receipt is sent to CometChat for each chat push.
  final bool sendDeliveryReceipts;

  /// The Android drawable used as the notification's small icon, by resource
  /// name — for example `'ic_notification'` for `res/drawable/ic_notification`.
  ///
  /// Android draws this as a flat silhouette, so it must be a white-on-
  /// transparent image. When null, or when no drawable of that name exists, the
  /// app's own launcher icon is used, which Android renders as a grey blob —
  /// ship a real icon before release.
  final String? androidSmallIcon;

  /// The Android notification channel this package posts to.
  ///
  /// Android freezes a channel's importance, sound and vibration the first time
  /// it is created; changing these afterwards requires a new [androidChannelId],
  /// because a user who has tuned the channel outranks the app.
  final String androidChannelId;

  /// The channel name the user sees in Android's notification settings.
  final String androidChannelName;

  /// The channel description shown under [androidChannelName].
  final String androidChannelDescription;

  /// Creates a [CometChatNotificationConfig].
  const CometChatNotificationConfig({
    required this.appId,
    required this.region,
    this.showInAppNotifications = false,
    this.enableBadgeCount = true,
    this.sendDeliveryReceipts = true,
    this.androidSmallIcon,
    this.androidChannelId = 'cometchat_messages',
    this.androidChannelName = 'Chat Messages',
    this.androidChannelDescription = 'New message notifications',
  });

  /// The wire form handed to the native side by
  /// [CometchatPushNotificationsPlatform.initialize].
  Map<String, Object?> toMap() => {
    'showInAppNotifications': showInAppNotifications,
    'enableBadgeCount': enableBadgeCount,
    'androidSmallIcon': androidSmallIcon,
    'androidChannelId': androidChannelId,
    'androidChannelName': androidChannelName,
    'androidChannelDescription': androidChannelDescription,
  };
}
