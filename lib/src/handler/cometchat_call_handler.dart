import 'package:notification_voip_plugin/notification_voip_plugin.dart';

import '../mapper/cometchat_mapper.dart';
import '../models/cometchat_call_details.dart';
import 'cometchat_call_action_handler.dart';

/// Manages VoIP call lifecycle internally.
///
/// Handles incoming call display, call dismissal, and call connection
/// across foreground, background, and terminated states.
/// Always uses a custom Flutter call screen — never native call UI.
/// On iOS, handles mandatory CallKit reporting for PushKit compliance
/// without showing the native CallKit UI to the user.
/// Routes in-call control actions through [CometChatCallActionHandler].
class CometChatCallHandler {
  CometChatCallHandler._();

  /// Reference to the active call action handler.
  /// Set by [CometChatPushNotifications.init].
  static CometChatCallActionHandler _actionHandler =
      CometChatCallActionHandler();

  /// Configures the call handler.
  ///
  /// No `useNativeScreen` parameter — always uses custom Flutter screen.
  static void configure({CometChatCallActionHandler? actionHandler}) {
    _actionHandler = actionHandler ?? CometChatCallActionHandler();
  }

  /// Replaces the active [CometChatCallActionHandler] at runtime.
  ///
  /// Use this when the handler depends on objects not available at
  /// init time (e.g., a WebRTC engine created after call setup).
  static set actionHandler(CometChatCallActionHandler handler) {
    _actionHandler = handler;
  }

  /// Shows incoming call UI for the given call details.
  ///
  /// Always uses the custom Flutter call screen.
  /// On iOS, NVP handles CallKit reporting internally for PushKit
  /// compliance (report and immediately end — no native UI shown).
  /// On Android, uses a high-priority notification to wake the app
  /// and display the custom Flutter call screen.
  static Future<void> showIncoming(CometChatCallDetails details) async {
    final nvpConfig = CometChatMapper.toNvpCallConfig(details);
    await NotificationVoipPlugin.showIncomingCall(nvpConfig);
  }

  /// Shows outgoing call UI using the custom Flutter call screen.
  static Future<void> showOutgoing(CometChatCallDetails details) async {
    final nvpConfig = NvpCallConfig(
      callId: details.sessionId,
      callerName: details.callerName,
      callerAvatar: details.callerAvatar,
      isVideo: details.isVideo,
      isOutgoing: true,
      useNativeScreen: false,
    );
    await NotificationVoipPlugin.showOutgoingCall(nvpConfig);
  }

  /// Dismisses the call UI for the given session.
  static Future<void> dismiss(String sessionId) async {
    await NotificationVoipPlugin.endCall(sessionId);
  }

  /// Marks a call as connected (answered and media established).
  static Future<void> connect(String sessionId) async {
    await NotificationVoipPlugin.setCallConnected(sessionId);
  }

  /// Processes an NVP call state change event.
  ///
  /// Called from the [NotificationVoipPlugin.onCallStateChanged]
  /// subscription. Routes in-call control actions through the
  /// registered [CometChatCallActionHandler].
  static Future<void> handleCallStateChange(NvpCallState state) async {
    final sessionId = state.callId;
    await _actionHandler.onMuteToggled(sessionId, state.isMuted);
    await _actionHandler.onSpeakerToggled(sessionId, state.isSpeakerOn);
    await _actionHandler.onCameraToggled(sessionId, state.isCameraOn);
  }
}
