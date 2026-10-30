<p align="center">
  <img alt="CometChat" src="https://assets.cometchat.io/website/images/logos/banner.png">
</p>

# CometChat Flutter Push Notifications

Two Flutter packages for CometChat-powered apps, side by side. Each is
versioned and published on its own; an app with chat and calls uses both.

| Package | For |
| --- | --- |
| [`cometchat_push_notifications`](cometchat_push_notifications/) | Chat notifications: posting them, grouping a conversation, delivery receipts, taps, the iOS badge |
| [`cometchat_voip`](cometchat_voip/) | Incoming calls: CallKit and PushKit on iOS, the full-screen ring on Android, answer, decline and missed calls |

Each package has a props reference listing every option, method, event and
platform setting: [chat](cometchat_push_notifications/docs/props.md),
[VoIP](cometchat_voip/docs/props.md).

A push that one package does not recognise it returns unhandled, so an app
hands each push to both:

```dart
final handled = await CometChatPushNotifications.handlePushNotification(data);
if (!handled) {
  await CometChatVoip.handlePushNotification(data, sentTime: sentTime);
}
```

## Repository layout

```
cometchat_push_notifications/   the chat package, with its example
cometchat_voip/                 the calls package, with its example
skills/                         an integration skill for app repositories
```

Work inside a package's directory: `flutter pub get`, `flutter test` and the
example app all run from there.
