import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'cometchat_voip_method_channel.dart';
import 'src/models/cometchat_voip_call.dart';
import 'src/models/cometchat_voip_config.dart';
import 'src/models/cometchat_voip_enums.dart';

/// The contract every platform implementation of this plugin fulfils.
///
/// Everything that has to happen while Dart may not be running lives on the
/// native side: ringing, the lock-screen answer, the decline, the missed call.
/// Registering the push token is the one CometChat call made from Dart.
abstract class CometchatVoipPlatform extends PlatformInterface {
  /// Constructs a CometchatVoipPlatform.
  CometchatVoipPlatform() : super(token: _token);

  static final Object _token = Object();

  static CometchatVoipPlatform _instance = MethodChannelCometchatVoip();

  /// The default instance of [CometchatVoipPlatform] to use.
  ///
  /// Defaults to [MethodChannelCometchatVoip].
  static CometchatVoipPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [CometchatVoipPlatform] when they
  /// register themselves.
  static set instance(CometchatVoipPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Hands the native side the settings a killed app needs to ring, which it
  /// persists.
  Future<void> initialize(
    CometChatVoipConfig config, {
    int? backgroundCallbackHandle,
  }) {
    throw UnimplementedError('initialize() has not been implemented.');
  }

  /// Rings, or ends the ringing of, the call in [data]. Returns false when
  /// [data] is not a call push.
  Future<bool> handlePushNotification(
    Map<String, String> data, {
    int? sentTimeMs,
  }) {
    throw UnimplementedError(
      'handlePushNotification() has not been implemented.',
    );
  }

  /// The PushKit token as lowercase hex. iOS only; null elsewhere.
  Future<String?> getVoipToken() {
    throw UnimplementedError('getVoipToken() has not been implemented.');
  }

  /// The device's IANA time zone.
  Future<String?> getTimeZone() {
    throw UnimplementedError('getTimeZone() has not been implemented.');
  }

  /// Answers the ringing call [sessionId].
  Future<void> answer(String sessionId) {
    throw UnimplementedError('answer() has not been implemented.');
  }

  /// What answering [call] needs and this device has not granted.
  ///
  /// Empty when nothing is missing, and on a platform that asks for its
  /// permissions elsewhere.
  Future<List<CometChatCallPermission>> permissionsToAnswer(
    CometChatVoipCall call,
  ) {
    throw UnimplementedError('permissionsToAnswer() has not been implemented.');
  }

  /// Asks for what [permissionsToAnswer] reports, returning whether every one
  /// of them is granted afterwards.
  Future<bool> requestCallPermissions(CometChatVoipCall call) {
    throw UnimplementedError(
      'requestCallPermissions() has not been implemented.',
    );
  }

  /// Declines the ringing call [sessionId].
  ///
  /// [busy] sends `busy` rather than `rejected`, for a decline that happened
  /// because this device already has a call. The ringer also derives `busy`
  /// on its own from a call it answered; this says so for a call it cannot
  /// see, such as one the app placed.
  Future<void> decline(String sessionId, {bool busy = false}) {
    throw UnimplementedError('decline() has not been implemented.');
  }

  /// Stops ringing [sessionId], which the app answered or declined itself.
  Future<void> dismissRinging(String sessionId, {required bool answered}) {
    throw UnimplementedError('dismissRinging() has not been implemented.');
  }

  /// The call ringing or answered on this device, if any.
  Future<CometChatVoipCall?> getActiveCall() {
    throw UnimplementedError('getActiveCall() has not been implemented.');
  }

  /// Reports a call this device placed to CallKit. iOS only.
  Future<void> reportOutgoingCall({
    required String sessionId,
    required String calleeName,
    required bool hasVideo,
  }) {
    throw UnimplementedError('reportOutgoingCall() has not been implemented.');
  }

  /// Names a remote participant of the live session, so an outgoing call the
  /// package reported on its own can show who is called. iOS only.
  Future<void> reportRemoteParticipant({String? uid, String? name}) {
    throw UnimplementedError(
      'reportRemoteParticipant() has not been implemented.',
    );
  }

  /// Tells the native side the session for [sessionId] is joined.
  Future<void> reportCallConnected(String sessionId) {
    throw UnimplementedError('reportCallConnected() has not been implemented.');
  }

  /// Tells the native side the call [sessionId] is over.
  Future<void> reportCallEnded(
    String sessionId, {
    CometChatCallEndReason reason = CometChatCallEndReason.remoteEnded,
  }) {
    throw UnimplementedError('reportCallEnded() has not been implemented.');
  }

  /// The first thing on this device that would stop a call from ringing.
  Future<CometChatRingReadiness> checkRingReadiness() {
    throw UnimplementedError('checkRingReadiness() has not been implemented.');
  }

  /// Opens the system settings page that fixes [readiness]. Returns false
  /// when there is none.
  Future<bool> openSettings(CometChatRingReadiness readiness) {
    throw UnimplementedError('openSettings() has not been implemented.');
  }

  /// Prompts for the notification permission, returning whether it is granted.
  Future<bool> requestNotificationPermission() {
    throw UnimplementedError(
      'requestNotificationPermission() has not been implemented.',
    );
  }

  /// What the OS can tell about this device's push setup.
  Future<String> verifyPushSetup() {
    throw UnimplementedError('verifyPushSetup() has not been implemented.');
  }

  /// How long the last push-woken ring took to get ready, in milliseconds.
  Future<Map<String, Object?>> lastWakeTiming() {
    throw UnimplementedError('lastWakeTiming() has not been implemented.');
  }

  /// Posts the incoming-call notification and arms its expiry. Android only.
  Future<void> showIncomingNotification(CometChatVoipCall call) {
    throw UnimplementedError(
      'showIncomingNotification() has not been implemented.',
    );
  }

  /// Tears down every visible and scheduled trace of a ringing session.
  Future<void> stopRinging(String sessionId) {
    throw UnimplementedError('stopRinging() has not been implemented.');
  }

  /// Connects while ringing. Android only.
  Future<void> verifyCall(CometChatVoipCall call) {
    throw UnimplementedError('verifyCall() has not been implemented.');
  }

  /// Keeps the process alive while ringing. Android only.
  Future<void> keepAlive(CometChatVoipCall call) {
    throw UnimplementedError('keepAlive() has not been implemented.');
  }

  /// Posts a missed-call notification. Android only.
  Future<void> showMissedCall(CometChatVoipCall call) {
    throw UnimplementedError('showMissedCall() has not been implemented.');
  }

  /// Remembers [sessionId] as over, in the store that survives the process.
  Future<void> markTerminal(String sessionId, String reason) {
    throw UnimplementedError('markTerminal() has not been implemented.');
  }

  /// Whether [sessionId] is remembered as over.
  Future<bool> wasTerminal(String sessionId) {
    throw UnimplementedError('wasTerminal() has not been implemented.');
  }

  /// Why [sessionId] is remembered as over, if it is.
  Future<String?> terminalReason(String sessionId) {
    throw UnimplementedError('terminalReason() has not been implemented.');
  }

  /// The channel the ringer calls Dart back on, so `NativeCallsBridge` can
  /// install its handler. Null on a platform with no ringer.
  MethodChannel? get bridgeChannel => null;

  /// Tells the ringer what the Calls SDK's session is doing. It reads this
  /// synchronously, on threads that cannot wait for a round trip.
  Future<void> setSessionState({
    required bool active,
    required bool joined,
    String? sessionId,
  }) {
    throw UnimplementedError('setSessionState() has not been implemented.');
  }

  /// Tells the ringer the app muted or unmuted in its own UI, so the CallKit
  /// call shows it.
  Future<void> setSessionMuted(bool muted) {
    throw UnimplementedError('setSessionMuted() has not been implemented.');
  }

  /// Tells the ringer the app paused or resumed video in its own UI.
  Future<void> setSessionVideoPaused(bool paused) {
    throw UnimplementedError(
      'setSessionVideoPaused() has not been implemented.',
    );
  }

  /// Tells the ringer the Calls SDK reported a ringing call ending — how a
  /// caller's cancel often reaches this device before the push does.
  Future<void> sdkEndedCall(String sessionId, String reason) {
    throw UnimplementedError('sdkEndedCall() has not been implemented.');
  }

  /// Records whether this Calls SDK can take the CallKit audio session, so
  /// `getDiagnostics` can say why CallKit audio is off before any call rings.
  Future<void> setCallKitAudioHandoff(bool available) {
    throw UnimplementedError(
      'setCallKitAudioHandoff() has not been implemented.',
    );
  }

  /// Writes down who is logged in, so the ring gates can read it on a process
  /// no SDK has come up in.
  /// Saves the ring screen and call notification colours (the saved form of
  /// a `CometChatVoipIncomingCallTheme`), or clears them when null. Android
  /// only.
  Future<void> setIncomingCallTheme(Map<String, Object?>? theme) {
    throw UnimplementedError(
      'setIncomingCallTheme() has not been implemented.',
    );
  }

  Future<void> setLoggedInUid(String? uid) {
    throw UnimplementedError('setLoggedInUid() has not been implemented.');
  }

  /// Queues a decline durably, so it survives the process dying.
  Future<void> enqueueDecline(String sessionId, String status) {
    throw UnimplementedError('enqueueDecline() has not been implemented.');
  }

  /// A redacted snapshot of what the ringer depends on, for a bug report.
  Future<Map<String, Object?>> getDiagnostics() {
    throw UnimplementedError('getDiagnostics() has not been implemented.');
  }

  /// Answered calls, ended calls and VoIP token changes, in the order they
  /// happened. Events from before Dart listened are held, not dropped.
  Stream<Map<Object?, Object?>> get events {
    throw UnimplementedError('events has not been implemented.');
  }
}
