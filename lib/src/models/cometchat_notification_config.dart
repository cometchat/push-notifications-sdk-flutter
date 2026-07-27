import 'package:flutter/widgets.dart';

import 'package:notification_voip_plugin/notification_voip_plugin.dart';

import '../handler/cometchat_call_action_handler.dart';
import 'cometchat_call_details.dart';

/// Callback invoked when the user accepts an incoming call from the
/// default call screen.
typedef CometChatCallAcceptedCallback =
    void Function(CometChatCallDetails callDetails);

/// Callback invoked when the user declines an incoming call from the
/// default call screen.
typedef CometChatCallDeclinedCallback =
    void Function(CometChatCallDetails callDetails);

/// Builder for a custom call screen.
///
/// Receives the [callDetails]. When a custom screen is provided, the
/// plugin delegates full control to it — the consumer is responsible for:
/// - Accepting or rejecting the call (via [CometChatPushNotifications.endCall]
///   or their own media engine).
/// - Dismissing the call notification using
///   [CometChatPushNotifications.cancelCallNotification].
/// - Popping the call screen when done.
///
/// The [CometChatNotificationConfig.onCallAccepted] /
/// [CometChatNotificationConfig.onCallDeclined] callbacks only apply to
/// the default call screen.
typedef CometChatCallScreenBuilder =
    Widget Function(CometChatCallDetails callDetails);

/// Configuration for initializing CometChatPushNotifications.
///
/// This plugin exclusively uses a custom Flutter call screen for
/// incoming and outgoing call UI on both Android and iOS.
/// Native call UI (CallKit/ConnectionService) is NOT used for display.
///
/// On iOS, CallKit is used internally only for mandatory PushKit
/// reporting — the actual UI shown to the user is always the custom screen.
///
/// ### Default vs Custom call screen
///
/// If [customCallScreenBuilder] is `null`, the plugin uses a built-in
/// default incoming call screen with caller name, avatar, and
/// Accept/Decline buttons. To override it, provide your own builder.
class CometChatNotificationConfig {
  /// The CometChat app ID (required for token registration).
  final String appId;

  /// The CometChat region (e.g., `'us'`, `'eu'`).
  final String region;

  /// Optional underlying NVP configuration for advanced customization.
  ///
  /// If not provided, a default [NvpConfig] is created internally.
  final NvpConfig? nvpConfig;

  /// Optional custom call screen builder.
  ///
  /// If `null`, the default [CometChatDefaultCallScreen] is used with
  /// pre-wired Accept / Decline buttons that route to [onCallAccepted]
  /// and [onCallDeclined].
  ///
  /// When provided, the plugin delegates full control to the custom
  /// screen — the consumer is responsible for accepting / rejecting the
  /// call, cancelling the call notification, and popping the screen.
  /// The [onCallAccepted] / [onCallDeclined] callbacks are **not**
  /// invoked when a custom screen is used.
  final CometChatCallScreenBuilder? customCallScreenBuilder;

  /// Called when the user accepts an incoming call from the **default**
  /// call screen.
  ///
  /// Use this to start your WebRTC/media engine, navigate to the ongoing
  /// call screen, and call [CometChatPushNotifications.setCallConnected].
  ///
  /// Not invoked when [customCallScreenBuilder] is provided.
  final CometChatCallAcceptedCallback? onCallAccepted;

  /// Called when the user declines an incoming call from the **default**
  /// call screen.
  ///
  /// Use this to clean up any call-related state. The plugin will
  /// automatically dismiss the call notification.
  ///
  /// Not invoked when [customCallScreenBuilder] is provided.
  final CometChatCallDeclinedCallback? onCallDeclined;

  /// Optional handler for in-call control actions (mute, speaker, camera).
  ///
  /// If not provided, a default [CometChatCallActionHandler] is used,
  /// which delegates all actions directly to `NotificationVoipPlugin`.
  ///
  /// Provide a custom subclass to intercept actions — e.g., to mute
  /// a WebRTC audio track when the user toggles mute.
  final CometChatCallActionHandler? callActionHandler;

  /// Whether to show in-app chat notifications when the app is in the
  /// foreground.
  ///
  /// When `false` (default), chat push notifications received while the
  /// app is in the foreground are suppressed (not displayed as banners).
  /// When `true`, they are shown as in-app notification banners.
  final bool showInAppNotifications;

  /// Whether to show the VoIP incoming call screen when the app is in
  /// the foreground.
  ///
  /// When `false` (default/recommended), incoming call pushes received while
  /// the app is in the foreground are suppressed — the UIKit's
  /// `CallEventService` handles foreground calls via WebSocket and shows
  /// `IncomingCallOverlay` instead. The call event is still emitted on the
  /// [CometChatPushNotifications.onCallEvent] stream.
  /// When `true`, the push SDK also shows the system call notification in
  /// foreground (use only if CallEventService is NOT active).
  final bool showInAppVoIP;

  /// Creates a [CometChatNotificationConfig] instance.
  ///
  /// [customCallScreenBuilder] is optional — when omitted, the plugin
  /// uses [CometChatDefaultCallScreen] to render incoming calls.
  CometChatNotificationConfig({
    required this.appId,
    required this.region,
    this.customCallScreenBuilder,
    this.onCallAccepted,
    this.onCallDeclined,
    this.nvpConfig,
    this.callActionHandler,
    this.showInAppNotifications = false,
    this.showInAppVoIP = false,
  });
}
