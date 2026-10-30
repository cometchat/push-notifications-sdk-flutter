import 'dart:async';
import 'dart:convert';

import 'package:cometchat_sdk/cometchat_sdk.dart' as sdk;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

import 'cometchat_push_notifications_platform_interface.dart';
import 'src/errors/cometchat_notification_exception.dart';
import 'src/models/cometchat_enums.dart';
import 'src/models/cometchat_notification_config.dart';
import 'src/models/cometchat_notification_details.dart';
import 'src/models/cometchat_notification_response.dart';
import 'src/models/cometchat_push_payload.dart';
import 'src/parser/cometchat_payload_parser.dart';
import 'src/token/push_token_transport_io.dart'
    if (dart.library.js_interop) 'src/token/push_token_transport_web.dart'
    as transport;

/// Chat push notifications for CometChat.
///
/// The package owns what only native code can do — posting the Android
/// notification, the iOS foreground presentation decision, the badge — and
/// registers push tokens with CometChat itself, under the Chat SDK's login. It
/// leans on `cometchat_sdk` for that login and for delivery receipts.
///
/// It deliberately does not own the push transport. Whichever library already
/// delivers pushes to the app (`firebase_messaging` on Android, and on iOS
/// either that or APNs directly) keeps doing so, and hands each payload to
/// [handlePushNotification]. Claiming Android's `FirebaseMessagingService`
/// would take it away from an app that already has one.
///
/// ```dart
/// await CometChatPushNotifications.init(
///   const CometChatNotificationConfig(appId: 'APP_ID', region: 'us'),
/// );
/// await CometChatPushNotifications.requestPermission();
///
/// // After the CometChat login completes.
/// final token = await FirebaseMessaging.instance.getToken();
/// await CometChatPushNotifications.registerPushToken(token: token);
///
/// FirebaseMessaging.onMessage.listen(
///   (m) => CometChatPushNotifications.handlePushNotification(m.data),
/// );
/// ```
///
/// Calling moved to its own package, `cometchat_voip`, in 2.0. A call push
/// still parses here and [handlePushNotification] reports it unhandled, so it
/// can be passed on to `CometChatVoip.handlePushNotification`.
class CometChatPushNotifications {
  /// Creates a [CometChatPushNotifications] instance.
  ///
  /// Only needed for the [getPlatformVersion] instance method; everything else
  /// is static.
  const CometChatPushNotifications();

  static CometChatNotificationConfig? _config;

  /// Sends one push token request and returns its status code and body:
  /// `dart:io` on Android and iOS, the browser's `fetch` on web.
  static Future<(int, String)> Function(
    String method,
    Uri url,
    Map<String, String> headers,
    String? body,
  )
  _sendTokenRequest = transport.sendRequest;

  /// The auth token of the user logged in to the Chat SDK.
  static Future<String?> Function() _chatAuthToken =
      sdk.CometChat.getUserAuthToken;

  /// The body this process last registered, so [unregisterPushToken] can
  /// name the token.
  static Map<String, Object>? _registeredBody;

  /// Replaces the token transport and the auth token source, for tests.
  @visibleForTesting
  static void debugSetTokenTransport({
    Future<(int, String)> Function(
      String method,
      Uri url,
      Map<String, String> headers,
      String? body,
    )?
    send,
    Future<String?> Function()? authToken,
  }) {
    _sendTokenRequest = send ?? transport.sendRequest;
    _chatAuthToken = authToken ?? sdk.CometChat.getUserAuthToken;
    _registeredBody = null;
  }

  static CometchatPushNotificationsPlatform get _platform =>
      CometchatPushNotificationsPlatform.instance;

  /// The configuration [init] was called with, or null before then.
  static CometChatNotificationConfig? get config => _config;

  /// Whether [init] has run.
  static bool get isInitialized => _config != null;

  static CometChatNotificationConfig _requireConfig() {
    final config = _config;
    if (config == null) {
      throw const CometChatNotificationException(
        code: CometChatErrorCode.notInitialized,
        message: 'CometChatPushNotifications.init() must be called before use.',
      );
    }
    return config;
  }

  // ──────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────

  /// Initializes the package. Call once, before anything else.
  ///
  /// Creates the Android notification channel, so it exists before the first
  /// push lands.
  static Future<void> init(CometChatNotificationConfig config) async {
    _config = config;
    await _platform.initialize(config);

    // Start the tap stream collecting now. A tap that launched the app from a
    // cold start is already waiting on the native side, and it is held until
    // the app subscribes rather than being released to nobody.
    _platform.onNotificationTap;
  }

  /// Releases the package's state.
  ///
  /// Delivered notifications are left alone: the user dismisses those.
  static Future<void> dispose() async {
    _config = null;
    _registeredBody = null;
  }

  /// The OS name and version, for diagnostics.
  Future<String?> getPlatformVersion() => _platform.getPlatformVersion();

  // ──────────────────────────────────────────────
  // Permission
  // ──────────────────────────────────────────────

