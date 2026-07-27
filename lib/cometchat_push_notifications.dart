import 'dart:async';
import 'dart:io' show Platform;

import 'package:cometchat_sdk/cometchat_sdk.dart' as sdk;
import 'package:flutter/material.dart';
import 'package:notification_voip_plugin/notification_voip_plugin.dart';

import 'cometchat_push_notifications_platform_interface.dart';
import 'src/errors/cometchat_notification_exception.dart';
import 'src/handler/cometchat_call_action_handler.dart';
import 'src/handler/cometchat_call_handler.dart';
import 'src/mapper/cometchat_mapper.dart';
import 'src/models/cometchat_call_details.dart';
import 'src/models/cometchat_enums.dart';
import 'src/models/cometchat_notification_config.dart';
import 'src/models/cometchat_notification_details.dart';
import 'src/models/cometchat_push_payload.dart';
import 'src/parser/cometchat_payload_parser.dart';
import 'src/screens/cometchat_default_call_screen.dart';
import 'src/utils/platform_guard.dart';

/// The main entry point for CometChat push notification and VoIP call handling.
///
/// All methods are static. Initialize once with [init], then use
/// [registerToken], [handlePushNotification], and the call methods
/// to handle the full notification and VoIP lifecycle.
///
/// This plugin exclusively uses a custom Flutter call screen for VoIP
/// call UI on both Android and iOS. No native CallKit or ConnectionService
/// UI is shown to the user.
///
/// Example:
/// ```dart
/// await CometChatPushNotifications.init(
///   CometChatNotificationConfig(
///     appId: 'APP_ID',
///     region: 'us',
///     customCallScreenBuilder: (callDetails) => MyCallScreen(callDetails),
///   ),
/// );
///
/// // Android
/// CometChatPushNotifications.registerToken(
///   PushPlatform.FCM_FLUTTER_ANDROID,
///   onSuccess: (token) => print('Registered: $token'),
///   onError: (e) => print('Failed: $e'),
/// );
///
/// // iOS — register both APNs and VoIP tokens
/// CometChatPushNotifications.registerToken(
///   PushPlatform.APNS_FLUTTER_DEVICE,
///   onSuccess: (token) => print('APNs registered: $token'),
///   onError: (e) => print('APNs failed: $e'),
/// );
/// CometChatPushNotifications.registerToken(
///   PushPlatform.APNS_FLUTTER_VOIP,
///   onSuccess: (token) => print('VoIP registered: $token'),
///   onError: (e) => print('VoIP failed: $e'),
/// );
/// ```
class CometChatPushNotifications {
  /// Creates a [CometChatPushNotifications] instance.
  ///
  /// Only needed for the [getPlatformVersion] instance method.
  /// All other methods are static.
  const CometChatPushNotifications();

  // ── Internal state ──

  static bool _initialized = false;
  static CometChatNotificationConfig? _config;

  /// Navigator key used to dismiss the call screen on silent decline.
  static GlobalKey<NavigatorState>? _navigatorKey;

  static final StreamController<CometChatNotificationDetails>
  _notificationTapController =
      StreamController<CometChatNotificationDetails>.broadcast();

  static final StreamController<CometChatCallEvent> _callEventController =
      StreamController<CometChatCallEvent>.broadcast();

  static final StreamController<NvpCallState> _callStateChangedController =
      StreamController<NvpCallState>.broadcast();

  static final StreamController<String> _tokenRefreshController =
      StreamController<String>.broadcast();

  static final StreamController<Map<String, dynamic>> _pushReceivedController =
      StreamController<Map<String, dynamic>>.broadcast();

  // ── NVP stream subscriptions ──

  static StreamSubscription<NvpNotification>? _nvpNotificationTapSub;
  static StreamSubscription<NvpCallEvent>? _nvpCallEventSub;
  static StreamSubscription<NvpCallState>? _nvpCallStateSub;
  static StreamSubscription<String>? _nvpTokenRefreshSub;
  static StreamSubscription<Map<String, dynamic>>? _nvpPushReceivedSub;

  /// Tracks call IDs that have already been handled via the Flutter call
  /// screen (buildCallScreen) to prevent double-firing callbacks when
  /// CallKit delegate also emits the same event.
  static final Set<String> _handledCallActions = {};

  // ── Internal helpers ──

  /// Throws [CometChatNotificationException] if [init] has not been called.
  static void _ensureInitialized() {
    if (!_initialized) {
      throw const CometChatNotificationException(
        code: CometChatErrorCode.notInitialized,
        message: 'CometChatPushNotifications.init() must be called before use.',
      );
    }
  }

  // ──────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────

