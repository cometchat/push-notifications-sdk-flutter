import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart' as calls;

import '../push/call_push_payload.dart';
import 'cometchat_voip_enums.dart';
import 'cometchat_voip_incoming_call_theme.dart';

/// How iOS presents a ringing call in CallKit.
///
/// Ignored on Android, where the call rings as a notification.
///
/// CallKit names the app with its `CFBundleDisplayName` unless
/// [localizedName] is set.
class CometChatCallKitOptions {
  /// The name CallKit shows for the app. Defaults to `CFBundleDisplayName`.
  final String? localizedName;

  /// An image in the app's asset catalog, drawn as a white-on-transparent
  /// template in the CallKit screen's corner button.
  final String? iconTemplateImageName;

  /// A sound file in the app bundle, played instead of the system ringtone.
  final String? ringtoneSound;

  /// Whether calls appear in the Phone app's Recents.
  final bool includesCallsInRecents;

  /// Whether CallKit offers video. Turn it off for an audio-only app.
  final bool supportsVideo;

  /// Creates a [CometChatCallKitOptions].
  const CometChatCallKitOptions({
    this.localizedName,
    this.iconTemplateImageName,
    this.ringtoneSound,
    this.includesCallsInRecents = true,
    this.supportsVideo = true,
  });

  /// The wire form read by the iOS side.
  Map<String, Object?> toMap() => {
    'localizedName': localizedName,
    'iconTemplateImageName': iconTemplateImageName,
    'ringtoneSound': ringtoneSound,
    'includesCallsInRecents': includesCallsInRecents,
    'supportsVideo': supportsVideo,
  };
}

/// Settings for `CometChatVoip.init`.
class CometChatVoipConfig {
  /// The CometChat app ID.
  final String appId;

  /// The CometChat region — `'us'`, `'eu'` or `'in'`.
  final String region;

  /// The push provider ID from the CometChat dashboard. Token registration
  /// fails without it until the backend can resolve the provider itself.
  final String? providerId;

  /// The auth token to register push tokens under.
  ///
  /// Leave it null: the package uses the Calls SDK's logged-in user. Set it
  /// only when that user is not the one whose device this is.
  final String? authToken;

  /// Replaces `{appId}.apiclient-{region}.cometchat.io/v3.0`, taking the same
  /// value as the Calls SDK's `overrideClientHost` — for a dedicated or staging
  /// deployment, whose app ID the default host does not know.
  final String? clientHost;

  /// The IANA time zone — `'Asia/Kolkata'`, say — registered with the push
  /// token, which the backend uses for quiet hours.
  ///
  /// Left out, the device's own zone is sent, read by the native plugin. A
  /// time zone is always sent, as the native SDKs send one.
  final String? timezone;

  /// Whether the push token is registered by itself whenever a user logs in to
  /// the Calls SDK.
  ///
  /// The token itself still has to reach this package: pass it to
  /// `CometChatVoip.registerPushToken`, or to `setPushToken`, once and it is
  /// remembered for the logins that follow.
  final bool autoRegisterPushToken;

  /// How long a call rings when its push does not say.
  ///
  /// The push's own `ringTimeout` wins whenever it carries one. Matches
  /// `defaultRingTimeoutMs` on both native SDKs.
  final Duration defaultRingTimeout;

  /// Who rings an incoming call: this package, or the app.
  ///
  /// See [CometChatCallMode]. With [CometChatCallMode.manual] the individual
  /// ring steps are available on `CometChatVoip.ringSurfaces`.
  final CometChatCallMode callMode;

  /// Whether Android posts a missed-call notification for a call nobody
  /// answered. iOS leaves the missed call in the Phone app's Recents instead.
  final bool showMissedCallNotification;

  /// Whether answering asks for the microphone, and the camera for a video
  /// call, when they have not been granted yet.
  ///
  /// A call answered from the lock screen is often the first time the app has
  /// run since install, and a denied microphone joins muted. Turn this off only
  /// when the app asks for both itself before any call can arrive.
  final bool requestCallPermissions;

  /// Whether [CometChatVoip.init] asks for notification permission, which
  /// Android 13+ needs before a call can ring.
  final bool requestNotificationPermission;

  /// The App Group the app shares with its Notification Service Extension, so
  /// the two see the same configuration and badge count. iOS only.
  final String? extensionGroupID;

  /// CallKit presentation on iOS.
  final CometChatCallKitOptions callKit;

  /// Whether a call that arrived late — past its ring window — is dropped
  /// rather than handed to the Calls SDK.
  ///
  /// FCM holds pushes while a device dozes, and ringing for a call that is
  /// already over is worse than not ringing. Turn it off only to debug
  /// delivery.
  final bool dropExpiredCalls;

  /// Whether CallKit owns the audio session on iOS, so WebRTC starts audio
  /// only once CallKit activates it.
  ///
  /// **A request, not a command.** Turning it on makes WebRTC wait to be told
  /// the session is live, and the only thing that can tell it is
  /// `CometChatAudioSession.activate` in the **native** Calls SDK — which this
  /// package does not link, and reaches through the Calls SDK's
  /// `notifyCallKitAudioActivated` instead.
  ///
  /// So `init` checks for that method before it turns the flag on, and leaves
  /// CallKit audio off on an SDK that lacks it: WebRTC then manages its own
  /// session and the call has sound, rather than ringing, connecting and being
  /// silent. Safe to set either way — `getDiagnostics()['callKitAudioHandoff']`
  /// says which happened. Ignored on Android.
  final bool callKitAudio;

