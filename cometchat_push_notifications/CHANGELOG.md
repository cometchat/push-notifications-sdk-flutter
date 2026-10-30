# 2.0.0

A rewrite. Chat notifications only, rendered by the package's own native code,
with CometChat reached through `cometchat_sdk`. See [MIGRATION.md](MIGRATION.md).

## New
- Android notifications are now built by this package: one per conversation,
  expanding into its recent messages, with the sender's avatar and a summary
  across conversations.
- A Notification Service Extension base class for iOS,
  `CometChatNotificationServiceExtension`, shipped as the
  `CometChatPushNotificationsNSE` pod. It sends delivery receipts while the app
  is backgrounded or killed, attaches the sender's avatar, groups notifications
  by conversation and strips markdown a notification cannot render.
- `onNotificationTap` reports taps, holding a cold-start tap until a listener
  attaches so it is not lost to app startup.
- `setActiveConversation` takes a receiver type alongside the id, as a
  `CometChatPushReceiverType`. It is named apart from the Chat SDK's
  `CometChatReceiverType` on purpose: both are in scope in any UI Kit app, and
  matching names there are an `ambiguous_import` error at the point of use.
- `PushPlatform` covers `FCM_FLUTTER_IOS` and `FCM_WEB`. 1.x had neither, so an
  iOS app using `firebase_messaging` — the usual Flutter setup — had no correct
  value to register its FCM token under.
- Web has a real implementation. It reaches as far as Dart does — token
  registration and the rest of the API — and no-ops the display methods, since
  a web push is delivered to a service worker. `init` used to throw there.
- A privacy manifest for iOS.

## Enhancements
- `notification_voip_plugin` is no longer a dependency.
- `cometchat_sdk` moves to `5.0.9`.
- The push token now carries `ringingFlowVersion: "v2"` and always a
  `timezone`, as the native Android and iOS SDKs send them. The Chat SDK's
  `CometChatNotifications.registerPushToken` cannot carry the field, so the
  token is now registered with CometChat directly, under the Chat SDK's auth
  token, over `dart:io` (Android, iOS) or `fetch` (web). No new dependency.
- `registerPushToken` and `unregisterPushToken` throw
  `CometChatNotificationException` on failure, carrying the SDK's error code
  and message alongside the platform and provider id they used.
- The package no longer claims Android's `FirebaseMessagingService`. Your app
  keeps its messaging library and forwards payloads to
  `handlePushNotification`, which now reports whether it took the payload.

## Fixes
- Clearing notifications no longer cancels notifications this package did not
  post. `clearAll()` called `cancelAll()`, taking down the host app's own.
- Cancelling one conversation's notification now works. It targeted a
  `(tag, id: 0)` pair that never matched what was posted.
- `showInAppNotifications` now has an effect on Android, where it was sent to a
  native setter that did not exist.
- A tap on a notification that launched a killed app now opens the
  conversation rather than the conversation list: the tap is held until a
  listener attaches instead of being lost to app startup.
- Notification suppression no longer applies to the wrong conversation when a
  user and a group share an id. `setActiveConversation` takes the receiver type
  with the id, so the two can no longer collide.

## Removed
- Calling, in full: the call screen, call handlers, `CometChatCallDetails`, the
  incoming-call activity, and every call member on the facade. It moves to its
  own package, `cometchat_voip`.
- `PushPlatform.APNS_FLUTTER_VOIP`. Chat delivery runs over the APNs device
  token, so a chat integrator has no VoIP provider to register against.
- `NvpConfig` and every other `notification_voip_plugin` type.
- `onPushReceived`, which reported what your messaging library already gives you,
  along with `parsePayload`, `showNotification` and `showInAppNotification`:
  `handlePushNotification` parses and posts.
- `openAutoStartSettings`, `openOverlaySettings` and
  `openBatteryOptimizationSettings`, which belonged to ringing.
  `openFullScreenIntentSettings` moves to
  `CometChatVoip.openSettings(CometChatRingReadiness.fullScreenIntentDenied)`.
- Inline reply. A notification carried a reply field, and the reply was sent
  through `cometchat_sdk` — from a background isolate when the app was dead.
  Sending a message is the app's job, not a notification package's, and the
  machinery it needed (a broadcast receiver, an on-disk queue, a headless
  Flutter engine, a second entry point the tree shaker could drop) cost more
  than the feature returned. `CometChatNotificationAction`, `replyText`,
  `enableInlineReply`, `onBackgroundSetup` and `onNotificationResponse` go with
  it; use `onNotificationTap`.

## Breaking changes
See [MIGRATION.md](MIGRATION.md) for the upgrade in full.

- The push transport is now yours. Add a messaging library such as
  `firebase_messaging` and forward every payload to `handlePushNotification`,
  which reports whether it took the payload — call and other non-chat payloads
  come back `false` for you to route onward (to `cometchat_voip`, for a call).
- Renamed: `registerToken` to `registerPushToken` (now a `Future` that throws
  on failure), `getPushToken` to `getApnsToken` (iOS only),
  `cancelNotification(tag)` to `clearNotifications(conversationId:)`,
  `clearAll()` to `clearNotifications()`, and `setCurrentOpenChatId(id)` to
  `setActiveConversation(id:, receiverType:)`, which now requires the receiver
  type.
- `CometChatReceiverType` is now `CometChatPushReceiverType`, to resolve an
  `ambiguous_import` against the Chat SDK's type of the same name in UI Kit
  apps.
- `nvpConfig` on `CometChatNotificationConfig` gives way to native fields such
  as `androidChannelId` and `androidSmallIcon`.
- iOS needs a Notification Service Extension for delivery receipts and sender
  avatars while the app is backgrounded or killed. Add one that subclasses
  `CometChatNotificationServiceExtension`.

# 1.0.1

## New
- None

## Enhancements
- Updated the `cometchat_sdk` dependency to version `5.0.6`.
- Added `homepage` and `repository` links to the package metadata, making the source repository and website discoverable from the pub.dev listing.

## Fixes
- None

# 1.0.0

## New
- Added comprehensive push notification support, including automatic APNs, VoIP, and FCM token management, background notifications and tap-to-chat navigation.
- Added native VoIP calling with CallKit integration, supporting incoming calls from VoIP pushes and WebSocket events, configurable call presentation, synchronized call controls, and reliable call handling across app states.

## Enhancements
- None

## Fixes
- None
