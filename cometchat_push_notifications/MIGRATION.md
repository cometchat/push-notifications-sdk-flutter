# Migrating from 1.x to 2.0

2.0 is a rewrite. 1.x was a wrapper around `notification_voip_plugin`, a
third-party package, and covered both chat and calling. 2.0 covers chat only,
renders notifications in its own native code, and talks to CometChat through
[`cometchat_sdk`][sdk].

[sdk]: https://pub.dev/packages/cometchat_sdk

## Calling has moved

Everything call-related is gone from this package: the call screen, the call
handlers, `CometChatCallDetails`, the VoIP token, and every `*Call*` member on
the facade. A call push still parses, and `handlePushNotification` returns
`false` for it so you can pass it on.

If your app makes calls, add [`cometchat_voip`](../cometchat_voip/README.md)
alongside this package. It owns ringing — CallKit on iOS, a full-screen call
notification on Android — and the VoIP token. Hand it the pushes this package
returns `false` for.

## Dependencies

| | 1.x | 2.0 |
| --- | --- | --- |
| `notification_voip_plugin` | `^2.1.0` | removed |
| `cometchat_sdk` | `^5.0.6` | `^5.0.7` |
| Push transport | bundled | yours (`firebase_messaging` or APNs) |

`notification_voip_plugin` is gone, so `CometChatNotificationConfig.nvpConfig`
and every `Nvp*` type with it. The package renders notifications itself now.

The transport change is the one that needs work in your app. 1.x received
pushes for you; 2.0 does not, because claiming Android's
`FirebaseMessagingService` breaks any app that already has one. Add a messaging
library and forward payloads:

```dart
FirebaseMessaging.onMessage.listen(
  (m) => CometChatPushNotifications.handlePushNotification(m.data),
);
```

## API changes

| 1.x | 2.0 |
| --- | --- |
| `init(config)` | unchanged in name; the config's fields differ |
| `registerToken(platform, onSuccess:, onError:)` | `registerPushToken({token, platform, providerId})`, which returns a `Future` and throws |
| `getPushToken()` | `getApnsToken()`, iOS only |
| `handlePushNotification(payload)` | unchanged in name; now returns whether it took the payload |
| `showNotification(...)` | removed — `handlePushNotification` posts it |
| `showInAppNotification(...)` | removed — see `showInAppNotifications` in the config |
| `cancelNotification(tag)` | `clearNotifications(conversationId:)` |
| `clearAll()` | `clearNotifications()` |
| `setCurrentOpenChatId(id)` | `setActiveConversation(id:, receiverType:)` |
| `onNotificationTap` | `onNotificationTap`, carrying a `CometChatNotificationResponse` |
| `onPushReceived` | removed — your messaging library already gives you this |
| `PushPlatform.APNS_FLUTTER_VOIP` | removed |
| `CometChatReceiverType` | `CometChatPushReceiverType` — renamed so it doesn't clash with the Chat SDK's `CometChatReceiverType`, which a UI Kit app also has in scope |
| `parsePayload(payload)` | removed — `handlePushNotification(payload)` reads the payload and returns whether it took it |
| `openFullScreenIntentSettings()` | moved to `cometchat_voip`: `CometChatVoip.openSettings(CometChatRingReadiness.fullScreenIntentDenied)` |
| `openAutoStartSettings()`, `openOverlaySettings()`, `openBatteryOptimizationSettings()` | removed — they existed for calls; `cometchat_voip` rings on a foreground service and needs none of them. `CometChatVoip.checkRingReadiness()` and `CometChatVoip.openSettings(readiness)` cover what a ring needs |

Three of these are fixes, not renames:

- `clearAll()` called `cancelAll()`, which cleared *every* notification on the
  device including ones your app posted for its own reasons. `clearNotifications()`
  cancels only what this package posted.
- `cancelNotification(tag)` could never cancel anything: it cancelled a
  `(tag, id: 0)` pair, while notifications are posted under an id derived from
  the conversation and no tag.
- `setCurrentOpenChatId` took only an id. A user and a group can share one, so
  suppression could silently drop a message from the wrong conversation;
  `setActiveConversation` takes the receiver type too.

## Configuration

```dart
// 1.x
CometChatNotificationConfig(
  appId: 'APP_ID',
  region: 'us',
  nvpConfig: NvpConfig(channelId: 'messages', ...),
  showInAppNotifications: false,
)

// 2.0
const CometChatNotificationConfig(
  appId: 'APP_ID',
  region: 'us',
  androidChannelId: 'messages',
  androidSmallIcon: 'ic_notification',
  showInAppNotifications: false,
)
```

## iOS

Delivery receipts and sender avatars while the app is backgrounded or killed now
need a Notification Service Extension. 1.x had none, so those receipts were
never sent. See the README for the four steps.

Remove the **Voice over IP** background mode and the PushKit capability if
nothing else in your app uses them.

## Android

Add a notification icon if you have not. 1.x fell back to the launcher icon,
which Android renders as a grey blob; so does 2.0, but it now warns in the log.
Point `androidSmallIcon` at a white-on-transparent drawable.
