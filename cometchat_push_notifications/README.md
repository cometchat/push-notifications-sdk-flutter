<p align="center">
  <img alt="CometChat" src="https://assets.cometchat.io/website/images/logos/banner.png">
</p>

# CometChat Flutter Push Notifications SDK

Chat push notifications for CometChat-powered Flutter apps. The package posts
the notification, groups a conversation's messages into one entry, sends
delivery receipts, reports taps, and keeps the iOS badge in
step — on Android and iOS.

Calling is not part of this package. It moved to its own in 2.0,
[`cometchat_voip`](../cometchat_voip/), which sits beside this one in the same
repository; see [Migrating from 1.x](MIGRATION.md).

Every option, method, event and platform setting is documented below, and in
the API reference on
[pub.dev](https://pub.dev/documentation/cometchat_push_notifications/latest/).

## Prerequisites

- Flutter 3.3.0 and later, Dart 3.10.8 and later
- Android `minSdkVersion 24`, `compileSdkVersion 36`
- iOS 13.0 and later, Swift 5.0+
- A CometChat app with **Push Notifications v2** enabled, and APNs and/or FCM
  credentials added in the dashboard

## How it fits together

This package does not own the push transport. Whichever library already
delivers pushes to your app keeps doing so, and hands each payload over:

```
FCM / APNs  →  your app  →  CometChatPushNotifications.handlePushNotification
```

That is deliberate. An Android app can only have one `FirebaseMessagingService`,
and claiming it would break every app that already has one — so the package
never does. It is also how the native Android SDK is integrated.

Everything that talks to CometChat — registering the token, sending receipts and
replies — runs through [`cometchat_sdk`][sdk], which pub resolves for you.

[sdk]: https://pub.dev/packages/cometchat_sdk

## Installation

```yaml
dependencies:
  cometchat_push_notifications: ^2.0.0
```

```bash
flutter pub get
```

### Android

Add your `google-services.json` to `android/app/`, and use a messaging library
such as [`firebase_messaging`][fm] to receive pushes.

Ship a notification icon. Android draws the small icon as a flat silhouette, so
it must be white on transparent — a launcher icon becomes a grey blob:

```dart
androidSmallIcon: 'ic_notification',  // res/drawable/ic_notification.png
```

[fm]: https://pub.dev/packages/firebase_messaging

### iOS

Enable **Push Notifications** and **Background Modes → Remote notifications** in
your target's Signing & Capabilities.

For delivery receipts and sender avatars while the app is backgrounded or
killed, add a Notification Service Extension. It runs in its own process with no
Flutter engine, so it cannot be written in Dart:

1. In Xcode: **File → New → Target → Notification Service Extension**.
2. In your `Podfile`, add the extension's pod — to the extension target only:

   ```ruby
   target 'NotificationService' do
     pod 'CometChatPushNotificationsNSE',
         :path => '.symlinks/plugins/cometchat_push_notifications/ios'
   end
   ```

3. Replace the generated `NotificationService.swift` with:

   ```swift
   import CometChatPushNotificationsNSE

   class NotificationService: CometChatNotificationServiceExtension {}
   ```

4. Give the app and the extension a shared App Group, and add the extension's
   `Info.plist` key `CometChatExtensionGroupID` with that group's identifier.
   The SDK uses it to keep the extension's receipts from duplicating the app's.

## Usage

### Initialize

```dart
import 'package:cometchat_push_notifications/cometchat_push_notifications_export.dart';

await CometChatPushNotifications.init(
  const CometChatNotificationConfig(
    appId: 'APP_ID',
    region: 'us',
    androidSmallIcon: 'ic_notification',
  ),
);

await CometChatPushNotifications.requestPermission();
```

### Register the token

After the CometChat login completes — the token is registered against the
logged-in user, so registering earlier has nothing to attach it to.

```dart
// Android, and anywhere else you use firebase_messaging.
final token = await FirebaseMessaging.instance.getToken();
await CometChatPushNotifications.registerPushToken(token: token);

// iOS, talking to APNs directly: omit the token and the package registers
// with APNs itself.
await CometChatPushNotifications.registerPushToken();
```

`platform` defaults to APNs on iOS and FCM everywhere else. That default is
wrong for the common case of `firebase_messaging` on iOS, where your token is an
FCM token — name the platform there, or CometChat sends its pushes to a provider
that has never heard of the device:

```dart
await CometChatPushNotifications.registerPushToken(
  token: await FirebaseMessaging.instance.getToken(),
  platform: PushPlatform.FCM_FLUTTER_IOS,
);
```

Unregister before logging out, while the session that owns the token still
exists:

```dart
await CometChatPushNotifications.unregisterPushToken();
await CometChat.logout(...);
```

### Forward incoming pushes

```dart
FirebaseMessaging.onMessage.listen(_handle);
FirebaseMessaging.onBackgroundMessage(_handle);

@pragma('vm:entry-point')
Future<void> _handle(RemoteMessage message) async {
  // false means it was not a chat push and is still yours to deal with.
  await CometChatPushNotifications.handlePushNotification(message.data);
}
```

A background handler runs in its own isolate, so it must call
`CometChatPushNotifications.init` — and log in to `cometchat_sdk`, if you want
delivery receipts from it — before forwarding.

### React to taps

```dart
CometChatPushNotifications.onNotificationTap.listen((response) {
  openConversation(response.conversationId, response.receiverType);
});
```

A tap that launched the app from a cold start is held until you subscribe, so it
is not lost to the race between the launch intent and Dart starting up.

### Suppress the conversation on screen

```dart
@override
void initState() {
  super.initState();
  CometChatPushNotifications.setActiveConversation(
    id: widget.uid,
    receiverType: CometChatPushReceiverType.user,
  );
}

@override
void dispose() {
  CometChatPushNotifications.setActiveConversation();
  super.dispose();
}
```

## Configuration

| Field | Default | What it does |
| --- | --- | --- |
| `appId`, `region` | — | Your CometChat app |
| `showInAppNotifications` | `false` | Show a banner while the app is in the foreground |
| `enableBadgeCount` | `true` | Mirror `unreadMessageCount` onto the iOS app icon |
| `sendDeliveryReceipts` | `true` | Tell CometChat the message was delivered |
| `androidSmallIcon` | launcher icon | Drawable name for the notification icon |
| `androidChannelId` | `cometchat_messages` | Notification channel to post to |
| `androidChannelName` | `Chat Messages` | Channel name in Android settings |
| `androidChannelDescription` | `New message notifications` | Channel description |

Android freezes a channel's importance, sound and vibration when it is first
created and ignores later changes, because a user who has tuned the channel
outranks the app. Changing any of them needs a new `androidChannelId`.

## Platform differences

| | Android | iOS |
| --- | --- | --- |
| Draws the notification | This package | iOS, from the APNs alert |
| Conversation grouping | `InboxStyle` + group summary | `threadIdentifier` (needs the NSE) |
| Sender avatar | Large icon | Attachment (needs the NSE) |
| Receipts while killed | On the forwarded push | Needs the NSE |
| App icon badge | No OS badge | `enableBadgeCount` |

Web is supported only as far as Dart reaches: token registration and the rest
of the API work, but nothing here displays a notification, because a web push is
delivered to a service worker that may not be running the app. The display
methods are no-ops there rather than errors, so code shared with mobile keeps
running.

## Help and Support

Consult our [documentation](https://www.cometchat.com/docs/notifications/push-overview),
open a [support ticket](https://help.cometchat.com/hc/en-us), or reach us
through the [CometChat Dashboard](https://app.cometchat.com/).