  /// Prompts for notification permission, returning whether it was granted.
  ///
  /// The OS shows the prompt only once per install; later calls return the
  /// standing answer without showing anything. Ask at a point where the app has
  /// explained why it needs notifications, not on first launch.
  static Future<bool> requestPermission() => _platform.requestPermission();

  /// Whether notifications are currently permitted.
  static Future<bool> isPermissionGranted() => _platform.isPermissionGranted();

  // ──────────────────────────────────────────────
  // Token registration
  // ──────────────────────────────────────────────

  /// Registers this device's push token with CometChat.
  ///
  /// Call after the CometChat login completes — the token is registered against
  /// the logged-in user, so registering earlier has nothing to attach it to.
  ///
  /// [token] is the token your messaging library holds. It may be omitted only
  /// on a direct-APNs iOS app, where the package registers with APNs itself and
  /// uses the device token it gets back.
  ///
  /// [platform] defaults to APNs on iOS, FCM elsewhere. Pass it explicitly if
  /// that is not where your token came from — an iOS app using
  /// `firebase_messaging` holds an FCM token and must register as
  /// [PushPlatform.FCM_FLUTTER_IOS], or CometChat sends its pushes to a
  /// provider that has never heard of the device.
  ///
  /// The request carries `ringingFlowVersion: "v2"` and the device's time
  /// zone, as the native Android and iOS SDKs send them.
  ///
  /// Returns the server's response. Throws a [CometChatNotificationException]
  /// when nobody is logged in to the Chat SDK or the server refuses the token.
  static Future<String?> registerPushToken({
    String? token,
    PushPlatform? platform,
    String? providerId,
  }) async {
    final config = _requireConfig();

    final target = platform ?? _defaultPlatform();
    final resolved =
        token ??
        (target == PushPlatform.APNS_FLUTTER_DEVICE
            ? await getApnsToken()
            : null);
    if (resolved == null || resolved.isEmpty) {
      throw CometChatNotificationException(
        code: CometChatErrorCode.tokenRegistrationFailed,
        message: target == PushPlatform.APNS_FLUTTER_DEVICE
            ? 'No APNs token available. Grant notification permission first, '
                  'or pass a token explicitly.'
            : 'A push token is required for $target. Pass the token from your '
                  'messaging library.',
      );
    }

    // Sent directly rather than through the Chat SDK's
    // CometChatNotifications.registerPushToken, whose body cannot carry
    // ringingFlowVersion, as the native 2.0 SDKs do.
    final body = <String, Object>{
      target.isFcm ? 'fcmToken' : 'deviceToken': resolved,
      'platform': switch (target) {
        PushPlatform.FCM_FLUTTER_ANDROID => 'fcm_flutter_android',
        PushPlatform.FCM_FLUTTER_IOS => 'fcm_flutter_ios',
        PushPlatform.APNS_FLUTTER_DEVICE => 'apns_flutter_device',
        PushPlatform.FCM_WEB => 'fcm_web',
      },
      'timezone': timeZoneFor(
        DateTime.now().timeZoneName,
        DateTime.now().timeZoneOffset,
      ),
      if (providerId != null && providerId.isNotEmpty) 'providerId': providerId,
      'ringingFlowVersion': 'v2',
    };
    final response = await _tokenRequest(config, 'POST', body);
    _registeredBody = body;
    return response;
  }

  /// Unregisters this device's push token, stopping further pushes to it.
  ///
  /// Call before logging the user out, while the session that owns the token
  /// still exists.
  static Future<String?> unregisterPushToken() async {
    final config = _requireConfig();
    // The token this process registered; with none (a logout after a restart)
    // the session's token is removed without naming it, as the Chat SDK did.
    final response = await _tokenRequest(config, 'DELETE', _registeredBody);
    _registeredBody = null;
    return response;
  }

  /// The IANA zone sent with the token, always: [name] when the platform
  /// gives one, otherwise the fixed-offset zone for a whole-hour [offset] —
  /// `Etc/GMT-1` for UTC+1, the sign inverted as POSIX names it — or `UTC`
  /// (UTC+5:30 has no fixed-offset zone).
  @visibleForTesting
  static String timeZoneFor(String name, Duration offset) {
    if (name.contains('/')) return name;
    final minutes = offset.inMinutes;
    if (minutes == 0 || minutes % 60 != 0) return 'UTC';
    final hours = minutes ~/ 60;
    if (hours < -12 || hours > 14) return 'UTC';
    return hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
  }