  /// Initializes the plugin.
  ///
  /// Must be called once before any other method, typically in `main()`.
  /// Internally calls [NotificationVoipPlugin.init] and sets up
  /// internal stream subscriptions for auto-handling.
  ///
  /// The [config] must include a [CometChatNotificationConfig.customCallScreenBuilder]
  /// which is used for all call UI on both platforms.
  static Future<void> init(CometChatNotificationConfig config) async {
    _config = config;

    // Configure the call handler with the provided action handler.
    CometChatCallHandler.configure(actionHandler: config.callActionHandler);

    // Initialize NotificationVoipPlugin with the provided or default config.
    // When showInAppNotifications is false, tell the native plugin to suppress
    // all foreground notifications (prevents iOS willPresent from showing them).
    // When showInAppVoIP is false, tell the native plugin to suppress VoIP
    // CallKit UI in foreground (iOS PushKit still reports but immediately ends).
    NvpConfig? nvpConfig = config.nvpConfig;
    if (!config.showInAppNotifications || !config.showInAppVoIP) {
      nvpConfig = NvpConfig(
        appName: nvpConfig?.appName,
        bannerDuration: nvpConfig?.bannerDuration ?? const Duration(seconds: 5),
        payloadKeys: nvpConfig?.payloadKeys ?? const NvpPayloadKeys(),
        channelId: nvpConfig?.channelId ?? 'default_channel',
        channelName: nvpConfig?.channelName ?? 'Default Channel',
        defaultTemplate:
            nvpConfig?.defaultTemplate ?? NvpNotificationTemplate.normal,
        callScreenConfig:
            nvpConfig?.callScreenConfig ?? const NvpCallScreenConfig(),
        defaultGroupKey: nvpConfig?.defaultGroupKey,
        suppressForegroundNotifications: !config.showInAppNotifications,
        suppressForegroundVoIP: !config.showInAppVoIP,
      );
    }
    await NotificationVoipPlugin.init(nvpConfig);

    // Set up NVP stream subscriptions for auto-handling.
    _setupStreamSubscriptions();

    // Wire the native decline broadcast to the CometChat SDK.
    CometchatPushNotificationsPlatform.instance.setDeclineCallHandler(
      _handleSilentDecline,
    );

    _initialized = true;
  }

  /// Handles the Decline action dispatched from the native
  /// [CallActionReceiver]. Pops the call screen if it's on the stack and
  /// notifies the host app so IT can reject the call.
  ///
  /// The plugin deliberately does NOT call the CometChat SDK to reject — all
  /// accept/reject SDK logic lives in the host app (Android VoIP is
  /// custom-screen only). The app rejects via its [onCallDeclined] handler
  /// and/or the [onCallEvent] stream.
  static void _handleSilentDecline(String sessionId) {
    final callDetails = CometChatCallDetails(
      sessionId: sessionId,
      callerUid: '',
      callerName: '',
      callType: CometChatCallType.audio,
      receiverType: CometChatReceiverType.user,
      conversationId: '',
      isVideo: false,
    );

    // Pop the call screen if it's currently visible.
    _popCallScreenIfActive();

    // Hand off to the host app — it owns the CometChat.rejectCall call.
    _config?.onCallDeclined?.call(callDetails);
    _callEventController.add(
      CometChatCallEvent(
        type: CometChatCallEventType.declined,
        sessionId: sessionId,
      ),
    );
  }

  /// Pops the CometChat default call screen from the navigator if it's
  /// on top of the stack.
  static void _popCallScreenIfActive() {
    final navigator = _navigatorKey?.currentState;
    if (navigator == null) return;
    navigator.popUntil((route) {
      return route.settings.name != '/cometchat_call_screen';
    });
  }

  /// Sets up subscriptions to NVP streams, forwarding events to the
  /// plugin's own typed streams.
  static void _setupStreamSubscriptions() {
    // onTokenRefresh → auto re-register with CometChat servers.
    _nvpTokenRefreshSub?.cancel();
    _nvpTokenRefreshSub = NotificationVoipPlugin.onTokenRefresh.listen((token) {
      _autoReRegisterToken(token);
      _tokenRefreshController.add(token);
    });

    // onCallEvent → map NvpCallEvent to CometChatCallEvent and forward.
    // Also invoke config callbacks for accept/decline from CallKit.
    _nvpCallEventSub?.cancel();
    _nvpCallEventSub = NotificationVoipPlugin.onCallEvent.listen((event) {
      final type = _mapNvpCallAction(event.action);
      if (type != null) {
        _callEventController.add(
          CometChatCallEvent(
            type: type,
            sessionId: event.callId,
            extraData: event.payload.isNotEmpty ? event.payload : null,
          ),
        );

        // Invoke config callbacks when accept/decline comes from CallKit
        // (native UI). This ensures the app's onCallAccepted/onCallDeclined
        // handlers fire regardless of whether the action came from the
        // Flutter call screen or the native CallKit UI.
        // Skip if already handled via buildCallScreen to prevent double-fire.
        final actionKey = '${event.callId}_${type.name}';
        if (_handledCallActions.contains(actionKey)) {
          _handledCallActions.remove(actionKey);
        } else if (type == CometChatCallEventType.accepted) {
          final callDetails = CometChatCallDetails(
            sessionId: event.callId,
            callerUid: '',
            callerName: event.callerName ?? '',
            callerAvatar: event.callerAvatar,
            callType: event.isVideo
                ? CometChatCallType.video
                : CometChatCallType.audio,
            receiverType: CometChatReceiverType.user,
            conversationId: '',
            isVideo: event.isVideo,
          );
          // Cancel the call notification since the call was accepted.
          CometchatPushNotificationsPlatform.instance.cancelCallNotification(
            event.callId,
          );
          _config?.onCallAccepted?.call(callDetails);
        } else if (type == CometChatCallEventType.declined) {
          final callDetails = CometChatCallDetails(
            sessionId: event.callId,
            callerUid: '',
            callerName: event.callerName ?? '',
            callerAvatar: event.callerAvatar,
            callType: event.isVideo
                ? CometChatCallType.video
                : CometChatCallType.audio,
            receiverType: CometChatReceiverType.user,
            conversationId: '',
            isVideo: event.isVideo,
          );
          // Cancel the call notification since the call was declined.
          CometchatPushNotificationsPlatform.instance.cancelCallNotification(
            event.callId,
          );
          _config?.onCallDeclined?.call(callDetails);
        }
      }
    });

    // onCallStateChanged → forward to our stream.
    _nvpCallStateSub?.cancel();
    _nvpCallStateSub = NotificationVoipPlugin.onCallStateChanged.listen((
      state,
    ) {
      _callStateChangedController.add(state);
    });

    // onNotificationTap → parse the notification data and forward.
    _nvpNotificationTapSub?.cancel();
    _nvpNotificationTapSub = NotificationVoipPlugin.onNotificationTap.listen((
      notification,
    ) {
      final details = CometChatNotificationDetails(
        title: notification.title,
        body: notification.body,
        sender: notification.senderId ?? '',
        senderName: notification.senderName ?? '',
        senderAvatar: notification.senderAvatar,
        receiver: notification.receiverId ?? '',
        receiverName: notification.receiverName ?? '',
        receiverType: CometChatReceiverType.fromString(
          notification.receiverType,
        ),
        tag: notification.tag ?? '',
        conversationId: notification.conversationId ?? '',
        type: CometChatPayloadType.chat,
        sentAt: '',
      );
      _notificationTapController.add(details);
    });

    // onPushReceived → forward raw payload (iOS only — Android has no native
    // handler for this event channel).
    _nvpPushReceivedSub?.cancel();
    if (Platform.isIOS) {
      _nvpPushReceivedSub = NotificationVoipPlugin.onPushReceived.listen((
        payload,
      ) {
        _pushReceivedController.add(payload);
      });
    }
  }

