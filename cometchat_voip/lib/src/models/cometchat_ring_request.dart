import 'cometchat_voip_call.dart';

/// The ringer asking the app to show its own ring screen for [call].
///
/// Only in `CometChatCallMode.autoCustomScreen`, where the ring's full-screen
/// alert and its tap open the app rather than the package's native screen.
/// Reaches the app on `CometChatVoip.onRingScreenRequested`.
class CometChatRingRequest {
  /// The call that is ringing.
  final CometChatVoipCall call;

  /// Whether answering [call] ends a call that is live on this device.
  ///
  /// The Calls SDK is in one session at a time, so answering a second call
  /// leaves the first. Say so on the screen — the native ring says "Answering
  /// ends your current call" — because the user cannot see it anywhere else.
  final bool answerEndsActiveCall;

  /// Creates a [CometChatRingRequest].
  const CometChatRingRequest({
    required this.call,
    this.answerEndsActiveCall = false,
  });

  @override
  String toString() =>
      'CometChatRingRequest(${call.sessionId}, '
      'answerEndsActiveCall: $answerEndsActiveCall)';
}
