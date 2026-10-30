<p align="center">
  <img alt="CometChat" src="https://assets.cometchat.io/website/images/logos/banner.png">
</p>

# CometChat Flutter VoIP SDK

Incoming CometChat calls that ring the way the phone's own calls do — through
CallKit on iOS, and as a full-screen call notification on Android — with the
app in the foreground, in the background, or killed. The user answers or
declines from the lock screen; the package connects the call while it rings,
sends the decline even if the app is suspended straight afterwards, and marks
the calls nobody answered.

The app joins the call once it is answered. That is the whole integration.

The package has its own Kotlin and Swift, ported from the native
push-notifications SDKs, because the ring runs in processes no Dart reaches: a
notification action, an alarm, a WorkManager job, a PushKit wake.

It declares **one dependency**, [`cometchat_calls_sdk`][calls], and no native
SDK of its own. Everything the ringer needs from the Calls SDK goes back
through Dart, and on Android it will start a headless isolate to get there when
the app is gone.

Every app-facing method on the native Android and iOS SDKs has a counterpart
here.

Chat notifications are [`cometchat_push_notifications`](../cometchat_push_notifications/README.md)' job. The
two packages live in this repository side by side, and an app with chat and
calls uses both.

Every option, method and event is documented below, and in the API reference
on [pub.dev](https://pub.dev/documentation/cometchat_voip/latest/).

[calls]: https://www.cometchat.com/docs/calls/flutter/overview

## Prerequisites

- Flutter 3.3.0 and later, Dart 3.10.8 and later
- [`cometchat_calls_sdk`][calls] 5.1.0, which pub resolves for you
- Android `minSdkVersion 26`, `compileSdkVersion 36`
- iOS 15.1 and later
- A CometChat app with **Push Notifications** enabled. On iOS add a
  token-based (`.p8`) APNs provider: a certificate provider serves only one of
  chat and VoIP pushes. Note the **provider ID**.

## How it fits together

```
iOS      PushKit ──────────────────────────→ cometchat_voip → CallKit
Android  FCM → your app → CometChatVoip.handlePushNotification → call notification

Answer  → CometChatVoip.onCallAnswered → your call screen → CometChatCalls.joinSession
Decline → cometchat_voip → CometChatCalls.endCall (durably)
```

On iOS the package owns the PushKit registry **and** the `CXProvider`, because
a VoIP push has to be reported to CallKit before the app returns from the push
— there is no time to hand it to Dart. On Android the app owns Firebase, as it
always does, and hands call pushes over; claiming `FirebaseMessagingService`
would take it away from every app that already has one.

Because the package links no native Calls SDK, the CallKit audio handoff goes
through the Calls SDK's `notifyCallKitAudioActivated`. `callKitAudio` is safe
to set: `init` checks for that method first and leaves CallKit audio off
without it, so the call keeps its sound either way — check
`getDiagnostics()['callKitAudioHandoff']` to see which you got. See
[Limitations](#limitations).

Every ringing call is also handed to the Calls SDK, so a
`CometChatCalls.addIncomingCallListener` hears calls that arrived by push
exactly as it hears any other.

### Three ways to take an incoming call

| | `auto` | `autoCustomScreen` | `manual` |
| --- | --- | --- | --- |
| Rings: notification, ringtone, expiry, keep-alive | package | package | app |
| The full-screen alert, and its tap | the package's native screen | **the app's Flutter screen** | nothing: the app rings |
| The notification's Answer and Decline | package | package | — |
| Gates a self-ring, a stale push, a duplicate | package | package | package |
| Busy: a second call over a live one, a third refused | package | package | app |
| Tells the caller "Ringing…" before the answer | package | package | `ringSurfaces.verify` |
| iOS | CallKit | CallKit — same as `auto` | the app owns PushKit |

**`CometChatCallMode.auto`** — the default, and everything above. The package
rings, and the app supplies a call screen for after the answer.

**`CometChatCallMode.autoCustomScreen`** — everything `auto` does, except that
the ring's full-screen alert and its tap open the **app**, which draws the ring
screen itself. Mirrors Android's `PNConfiguration.setIncomingCallActivity(...)`.

```dart
await CometChatVoip.init(
  CometChatVoipConfig(
    appId: 'APP_ID',
    region: 'us',
    providerId: 'PROVIDER_ID',
    callMode: CometChatCallMode.autoCustomScreen,
  ),
);

CometChatVoip.onRingScreenRequested.listen((request) async {
  // The ring is already going: this is the screen on top of it.
  final missing = await CometChatVoip.permissionsToAnswer(request.call);
  showIncomingCall(
    request.call,
    // "Answering ends your current call" — the Calls SDK holds one session.
    endsCurrentCall: request.answerEndsActiveCall,
    needsPermissions: missing,
    onAnswer: () => CometChatVoip.answer(request.call.sessionId),
    onDecline: () => CometChatVoip.decline(request.call.sessionId),
  );
});

// Cancelled, answered on another device, rung out: close the screen.
CometChatVoip.onCallEnded.listen((ended) => closeIncomingCall(ended.call));
```

`answer` asks for the microphone, and the camera for a video call, by itself —
`permissionsToAnswer` and `requestCallPermissions` are there for a screen that
wants to show or ask first. An answered call reaches `onCallAnswered`, never
`onCallEnded`, so one screen can serve the ring and the call without having to
tell an answer from an end. A call that arrives while the app is already in
front has no full-screen alert to fire — Android shows a heads-up instead — so
listen to `onCallRinging` as well if the app rings its own screen then too.

A Flutter screen needs an engine to draw and a native one does not, so this
rings a fraction slower than `auto` on a process the push created. On iOS
CallKit is the only incoming-call UI there is, so the mode behaves as `auto`
and `onRingScreenRequested` never fires.

**`CometChatCallMode.manual`** — the package parses, gates and forwards only.
It never rings: `onCallRinging` is the app's trigger, and the steps `auto`
would have taken are on `CometChatVoip.ringSurfaces`. On iOS the app owns the
`PKPushRegistry` in this mode and forwards pushes itself. The busy handling
goes with the ring, and so does the "Ringing…" the caller sees unless the app
calls `ringSurfaces.verify`.

### A second call, and a third

The package handles call waiting in both `auto` modes, as the native SDKs do:

- a **second** call rings over the live one, and says that answering ends it.
  Answering leaves the live session first — "End & accept" — and declining
  sends `busy`.
- a **third** call, or one that arrives while this device's own outgoing call
  is still ringing, is refused as `busy` without ringing and shown as a missed
  call.

## Installation

```yaml
dependencies:
  cometchat_voip: ^2.0.0
```

```bash
flutter pub get
```

The Calls SDK comes with it — `cometchat_calls_sdk` `^5.1.0`. To pin it
yourself:

```bash
dart pub add cometchat_calls_sdk:^5.1.0
```

### Android

Raise `minSdk` to 26 in `android/app/build.gradle` — the Calls SDK needs it —
then hand every call push over, from both of `firebase_messaging`'s handlers.
The background one is what runs when the app is killed:

```dart
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(RemoteMessage message) async {
  // init() need not have run in this isolate: the native side works from the
  // configuration it persisted.
  await CometChatVoip.handlePushNotification(
    message.data,
    sentTime: message.sentTime,
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FirebaseMessaging.onBackgroundMessage(onBackgroundMessage);
  FirebaseMessaging.onMessage.listen(
    (m) => CometChatVoip.handlePushNotification(m.data, sentTime: m.sentTime),
  );
  runApp(const MyApp());
}
```

Pass `sentTime`. FCM holds pushes while a device dozes, and without it a push
delivered late rings for a call that is already over.

Send call pushes at **high priority**. Android only lets a background app keep
itself alive through the answer when a high-priority message woke it.

### iOS

1. In Xcode, on the app target, add the **Push Notifications** capability, and
   under **Background Modes** check **Voice over IP** and **Remote
   notifications**.
2. Add `NSMicrophoneUsageDescription` to `Info.plist`, and
   `NSCameraUsageDescription` for video calls.
3. `cometchat_calls_sdk` builds on iOS with **Swift Package Manager** only — it
   ships no CocoaPods variant, and its podspec stops `pod install` with a
   message saying so. SwiftPM is on by default from Flutter 3.44; on an earlier
   Flutter, turn it on:

   ```bash
   flutter config --enable-swift-package-manager
   ```

   If the app's `pubspec.yaml` sets `enable-swift-package-manager: false`,
   remove it. Then raise the deployment target to 15.1, which the Calls SDK
   requires:

   ```ruby
   platform :ios, '15.1'
   ```

Nothing else. In `auto` the plugin creates the PushKit registry inside
`didFinishLaunching`, which is where Apple requires it, so the generated
`AppDelegate` is already right. Call `CometChatVoip.init` early in `main` —
a push that launched a killed app waits for Dart to come up before the Calls
SDK can ring it, and Apple does not wait forever.

**Do not create a `PKPushRegistry` of your own.** There is one per app: a
second one takes the VoIP pushes, and those calls never ring, with no error
anywhere. An app that wants to own PushKit sets `CometChatCallMode.manual` and
forwards the token with `setPushToken` and each push with
`handlePushNotification`.

## Usage

### Initialize, and join answered calls

The Calls SDK first — it is what rings. Build this package's config from the
settings you just gave it, so the app ID and region cannot drift apart:

```dart
final settings = (CallAppSettingBuilder()
      ..appId = 'APP_ID'
      ..region = 'us').build();

CometChatCalls.init(settings, onSuccess: (_) {}, onError: (e) {});

await CometChatVoip.init(
  CometChatVoipConfig.fromCallAppSettings(
    settings,
    providerId: 'PROVIDER_ID',
  ),
);

CometChatVoip.onCallRinging.listen((call) {
  // Show your incoming-call screen, then accept() or decline().
  // On iOS the call is also ringing in CallKit, which answers it without this.
});

CometChatVoip.onCallAnswered.listen((call) {
  navigator.push(CallScreen.route(call));
  CometChatCalls.joinSession(sessionId: call.sessionId, /* … */);
});

CometChatVoip.onCallEnded.listen((ended) {
  // Close the call screen. ended.reason says why; ended.reason.isMissed
  // tells a missed call from a declined one.
});
```

Subscribe early, in `main` or the first screen. A call that arrived with the
push that launched the app lands before anything has subscribed; the package
holds it and delivers it to the first listener.

On iOS `onCallAnswered` fires while the phone may still be locked. Join then:
that is what connects the audio before the user unlocks.

### Answer and decline

```dart
await CometChatVoip.answer(call.sessionId);   // onCallAnswered follows
await CometChatVoip.decline(call.sessionId);  // rejected, durably
await CometChatVoip.decline(call.sessionId, busy: true); // already on a call
```

`answer` stops the ring as well, so the notification and CallKit stay in step
with a tap in the app. For an app whose own UI already told CometChat — the UI
Kit's overlay, say — use `dismissRinging(sessionId, answered: …)` instead,
which stops the ring and sends nothing.

`accept` is the lighter form: it reports the answer without touching a ring,
for `manual` mode.

### Push token

The token registers itself whenever someone logs in to the Calls SDK, under the
Calls SDK's auth token — a calls-only app needs no Chat SDK. On iOS it is the
PushKit token, which the package gets itself.

On Android the package cannot see the FCM token, so hand it over once after
login. Later logins reuse it:

```dart
final token = await FirebaseMessaging.instance.getToken();
await CometChatVoip.registerPushToken(token: token!);
```

Unregister before logging out, while the auth token that owns the push token
still works:

```dart
await CometChatVoip.unregisterPushToken();
await CometChatCalls.logout(/* … */);
```

Set `autoRegisterPushToken: false` to call `registerPushToken` yourself instead.

When the token rotates, hand the new one over:

```dart
FirebaseMessaging.instance.onTokenRefresh.listen(
  CometChatVoip.handleTokenRefresh,
);
```

And when the OS refuses to issue one at all, say so — it is the only signal
that a capability, background mode or provisioning profile is wrong, and
nothing else about it is visible:

```dart
// iOS, from didFailToRegisterForRemoteNotificationsWithError
CometChatVoip.handleRegistrationFailure(error);
```

### When a call does not ring

Each of these silences a call with no error anywhere, so check at sign-in:

```dart
final readiness = await CometChatVoip.checkRingReadiness();
if (readiness != CometChatRingReadiness.ready) {
  await CometChatVoip.openSettings(readiness);   // after explaining
}
```

| Readiness | Platform | Meaning |
| --- | --- | --- |
| `notificationsOff` | Android | Nothing can ring. Also ask with `requestNotificationPermission()`. |
| `channelMuted` | Android | The user lowered the incoming-call channel. |
| `fullScreenIntentDenied` | Android 14+ | A locked phone shows a notification, not the ring screen. |
| `doNotDisturb` | Android | Do Not Disturb is filtering. |
| `backgroundModeMissing` | iOS | `UIBackgroundModes` lacks `voip`: a killed app is never woken. |
| `voipEntitlementMissing` | iOS | No `aps-environment`: iOS issues no VoIP token. |
| `microphoneDenied` | both | An answered call joins muted. |

`verifyPushSetup()` rolls that together with the token and the login:

```dart
final result = await CometChatVoip.verifyPushSetup();
if (result != CometChatPushSetupResult.ok) {
  debugPrint('Calls will not arrive: ${result.name}');
  debugPrint('${await CometChatVoip.getDiagnostics()}');
}
```

`getDiagnostics` is safe to attach to a bug report: never a token, an auth
value or a payload. Its `pushesSeen` / `pushesRung` / `pushesDropped` counts
tell "no push arrived" from "the push arrived and a gate dropped it", and
`native.lastWakeTiming` tells a slow ring from one that never started.

### Callers on the Chat SDK's calling

In the ringing flow, joining the session is the answer. A caller that still
places calls through the Chat SDK — a UI Kit, web or React app — instead waits
for the call's status to become `ongoing`. So on every answer the package also
sets it (`PUT /calls/{sessionId}`, as the Chat SDK's `acceptCall` does), and
that caller joins too. Turn it off with `acceptOnAnswer: false` once every
caller is on the ringing flow.

### A UI that already answers calls

An app whose own screen answers and declines through CometChat — the UI Kit's
incoming-call overlay, say — ends up with two ringing surfaces while it is in
the foreground. When the user acts on the app's own, stop the package's without
sending anything a second time:

```dart
CometChatVoip.dismissRinging(call.sessionId, answered: true);  // after acceptCall
CometChatVoip.dismissRinging(call.sessionId, answered: false); // after rejectCall
```

### Ringing it yourself

In `CometChatCallMode.manual` nothing rings until the app says so, and the
steps `auto` would have taken are available one at a time:

```dart
CometChatVoip.onCallRinging.listen((call) async {
  await CometChatVoip.ringSurfaces.keepAlive(call);  // survive the connect
  await CometChatVoip.ringSurfaces.verify(call);     // connect while ringing
  await CometChatVoip.ringSurfaces.showIncomingNotification(call);
});
```

Android only — on iOS reporting a call to CallKit *is* the ring and cannot be
driven piecemeal, which is true of the native SDK too.

### Reporting the session

The package watches the Calls SDK's own session and media listeners, so
CallKit's timer, mute and hold follow the call without you doing anything.
These stay available for a session the package never saw ring, and are harmless
otherwise:

```dart
await CometChatVoip.reportCallConnected(sessionId);
await CometChatVoip.reportCallEnded(sessionId);
await CometChatVoip.reportMuted(true);
await CometChatVoip.reportVideoPaused(true);
```

### Calls this device places (iOS)

Report an outgoing call to CallKit so it survives a cellular call, can be ended
from the lock screen, and appears in Recents:

```dart
await CometChatVoip.reportOutgoingCall(
  sessionId: sessionId,
  calleeName: 'Alex',
  hasVideo: true,
);
```

The call is on CallKit from that moment, while the callee still rings — as the
native iOS SDK reports it — so it can be hung up from outside the app before
anyone answers, and leaves a Recents entry either way. That hang-up ends the
CallKit call and nothing else, so watch for it and withdraw the call:

```dart
CometChatVoip.onOutgoingCallEnded.listen((sessionId) {
  // Close the outgoing screen and tell the far side.
  CometChatCalls.endCall(sessionId: sessionId, status: 'cancelled', ...);
});
```

Calling this is optional: a session the Calls SDK owns that CallKit has not
heard of — `initiateCall`'s prepared session, or a plain `joinSession` — is
reported by the package itself, under the app's own name until a participant
connects. Report it yourself to give CallKit the callee's name and the call
type from the start.

## Configuration

`CometChatVoipConfig`, or `CometChatVoipConfig.fromCallAppSettings` to build it
from the Calls SDK settings the app already has:

| Field | Default | What it does |
| --- | --- | --- |
| `appId`, `region` | — | Your CometChat app |
| `providerId` | — | The dashboard push provider the token registers under |
| `callMode` | `auto` | Who rings the call and draws the ring screen |
| `defaultRingTimeout` | 45 seconds | How long a call rings when the push does not say |
| `autoRegisterPushToken` | `true` | Register the token again on every Calls SDK login |
| `requestCallPermissions` | `true` | Ask for the microphone — and the camera, for video — when the user answers |
| `requestNotificationPermission` | `true` | Ask for notification permission during `init` |
| `showMissedCallNotification` | `true` | Show a notification for a call that rang out or was cancelled |
| `dropExpiredCalls` | `true` | Do not ring a push that arrives after its call stopped ringing |
| `acceptOnAnswer` | `true` | Mark an answered call `ongoing`, which a caller on the Chat SDK's calling waits for |
| `callKitAudio` | `false` | Let CallKit own the iOS audio session — see [Limitations](#limitations) |
| `callKit` | `CometChatCallKitOptions()` | iOS call presentation: name, icon, ringtone, Recents, video |
| `incomingCallTheme` | — | Colours for the Android ring screen and call notifications |
| `extensionGroupID` | — | App Group shared with a Notification Service Extension |
| `authToken`, `clientHost`, `timezone` | — | Overrides for a custom host or a fixed timezone |

`CometChatCallKitOptions` and `CometChatVoipIncomingCallTheme` have their own
fields; the API reference on
[pub.dev](https://pub.dev/documentation/cometchat_voip/latest/) lists them all.

## Platform differences

| | Android | iOS |
| --- | --- | --- |
| Rings the call | This package: CallStyle notification + full-screen ring screen | CallKit |
| Ring screen the app draws | `autoCustomScreen` → `onRingScreenRequested` | Not possible: CallKit is the only incoming-call UI |
| Ring surfaces à la carte | `ringSurfaces` | — |
| Owns the push registry | — | `PKPushRegistry`, in `auto`; the app's in `manual` |
| Missed calls | Notification (`showMissedCallNotification`) | Recents |
| Outgoing calls | — | Reported to CallKit (`reportOutgoingCall`) |
| Durable declines | WorkManager | Background task with replay |
| Call waiting refuses a third call | Yes | No: every VoIP push must reach CallKit |

## Parity with the native SDKs

Every app-facing calls API on the native Android and iOS SDKs was checked
against this one, row by row: **68 of 77 matched, 5 different, 0 missing** —
with one dependency. The one trade that comes with it is the CallKit audio
handoff, under [Limitations](#limitations).

## Limitations

- **`callKitAudio` needs a Calls SDK that carries the handoff.** It defaults
  off. The package forwards `didActivate` through the Calls SDK's
  `notifyCallKitAudioActivated`; on an SDK without that method the handoff is
  unavailable, so `init` leaves CallKit audio off however the flag is set and
  WebRTC manages its own audio session. The flag can never silence a call, but
  it also does nothing until such an SDK ships —
  `getDiagnostics()['callKitAudioHandoff']` says which state you are in. With
  the handoff off, the residual risk is a lost first moment of audio or a wrong
  initial route when answering on a locked device — worth a device test.
- **One `PKPushRegistry` per app.** A second — a hand-written one or
  `flutter_callkit_incoming`'s — takes the VoIP pushes, and those calls never ring, with no error. Use
  `CometChatCallMode.manual` to own it yourself.
- `ringSurfaces` is Android-only, as it is natively.
- **Android's background isolate needs the entry point.** `init` registers it,
  and `@pragma('vm:entry-point')` keeps the tree shaker off it. An app that has
  never run `init` has nothing to start, so a lock-screen decline on a killed
  app waits for the app instead.
- **What the ringer knows about the session is a snapshot.** Dart fills it by
  subscribing to the Calls SDK's own session and media listeners, so no app
  cooperation is needed, but it can be briefly stale. The gates fail towards
  ringing, never towards ending a live call.
- `CometChatPushSetupResult` has no equivalent of the native
  `TEST_PUSH_UNAVAILABLE`: that needs a test push the backend sends.
- CallKit and PushKit need a real iPhone. A simulator never receives a VoIP push.
- The native Calls SDK's iOS WebRTC build has no arm64 simulator slice, so on an
  Apple-silicon Mac the example runs only on simulators that still run x86_64
  apps (iOS 18 and earlier).
- **After changing the Calls SDK version, clean both builds.** Stale incremental
  Kotlin state surfaces as `Unresolved reference 'SessionSettingsMapper'`
  *inside `cometchat_calls_sdk`* — not a bug there; `flutter clean` fixes it.
  iOS needs DerivedData cleared, and the resolved Swift package versions too
  (**File → Packages → Reset Package Caches** in Xcode).

## Help and Support

Consult our [documentation](https://www.cometchat.com/docs/calls/flutter/overview),
open a [support ticket](https://help.cometchat.com/hc/en-us), or reach us
through the [CometChat Dashboard](https://app.cometchat.com/).
