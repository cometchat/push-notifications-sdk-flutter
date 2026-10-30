# 2.0.0

The first release. Incoming CometChat calls for Flutter, as their own package:
the calling half of `cometchat_push_notifications` 1.x, versioned alongside its
2.0.0. Calls ring the way the phone's own calls do — through CallKit on iOS and
as a full-screen call notification on Android — with the app in the
foreground, in the background or killed. The package has its own Kotlin and
Swift, ported from the native push-notifications SDKs, and declares one
dependency, `cometchat_calls_sdk` 5.1.0. It needs iOS 15.1 and Android
`minSdk` 26.

## New
- **Three ways to take an incoming call**, as `CometChatCallMode`:
  - `auto` (the default): the package rings — the notification, the
    ringtone, the expiry, the keep-alive, and Answer and Decline from the
    lock screen.
  - `autoCustomScreen`: everything `auto` does, except that the ring's
    full-screen alert and its tap open the app, which draws its own ring
    screen from `CometChatVoip.onRingScreenRequested`. Held until the screen
    subscribes, so a cold-start ring is not missed. Android only; iOS rings in
    CallKit, as it must.
  - `manual`: the package parses, gates and forwards, and the app rings.
    `CometChatVoip.ringSurfaces` offers each step of `auto` on its own
    (Android).
- iOS: the package owns the PushKit registry and the `CXProvider`, and
  reports every VoIP push to CallKit before acknowledging it. Presentation is
  set with `CometChatCallKitOptions`.
- Android: a CallStyle notification with Answer and Decline, full screen over
  the lock screen, held by a `phoneCall` foreground service until the answered
  call joins. A decline tapped after the app was killed is sent from a
  headless isolate.
- The call connects while it rings, so answering only adds media.
- **Call waiting.** A second call rings over the live one and says that
  answering ends it ("End & accept"); declining it sends `busy`. A third call,
  or one that arrives while this device's own outgoing call is still ringing,
  is refused as `busy` and shown as a missed call (Android).
- **Ring gates**, as on the native SDKs: a call this user placed, a
  one-to-one call addressed to someone else, a duplicate and a call already
  over never ring. A call that arrives past its ring window is dropped
  (`dropExpiredCalls`). `RingGate` and `TerminalLedger` are exported.
- Durable declines: WorkManager on Android, a background task with replay on
  iOS. A one-to-one ring that times out sends `unanswered`; a group call
  declined or timed out ends locally and carries on for the other members.
- A caller is told how its call ended: a decline, busy or cancel reaches the
  caller's `IncomingCallListener` through the Calls SDK.
- Missed calls: a notification on Android (`showMissedCallNotification`),
  Recents on iOS.
- iOS: calls this device places are on CallKit too, from the moment they are
  placed — a Recents entry whether or not anyone answers, a hang-up from the
  lock screen while the callee still rings (`onOutgoingCallEnded`), and
  survival of a cellular call. `reportOutgoingCall` names the callee and the
  call type; a session the Calls SDK owns that CallKit has not heard of is
  reported by the package itself and renamed when a participant connects.
- `onCallRinging`, `onCallAnswered` and `onCallEnded`, holding the answer that
  launched the app until something listens. Every ringing call also reaches
  the Calls SDK's `IncomingCallListener`.
- `answer`, `accept`, `decline`, `dismissRinging` and `getActiveCall`.
  `permissionsToAnswer` and `requestCallPermissions` cover the microphone,
  and the camera for video; `answer` asks by itself when
  `requestCallPermissions` is on.
- `reportOutgoingCall`, `reportCallConnected`, `reportCallEnded`,
  `reportMuted` and `reportVideoPaused` keep CallKit in step with the call.
  They are optional: the package follows the Calls SDK's session and media
  events itself.
- Push tokens register on every Calls SDK login, with no Chat SDK:
  `registerPushToken`, `setPushToken`, `handleTokenRefresh`,
  `handleRegistrationFailure`, `unregisterPushToken`, and `getVoipToken` on
  iOS. Each registration carries `ringingFlowVersion: "v2"` and a `timezone`,
  as the native SDKs send them; a device that cannot name its zone sends a
  fixed-offset zone from its UTC offset (or `UTC`) rather than nothing.
- `acceptOnAnswer` marks an answered call `ongoing`, which a caller on the
  Chat SDK's calling waits for.
- Setup checks: `verifyPushSetup`, `checkRingReadiness`, `openSettings`,
  `requestNotificationPermission`, `lastWakeTiming`, and `getDiagnostics` — a
  redacted snapshot for a bug report.
- `CometChatVoipConfig.fromCallAppSettings` builds the config from the Calls
  SDK settings the app already has. Also configurable: `defaultRingTimeout`,
  `timezone`, `clientHost`, `extensionGroupID` and `callKitAudio`.
- `CometChatVoipCall` carries `source`, `extras` and `initials`.
- `CometChatVoipIncomingCallTheme` styles the Android ring screen and the call
  notifications, with a light, dark or system colour set.
- A privacy manifest for iOS.

## Fixes

- **After the app died mid-call, every later call rang as call waiting
  (both platforms).** The store outlives the process, so a call answered
  before a crash or a swipe-away stayed recorded as answered with nothing
  left to report its end; the next call then rang over it ("Answering ends
  your current call"), and that dead call came back into the active slot
  each time the new one ended. Before ringing, an answered call — active or
  held — that the Calls SDK is not in a session for, and that was answered
  more than the answer-to-joined window ago (20 s), is now dropped as over.
  The same fix as push-notifications-sdk-ios #6 and the Android SDK's
  hand-off check. Android also forgets a held call when the app ends it.

## Known limitations
- `callKitAudio` does nothing until a Calls SDK carrying
  `notifyCallKitAudioActivated` is published. `init` checks for it and leaves
  CallKit audio off without it, so a call never goes silent;
  `getDiagnostics()['callKitAudioHandoff']` says which you got.
- One `PKPushRegistry` per app. A second one takes the VoIP pushes and those
  calls never ring; use `CometChatCallMode.manual` to own it yourself.
- CallKit and PushKit need a real iPhone: a simulator never receives a VoIP
  push.
