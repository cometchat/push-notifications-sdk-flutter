import '../push/call_push_payload.dart';
import 'cometchat_voip_call.dart';

/// How a call reached this device.
enum CometChatCallSource {
  /// A push notification. Everything this package handles arrives this way.
  push('PUSH'),

  /// The Calls SDK's own websocket, for a call that arrived while connected.
  webSocket('WEBSOCKET');

  const CometChatCallSource(this.wireName);

  /// The name the native SDKs use.
  final String wireName;

  /// The source named [wire], or [push].
  static CometChatCallSource fromWire(String? wire) {
    final value = wire?.trim().toUpperCase();
    return values.firstWhere(
      (source) => source.wireName == value,
      orElse: () => push,
    );
  }
}

/// Why a call stopped ringing.
///
/// The same vocabulary on both platforms, whatever the push or the Calls SDK
/// called it.
enum CometChatCallEndReason {
  /// Answered on another of this user's devices.
  answeredElsewhere('answeredElsewhere'),

  /// The caller hung up before anyone answered. A missed call.
  cancelled('cancelled'),

  /// Declined on this device.
  declined('declined'),

  /// Nobody answered within the ring window. A missed call.
  timedOut('timedOut'),

  /// The other side ended the call, or the caller's device reported it over.
  remoteEnded('remoteEnded'),

  /// The call could not be set up or kept going.
  failed('failed'),

  /// Dropped before it rang: a duplicate, a stale push, or filtered by the OS.
  filtered('filtered');

  const CometChatCallEndReason(this.wireName);

  /// The name this package reports.
  final String wireName;

  /// Whether the user missed this call.
  bool get isMissed =>
      this == CometChatCallEndReason.cancelled ||
      this == CometChatCallEndReason.timedOut;

  /// The reason named [wire], or [remoteEnded] for one this version does not
  /// know.
  ///
  /// Reads both vocabularies the Calls SDK reports, which differ per platform:
  /// Android sends the call status (`cancelled`, `rejected`, `busy`, `ended`,
  /// `unanswered`, `ongoing`), iOS sends a CallKit reason (`answeredElsewhere`,
  /// `declined`, `timedOut`, `remoteEnded`, `failed`, `filtered`).
  static CometChatCallEndReason fromWire(String? wire) {
    final value = wire?.trim().toLowerCase();
    if (value == null || value.isEmpty) return remoteEnded;
    for (final reason in values) {
      if (reason.wireName.toLowerCase() == value) return reason;
    }
    return fromAction(CometChatCallAction.fromWire(value));
  }

  /// The reason a terminal push ends the ringing with.
  ///
  /// `ended` for a call still ringing is the caller's device saying it is over:
  /// not a missed call.
  static CometChatCallEndReason fromAction(
    CometChatCallAction action,
  ) => switch (action) {
    CometChatCallAction.cancelled => cancelled,
    CometChatCallAction.unanswered || CometChatCallAction.timedOut => timedOut,
    CometChatCallAction.ongoing => answeredElsewhere,
    CometChatCallAction.rejected ||
    CometChatCallAction.busy ||
    CometChatCallAction.ended => declined,
    CometChatCallAction.initiated || CometChatCallAction.unknown => remoteEnded,
  };
}

/// A call that ended, and why.
class CometChatCallEnded {
  /// The call.
  final CometChatVoipCall call;

  /// Why it ended.
  final CometChatCallEndReason reason;

  /// Creates a [CometChatCallEnded].
  const CometChatCallEnded({required this.call, required this.reason});

  @override
  String toString() => 'CometChatCallEnded(${call.sessionId}, ${reason.name})';
}

/// What `CometChatVoip.verifyPushSetup` found.
///
/// Mirrors `PushSetupResult` on both native SDKs, minus the cases that need a
/// test push the backend has to send.
enum CometChatPushSetupResult {
  /// Everything this package can check is in order.
  ok,

  /// `CometChatVoip.init` has not run.
  notInitialized,

  /// Nobody is logged in to the Calls SDK, and no auth token is configured, so
  /// a token cannot be registered against a user.
  notLoggedIn,

  /// No push token has reached this package, so nothing could be registered.
  /// On iOS the app's `PKPushRegistry` has not handed one over; on Android the
  /// FCM token has not been passed in.
  tokenNotRegistered,

  /// A token was handed over but its registration has not succeeded.
  tokenRegistrationFailed,

  /// Notifications are blocked for the app, so nothing can ring on Android.
  notificationsBlocked,

  /// Something on this device would stop a call ringing.
  /// `CometChatVoip.checkRingReadiness` names which.
  ringNotReady,
}