  /// Automatically re-registers a refreshed token with CometChat servers.
  static void _autoReRegisterToken(String token) {
    if (_config == null) return;

    sdk.CometChat.registerTokenForPushNotification(
      token,
      onSuccess: (_) {},
      onError: (_) {},
    );
  }

  /// Maps an [NvpCallAction] to a [CometChatCallEventType].
  static CometChatCallEventType? _mapNvpCallAction(NvpCallAction? action) {
    switch (action) {
      case NvpCallAction.accept:
        return CometChatCallEventType.accepted;
      case NvpCallAction.decline:
        return CometChatCallEventType.declined;
      case NvpCallAction.ended:
        return CometChatCallEventType.ended;
      case NvpCallAction.incoming:
        return CometChatCallEventType.incoming;
      case NvpCallAction.timeoutEnded:
        return CometChatCallEventType.timeoutEnded;
      case null:
        return null;
    }
  }

  /// Disposes all resources, cancels stream subscriptions,
  /// and calls [NotificationVoipPlugin.dispose].
  static Future<void> dispose() async {
    _nvpNotificationTapSub?.cancel();
    _nvpNotificationTapSub = null;
    _nvpCallEventSub?.cancel();
    _nvpCallEventSub = null;
    _nvpCallStateSub?.cancel();
    _nvpCallStateSub = null;
    _nvpTokenRefreshSub?.cancel();
    _nvpTokenRefreshSub = null;
    _nvpPushReceivedSub?.cancel();
    _nvpPushReceivedSub = null;

    await NotificationVoipPlugin.dispose();

    _initialized = false;
    _config = null;
  }

  // ──────────────────────────────────────────────
  // Permissions
  // ──────────────────────────────────────────────

  /// Requests notification permission from the OS.
  ///
  /// Returns `true` if granted.
  static Future<bool> requestPermission() async {
    return NotificationVoipPlugin.requestPermission();
  }

  /// Checks whether notification permission is currently granted.
  static Future<bool> isPermissionGranted() async {
    return NotificationVoipPlugin.isPermissionGranted();
  }

  // ──────────────────────────────────────────────
  // Token Registration
  // ──────────────────────────────────────────────

  /// Registers a push token with CometChat servers for the specified platform.
  ///
  /// The consumer explicitly chooses which platform token to register via
  /// the [platform] enum. The plugin internally:
  ///
  /// 1. Retrieves the corresponding token from [NotificationVoipPlugin]:
  ///    - [PushPlatform.FCM_FLUTTER_ANDROID] →
  ///      [NotificationVoipPlugin.getFCMToken]
  ///    - [PushPlatform.APNS_FLUTTER_DEVICE] →
  ///      [NotificationVoipPlugin.getAPNsToken]
  ///    - [PushPlatform.APNS_FLUTTER_VOIP] →
  ///      [NotificationVoipPlugin.getVoIPToken]
  /// 2. For iOS platforms, also fetches the companion token (VoIP when
  ///    registering APNs, and vice versa) since the CometChat server
  ///    requires both tokens in a single registration call.
  /// 3. Registers the token(s) with CometChat servers via
  ///    [sdk.CometChatNotifications.registerPushToken].
  /// 4. Calls [onSuccess] with the registered token string on success.
  /// 5. Calls [onError] with a [CometChatNotificationException] on failure.
  ///
  /// [providerId] is the push provider ID configured in the CometChat
  /// Dashboard (e.g., `'apns_provider'`). This must match exactly.
  ///
  /// On iOS, call this separately for [PushPlatform.APNS_FLUTTER_DEVICE]
  /// and [PushPlatform.APNS_FLUTTER_VOIP]. Each call internally includes
  /// both tokens in the server request.
  static void registerToken(
    PushPlatform platform, {
    required String providerId,
    required Function(String token) onSuccess,
    required Function(CometChatNotificationException e) onError,
  }) {
    _ensureInitialized();
    _registerTokenAsync(platform, onSuccess, onError, providerId: providerId);
  }

