<p align="center">
  <img alt="CometChat" src="https://assets.cometchat.io/website/images/logos/banner.png">
</p>

# CometChat Flutter Push Notifications SDK

The CometChat Flutter Push Notifications SDK provides a drop-in push notifications & VoIP calling integration that developers can use to quickly add a reliable & fully-featured notification experience to an existing or a new CometChat-powered app — FCM (Android) and APNs/PushKit (iOS) token registration, foreground presentation, notification taps, badge management, and full incoming call handling with a customizable Flutter call screen, all handled inside the plugin.

## Prerequisites

- Flutter 3.3.0 and later
- Dart 3.10.8 and later
- Android: `minSdkVersion 24`, `compileSdkVersion 36`
- iOS 13.0 and later, Swift 5.0+
- APNs credentials from your Apple Developer account (iOS) and a Firebase project with `google-services.json` (Android)

## Getting Started

To set up the Flutter Push Notifications SDK and utilize CometChat for your notification functionality, you'll need to follow these steps:

1. Registration: Go to the [CometChat Dashboard](https://app.cometchat.com/) and sign up for an account.
2. After registering, log into your CometChat account and create a new app. Once created, CometChat will generate an Auth Key and App ID for you. Keep these credentials secure as you'll need them later.
3. In the dashboard, enable **Push Notifications v2**, add your APNs and/or FCM credentials, and note the **Provider ID**.
4. Check the [Key Concepts](https://www.cometchat.com/docs/fundamentals/key-concepts) to understand the basic components of CometChat.
5. Refer to the [Push Notifications documentation](https://www.cometchat.com/docs/notifications/push-overview) to integrate the SDK into your Flutter app.

## Installation

Add the SDK to your `pubspec.yaml`:

```yaml
dependencies:
  cometchat_push_notifications: ^1.0.1
```

Then fetch the package:

```
flutter pub get
```

> **Important:** the plugin also requires the CometChat Chat SDK, which pub resolves for you:
>
> | Package | Minimum version |
> | --- | --- |
> | [`cometchat_sdk`](https://pub.dev/packages/cometchat_sdk) | **5.0.6** |
>
> On iOS, enable **Push Notifications** and **Background Modes** (Remote notifications, Voice over IP) in Xcode capabilities. On Android, add your `google-services.json` to `android/app/`.

## Help and Support

For issues running the project or integrating with our SDKs, consult our [documentation](https://www.cometchat.com/docs/notifications/push-overview) or create a [support ticket](https://help.cometchat.com/hc/en-us) or seek real-time support via the [CometChat Dashboard](https://app.cometchat.com/).