/// Something on this device that would stop a call from ringing.
///
/// Each of these silences calls without any error, which is why
/// `CometChatVoip.checkRingReadiness` names them.
enum CometChatRingReadiness {
  /// Nothing is in the way.
  ready('ready'),

  /// Android: notifications are off for the app, so nothing can ring.
  notificationsOff('notificationsOff'),

  /// Android: the user lowered the incoming-call channel, so it no longer
  /// rings or shows full screen.
  channelMuted('channelMuted'),

  /// Android 14+: the app may not use full-screen intents, so a call on a
  /// locked device shows as a notification rather than the ring screen.
  fullScreenIntentDenied('fullScreenIntentDenied'),

  /// Android: Do Not Disturb is filtering calls.
  doNotDisturb('doNotDisturb'),

  /// iOS: `UIBackgroundModes` lacks `voip`, so PushKit cannot wake a killed
  /// app.
  backgroundModeMissing('backgroundModeMissing'),

  /// iOS: the build has no `aps-environment` entitlement, so iOS issues no
  /// VoIP token.
  voipEntitlementMissing('voipEntitlementMissing'),

  /// The microphone was denied: an answered call joins muted.
  microphoneDenied('microphoneDenied');

  const CometChatRingReadiness(this.wireName);

  /// The name the native side uses.
  final String wireName;

  /// The readiness named [wire], or [ready] for one this version does not know.
  static CometChatRingReadiness fromWire(String? wire) => values.firstWhere(
    (readiness) => readiness.wireName == wire,
    orElse: () => ready,
  );
}

/// Who rings an incoming call.
///
/// Mirrors `CallMode` on Android and, for the PushKit half, `PushKitOwnership`
/// on iOS.
enum CometChatCallMode {
  /// This package rings: the notification, the full-screen intent, the
  /// ringtone, connect-while-ringing, the expiry, the keep-alive and the
  /// decline queue, including the package's own full-screen ring screen. On
  /// iOS it also owns the `PKPushRegistry`. The app supplies an answer screen
  /// and nothing else. The default.
  auto('auto'),

  /// Everything [auto] does, except that the ring's full-screen alert and its
  /// tap open the **app's** Flutter screen rather than the package's native
  /// one. The notification, the ringtone, the gates, the expiry, the
  /// keep-alive, the busy handling and the notification's own Answer and
  /// Decline buttons are all still the package's.
  ///
  /// `CometChatVoip.onRingScreenRequested` is where the app's screen comes up;
  /// `CometChatVoip.answer` and `CometChatVoip.decline` are its buttons, and
  /// `CometChatVoip.onCallEnded` is when it closes. Mirrors Android's
  /// `PNConfiguration.setIncomingCallActivity(...)`.
  ///
  /// A Flutter screen takes an engine to draw, and a native one does not, so
  /// this rings a fraction slower than [auto] on a process the push created.
  /// iOS rings in CallKit, which is the only incoming-call UI iOS allows, so
  /// there this is [auto].
  autoCustomScreen('autoCustomScreen'),

  /// This package parses, gates and forwards only. It never rings and never
  /// calls the Calls SDK on its own: `onCallRinging` is the app's trigger, and
  /// the individual steps are available à la carte on
  /// `CometChatVoip.ringSurfaces`. On iOS the app owns the `PKPushRegistry`
  /// and forwards pushes with `handlePushNotification`.
  ///
  /// The busy handling goes with the ring: a second call does not ring over a
  /// live one and a third is not refused for you. So does the "Ringing…" the
  /// caller sees, unless the app calls `ringSurfaces.verify`.
  manual('manual');

  const CometChatCallMode(this.wireName);

  /// The name the native side uses.
  final String wireName;

  /// The mode named [wire], or [auto].
  static CometChatCallMode fromWire(String? wire) =>
      values.firstWhere((mode) => mode.wireName == wire, orElse: () => auto);
}

/// A runtime permission answering a call needs.
///
/// What `CometChatVoip.permissionsToAnswer` reports and
/// `CometChatVoip.requestCallPermissions` asks for. A call answered from the
/// lock screen is often the first time the app has run since install, and a
/// denied microphone joins the call muted with no error anywhere.
enum CometChatCallPermission {
  /// Android `RECORD_AUDIO`, iOS `NSMicrophoneUsageDescription`. Every call.
  microphone('microphone'),

  /// Android `CAMERA`, iOS `NSCameraUsageDescription`. Video calls only.
  camera('camera');

  const CometChatCallPermission(this.wireName);

  /// The name the native side uses.
  final String wireName;

  /// The permission named [wire], or null for one this version does not know.
  static CometChatCallPermission? fromWire(String? wire) {
    final value = wire?.trim();
    for (final permission in values) {
      if (permission.wireName == value) return permission;
    }
    return null;
  }
}