  static Future<void> _registerTokenAsync(
    PushPlatform platform,
    Function(String token) onSuccess,
    Function(CometChatNotificationException e) onError, {
    required String providerId,
  }) async {
    try {
      String? token;
      sdk.PushPlatforms sdkPlatform;
      String? deviceToken;
      String? voipToken;
      String? fcmToken;

      switch (platform) {
        case PushPlatform.FCM_FLUTTER_ANDROID:
          token = await NotificationVoipPlugin.getFCMToken();
          sdkPlatform = sdk.PushPlatforms.FCM_FLUTTER_ANDROID;
          fcmToken = token;
        case PushPlatform.APNS_FLUTTER_DEVICE:
          token = await NotificationVoipPlugin.getAPNsToken();
          sdkPlatform = sdk.PushPlatforms.APNS_FLUTTER_DEVICE;
          deviceToken = token;
          // Also fetch VoIP token — the server requires both together.
          voipToken = await NotificationVoipPlugin.getVoIPToken();
        case PushPlatform.APNS_FLUTTER_VOIP:
          token = await NotificationVoipPlugin.getVoIPToken();
          sdkPlatform = sdk.PushPlatforms.APNS_FLUTTER_VOIP;
          voipToken = token;
          // Also fetch APNs device token — the server requires both together.
          deviceToken = await NotificationVoipPlugin.getAPNsToken();
      }

      if (token == null || token.isEmpty) {
        onError(
          CometChatNotificationException(
            code: CometChatErrorCode.tokenRegistrationFailed,
            message: 'Failed to retrieve ${platform.name} token.',
          ),
        );
        return;
      }

      // ignore: avoid_print
      print(
        '[CometChatPushNotifications] Registering ${platform.name} '
        'token: ${token.substring(0, 8)}...',
      );

      await sdk.CometChatNotifications.registerPushToken(
        sdkPlatform,
        fcmToken: fcmToken,
        deviceToken: deviceToken,
        voipToken: voipToken,
        providerId: providerId,
        onSuccess: (response) {
          onSuccess(token!);
        },
        onError: (exception) {
          // ignore: avoid_print
          print(
            '[CometChatPushNotifications] registerPushToken error: '
            'code=${exception.code}, message=${exception.message}, '
            'details=${exception.details}',
          );
          onError(
            CometChatNotificationException(
              code: CometChatErrorCode.tokenRegistrationFailed,
              message:
                  'CometChat token registration failed for ${platform.name}. '
                  'Server error: ${exception.message}',
              cause: exception,
            ),
          );
        },
      );
    } catch (e) {
      onError(
        CometChatNotificationException(
          code: CometChatErrorCode.tokenRegistrationFailed,
          message: 'Token registration failed for ${platform.name}.',
          cause: e,
        ),
      );
    }
  }

  /// Retrieves the platform push token without registering it.
  ///
  /// Returns FCM token on Android, APNs token on iOS, `null` on web.
  static Future<String?> getPushToken() async {
    return NotificationVoipPlugin.getPushToken();
  }

  /// Retrieves the VoIP token (iOS only via PushKit).
  ///
  /// Returns `null` on Android and web.
  static Future<String?> getVoIPToken() async {
    return NotificationVoipPlugin.getVoIPToken();
  }

  // ──────────────────────────────────────────────
  // Push Notification Handling
  // ──────────────────────────────────────────────

  /// Parses a raw CometChat push payload and handles it end-to-end.
  ///
  /// This is the single entry point for processing all incoming push
  /// notifications. Call this from your FCM/APNs background handler
  /// with `remoteMessage.data`.
  ///
  /// Internally:
  /// 1. Parses the payload via [CometChatPayloadParser].
  /// 2. Applies optional overrides:
  ///    - If [title] is provided, it replaces the payload's title.
  ///    - If [icon] is provided, it replaces the notification icon/image.
  /// 3. Determines notification grouping:
  ///    - By default, notifications are grouped by `conversationId`.
  ///    - If [uid] is provided, notifications are grouped by that UID.
  ///    - If [guid] is provided, notifications are grouped by that GUID.
  ///    - [uid] and [guid] are mutually exclusive — if both are provided,
  ///      [guid] takes precedence.
  /// 4. Routes based on payload type:
  ///    - `type == "chat"` → maps to [NvpNotification] and displays it.
  ///    - `type == "call"` → delegates to internal call handling
  ///      (always uses custom Flutter call screen).
  ///
  /// Returns the parsed [CometChatPushPayload] for further app-level
  /// handling.
  static Future<CometChatPushPayload> handlePushNotification(
    Map<String, dynamic> messageData, {
    String? title,
    String? icon,
    String? uid,
    String? guid,
  }) async {
    _ensureInitialized();

    final payload = CometChatPayloadParser.parse(messageData);
    final details = payload.notificationDetails;

    if (details.isCall) {
      await handleCallNotification(messageData);
    } else if (details.isChat) {
      // Skip showing in-app chat notification if the app is in the
      // foreground and showInAppNotifications is disabled.
      final isForeground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (isForeground && !(_config?.showInAppNotifications ?? false)) {
        return payload;
      }

      String? groupKeyOverride;
      if (guid != null) {
        groupKeyOverride = guid;
      } else if (uid != null) {
        groupKeyOverride = uid;
      }

      final nvpNotification = CometChatMapper.toNvpNotification(
        details,
        titleOverride: title,
        iconOverride: icon,
        groupKeyOverride: groupKeyOverride,
      );

      await NotificationVoipPlugin.showNotification(nvpNotification);
    }

    return payload;
  }