  /// `POST`/`DELETE https://{appId}.apiclient-{region}.cometchat.io/v3.0/notifications/push/v1/tokens`,
  /// under the Chat SDK's auth token.
  static Future<String> _tokenRequest(
    CometChatNotificationConfig config,
    String method,
    Map<String, Object>? body,
  ) async {
    String? authToken;
    try {
      authToken = await _chatAuthToken();
    } catch (_) {}
    if (authToken == null || authToken.isEmpty) {
      throw const CometChatNotificationException(
        code: CometChatErrorCode.tokenRegistrationFailed,
        message:
            'Nobody is logged in to the Chat SDK. Register the push token '
            'after CometChat.login completes.',
      );
    }
    final url = Uri.parse(
      'https://${config.appId}.apiclient-${config.region}.cometchat.io'
      '/v3.0/notifications/push/v1/tokens',
    );
    final int status;
    final String response;
    try {
      (status, response) = await _sendTokenRequest(method, url, {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'appId': config.appId,
        'authToken': authToken,
        // The backend refuses every request without it.
        'chatApiVersion': 'v3.0',
      }, body == null ? null : jsonEncode(body));
    } catch (e) {
      throw CometChatNotificationException(
        code: CometChatErrorCode.tokenRegistrationFailed,
        message: '$method push token failed: $e',
        cause: e,
      );
    }
    if (status < 200 || status >= 300) {
      throw CometChatNotificationException(
        code: CometChatErrorCode.tokenRegistrationFailed,
        message:
            'HTTP $status from the push token endpoint: '
            '${response.length > 500 ? response.substring(0, 500) : response}',
      );
    }
    return response;
  }

  /// Registers with APNs and returns the device token as lowercase hex.
  ///
  /// iOS only; returns null elsewhere. Resolves to null if permission has not
  /// been granted, since APNs issues no token without it.
  static Future<String?> getApnsToken() => _platform.getApnsToken();

  /// The platform to register against when the caller did not name one.
  ///
  /// Read from [defaultTargetPlatform] rather than `dart:io`, which does not
  /// exist on web. On web that reports the browser's host OS, which says
  /// nothing about how pushes reach it — so a web caller names the platform and
  /// supplies the token.
  static PushPlatform _defaultPlatform() {
    if (kIsWeb) return PushPlatform.FCM_WEB;
    return defaultTargetPlatform == TargetPlatform.iOS
        ? PushPlatform.APNS_FLUTTER_DEVICE
        : PushPlatform.FCM_FLUTTER_ANDROID;
  }

  // ──────────────────────────────────────────────
  // Incoming pushes
  // ──────────────────────────────────────────────

  /// Handles one push payload, returning whether this package took it.
  ///
  /// A chat payload is marked delivered and — on Android — posted as a
  /// notification. False means the payload was not a chat push (a call push, or
  /// something else entirely) and is still yours to handle.
  ///
  /// Only Android posts a notification from this: the iOS implementation is a
  /// no-op there, because the APNs alert already showed one and a second would
  /// duplicate it.
  static Future<bool> handlePushNotification(
    Map<String, dynamic> payload,
  ) async {
    final config = _requireConfig();

    final CometChatPushPayload parsed;
    try {
      parsed = CometChatPayloadParser.parse(payload);
    } on CometChatNotificationException {
      return false;
    }

    final details = parsed.notificationDetails;
    if (!details.isChat) return false;

    // The notification first: it is what the user is waiting for, and a slow
    // receipt should not hold it up.
    await _platform.showNotification(details);
    if (config.sendDeliveryReceipts) {
      await _markDelivered(details);
    }
    return true;
  }

  /// Tells the package which conversation is on screen.
  ///
  /// Pushes for it are dropped rather than shown, since the user is already
  /// reading it. Call with no arguments when leaving the chat.
  static Future<void> setActiveConversation({
    String? id,
    CometChatPushReceiverType? receiverType,
  }) => _platform.setActiveConversation(
    id: id,
    receiverType: receiverType == null || receiverType.name == 'unknown'
        ? null
        : receiverType.name,
  );

  /// Cancels the notification for [conversationId], or every notification this
  /// package posted when it is omitted.
  ///
  /// Notifications the app posted itself are never touched.
  static Future<void> clearNotifications({String? conversationId}) =>
      _platform.cancelNotifications(conversationId: conversationId);

  // ──────────────────────────────────────────────
  // Badge
  // ──────────────────────────────────────────────

  /// Sets the app icon badge. iOS only; a no-op on Android, which has no
  /// OS-level badge.
  static Future<void> setBadgeCount(int count) =>
      _platform.setBadgeCount(count);

  /// Reads the app icon badge. iOS only; returns 0 on Android.
  static Future<int> getBadgeCount() => _platform.getBadgeCount();

  // ──────────────────────────────────────────────
  // User responses
  // ──────────────────────────────────────────────

  /// Notification taps, carrying the conversation that was tapped.
  ///
  /// A tap that launched the app from a cold start is held until a listener
  /// attaches, so it survives the race between the launch intent and Dart
  /// starting up.
  static Stream<CometChatNotificationResponse> get onNotificationTap =>
      _platform.onNotificationTap;

  static Future<void> _markDelivered(
    CometChatNotificationDetails details,
  ) async {
    final messageId = int.tryParse(details.tag);
    if (messageId == null || details.sender.isEmpty) return;

    await sdk.CometChat.markAsDelivered(
      sdk.TextMessage(
        text: details.body,
        id: messageId,
        sender: sdk.User(uid: details.sender, name: details.senderName),
        receiverUid: details.receiver,
        receiverType: details.receiverType == CometChatPushReceiverType.group
            ? sdk.CometChatReceiverType.group
            : sdk.CometChatReceiverType.user,
        type: sdk.CometChatMessageType.text,
      ),
      onSuccess: (_) {},
      onError: (_) {},
    );
  }
}