  /// Whether answering also marks the call answered with CometChat — its
  /// status set to `ongoing`, as the Chat SDK's `acceptCall` does.
  ///
  /// A caller on the Calls SDK ringing flow sees the answer when this device
  /// joins, and needs nothing more. A caller still on the Chat SDK's calling —
  /// a UI Kit, web or React app — waits for that status before it joins, and
  /// without it rings on while this device sits alone in the call. Leave it on
  /// unless every caller is on the ringing flow.
  final bool acceptOnAnswer;

  /// The colours of the Android ring screen and call notifications, saved
  /// natively so a killed app's next ring uses them.
  ///
  /// Null keeps whatever theme was saved before: the background message
  /// handler calls `init` again on every push, without a theme, and must not
  /// wipe the app's. So dropping this field in a later release of the app does
  /// not clear a saved theme; call `CometChatVoip.setIncomingCallTheme(null)`
  /// for that. Ignored on iOS.
  final CometChatVoipIncomingCallTheme? incomingCallTheme;

  /// Creates a [CometChatVoipConfig].
  const CometChatVoipConfig({
    required this.appId,
    required this.region,
    this.providerId,
    this.authToken,
    this.clientHost,
    this.timezone,
    this.autoRegisterPushToken = true,
    this.defaultRingTimeout = const Duration(
      milliseconds: CallPushPayload.defaultRingTimeoutMs,
    ),
    this.callMode = CometChatCallMode.auto,
    this.showMissedCallNotification = true,
    this.requestCallPermissions = true,
    this.requestNotificationPermission = true,
    this.callKit = const CometChatCallKitOptions(),
    this.extensionGroupID,
    this.dropExpiredCalls = true,
    this.callKitAudio = false,
    this.acceptOnAnswer = true,
    this.incomingCallTheme,
  });

  /// The wire form handed to the native side, which persists it so a push
  /// that wakes a killed app can still ring.
  ///
  /// The auth token and provider ID stay in Dart: token registration happens
  /// there, and a credential is not worth writing to disk for nothing.
  Map<String, Object?> toMap() => {
    'appId': appId,
    'region': region,
    'clientHost': clientHost,
    'callMode': callMode.wireName,
    'defaultRingTimeoutMs': defaultRingTimeout.inMilliseconds,
    'showMissedCallNotification': showMissedCallNotification,
    'requestCallPermissions': requestCallPermissions,
    'requestNotificationPermission': requestNotificationPermission,
    'dropExpiredCalls': dropExpiredCalls,
    'callKit': callKit.toMap(),
    'extensionGroupID': extensionGroupID,
    // Only when set: an init without a theme keeps the saved one.
    if (incomingCallTheme != null)
      'incomingCallTheme': incomingCallTheme!.toMap(),
  };

  /// Builds a configuration from the Calls SDK settings the app already has,
  /// so the app ID and region are not typed twice and cannot drift apart.
  ///
  /// Mirrors `PNConfiguration.from(callAppSettings)` on Android and
  /// `PNConfigurationBuilder.from(appId:settings:)` on iOS.
  ///
  /// ```dart
  /// final settings = (CallAppSettingBuilder()
  ///       ..appId = 'APP_ID'
  ///       ..region = 'us').build();
  /// CometChatCalls.init(settings, onSuccess: (_) {}, onError: (_) {});
  /// await CometChatVoip.init(
  ///   CometChatVoipConfig.fromCallAppSettings(settings,
  ///       providerId: 'PROVIDER_ID'),
  /// );
  /// ```
  ///
  /// Throws [ArgumentError] when [settings] carries no app ID or region.
  factory CometChatVoipConfig.fromCallAppSettings(
    calls.CallAppSettings settings, {
    String? providerId,
    String? authToken,
    String? timezone,
    bool autoRegisterPushToken = true,
    Duration defaultRingTimeout = const Duration(
      milliseconds: CallPushPayload.defaultRingTimeoutMs,
    ),
    CometChatCallMode callMode = CometChatCallMode.auto,
    bool showMissedCallNotification = true,
    bool requestCallPermissions = true,
    bool requestNotificationPermission = true,
    CometChatCallKitOptions callKit = const CometChatCallKitOptions(),
    String? extensionGroupID,
    bool dropExpiredCalls = true,
    bool callKitAudio = false,
    bool acceptOnAnswer = true,
    CometChatVoipIncomingCallTheme? incomingCallTheme,
  }) {
    final appId = settings.appId;
    final region = settings.region;
    if (appId == null || appId.isEmpty || region == null || region.isEmpty) {
      throw ArgumentError.value(
        settings,
        'settings',
        'CallAppSettings needs an appId and a region',
      );
    }
    return CometChatVoipConfig(
      appId: appId,
      region: region,
      providerId: providerId,
      authToken: authToken,
      // The Calls SDK's own override, so one value serves both.
      clientHost: settings.clientHost,
      timezone: timezone,
      autoRegisterPushToken: autoRegisterPushToken,
      defaultRingTimeout: defaultRingTimeout,
      callMode: callMode,
      showMissedCallNotification: showMissedCallNotification,
      requestCallPermissions: requestCallPermissions,
      requestNotificationPermission: requestNotificationPermission,
      callKit: callKit,
      extensionGroupID: extensionGroupID,
      dropExpiredCalls: dropExpiredCalls,
      callKitAudio: callKitAudio,
      acceptOnAnswer: acceptOnAnswer,
      incomingCallTheme: incomingCallTheme,
    );
  }
}