  /// Shows a system notification from a pre-parsed
  /// [CometChatNotificationDetails].
  ///
  /// Useful when you've already parsed the payload and want to display it.
  static Future<bool> showNotificationFromDetails(
    CometChatNotificationDetails details, {
    NvpNotificationTemplate? template,
  }) async {
    _ensureInitialized();

    final nvpNotification = CometChatMapper.toNvpNotification(details);
    return NotificationVoipPlugin.showNotification(
      nvpNotification,
      template: template,
    );
  }

  /// Shows an in-app banner notification from a
  /// [CometChatNotificationDetails].
  static Future<bool> showInAppNotification(
    CometChatNotificationDetails details, {
    NvpNotificationTemplate? template,
  }) async {
    _ensureInitialized();

    final nvpNotification = CometChatMapper.toNvpNotification(details);
    return NotificationVoipPlugin.showInAppNotification(
      nvpNotification,
      template: template,
    );
  }

  /// Cancels a notification by its [tag] (the message ID from the payload).
  static Future<void> cancelNotification(String tag) async {
    _ensureInitialized();
    await NotificationVoipPlugin.cancelNotification(tag);
  }

  /// Clears all notifications.
  static Future<void> clearAll() async {
    _ensureInitialized();
    await NotificationVoipPlugin.clearAll();
  }

  // ──────────────────────────────────────────────
  // Badge Count
  // ──────────────────────────────────────────────

  /// Sets the app badge count.
  static Future<void> setBadgeCount(int count) async {
    _ensureInitialized();
    await NotificationVoipPlugin.setBadgeCount(count);
  }

  /// Gets the current app badge count.
  static Future<int> getBadgeCount() async {
    _ensureInitialized();
    return NotificationVoipPlugin.getBadgeCount();
  }

  // ──────────────────────────────────────────────
  // VoIP Call Handling
  // ──────────────────────────────────────────────

  /// Handles a CometChat call notification payload end-to-end.
  ///
  /// This is called internally by [handlePushNotification] when
  /// `type == "call"`. It can also be called directly if you have
  /// a raw call payload.
  ///
  /// It:
  /// 1. Parses the payload to extract call details.
  /// 2. For `callAction == "initiated"`:
  ///    - Shows a high-priority notification via
  ///      [NotificationVoipPlugin.showNotification] to ensure visibility
  ///      in background and killed states.
  ///    - Also attempts to show the custom Flutter call screen for
  ///      foreground state via [CometChatCallHandler.showIncoming].
  /// 3. For `callAction == "cancelled" | "ended" | "rejected" |
  ///    "busy" | "unanswered"`:
  ///    - Dismisses the active call UI for the given sessionId.
  ///    - Cancels the call notification.
  /// 4. For `callAction == "ongoing"`:
  ///    - Marks the call as connected.
  ///
  /// Throws [UnsupportedError] on web.
  ///
  /// Returns the parsed [CometChatCallDetails] for further app-level
  /// handling.
  static Future<CometChatCallDetails> handleCallNotification(
    Map<String, dynamic> payload,
  ) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();

    final parsed = CometChatPayloadParser.parse(payload);
    final details = parsed.notificationDetails;
    final callDetails = CometChatCallDetails.fromNotificationDetails(details);

    if (details.isIncomingCall) {
      // Check if the app is in the foreground and showInAppVoIP is disabled.
      final isForeground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (isForeground && !(_config?.showInAppVoIP ?? false)) {
        // Still emit the call event on the stream so the app can handle
        // it (e.g., show a custom in-app UI), but don't show the
        // system call notification or the default call screen.
        return callDetails;
      }

      // ignore: avoid_print
      print(
        '[CometChatPushNotifications] Showing call notification for '
        '${callDetails.callerName} (${callDetails.sessionId})',
      );

      // Show a full-screen call notification that works in all app states.
      try {
        final shown = await CometchatPushNotificationsPlatform.instance
            .showCallNotification(
              callId: callDetails.sessionId,
              callerName: callDetails.callerName,
              isVideo: callDetails.isVideo,
              callerAvatar: callDetails.callerAvatar,
            );
        // ignore: avoid_print
        print('[CometChatPushNotifications] Call notification shown: $shown');
      } catch (e) {
        // ignore: avoid_print
        print('[CometChatPushNotifications] Call notification failed: $e');
      }

      // Also try to show the Flutter call screen for foreground state.
      try {
        await CometChatCallHandler.showIncoming(callDetails);
      } catch (_) {
        // Silently ignore — notification is the fallback for bg/killed.
      }
    } else if (details.isCallDismissal) {
      await CometChatCallHandler.dismiss(callDetails.sessionId);
      // Cancel the call notification.
      await CometchatPushNotificationsPlatform.instance.cancelCallNotification(
        callDetails.sessionId,
      );
      // Close the dedicated locked-call screen if it's ringing (caller
      // cancelled/ended before answer). No-op if it isn't showing.
      try {
        await CometchatPushNotificationsPlatform.instance
            .dismissIncomingCallActivity();
      } catch (_) {}
    } else if (details.callAction == CometChatCallAction.ongoing) {
      await CometChatCallHandler.connect(callDetails.sessionId);
      // Cancel the call notification since call is now connected.
      await CometchatPushNotificationsPlatform.instance.cancelCallNotification(
        callDetails.sessionId,
      );
    }

