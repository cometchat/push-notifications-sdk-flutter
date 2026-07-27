import 'package:notification_voip_plugin/notification_voip_plugin.dart';

/// Handler for in-call control actions (mute, speaker, camera).
///
/// Every method has a default implementation that delegates to
/// [NotificationVoipPlugin]. Consumers extend this class and override
/// only the methods they need to intercept.
///
/// This handler is invoked when:
/// - The user toggles a control from the custom Flutter call screen.
/// - The app programmatically calls
///   [CometChatPushNotifications.toggleMute],
///   [CometChatPushNotifications.toggleSpeaker], or
///   [CometChatPushNotifications.toggleCamera].
///
/// **Scope:** In-call controls only. Accept, decline, and end actions
/// remain on the `CometChatPushNotifications.onCallEvent` stream.
///
/// Example — intercept mute to control a WebRTC audio track:
/// ```dart
/// class MyCallActionHandler extends CometChatCallActionHandler {
///   final WebRtcEngine _engine;
///
///   MyCallActionHandler(this._engine);
///
///   @override
///   Future<void> onMuteToggled(String sessionId, bool isMuted) async {
///     _engine.muteLocalAudio(isMuted);
///     await super.onMuteToggled(sessionId, isMuted);
///   }
/// }
/// ```
class CometChatCallActionHandler {
  /// Called when the user toggles mute (from call screen UI or
  /// programmatically).
  ///
  /// [sessionId] — the active call session ID.
  /// [isMuted] — `true` if the microphone is now muted, `false` if unmuted.
  ///
  /// Default: delegates to [NotificationVoipPlugin.toggleMute].
  Future<void> onMuteToggled(String sessionId, bool isMuted) async {
    await NotificationVoipPlugin.toggleMute(sessionId);
  }

  /// Called when the user toggles the speaker / audio route.
  ///
  /// [sessionId] — the active call session ID.
  /// [isOn] — `true` if speaker is now on, `false` if off.
  ///
  /// Default: delegates to [NotificationVoipPlugin.toggleSpeaker].
  Future<void> onSpeakerToggled(String sessionId, bool isOn) async {
    await NotificationVoipPlugin.toggleSpeaker(sessionId);
  }

  /// Called when the user toggles the camera (video calls).
  ///
  /// [sessionId] — the active call session ID.
  /// [isOn] — `true` if the camera is now on, `false` if off.
  ///
  /// Default: delegates to [NotificationVoipPlugin.toggleCamera].
  Future<void> onCameraToggled(String sessionId, bool isOn) async {
    await NotificationVoipPlugin.toggleCamera(sessionId);
  }
}