    return callDetails;
  }

  /// Shows an incoming call UI from pre-parsed [CometChatCallDetails].
  ///
  /// Always uses the custom Flutter call screen provided via
  /// [CometChatNotificationConfig.customCallScreenBuilder].
  /// On iOS, also reports to CallKit for PushKit compliance.
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> showIncomingCall(CometChatCallDetails callDetails) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await CometChatCallHandler.showIncoming(callDetails);
  }

  /// Shows an outgoing call UI using the custom Flutter call screen.
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> showOutgoingCall(CometChatCallDetails callDetails) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await CometChatCallHandler.showOutgoing(callDetails);
  }

  /// Marks a call as connected (answered and media established).
  ///
  /// Call this after your WebRTC/media setup completes.
  /// This is critical for connecting calls from terminated state.
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> setCallConnected(String sessionId) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await CometChatCallHandler.connect(sessionId);
  }

  /// Ends a specific call by session ID.
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> endCall(String sessionId) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await CometChatCallHandler.dismiss(sessionId);
  }

  /// Ends all active calls. Useful on logout.
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> endAllCalls() async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await NotificationVoipPlugin.endAllCalls();
  }

  /// Returns the list of active call session IDs.
  ///
  /// Throws [UnsupportedError] on web.
  static Future<List<String>> getActiveCallIds() async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    return NotificationVoipPlugin.getActiveCallIds();
  }

  /// Toggles mute for a call.
  ///
  /// Delegates to the registered
  /// [CometChatCallActionHandler.onMuteToggled].
  /// By default, this calls [NotificationVoipPlugin.toggleMute].
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> toggleMute(
    String sessionId, {
    required bool isMuted,
  }) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await CometChatCallHandler.handleCallStateChange(
      NvpCallState(
        callId: sessionId,
        status: NvpCallStatus.connected,
        isMuted: isMuted,
      ),
    );
  }

  /// Toggles speaker for a call.
  ///
  /// Delegates to the registered
  /// [CometChatCallActionHandler.onSpeakerToggled].
  /// By default, this calls [NotificationVoipPlugin.toggleSpeaker].
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> toggleSpeaker(
    String sessionId, {
    required bool isOn,
  }) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await CometChatCallHandler.handleCallStateChange(
      NvpCallState(
        callId: sessionId,
        status: NvpCallStatus.connected,
        isSpeakerOn: isOn,
      ),
    );
  }

  /// Toggles camera for a video call.
  ///
  /// Delegates to the registered
  /// [CometChatCallActionHandler.onCameraToggled].
  /// By default, this calls [NotificationVoipPlugin.toggleCamera].
  ///
  /// Throws [UnsupportedError] on web.
  static Future<void> toggleCamera(
    String sessionId, {
    required bool isOn,
  }) async {
    PlatformGuard.ensureVoipSupported();
    _ensureInitialized();
    await CometChatCallHandler.handleCallStateChange(
      NvpCallState(
        callId: sessionId,
        status: NvpCallStatus.connected,
        isCameraOn: isOn,
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Call Action Handler
  // ──────────────────────────────────────────────

  /// Replaces the active [CometChatCallActionHandler] at runtime.
  ///
  /// Use this when the handler depends on objects not available at
  /// [init] time (e.g., a WebRTC engine created after joining a call).
  ///
  /// Pass `null` to reset to the default NVP-delegating handler.
  static set callActionHandler(CometChatCallActionHandler? handler) {
    if (handler != null) {
      CometChatCallHandler.actionHandler = handler;
    } else {
      CometChatCallHandler.configure();
    }
  }

  // ──────────────────────────────────────────────
  // Payload Parsing (for advanced use)
  // ──────────────────────────────────────────────

  /// Parses a raw CometChat push payload into a typed
  /// [CometChatPushPayload].
  ///
  /// Use this if you need to inspect the payload before deciding
  /// whether to show a notification or handle a call.
  static CometChatPushPayload parsePayload(Map<String, dynamic> payload) {
    return CometChatPayloadParser.parse(payload);
  }

  // ──────────────────────────────────────────────
  // Event Streams
  // ──────────────────────────────────────────────

  /// Stream of notification tap events.
  ///
  /// Emits the [CometChatNotificationDetails] of the tapped notification.
  /// Use this to navigate to the relevant conversation.
  static Stream<CometChatNotificationDetails> get onNotificationTap =>
      _notificationTapController.stream;

  /// Stream of call events (accepted, declined, ended, incoming,
  /// timeoutEnded).
  ///
  /// Emits [CometChatCallEvent] with the session ID and event type.
  /// Use this to coordinate with your call/media logic.
  static Stream<CometChatCallEvent> get onCallEvent =>
      _callEventController.stream;

  /// Stream of call state changes (mute, speaker, camera, status).
  ///
  /// Directly forwards [NotificationVoipPlugin.onCallStateChanged].
  static Stream<NvpCallState> get onCallStateChanged =>
      _callStateChangedController.stream;

  /// Stream of token refresh events.
  ///
  /// When a token refreshes, the plugin automatically re-registers it
  /// with CometChat servers. This stream notifies the app for
  /// logging/debugging.
  static Stream<String> get onTokenRefresh => _tokenRefreshController.stream;

  /// Stream of raw push payloads received in the foreground.
  ///
  /// Directly forwards [NotificationVoipPlugin.onPushReceived].
  static Stream<Map<String, dynamic>> get onPushReceived =>
      _pushReceivedController.stream;

  // ──────────────────────────────────────────────
  // Platform (Method Channel — retained)
  // ──────────────────────────────────────────────

  /// Returns the incoming call screen widget for the given [callDetails].
  ///
  /// - If [CometChatNotificationConfig.customCallScreenBuilder] was
  ///   provided, the builder is invoked with [callDetails] and the
  ///   consumer takes full control. They are responsible for accepting /
  ///   rejecting, cancelling the call notification, and popping the
  ///   screen.
  /// - Otherwise, the default [CometChatDefaultCallScreen] is returned
  ///   with Accept / Decline buttons that:
  ///   - Dismiss the native call notification.
  ///   - Pop the call screen off the navigator.
  ///   - Fire [CometChatNotificationConfig.onCallAccepted] /
  ///     [CometChatNotificationConfig.onCallDeclined].
  ///   - End the underlying NVP call on decline.
  static Widget buildCallScreen(CometChatCallDetails callDetails) {
    final config = _config;

    // Custom screen — consumer handles everything.
    final customBuilder = config?.customCallScreenBuilder;
    if (customBuilder != null) {
      return customBuilder(callDetails);
    }

    // Default screen — wire Accept / Decline handlers.
    final platform = CometchatPushNotificationsPlatform.instance;
    return Builder(
      builder: (context) {
        Future<void> popIfActive() async {
          final navigator = Navigator.of(context, rootNavigator: true);
          if (navigator.canPop()) {
            navigator.pop();
          }
        }

        Future<void> handleAccept() async {
          // Mark as handled to prevent double-fire from CallKit delegate.
          _handledCallActions.add(
            '${callDetails.sessionId}_${CometChatCallEventType.accepted.name}',
          );
          await platform.cancelCallNotification(callDetails.sessionId);
          await popIfActive();
          config?.onCallAccepted?.call(callDetails);
        }

        Future<void> handleDecline() async {
          // Mark as handled to prevent double-fire from CallKit delegate.
          _handledCallActions.add(
            '${callDetails.sessionId}_${CometChatCallEventType.declined.name}',
          );
          await platform.cancelCallNotification(callDetails.sessionId);
          await CometChatCallHandler.dismiss(callDetails.sessionId);
          await popIfActive();
          config?.onCallDeclined?.call(callDetails);
        }

        return CometChatDefaultCallScreen(
          callDetails: callDetails,
          onAccept: handleAccept,
          onDecline: handleDecline,
        );
      },
    );
  }

  /// Checks if the app was launched from an incoming call notification.
  ///
  /// If yes, navigates to the call screen using [navigatorKey]. Call this
  /// after your app's navigator is ready (typically in the first screen's
  /// `initState` or `didChangeDependencies`).
  ///
  /// Also sets up a handler for notification taps that arrive while the
  /// app is already running — so subsequent call notifications also route
  /// to the call screen.
  ///
  /// If [navigatorKey.currentState] is null, the check is skipped
  /// silently.
  static Future<void> handleIncomingCallLaunch(
    GlobalKey<NavigatorState> navigatorKey,
  ) async {
    final platform = CometchatPushNotificationsPlatform.instance;
    _navigatorKey = navigatorKey;

    Future<void> showCallScreen(Map<String, dynamic> details) async {
      // During a cold start (app launched from killed state by the call) the
      // navigator may not be ready for several seconds. Retry briefly instead
      // of bailing immediately, otherwise the call screen never shows.
      var navigator = navigatorKey.currentState;
      for (var i = 0; navigator == null && i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        navigator = navigatorKey.currentState;
      }
      if (navigator == null) return;

      // On iOS, when the app is genuinely in the foreground, CallEventService
      // handles call UI via WebSocket (IncomingCallOverlay) and the suppressed
      // VoIP push must not also push a call screen — suppress it here.
      //
      // This guard is iOS-only. On Android, showCallScreen('incoming') is only
      // ever reached from a real user tap on a background-posted notification,
      // or from the full-screen intent launching over the keyguard — in both
      // cases the app has just resumed (so isForeground is true) but there is
      // NO active overlay (foreground call arrivals never post a notification,
      // see handleCallNotification's foreground guard). Suppressing on Android
      // would leave the tap / lock-screen launch with no call UI at all.
      final isForeground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      final action = details['callAction'] as String?;
      if (Platform.isIOS &&
          isForeground &&
          action != 'answer' &&
          !(_config?.showInAppVoIP ?? false)) {
        return;
      }

      final callDetails = CometChatCallDetails(
        sessionId: details['callId'] as String? ?? '',
        callerUid: '',
        callerName: details['callerName'] as String? ?? 'Unknown',
        callerAvatar: details['callerAvatar'] as String?,
        callType: (details['isVideo'] as bool? ?? false)
            ? CometChatCallType.video
            : CometChatCallType.audio,
        receiverType: CometChatReceiverType.user,
        conversationId: '',
        isVideo: details['isVideo'] as bool? ?? false,
      );

      // Answer — pop any default call screen that was pushed by the
      // full-screen intent, then fire the accept callback so the consumer
      // can push their in-call screen.
      if (action == 'answer') {
        // Mark as handled to prevent double-fire from CallKit delegate.
        _handledCallActions.add(
          '${callDetails.sessionId}_${CometChatCallEventType.accepted.name}',
        );
        await platform.cancelCallNotification(callDetails.sessionId);
        // Pop back to the last non-call route (removes the default
        // CometChatDefaultCallScreen from the stack).
        navigator.popUntil((route) {
          final name = route.settings.name;
          return name != '/cometchat_call_screen';
        });
        _config?.onCallAccepted?.call(callDetails);
        return;
      }

      // For 'incoming' taps (or full-screen intent), show the call screen.
      // Note: 'decline' never reaches here because it's handled by the
      // native CallActionReceiver without launching the app.
      navigator.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/cometchat_call_screen'),
          builder: (_) => buildCallScreen(callDetails),
          fullscreenDialog: true,
        ),
      );
    }

    // Handle cold launch from a call notification.
    final launchDetails = await platform.getLaunchCallDetails();
    if (launchDetails != null) {
      // Delay to let the navigator settle.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showCallScreen(launchDetails);
      });
    }

    // Handle subsequent notification taps while the app is running.
    platform.setIncomingCallLaunchHandler(showCallScreen);
  }

  /// Cancels the system call notification for the given [sessionId].
  ///
  /// Custom call screens should call this after the user accepts or
  /// rejects the call so the system notification is dismissed. The
  /// default call screen calls this automatically.
  static Future<void> cancelCallNotification(String sessionId) async {
    await CometchatPushNotificationsPlatform.instance.cancelCallNotification(
      sessionId,
    );
  }

  // ──────────────────────────────────────────────
  // OEM Permissions (Android only)
  // ──────────────────────────────────────────────

  /// Returns the current state of Android permissions that affect
  /// call-screen visibility on locked or background devices.
  ///
  /// Map keys:
  /// - `fullScreenIntent`: Android 14+ full-screen intent permission
  /// - `overlay`: `SYSTEM_ALERT_WINDOW` (required on Xiaomi / MIUI to
  ///   wake the device over the lock screen)
  /// - `batteryOptimized`: whether the app is exempt from Doze mode
  ///
  /// On iOS and web, returns all permissions as granted.
  static Future<Map<String, bool>> checkCallPermissions() async {
    return CometchatPushNotificationsPlatform.instance.checkCallPermissions();
  }

  /// Opens the OEM-specific Autostart permission screen (Xiaomi / MIUI,
  /// Oppo, Vivo, Huawei, Samsung). Falls back to the generic app-details
  /// page if no OEM shortcut is available.
  ///
  /// Required on MIUI / Redmi / POCO to let the app launch an activity
  /// from a full-screen intent.
  static Future<bool> openAutoStartSettings() async {
    return CometchatPushNotificationsPlatform.instance.openAutoStartSettings();
  }

  /// Opens Android 14+ full-screen intent permission screen.
  static Future<bool> openFullScreenIntentSettings() async {
    return CometchatPushNotificationsPlatform.instance
        .openFullScreenIntentSettings();
  }

  /// Opens the "Display over other apps" permission screen. Required on
  /// Xiaomi / MIUI to show the call activity over the lock screen.
  static Future<bool> openOverlaySettings() async {
    return CometchatPushNotificationsPlatform.instance.openOverlaySettings();
  }

  /// Opens the battery optimization exemption request. Required so
  /// Android doesn't deprioritize the app's ability to start
  /// full-screen activities in the background.
  static Future<bool> openBatteryOptimizationSettings() async {
    return CometchatPushNotificationsPlatform.instance
        .openBatteryOptimizationSettings();
  }

  /// Returns the platform version string.
  Future<String?> getPlatformVersion() {
    return CometchatPushNotificationsPlatform.instance.getPlatformVersion();
  }
}

/// A CometChat call event emitted on the
/// [CometChatPushNotifications.onCallEvent] stream.
class CometChatCallEvent {
  /// The type of call event.
  final CometChatCallEventType type;

  /// The call session ID.
  final String sessionId;

  /// Optional extra data associated with the event.
  final Map<String, dynamic>? extraData;

  /// Creates a [CometChatCallEvent].
  const CometChatCallEvent({
    required this.type,
    required this.sessionId,
    this.extraData,
  });
}
