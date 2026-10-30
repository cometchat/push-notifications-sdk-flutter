import 'dart:async';

import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart' as calls;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

import 'cometchat_voip_platform_interface.dart';
import 'src/calls/call_accept_client.dart';
import 'src/calls/native_calls_bridge.dart';
import 'src/errors/cometchat_voip_exception.dart';
import 'src/models/cometchat_ring_request.dart';
import 'src/models/cometchat_voip_call.dart';
import 'src/models/cometchat_voip_config.dart';
import 'src/models/cometchat_voip_enums.dart';
import 'src/models/cometchat_voip_incoming_call_theme.dart';
import 'src/push/call_push_payload.dart';
import 'src/push/ring_gate.dart';
import 'src/token/push_token_client.dart';

export 'src/errors/cometchat_voip_exception.dart';
export 'src/models/cometchat_ring_request.dart';
export 'src/models/cometchat_voip_call.dart';
export 'src/models/cometchat_voip_config.dart';
export 'src/models/cometchat_voip_enums.dart';
export 'src/models/cometchat_voip_incoming_call_theme.dart';
export 'src/push/call_push_payload.dart' show CometChatCallAction;
export 'src/push/ring_gate.dart' show RingDrop, TerminalLedger;

/// Call notifications for CometChat.
///
/// This package holds no native code of its own. It turns a call push into a
/// ringing call on the **Calls SDK**, which owns the ringing: on iOS the call
/// rings through CallKit, and on both platforms it reaches every
/// `CometChatCalls.addIncomingCallListener`. What this package adds on top is
/// the push side — recognising a call push, dropping one that arrived too
/// late, registering the device's push token, and reporting the answer and
/// the decline.
///
/// ```dart
/// await CometChatVoip.init(
///   const CometChatVoipConfig(appId: 'APP_ID', region: 'us', providerId: 'ID'),
/// );
///
/// // The token comes from the app: FCM on Android, PushKit on iOS.
/// await CometChatVoip.registerPushToken(token: fcmToken);
///
/// CometChatVoip.onCallRinging.listen((call) {
///   // Show your incoming-call screen, then accept() or decline().
/// });
/// CometChatVoip.onCallAnswered.listen((call) {
///   // Join call.sessionId with CometChatCalls.
/// });
///
/// // Hand every push over; non-call pushes come straight back to you.
/// FirebaseMessaging.onMessage.listen(
///   (m) => CometChatVoip.handlePushNotification(m.data, sentTime: m.sentTime),
/// );
/// ```
///
/// Because the package owns no native code, the app owns the push transport:
/// `firebase_messaging` on Android, and PushKit in the iOS app's own
/// `AppDelegate` on iOS. Both hand their payload to [handlePushNotification]
/// and their token to [registerPushToken].
///
/// Chat notifications are `cometchat_push_notifications`' job; this package
/// only ever acts on call pushes.
class CometChatVoip {
  const CometChatVoip._();

  static CometChatVoipConfig? _config;

  static const _listenerId = 'cometchat_voip';

  static final _ringing = _HeldEvents<CometChatVoipCall>();
  static final _ringScreens = _HeldEvents<CometChatRingRequest>();
  static final _answered = _HeldEvents<CometChatVoipCall>();
  static final _ended = _HeldEvents<CometChatCallEnded>();
  static final _outgoingEnded = _HeldEvents<String>();

  static CometchatVoipPlatform get _platform => CometchatVoipPlatform.instance;

  /// The native ringer's events: answered, ended, and VoIP token changes.
  static StreamSubscription<Map<Object?, Object?>>? _events;

  static PushTokenClient _tokenClient = PushTokenClient();
  static CallAcceptClient _acceptClient = CallAcceptClient();

  /// How long an answer waits for a Calls SDK login before giving up on
  /// marking the call answered. An answer can arrive before the app has
  /// logged in.
  static const _loginWaitForAccept = Duration(seconds: 20);

  /// The auth token of the user logged in to the Calls SDK.
  static Future<String?> Function() _callsAuthToken =
      calls.CometChatCalls.getUserAuthToken;

  /// The push token the app handed over, kept so a later login can register it
  /// again without being asked.
  static String? _pushToken;

  /// The token last registered from this process.
  static String? _registeredToken;

  /// The call ringing on this device, if any.
  static CometChatVoipCall? _activeCall;

  /// The Calls SDK user, as last seen at init and on login and logout. Read
  /// synchronously by [_onCallEnded], which runs inside a listener callback.
  static String? _myUid;

  /// The session whose listeners are already attached, so they attach once.
  static calls.CallSession? _watchedSession;

  /// Sessions already reported answered, so an answer is never marked twice.
  static final Set<String> _answeredSessions = {};

  /// The session the Calls SDK has joined, as its own listeners last reported
  /// it. What makes answering a second call "End & accept": the SDK is in one
  /// session at a time, so the live one has to go first.
  static String? _liveSession;

  /// The sessions this process knows are over, so a redelivered push for one
  /// cannot revive it.
  static final TerminalLedger _ledger = TerminalLedger();

  /// The last token registration failure, for [getDiagnostics] and
  /// [verifyPushSetup]. Registration happens off the back of a login, where
  /// there is nobody to throw to.
  static Object? _lastTokenError;

  /// How many pushes this process has seen, and what became of them.
  static int _pushesSeen = 0;
  static int _pushesRung = 0;
  static int _pushesDropped = 0;

  /// How often a failed decline is retried, and how long it waits between
  /// tries. The native SDKs queue declines durably; this is the most a package
  /// with no native code and no storage can do.
  static const _declineRetries = 3;
  static const _declineBackoff = Duration(seconds: 2);

  /// The configuration [init] was called with, or null before then.
  static CometChatVoipConfig? get config => _config;

  /// Whether [init] has run.
  static bool get isInitialized => _config != null;

  /// The call ringing on this device, if any.
  static CometChatVoipCall? get activeCall => _activeCall;

  static CometChatVoipConfig _requireConfig() {
    final config = _config;
    if (config == null) {
      throw const CometChatVoipException(
        code: CometChatVoipErrorCode.notInitialized,
        message: 'CometChatVoip.init() must be called before use.',
      );
    }
    return config;
  }

  // ──────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────

  /// Initializes the package. Call once, early in `main`, and after
  /// `CometChatCalls.init` — the Calls SDK is what rings, so it has to be up
  /// before a push can be handed to it.
  ///
  /// On Android a push can start a killed app in a background isolate, where
  /// none of this has run. Initialize the Calls SDK and this package in that
  /// isolate too before calling [handlePushNotification].
  /// Whether the native ringer owns the ring in the configured mode — both
  /// [CometChatCallMode.auto] and [CometChatCallMode.autoCustomScreen], which
  /// differ only in whose screen the ring opens.
  static bool get _ringerOwnsRing =>
      (_config?.callMode ?? CometChatCallMode.auto) != CometChatCallMode.manual;

  static Future<void> init(CometChatVoipConfig config) async {
    _config = config;
    // The native side persists this, so a push that starts a killed app rings
    // before any Dart runs. The callback handle goes with it: it is how the
    // ringer starts an isolate to reach the Calls SDK when the app is gone.
    await _platform.initialize(
      config,
      backgroundCallbackHandle: cometchatVoipBackgroundHandle(),
    );
    _listen();

    // The session is watched from the start, not only once a 1-on-1 call was
    // answered or reported: a meeting the app joins itself is a live call too,
    // and a call declined during it has to go out `busy`, not `rejected`.
    _watchSession();
    unawaited(_reportSessionAtInit());

    // The ringer links no Calls SDK of its own, so every request it makes for
    // one comes back here. Attaching also flushes anything it had queued while
    // this isolate was starting — a push that launched the app.
    final bridgeChannel = _platform.bridgeChannel;
    if (bridgeChannel != null) await NativeCallsBridge.attach(bridgeChannel);

    // The ring gates run on a process no SDK has come up in, so the uid has to
    // be on disk before the push arrives.
    unawaited(_syncLoggedInUid());

    calls.CometChatCalls.addIncomingCallListener(
      _listenerId,
      const _IncomingCalls(),
    );

    // Always attached: the watcher is also what keeps the ring gates' uid
    // current, which the gates need whether or not this package registers the
    // push token. Registration itself is gated inside the watcher, through
    // [_registerQuietly].
    calls.CometChatCalls.addLoginListener(_listenerId, const _LoginWatcher());

    // The PushKit token arrives in didFinishLaunching, before this isolate
    // listens, and the native side holds no token for a late listener — so
    // it is asked for here, or it would never be registered and no call
    // would ring. In MANUAL the app owns PushKit and hands the token over.
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        config.callMode != CometChatCallMode.manual) {
      unawaited(_adoptNativeVoipToken());
    }

    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        config.callKitAudio) {
      await _enableCallKitAudioIfSafe();
    }

    // Android 13+ will not show a ring without it, and a call can arrive
    // before the app has any other reason to ask. Not awaited: the prompt
    // waits for the user, and init is on the path to a ringing call. It
    // needs a foreground activity, so it is refused — and only logged — on
    // the background isolate a push starts.
    if (!kIsWeb && config.requestNotificationPermission) {
      unawaited(
        requestNotificationPermission().catchError((Object e) {
          calls.CometChatCallsLogger.error(
            'CometChatVoip: asking for notification permission: $e',
          );
          return false;
        }),
      );
    }
  }

  /// Turns CallKit audio on, but only on a Calls SDK that can finish the job.
  ///
  /// `callKitAudio: true` is a request, not a command. The flag makes WebRTC
  /// wait to be told the audio session is live, and only
  /// `notifyCallKitAudioActivated` can tell it; on an SDK without that binding
  /// the flag would leave a connected call completely silent, with nothing in
  /// the logs of an app that does not read ours. So the flag goes on only once
  /// the handoff is known to be there. Otherwise CallKit audio stays off and
  /// WebRTC manages its own session, which is audible — the point of the gate
  /// is that a missing handoff costs a little audio quality rather than all of
  /// the audio.
  static Future<void> _enableCallKitAudioIfSafe() async {
    final available = await NativeCallsBridge.callKitAudioHandoffAvailable();

    if (available != null) {
      // Worth recording either way: `getDiagnostics` is where an integrator
      // looks to find out why CallKit audio is off, and a silent call has no
      // other symptom.
      try {
        await _platform.setCallKitAudioHandoff(available);
      } catch (_) {
        // Diagnostics only. Never worth failing init over.
      }
    }

    if (available != true) {
      final why = available == null
          ? 'a call is already up, so the handoff could not be checked'
          : 'this Calls SDK has no notifyCallKitAudioActivated';
      calls.CometChatCallsLogger.error(
        'CometChatVoip: callKitAudio is on, but $why. Leaving CallKit audio '
        'off so the call has sound — WebRTC manages its own audio session '
        'instead.',
      );
      return;
    }

    try {
      await calls.CometChatCalls.setCallKitAudioEnabled(true);
    } catch (e) {
      // Not fatal: the call still rings, it just starts its audio session
      // the way a non-CallKit call does.
      calls.CometChatCallsLogger.error(
        'CometChatVoip: could not hand the audio session to CallKit: $e',
      );
    }
  }

  /// Stops listening to the Calls SDK and to the native ringer. Calls keep
  /// ringing — the Calls SDK is what rings them — but this package no longer
  /// reports them. [init] listens again.
  static Future<void> dispose() async {
    calls.CometChatCalls.removeIncomingCallListener(_listenerId);
    calls.CometChatCalls.removeLoginListener(_listenerId);
    await _events?.cancel();
    _events = null;
    _config = null;
    _activeCall = null;
  }

  /// Takes the PushKit token the native ringer already has, and registers it
  /// if somebody is logged in. Otherwise the next Calls SDK login does.
  ///
  /// Not awaited by [init]: the native side waits a moment for a token
  /// PushKit has not delivered yet, and one that comes later arrives as a
  /// `voipToken` event instead.
  static Future<void> _adoptNativeVoipToken() async {
    try {
      final token = await _platform.getVoipToken();
      if (token == null || token.isEmpty) return;
      setPushToken(token);
      final config = _config;
      if (config == null) return;
      final authToken = config.authToken ?? await _callsAuthToken();
      if (authToken == null || authToken.isEmpty) return;
      await _registerQuietly();
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: reading the VoIP token: $e',
      );
    }
  }

  /// Subscribes to the native ringer. Idempotent.
  static void _listen() {
    _events ??= _platform.events.listen(_onNativeEvent);
  }

  /// Watches the Calls SDK's session so the ringer does not need the app to
  /// report it.
  ///
  /// The ringer owns the CallKit call and the Android ring but cannot see the
  /// session — the Calls SDK lives behind Dart — so it reads a snapshot. The
  /// native SDKs subscribe to these listeners themselves; this is how the
  /// package does the same, which is what makes `reportCallConnected` and the
  /// rest optional rather than load-bearing.
  ///
  /// The session is a singleton created on the first join, so this re-attaches
  /// whenever one appears.
  static void _watchSession() {
    final session = calls.CallSession.getInstance();
    if (session == null || identical(session, _watchedSession)) return;
    _watchedSession = session;
    final listener = _SessionWatcher();
    session
      ..addSessionStatusListener(listener)
      ..addMediaEventsListener(listener)
      // A mute is mirrored onto the CallKit call only when the user asked for
      // it on the call screen, which is what this listener says.
      ..addButtonClickListener(listener)
      // Who is on the call, so an outgoing call the ringer reported on its own
      // can be named.
      ..addParticipantEventListener(_ParticipantWatcher());
  }

  /// Reports a session the Calls SDK already has when [init] runs, which the
  /// listeners [_watchSession] attaches would not hear again. Only a session
  /// that is there, never its absence: a report that clears the state is left
  /// to the listeners.
  static Future<void> _reportSessionAtInit() async {
    final session = calls.CallSession.getInstance();
    if (session == null) return;
    try {
      final joined = await session.isSessionJoined();
      final active = joined || await session.isSessionActive();
      if (active) await _sessionChanged(active: true, joined: joined);
    } catch (_) {
      // Nothing to report: the listeners take over from here.
    }
  }

  /// Reports the session the Calls SDK now has, straight from its listeners.
  static Future<void> _sessionChanged({
    required bool active,
    required bool joined,
  }) async {
    final session = calls.CallSession.getInstance();
    String? sessionId;
    try {
      sessionId = await session?.getSessionId();
    } catch (_) {
      // A session being torn down; the id is gone and `active: false` is what
      // matters.
    }
    // A session joined without a prepare has no id in the Calls SDK — a call
    // answered over a live one never is prepared — so a join reported without
    // one is the live session already known, if there is one.
    final id =
        sessionId ?? (joined ? _liveSession : null) ?? _activeCall?.sessionId;
    // Remembered for "End & accept": answering a second call has to leave
    // this one first. A join without an id must not forget it, or the next
    // "End & accept" leaves nothing and joins on top of the live call.
    // Cleared on anything but a join, so a session being torn down is never
    // ended twice.
    if (joined) {
      if (id != null) _liveSession = id;
    } else {
      _liveSession = null;
    }
    await _setSessionState(active: active, joined: joined, sessionId: id);
  }

  /// Writes the logged-in uid where the ring gates can read it.
  ///
  /// A uid it cannot find is left alone rather than written as null. At [init]
  /// the Calls SDK may not have restored its login yet, and a null uid is how
  /// a logout is reported: the ringer ends a call that is still ringing for a
  /// user who is gone. On a process a call push launched, that is the call
  /// being rung. [_LoginWatcher.logoutSuccess] is what clears it.
  static Future<void> _syncLoggedInUid() async {
    try {
      final uid = await _loggedInUid();
      if (uid == null) return;
      _myUid = uid;
      await _platform.setLoggedInUid(uid);
    } catch (_) {
      // A platform without a ringer; the Dart gates still run.
    }
  }

  // ──────────────────────────────────────────────
  // Incoming pushes
  // ──────────────────────────────────────────────

  /// Hands one push to the Calls SDK, returning whether it was a call push.
  ///
  /// A call push that announces a new call starts the ringing, and one that
  /// announces the call is over stops it. False means the payload was not a
  /// call push and is still yours — a chat message, say, for
  /// `cometchat_push_notifications`.
  ///
  /// **Android.** Call from both of `firebase_messaging`'s handlers:
  /// `onMessage`, and the background handler, which is what runs when the app
  /// is killed. Pass the message's `sentTime`: FCM holds pushes while a device
  /// dozes, and without it a push delivered late rings for a call that is
  /// already over.
  ///
  /// Send call pushes at high priority. Android only lets a background app
  /// keep itself alive through the answer when a high-priority message woke it.
  ///
  /// **iOS.** Call from the app's own PushKit delegate
  /// (`pushRegistry(_:didReceiveIncomingPushWith:)`), forwarded to Dart. This
  /// package owns no native code, so it cannot see the PushKit push itself.
  /// Report the call to CallKit in that same delegate callback — iOS kills an
  /// app that takes a VoIP push without reporting a call.
  static Future<bool> handlePushNotification(
    Map<String, dynamic> payload, {
    DateTime? sentTime,
  }) async {
    final data = <String, String>{
      for (final MapEntry(:key, :value) in payload.entries)
        if (value != null) key: value.toString(),
    };

    final push = CallPushPayload.parse(data);
    if (push == null) return false;

    _pushesSeen++;
    final config = _config;

    // AUTO: the native ringer owns everything from here — the gates, the ring,
    // the expiry, the keep-alive and the decline queue — because it has to run
    // on processes no Dart reaches: a notification action, an alarm, a
    // WorkManager job. It reports back on the event channel.
    if (_ringerOwnsRing) {
      _listen();
      try {
        final handled = await _platform.handlePushNotification(
          data,
          sentTimeMs: sentTime?.millisecondsSinceEpoch,
        );
        if (handled) _pushesRung++;
        return handled;
      } on MissingPluginException {
        // No ringer on this platform: fall through to the Dart path, which
        // still gates the call and hands it to the Calls SDK.
      }
    }

    final ringTimeout =
        config?.defaultRingTimeout ??
        const Duration(milliseconds: CallPushPayload.defaultRingTimeoutMs);
    final receivedAt = sentTime ?? DateTime.now();

    CometChatVoipCall callOf() => CometChatVoipCall.fromPushPayload(
      push,
      receivedAt: receivedAt,
      defaultRingTimeout: ringTimeout,
    );

    if (push.action.isTerminal) {
      final reason = CometChatCallEndReason.fromAction(push.action);
      // Remembered before the inject, so a redelivered `initiated` for this
      // session cannot revive a call that is already over.
      _markTerminal(push.sessionId, push.rawAction);
      await _inject(
        () => calls.CometChatCalls.injectIncomingCallEnded(
          push.raw,
          reason.wireName,
        ),
        push,
        // The SDK reports the end to the listener only for a call it had
        // ringing. A terminal push for one it never saw still has to reach
        // the app, so that a missed call is recorded.
        fallback: () => _emitEnded(callOf(), reason),
      );
      return true;
    }

    // An action this build does not know neither rings nor silences a call,
    // which is what the native ringer does with it (`RingingCallHandler`
    // logs it and ignores it). Falling through to the gate rang it like an
    // `initiated`.
    if (push.action == CometChatCallAction.unknown) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: unknown call action "${push.rawAction}" for '
        '${push.sessionId} — ignoring',
      );
      return true;
    }

    // The native store persists the ledger, so a duplicate arriving on a cold
    // process is still caught; the in-memory one is the fallback.
    await _primeLedger(push.sessionId);

    final drop = RingGate.decide(
      push,
      myUid: await _loggedInUid(),
      ledger: _ledger,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      receivedAtMs: receivedAt.millisecondsSinceEpoch,
      dropExpired: config?.dropExpiredCalls ?? true,
    );
    if (drop != null) {
      _pushesDropped++;
      calls.CometChatCallsLogger.error(
        'CometChatVoip: did not ring ${push.sessionId} — ${drop.reason}',
      );
      if (drop.markTerminal) {
        _markTerminal(push.sessionId, drop.endAs.wireName);
      }
      _emitEnded(callOf(), drop.endAs);
      return true;
    }

    _pushesRung++;
    await _inject(
      () => calls.CometChatCalls.injectIncomingCall(push.raw),
      push,
    );
    return true;
  }

  /// Copies what the native store knows about [sessionId] into the in-memory
  /// ledger, so the gate sees a session an earlier process ended.
  static Future<void> _primeLedger(String sessionId) async {
    if (_ledger.wasTerminal(sessionId)) return;
    try {
      if (await _platform.wasTerminal(sessionId)) {
        _ledger.markTerminal(
          sessionId,
          await _platform.terminalReason(sessionId) ?? 'ended',
        );
      }
    } catch (_) {
      // No native store here; the in-memory ledger is all there is.
    }
  }

  /// Remembers [sessionId] as over, in memory and on disk.
  static void _markTerminal(String sessionId, String reason) {
    _ledger.markTerminal(sessionId, reason);
    unawaited(
      _platform.markTerminal(sessionId, reason).catchError((Object _) {}),
    );
  }

  /// How long a call rings when its push does not say.
  static Duration get _ringTimeout =>
      _config?.defaultRingTimeout ??
      const Duration(milliseconds: CallPushPayload.defaultRingTimeoutMs);

  /// The logged-in user's UID, or null when this process cannot tell whose
  /// device it is — a background isolate before the Calls SDK has restored its
  /// session. The ring gates are deliberately weaker then, never wrong.
  static Future<String?> _loggedInUid() async {
    try {
      final user = await calls.CometChatCalls.getLoggedInUser();
      final uid = user?.uid.trim();
      return uid == null || uid.isEmpty ? null : uid;
    } catch (_) {
      return null;
    }
  }

  /// Runs one inject, turning a Calls SDK refusal into a log rather than an
  /// error: a push handler has nobody to throw to, and on Android it runs in a
  /// background isolate where an uncaught error takes the ring with it.
  static Future<void> _inject(
    Future<calls.InitiatedCall?> Function() inject,
    CallPushPayload push, {
    void Function()? fallback,
  }) async {
    try {
      final call = await inject();
      if (call == null && fallback != null) fallback();
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: the Calls SDK refused ${push.sessionId} '
        '(${push.rawAction}): $e',
      );
      if (fallback != null) fallback();
    }
  }

  // ──────────────────────────────────────────────
  // Calls
  // ──────────────────────────────────────────────

  /// Calls that started ringing on this device.
  ///
  /// Show your incoming-call screen here, then [accept] or [decline]. On iOS
  /// the call is also ringing in CallKit, which answers and declines it
  /// without any of this.
  ///
  /// A call that arrived before anything listened — the push that launched the
  /// app — is held and delivered to the first listener.
  static Stream<CometChatVoipCall> get onCallRinging => _ringing.stream;

  /// The ringer asking for the app's own ring screen, in
  /// [CometChatCallMode.autoCustomScreen].
  ///
  /// It fires when the ring's full-screen alert opens the app on a locked
  /// device, and when the user taps the ring — the two moments Android would
  /// otherwise open the package's own screen. Everything else about the ring
  /// stays the package's: the notification, the ringtone, the gates, the
  /// expiry, the keep-alive, the busy handling, and the notification's own
  /// Answer and Decline.
  ///
  /// Push the screen here; [answer] and [decline] are its buttons, and
  /// [onCallEnded] for the same session is when to close it — the call was
  /// cancelled, answered elsewhere or rang out.
  ///
  /// The request that launched the app is held and delivered to the first
  /// listener, so a screen subscribed in `initState` still gets it. Never
  /// fires in [CometChatCallMode.auto] or [CometChatCallMode.manual], and
  /// never on iOS, where CallKit is the ring.
  ///
  /// ```dart
  /// CometChatVoip.onRingScreenRequested.listen((request) {
  ///   navigator.push(MaterialPageRoute(
  ///     builder: (_) => IncomingCallScreen(
  ///       call: request.call,
  ///       endsCurrentCall: request.answerEndsActiveCall,
  ///     ),
  ///   ));
  /// });
  /// ```
  static Stream<CometChatRingRequest> get onRingScreenRequested =>
      _ringScreens.stream;

  /// Calls the user answered, from CallKit on iOS or from [accept].
  ///
  /// Show the call screen and join `call.sessionId` straight away. On iOS this
  /// fires while the phone may still be locked; joining then is what connects
  /// the audio before the user unlocks.
  static Stream<CometChatVoipCall> get onCallAnswered => _answered.stream;

  /// Calls that stopped ringing without being answered here. Close the
  /// incoming-call screen on these.
  static Stream<CometChatCallEnded> get onCallEnded => _ended.stream;

  /// Session ids of outgoing calls the native call screen ended — the lock
  /// screen's hang-up, or CallKit's own End. iOS only.
  ///
  /// A call this device placed is in no incoming-call store, so it cannot
  /// reach [onCallEnded]. Close the outgoing or call screen for the session
  /// here, and withdraw a call the callee has not answered yet
  /// (`CometChatCalls.endCall` with `cancelled`) — the CallKit call is already
  /// gone, and nothing else tells the far side.
  static Stream<String> get onOutgoingCallEnded => _outgoingEnded.stream;

  /// Reports that the user answered [sessionId] in the app's own
  /// incoming-call screen. [onCallAnswered] follows, and the app joins the
  /// session from there.
  ///
  /// With [CometChatVoipConfig.acceptOnAnswer] on — the default — this also
  /// marks the call answered with CometChat, which is what a caller on the
  /// Chat SDK's calling waits for.
  ///
  /// On iOS a call answered in CallKit reaches [onCallAnswered] by itself;
  /// this is for an app that rings in its own UI.
  static Future<void> accept(String sessionId) async {
    final call = _activeCall?.sessionId == sessionId
        ? _activeCall!
        : CometChatVoipCall(
            sessionId: sessionId,
            callerName: 'Unknown caller',
            callType: CometChatVoipCall.typeAudio,
            receiverType: CometChatVoipCall.receiverTypeUser,
            initiatedAt: DateTime.now(),
            ringTimeout: _ringTimeout,
          );
    _emitAnswered(call);
  }

  /// Answers the ringing call [sessionId], as the Answer button does, for an
  /// in-app incoming-call screen. [onCallAnswered] follows.
  ///
  /// Prefer this over [accept] in [CometChatCallMode.auto]: it stops the
  /// native ring as well, so the notification and CallKit stay in step with
  /// what the user did in the app. [accept] only reports the answer.
  ///
  /// It also does the two things the ring's own Answer button does, so an
  /// app's ring screen does not have to: it asks for the microphone, and the
  /// camera for a video call, when
  /// [CometChatVoipConfig.requestCallPermissions] is on, and it leaves a call
  /// that is live on this device — the Calls SDK holds one session at a time,
  /// so answering a second call is "End & accept".
  static Future<void> answer(String sessionId) async {
    try {
      await _platform.answer(sessionId);
    } on MissingPluginException {
      // No ringer on this platform: report the answer and let the app join.
      await accept(sessionId);
    }
  }

  /// What answering [call] needs and this device has not granted: the
  /// microphone always, the camera for a video call.
  ///
  /// For an app that rings in its own UI — [CometChatCallMode.autoCustomScreen]
  /// or [CometChatCallMode.manual] — and wants to show the state, or ask
  /// before the user ever taps Answer. [answer] asks for whatever is missing
  /// by itself, so checking is optional.
  ///
  /// Empty on iOS once the app has been granted both, and for a call answered
  /// in CallKit, where iOS asks on the app's behalf.
  static Future<List<CometChatCallPermission>> permissionsToAnswer(
    CometChatVoipCall call,
  ) async {
    try {
      return await _platform.permissionsToAnswer(call);
    } on MissingPluginException {
      return const [];
    }
  }

  /// Asks for what [permissionsToAnswer] reports, returning whether every one
  /// of them is granted afterwards.
  ///
  /// Never fails a call: answer whatever the user chose. A denied microphone
  /// joins the call muted, which is still better than not joining, and
  /// [checkRingReadiness] reports it as
  /// [CometChatRingReadiness.microphoneDenied] afterwards.
  ///
  /// Needs the app in the foreground, so call it from the app's own ring
  /// screen. On a locked device Android asks the user to unlock first.
  static Future<bool> requestCallPermissions(CometChatVoipCall call) async {
    try {
      return await _platform.requestCallPermissions(call);
    } on MissingPluginException {
      return true;
    }
  }

  /// Stops ringing [sessionId], which the app has already answered or
  /// declined through its own UI and reported to CometChat itself — the UI
  /// Kit's incoming-call overlay, say, with `acceptCall` or `rejectCall`.
  ///
  /// Nothing is sent to CometChat, and [onCallEnded] does not fire. With
  /// [answered], the session prepared while ringing is kept for the app's
  /// join; otherwise it is released. A no-op for a call that is not ringing.
  ///
  /// Mirrors `onIncomingCallScreenOpened` / `onIncomingCallScreenClosed` on
  /// Android.
  static Future<void> dismissRinging(
    String sessionId, {
    required bool answered,
  }) => _platform.dismissRinging(sessionId, answered: answered);

  /// The call ringing or answered on this device, if any, read from the native
  /// store — so it is right even on a process that has just started.
  ///
  /// [activeCall] is the synchronous, in-memory view of the same thing.
  static Future<CometChatVoipCall?> getActiveCall() =>
      _platform.getActiveCall();

  /// Reports a call this device placed, so CallKit knows about it: it can then
  /// be ended from the lock screen, survives a cellular call, and appears in
  /// Recents. iOS only; a no-op elsewhere.
  ///
  /// Follow it with [reportCallConnected] once the session joins and
  /// [reportCallEnded] when it is over.
  static Future<void> reportOutgoingCall({
    required String sessionId,
    required String calleeName,
    bool hasVideo = false,
  }) => _platform.reportOutgoingCall(
    sessionId: sessionId,
    calleeName: calleeName,
    hasVideo: hasVideo,
  );

  /// Tells the package the session [sessionId] is joined. CallKit starts its
  /// call timer from here.
  static Future<void> reportCallConnected(String sessionId) async {
    // Optional: `_watchSession` reports the join by itself. Kept because an app
    // that calls it loses nothing, and it is the only route when the app drives
    // a session this package never saw ring.
    _watchSession();
    // Remembered for "End & accept", as the session's own listeners do:
    // answering a second call has to leave this one first.
    _liveSession = sessionId;
    // The ringer reads this to tell a live call from a prepared one.
    await _setSessionState(active: true, joined: true, sessionId: sessionId);
    await _platform.reportCallConnected(sessionId);
  }

  /// Tells the package the call [sessionId] is over, when the app ended it.
  ///
  /// On iOS this ends the CallKit call. On Android it lets the app's screen
  /// stop showing over the lock screen, which it did for the answered call.
  /// [reason] is what CallKit records for the call, and what an app's own
  /// call log would show.
  static Future<void> reportCallEnded(
    String sessionId, {
    CometChatCallEndReason reason = CometChatCallEndReason.remoteEnded,
  }) async {
    if (_liveSession == sessionId) _liveSession = null;
    // With its id: without one the ringer ends whichever call it tracks,
    // which after "End & accept" is the call just answered.
    await _setSessionState(active: false, joined: false, sessionId: sessionId);
    await _platform.reportCallEnded(sessionId, reason: reason);
  }

  /// Names a remote participant of the live session to the ringer.
  ///
  /// An outgoing call the ringer put on CallKit itself — one the app never
  /// reported — carries the app's own name until the other party is in the
  /// room, because the Calls SDK does not say who is called. This is how it
  /// learns.
  static Future<void> _reportRemoteParticipant(calls.Participant p) async {
    if (p.uid == null || p.uid == _myUid) return;
    try {
      await _platform.reportRemoteParticipant(uid: p.uid, name: p.name);
    } catch (_) {
      // No ringer here.
    }
  }

  /// Reports that the app muted or unmuted the call in its own UI, so the
  /// CallKit call on iOS shows it.
  ///
  /// The ringer owns the CallKit call but cannot see the session, so a mute
  /// made anywhere but CallKit has to be reported or the two drift apart.
  static Future<void> reportMuted(bool muted) async {
    try {
      await _platform.setSessionMuted(muted);
    } catch (_) {
      // No ringer here.
    }
  }

  /// Reports that the app paused or resumed video in its own UI.
  static Future<void> reportVideoPaused(bool paused) async {
    try {
      await _platform.setSessionVideoPaused(paused);
    } catch (_) {
      // No ringer here.
    }
  }

  /// Tells the ringer what the session is doing. Never throws: it is a hint,
  /// and a platform without a ringer simply has nobody to hint to.
  static Future<void> _setSessionState({
    required bool active,
    required bool joined,
    String? sessionId,
  }) async {
    try {
      await _platform.setSessionState(
        active: active,
        joined: joined,
        sessionId: sessionId,
      );
    } catch (_) {
      // No ringer here.
    }
  }

  // ──────────────────────────────────────────────
  // Readiness
  // ──────────────────────────────────────────────

  /// The first thing on this device that would stop a call from ringing, or
  /// [CometChatRingReadiness.ready].
  ///
  /// None of these produce an error anywhere — the call simply does not ring —
  /// so check at sign-in and send the user to [openSettings] for anything else.
  static Future<CometChatRingReadiness> checkRingReadiness() =>
      _platform.checkRingReadiness();

  /// Opens the system settings page that fixes [readiness]. Returns false when
  /// there is no such page, as for a missing iOS entitlement, which is fixed in
  /// the build.
  ///
  /// Mirrors `settingsIntentFor` on Android.
  static Future<bool> openSettings(CometChatRingReadiness readiness) =>
      _platform.openSettings(readiness);

  /// Sets the colours of the ring screen this package draws in
  /// [CometChatCallMode.auto] on Android, and of its ring, connecting and
  /// missed-call notifications; null clears them.
  ///
  /// Saved natively and read on every ring, so it applies to the next ring,
  /// including one that starts a killed app. Call it again when the app's
  /// theme changes (an in-app light/dark toggle, say). The last theme set
  /// wins, whether from here or from [CometChatVoipConfig.incomingCallTheme].
  ///
  /// Does nothing on iOS, where CallKit draws the ring and cannot be styled.
  static Future<void> setIncomingCallTheme(
    CometChatVoipIncomingCallTheme? theme,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _platform.setIncomingCallTheme(theme?.toMap());
  }

  /// Prompts for notification permission, which Android 13+ needs before a
  /// call can ring. Returns whether it is granted.
  ///
  /// iOS rings through CallKit, which needs no permission, so this reports the
  /// standing notification permission there without prompting.
  static Future<bool> requestNotificationPermission() =>
      _platform.requestNotificationPermission();

  /// How long the last push-woken ring took to get ready: `sdkReadyMs` for
  /// bringing the Calls SDK up, `connectMs` for the connect that followed.
  ///
  /// The one pair of numbers that tells a slow ring from a ring that never
  /// started. Null entries until a push has woken the process.
  static Future<Map<String, Object?>> lastWakeTiming() =>
      _platform.lastWakeTiming();

  // ──────────────────────────────────────────────
  // Ring surfaces
  // ──────────────────────────────────────────────

  /// Everything the ringer does in [CometChatCallMode.auto], a piece at a
  /// time, for an app in [CometChatCallMode.manual].
  ///
  /// Android only: on iOS reporting a call to CallKit *is* the ring, and it is
  /// all or nothing, so each of these throws
  /// [CometChatVoipErrorCode.unsupportedPlatform] there.
  ///
  /// Mirrors `CometChatCallNotifications.Calls` on Android.
  static const ringSurfaces = CometChatVoipRingSurfaces._();

  /// Runs one ring surface, turning the platform's refusal into this
  /// package's own exception so an app catches one kind of error.
  static Future<void> _ringSurface(Future<void> Function() body) async {
    try {
      await body();
    } on PlatformException catch (e) {
      throw CometChatVoipException(
        code: e.code == 'unsupported_platform'
            ? CometChatVoipErrorCode.unsupportedPlatform
            : CometChatVoipErrorCode.pluginError,
        message: e.message ?? 'The ring surface failed: ${e.code}',
        cause: e,
      );
    } on MissingPluginException catch (e) {
      throw CometChatVoipException(
        code: CometChatVoipErrorCode.unsupportedPlatform,
        message: 'The ring surfaces are Android-only.',
        cause: e,
      );
    }
  }

  /// The VoIP push token iOS issued, as lowercase hex, waiting briefly for one.
  /// iOS only; null elsewhere.
  ///
  /// In [CometChatCallMode.auto] the package owns the `PKPushRegistry` and
  /// gets this itself, so an app need not touch PushKit at all. In
  /// [CometChatCallMode.manual] the app owns the registry and hands the token
  /// over with [setPushToken] instead.
  static Future<String?> getVoipToken() => _platform.getVoipToken();

  /// Declines the ringing call [sessionId].
  ///
  /// Sends `busy` rather than `rejected` with [busy] on, for a decline that
  /// happened because another call is already in progress.
  ///
  /// Retried a few times with a short backoff, because a decline that does not
  /// land leaves the caller ringing at nobody. It is not durable the way the
  /// native SDKs' decline queue is: a process killed mid-retry forgets it, and
  /// surviving that needs storage this package does not have. Still throws
  /// once the retries are spent, so the app can tell the user.
  static Future<void> decline(String sessionId, {bool busy = false}) async {
    if (_activeCall?.sessionId == sessionId) _activeCall = null;

    final reason = busy ? 'busy' : 'rejected';
    final status = busy
        ? calls.EndCallStatus.busy
        : calls.EndCallStatus.rejected;

    // AUTO: hand it to the native queue, which retries across a process death
    // — the app can be suspended the instant after the tap.
    if (_ringerOwnsRing) {
      try {
        // Marked terminal only once the ringer has it. The native decline
        // treats an already-terminal session as a double tap and returns
        // without sending anything, so marking first dropped the `endCall`
        // and left the caller ringing at nobody. The ringer records the
        // session itself when it clears it.
        await _platform.decline(sessionId, busy: busy);
        _markTerminal(sessionId, reason);
        return;
      } on MissingPluginException {
        // No ringer here; send it from Dart below.
      } catch (_) {
        // The ringer refused it and so recorded nothing: remember it here, as
        // before this call reached the ringer at all.
        _markTerminal(sessionId, reason);
        rethrow;
      }
    }

    _markTerminal(sessionId, reason);
    Object? last;
    for (var attempt = 1; attempt <= _declineRetries; attempt++) {
      try {
        await _endCall(sessionId, status);
        return;
      } on CometChatVoipException catch (e) {
        last = e;
        if (attempt < _declineRetries) {
          calls.CometChatCallsLogger.error(
            'CometChatVoip: declining $sessionId failed (attempt $attempt of '
            '$_declineRetries), retrying: ${e.message}',
          );
          await Future<void>.delayed(_declineBackoff * attempt);
        }
      }
    }
    throw last!;
  }

  /// One `endCall`, as a future.
  static Future<void> _endCall(String sessionId, String status) {
    final completer = Completer<void>();
    calls.CometChatCalls.endCall(
      sessionId: sessionId,
      status: status,
      // 5.1.0-team's endCall reports no data; EndedCall is gone with it.
      onSuccess: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        if (!completer.isCompleted) {
          completer.completeError(
            CometChatVoipException(
              code: CometChatVoipErrorCode.callsSdkError,
              message: 'Declining $sessionId failed: ${e.message}',
              cause: e,
            ),
          );
        }
      },
    );
    return completer.future;
  }

  // ──────────────────────────────────────────────
  // Push token
  // ──────────────────────────────────────────────

  /// Remembers the device's push token without registering it yet, for an app
  /// whose token arrives before anybody has logged in.
  ///
  /// With [CometChatVoipConfig.autoRegisterPushToken] on — the default — the
  /// next Calls SDK login registers it.
  static void setPushToken(String token) {
    if (token.isEmpty || token == _pushToken) return;
    _pushToken = token;
    _registeredToken = null;
  }

  /// Registers this device's push token with CometChat, so calls reach it.
  ///
  /// [token] is the token the app obtained: the **FCM** token from
  /// `firebase_messaging` on Android, the **PushKit VoIP** token on iOS. This
  /// package holds no native code, so it cannot obtain either itself. The
  /// token is remembered for the logins that follow, and may be left out once
  /// it has been passed in once, here or through [setPushToken].
  ///
  /// An app that also registers the same token for chat with
  /// `cometchat_push_notifications` may do both: the backend keeps one entry
  /// per token.
  static Future<void> registerPushToken({String? token}) async {
    final config = _requireConfig();
    final request = await _request(config, token: token);
    try {
      await _tokenClient.register(request);
    } catch (e) {
      _lastTokenError = e;
      rethrow;
    }
    _registeredToken = request.token;
    _lastTokenError = null;
  }

  /// Takes a rotated push token and registers it in place of the old one.
  ///
  /// The FCM token from `onTokenRefresh` on Android, or a new PushKit token
  /// from `didUpdate pushCredentials` on iOS. Mirrors `handleTokenRefresh` on
  /// Android and `fcmTokenDidRefresh` on iOS.
  ///
  /// Unregisters nothing: the backend keeps one entry per token, and the old
  /// one stops being delivered to on its own. Failures are reported through
  /// [getDiagnostics] rather than thrown — a token callback has nobody to
  /// throw to — unless [throwOnError] is set.
  static Future<void> handleTokenRefresh(
    String token, {
    bool throwOnError = false,
  }) async {
    if (token.isEmpty || token == _registeredToken) return;
    _pushToken = token;
    _registeredToken = null;
    if (_config == null) return;
    try {
      await registerPushToken(token: token);
      _lastTokenError = null;
    } on CometChatVoipException catch (e) {
      _lastTokenError = e;
      calls.CometChatCallsLogger.error('CometChatVoip: $e');
      if (throwOnError) rethrow;
    }
  }

  /// Records that the OS refused to issue a push token.
  ///
  /// On iOS pass the error from
  /// `didFailToRegisterForRemoteNotificationsWithError`, or from the app's
  /// PushKit delegate. It is what surfaces a missing Push Notifications
  /// capability, a missing `voip` background mode, or bad provisioning — none
  /// of which produce any other symptom than calls silently never arriving.
  ///
  /// Mirrors `handleRegistrationFailure` on iOS. The error is logged and
  /// reported by [getDiagnostics] and [verifyPushSetup].
  static void handleRegistrationFailure(Object error) {
    _lastTokenError = error;
    calls.CometChatCallsLogger.error(
      'CometChatVoip: the OS refused to issue a push token, so no call can '
      'arrive. Check the Push Notifications capability, the "voip" background '
      'mode and the provisioning profile: $error',
    );
  }

  /// Unregisters this device's push token, so calls stop reaching it.
  ///
  /// Call before logging out, while the auth token that owns it still works.
  static Future<void> unregisterPushToken() async {
    final config = _requireConfig();
    final request = await _request(config, token: _pushToken);
    await _tokenClient.unregister(request);
    _registeredToken = null;
  }

  static Future<PushTokenRequest> _request(
    CometChatVoipConfig config, {
    String? token,
  }) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      throw const CometChatVoipException(
        code: CometChatVoipErrorCode.unsupportedPlatform,
        message: 'VoIP push tokens exist only on Android and iOS.',
      );
    }
    final kind = defaultTargetPlatform == TargetPlatform.iOS
        ? PushTokenKind.apnsVoip
        : PushTokenKind.fcmAndroid;

    final resolved = token ?? _pushToken;
    if (resolved == null || resolved.isEmpty) {
      throw CometChatVoipException(
        code: CometChatVoipErrorCode.noPushToken,
        message: kind == PushTokenKind.apnsVoip
            ? 'Pass the PushKit VoIP token from the app\'s PKPushRegistry '
                  'delegate to registerPushToken(token:).'
            : 'Pass the FCM token from firebase_messaging to '
                  'registerPushToken(token:).',
      );
    }
    _pushToken = resolved;

    final authToken = config.authToken ?? await _callsAuthToken();
    if (authToken == null || authToken.isEmpty) {
      throw const CometChatVoipException(
        code: CometChatVoipErrorCode.notLoggedIn,
        message:
            'Nobody is logged in to the Calls SDK. Register the push token '
            'after CometChatCalls.login, or set CometChatVoipConfig.authToken.',
      );
    }

    return PushTokenRequest(
      appId: config.appId,
      region: config.region,
      authToken: authToken,
      token: resolved,
      kind: kind,
      providerId: config.providerId,
      timezone: config.timezone ?? await _timeZone(),
      clientHost: config.clientHost,
    );
  }

  /// The device's IANA time zone, which only the native side can name.
  static Future<String?> _timeZone() async {
    try {
      return await _platform.getTimeZone();
    } catch (_) {
      return null;
    }
  }

  /// Registers again after a login.
  ///
  /// Failures are logged rather than thrown: nothing called this, so there is
  /// nobody to throw to. The app sees the same failure the next time it calls
  /// [registerPushToken] itself.
  static Future<void> _registerQuietly() async {
    final config = _config;
    if (config == null || !config.autoRegisterPushToken) return;
    final token = _pushToken;
    // Nothing to register until the app hands its token over.
    if (token == null || token == _registeredToken) return;
    try {
      await registerPushToken(token: token);
    } on CometChatVoipException catch (e) {
      _lastTokenError = e;
      calls.CometChatCallsLogger.error('CometChatVoip: $e');
    }
  }

  // ──────────────────────────────────────────────
  // Setup and diagnostics
  // ──────────────────────────────────────────────

  /// Checks everything about this device's push setup that Dart can see.
  ///
  /// Mirrors `verifyPushSetup` on both native SDKs, minus the cases that need
  /// the backend to send a test push. It cannot see the OS-level settings that
  /// silence a ring — notifications switched off, Do Not Disturb, a missing
  /// `voip` background mode — because reading those needs native code this
  /// package does not have. [getDiagnostics] says as much.
  static Future<CometChatPushSetupResult> verifyPushSetup() async {
    final config = _config;
    if (config == null) return CometChatPushSetupResult.notInitialized;

    final authToken = config.authToken ?? await _callsAuthToken();
    if (authToken == null || authToken.isEmpty) {
      return CometChatPushSetupResult.notLoggedIn;
    }
    if (_pushToken == null || _pushToken!.isEmpty) {
      return CometChatPushSetupResult.tokenNotRegistered;
    }
    if (_registeredToken != _pushToken || _lastTokenError != null) {
      return CometChatPushSetupResult.tokenRegistrationFailed;
    }

    // The OS half: notifications blocked, the ring not ready, a missing VoIP
    // entitlement. Only the native side can see any of it.
    try {
      return switch (await _platform.verifyPushSetup()) {
        'ok' => CometChatPushSetupResult.ok,
        'notInitialized' => CometChatPushSetupResult.notInitialized,
        'noVoipToken' => CometChatPushSetupResult.tokenNotRegistered,
        'notificationsBlocked' => CometChatPushSetupResult.notificationsBlocked,
        'ringNotReady' => CometChatPushSetupResult.ringNotReady,
        'backgroundModeMissing' ||
        'voipEntitlementMissing' => CometChatPushSetupResult.ringNotReady,
        _ => CometChatPushSetupResult.ok,
      };
    } on MissingPluginException {
      return CometChatPushSetupResult.ok;
    }
  }

  /// A redacted snapshot of what ringing depends on, for a bug report.
  ///
  /// Never holds a token, an auth value or a payload: the token appears only
  /// as a length and a six-character prefix, which is enough to tell a rotated
  /// token from the same one and no use to a reader.
  ///
  /// Mirrors `getDiagnostics` on both native SDKs, over a smaller surface —
  /// `ringReadiness` and the OS-level settings it reported are not knowable
  /// from Dart, and `platformRingSurface` says who owns the ring instead.
  static Future<Map<String, Object?>> getDiagnostics() async {
    final config = _config;
    final token = _pushToken;
    return {
      'package': 'cometchat_voip',
      'nativeCode': false,
      'initialized': config != null,
      'appId': config?.appId,
      'region': config?.region,
      'providerIdSet': config?.providerId != null,
      'clientHostSet': config?.clientHost != null,
      'authTokenConfigured': config?.authToken != null,
      'timezoneSet': config?.timezone != null,
      'autoRegisterPushToken': config?.autoRegisterPushToken,
      'dropExpiredCalls': config?.dropExpiredCalls,
      'callKitAudio': config?.callKitAudio,
      'acceptOnAnswer': config?.acceptOnAnswer,
      'defaultRingTimeoutMs': config?.defaultRingTimeout.inMilliseconds,
      'pushTokenPresent': token != null,
      'pushToken': token == null ? null : PushTokenClient.describe(token),
      'pushTokenRegistered': token != null && _registeredToken == token,
      'lastTokenError': _lastTokenError?.toString(),
      'callsSdkInitialized': calls.CometChatCalls.isInitialized,
      'callsSdkLoggedIn': await _loggedInUid() != null,
      'activeCallSession': _activeCall?.sessionId,
      'pushesSeen': _pushesSeen,
      'pushesRung': _pushesRung,
      'pushesDropped': _pushesDropped,
      'terminalLedgerSize': _ledger.length,
      'answeredSessions': _answeredSessions.length,
      'setupResult': (await verifyPushSetup()).name,
      'callMode': config?.callMode.name,
      // The native ringer's own snapshot, nested so the two cannot collide.
      'native': await _nativeDiagnostics(),
    };
  }

  /// The native ringer's diagnostics, or why there are none.
  static Future<Map<String, Object?>> _nativeDiagnostics() async {
    try {
      return {
        ...await _platform.getDiagnostics(),
        'ringReadiness': (await _platform.checkRingReadiness()).wireName,
        'lastWakeTiming': await _platform.lastWakeTiming(),
      };
    } on MissingPluginException {
      return {'available': false, 'reason': 'no ringer on this platform'};
    } catch (e) {
      return {'available': false, 'reason': e.toString()};
    }
  }

  // ──────────────────────────────────────────────
  // Calls SDK events
  // ──────────────────────────────────────────────

  /// One event from the native ringer.
  ///
  /// The native side is what rings, answers and declines when
  /// [CometChatCallMode.auto] is on, so these are the authoritative events for
  /// an answer from the lock screen or from CallKit — they arrive on processes
  /// the Calls SDK never came up in.
  static void _onNativeEvent(Map<Object?, Object?> event) {
    final callMap = event['call'];
    final call = callMap is Map
        ? CometChatVoipCall.fromMap(
            callMap.cast<Object?, Object?>(),
            defaultRingTimeout: _ringTimeout,
          )
        : null;

    switch (event['event']) {
      case 'answered' when call != null:
        _emitAnswered(call);
      // The ring's full-screen alert, or its tap, opened the app for a call
      // the app's own screen draws. `autoCustomScreen` only.
      case 'ringScreen' when call != null:
        _ringScreens.add(
          CometChatRingRequest(
            call: call,
            answerEndsActiveCall: event['endsActiveCall'] == true,
          ),
        );
      case 'ended' when call != null:
        if (_activeCall?.sessionId == call.sessionId) _activeCall = null;
        _emitEnded(
          call,
          CometChatCallEndReason.fromWire(event['reason']?.toString()),
        );
      case 'outgoingEnded':
        final sessionId = event['sessionId']?.toString();
        if (sessionId != null && sessionId.isNotEmpty) {
          if (_liveSession == sessionId) _liveSession = null;
          if (_activeCall?.sessionId == sessionId) _activeCall = null;
          _outgoingEnded.add(sessionId);
        }
      case 'voipToken':
        final token = event['token']?.toString();
        if (token != null && token.isNotEmpty && token != _registeredToken) {
          unawaited(handleTokenRefresh(token));
        }
    }
  }

  static void _onRinging(calls.InitiatedCall initiated) {
    final call = CometChatVoipCall.fromInitiatedCall(
      initiated,
      defaultRingTimeout: _ringTimeout,
    );
    if (call == null) return;
    _activeCall = call;
    _ringing.add(call);
  }

  /// The Calls SDK's end signal. iOS reports `answered` here when the user
  /// took the call in CallKit, which is an answer rather than an end.
  static void _onCallEnded(calls.InitiatedCall initiated, String reason) {
    final call = CometChatVoipCall.fromInitiatedCall(
      initiated,
      defaultRingTimeout: _ringTimeout,
    );
    if (call == null) return;

    // A call this user placed: the ringer hands its terminal push (a decline,
    // busy, cancel or no answer) to the Calls SDK so the caller's UI hears it
    // on its own IncomingCallListener. It never rang here, so it is not an
    // end of a ringing call: no onCallEnded, and nothing for the ringer. A
    // decline or busy carries the callee as the sender and this user as the
    // receiver.
    final me = _myUid;
    if (me != null && _placedHere(call, reason, me)) return;

    // The ringer cannot hear the Calls SDK itself any more, and this is how a
    // caller's cancel usually reaches the device — before the push, if a push
    // comes at all. Forward it so the ring stops.
    unawaited(
      _platform.sdkEndedCall(call.sessionId, reason).catchError((Object _) {}),
    );
    if (_activeCall?.sessionId == call.sessionId) _activeCall = null;

    if (reason.trim().toLowerCase() == 'answered') {
      _emitAnswered(call);
      return;
    }
    _emitEnded(call, CometChatCallEndReason.fromWire(reason));
  }

  /// Whether [call], ending with [reason], is one [me] placed: [me] is its
  /// caller, or the callee declined or was busy and [me] is the receiver.
  static bool _placedHere(CometChatVoipCall call, String reason, String me) {
    if (call.callerUid == me) return true;
    final r = reason.trim().toLowerCase();
    return call.isPeerCall &&
        call.receiverUid == me &&
        (r == 'rejected' || r == 'busy');
  }

  static void _emitAnswered(CometChatVoipCall call) {
    if (!_answeredSessions.add(call.sessionId)) return;
    // The app is about to join, which is when the session appears.
    _watchSession();
    if (_activeCall?.sessionId == call.sessionId) _activeCall = null;

    // "End & accept": the user answered a second call while one was live, and
    // the Calls SDK holds one session at a time, so the live one has to go
    // before the app can join this one. The app hears the end on the live
    // session's own listeners, as it does for any hang-up. Reported to the app
    // only once that has happened — joining first would leave the two calls
    // racing for the session.
    final live = _liveSession;
    if (live != null && live != call.sessionId) {
      unawaited(_endLiveThenAnswer(live, call));
      return;
    }

    _answered.add(call);
    unawaited(_markAnswered(call));
  }

  /// Leaves the live session [live], then reports [next] answered.
  ///
  /// A leave that fails is logged and the answer still goes out: the user
  /// tapped Answer, and a call that joins beside a stuck session is better
  /// than one that never arrives.
  static Future<void> _endLiveThenAnswer(
    String live,
    CometChatVoipCall next,
  ) async {
    _liveSession = null;
    try {
      // Waits for the session to be gone, not just asked to go: the call
      // view the answer opens hears the Calls SDK's connection-closed for
      // any session, and the live one's arriving late shows "The session
      // has ended." over the call just answered.
      if (!await NativeCallsBridge.leaveActiveSession(waitUntilIdle: true)) {
        calls.CometChatCallsLogger.error(
          'CometChatVoip: the Calls SDK had no session to leave for $live '
          'before answering ${next.sessionId}',
        );
      }
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: leaving $live before answering ${next.sessionId} '
        'failed: $e',
      );
    }
    await _setSessionState(active: false, joined: false, sessionId: live);
    // The ringer's own record of the ended call, so a decline of a third call
    // is not reported busy for a call that is over.
    try {
      await _platform.reportCallEnded(live);
    } catch (_) {
      // No ringer here.
    }
    _answered.add(next);
    unawaited(_markAnswered(next));
  }

  static void _emitEnded(
    CometChatVoipCall call,
    CometChatCallEndReason reason,
  ) => _ended.add(CometChatCallEnded(call: call, reason: reason));

  /// Marks [call] answered with CometChat, for a caller on the Chat SDK's
  /// calling. See [CometChatVoipConfig.acceptOnAnswer].
  static Future<void> _markAnswered(CometChatVoipCall call) async {
    final config = _config;
    if (config == null || !config.acceptOnAnswer) return;

    var authToken = config.authToken;
    final deadline = DateTime.now().add(_loginWaitForAccept);
    while (authToken == null || authToken.isEmpty) {
      authToken = await _callsAuthToken();
      if (authToken != null && authToken.isNotEmpty) break;
      if (DateTime.now().isAfter(deadline)) {
        calls.CometChatCallsLogger.error(
          'CometChatVoip: nobody logged in to the Calls SDK, so '
          '${call.sessionId} was not marked answered. A caller on the Chat '
          "SDK's calling will keep ringing.",
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    final (status, _) = await _acceptClient.accept(
      appId: config.appId,
      region: config.region,
      authToken: authToken,
      sessionId: call.sessionId,
      clientHost: config.clientHost,
    );
    if (status >= 200 && status < 300) {
      calls.CometChatCallsLogger.debug(
        'CometChatVoip: marked ${call.sessionId} answered',
      );
    } else {
      // Expected for a call a ringing-flow caller placed when the backend
      // already counts the join as the answer; nothing is lost.
      calls.CometChatCallsLogger.debug(
        'CometChatVoip: marking ${call.sessionId} answered returned $status',
      );
    }
  }

  @visibleForTesting
  static void resetForTesting({
    PushTokenClient? tokenClient,
    Future<String?> Function()? callsAuthToken,
    CallAcceptClient? acceptClient,
  }) {
    _config = null;
    _events?.cancel();
    _events = null;
    _ringing.reset();
    _ringScreens.reset();
    _answered.reset();
    _ended.reset();
    _outgoingEnded.reset();
    _pushToken = null;
    _registeredToken = null;
    _activeCall = null;
    _watchedSession = null;
    _answeredSessions.clear();
    _liveSession = null;
    _ledger.clear();
    _lastTokenError = null;
    _pushesSeen = 0;
    _pushesRung = 0;
    _pushesDropped = 0;
    _tokenClient = tokenClient ?? PushTokenClient();
    _acceptClient = acceptClient ?? CallAcceptClient();
    _callsAuthToken = callsAuthToken ?? calls.CometChatCalls.getUserAuthToken;
  }

  /// Runs what a Calls SDK login runs.
  @visibleForTesting
  static Future<void> registerOnLoginForTesting() => _registerQuietly();

  /// Runs what the Calls SDK's session listeners run, for a session whose id
  /// the SDK does not report.
  @visibleForTesting
  static Future<void> sessionChangedForTesting({
    required bool active,
    required bool joined,
  }) => _sessionChanged(active: active, joined: joined);

  @visibleForTesting
  static void handleRingingForTesting(calls.InitiatedCall call) =>
      _onRinging(call);

  @visibleForTesting
  static void handleEndedForTesting(calls.InitiatedCall call, String reason) =>
      _onCallEnded(call, reason);
}

/// Everything the ringer does in [CometChatCallMode.auto], a piece at a time.
///
/// Reached through `CometChatVoip.ringSurfaces`. An app in
/// [CometChatCallMode.manual] drives the ring itself from `onCallRinging`,
/// and these are the steps it would otherwise have got for free:
///
/// ```dart
/// CometChatVoip.onCallRinging.listen((call) async {
///   await CometChatVoip.ringSurfaces.keepAlive(call);   // survive the connect
///   await CometChatVoip.ringSurfaces.verify(call);      // connect while ringing
///   await CometChatVoip.ringSurfaces.showIncomingNotification(call);
/// });
/// ```
///
/// Android only. On iOS reporting a call to CallKit *is* the ring — it cannot
/// be driven a piece at a time — so each of these throws
/// [CometChatVoipErrorCode.unsupportedPlatform] there.
///
/// Mirrors `CometChatCallNotifications.Calls` on Android.
class CometChatVoipRingSurfaces {
  const CometChatVoipRingSurfaces._();

  /// Posts the incoming-call notification and arms its expiry.
  ///
  /// A call shown this way runs the keep-alive on that same notification, so
  /// [keepAlive] adds nothing for it.
  Future<void> showIncomingNotification(CometChatVoipCall call) =>
      CometChatVoip._ringSurface(
        () => CometChatVoip._platform.showIncomingNotification(call),
      );

  /// Tears down every visible and scheduled trace of a ringing session.
  /// Idempotent.
  Future<void> stopRinging(String sessionId) => CometChatVoip._ringSurface(
    () => CometChatVoip._platform.stopRinging(sessionId),
  );

  /// Connects while ringing: pre-warms the session so answering only adds
  /// media, and confirms the call is still alive, which fires
  /// `onParticipantConnected` on the caller so they see it ringing.
  ///
  /// Never ends the ring on an inconclusive result — only on a definite "this
  /// call is over" — because dismissing a live call is the worse failure.
  Future<void> verify(CometChatVoipCall call) => CometChatVoip._ringSurface(
    () => CometChatVoip._platform.verifyCall(call),
  );

  /// Keeps the process alive while ringing, so Android does not reclaim it
  /// mid-connect. Around a ring of your own it shows a quiet stand-in
  /// notification.
  Future<void> keepAlive(CometChatVoipCall call) =>
      CometChatVoip._ringSurface(() => CometChatVoip._platform.keepAlive(call));

  /// Posts a missed-call notification.
  Future<void> showMissedCall(CometChatVoipCall call) =>
      CometChatVoip._ringSurface(
        () => CometChatVoip._platform.showMissedCall(call),
      );
}

/// Bridges the Calls SDK's incoming calls onto this package's streams.
class _IncomingCalls implements calls.IncomingCallListener {
  const _IncomingCalls();

  @override
  void onIncomingCallReceived(calls.InitiatedCall call) =>
      CometChatVoip._onRinging(call);

  @override
  void onIncomingCallEnded(calls.InitiatedCall call, String reason) =>
      CometChatVoip._onCallEnded(call, reason);
}

/// The Calls SDK's session, watched so the ringer does not need the app to
/// report it.
///
/// The native SDKs subscribe to exactly these listeners. Doing the same here
/// is what keeps `reportCallConnected` / `reportMuted` optional rather than
/// load-bearing: the ringer owns the CallKit call but cannot see the session,
/// and this is where the snapshot it reads comes from.
class _SessionWatcher
    implements
        calls.SessionStatusListeners,
        calls.MediaEventListeners,
        calls.ButtonClickListeners {
  /// The Calls SDK fires mute and unmute on its own while the audio device
  /// restarts — about a second after a join, and again when CallKit activates
  /// the audio session — with nobody touching mute. Mirrored, CallKit showed a
  /// live call muted, and the next ring applied that mute for real. So a mute
  /// counts as the user's only within this long of a tap on the call screen's
  /// mute button, and never within this long of a join. The native iOS SDK
  /// settled on the same rule.
  static const _muteSettle = Duration(seconds: 3);

  DateTime? _joinedAt;

  /// When the user last tapped the call screen's mute button.
  DateTime? _audioToggledAt;

  bool get _settling {
    final joinedAt = _joinedAt;
    return joinedAt != null &&
        DateTime.now().difference(joinedAt) < _muteSettle;
  }

  /// Whether a mute arriving now is one the user asked for on the call screen.
  bool get _userAskedToMute {
    final toggledAt = _audioToggledAt;
    return toggledAt != null &&
        DateTime.now().difference(toggledAt) < _muteSettle;
  }

  @override
  void onSessionJoined() {
    _joinedAt = DateTime.now();
    _audioToggledAt = null;
    // A join starts unmuted in CallKit, whatever was left over from before.
    unawaited(CometChatVoip.reportMuted(false));
    unawaited(CometChatVoip._sessionChanged(active: true, joined: true));
  }

  /// The prepare connecting, which comes before a join. Never reported over
  /// a session already joined: that would write the live call as unjoined,
  /// so a call ringing over it would be refused busy on Android as one this
  /// device is still placing, and answering it would no longer end the live
  /// call first.
  @override
  void onConnected() {
    if (_joinedAt != null) return;
    unawaited(CometChatVoip._sessionChanged(active: true, joined: false));
  }

  @override
  void onSessionLeft() => _ended();

  @override
  void onConnectionClosed() => _ended();

  @override
  void onSessionTimedOut() => _ended();

  @override
  void onConnectionLost() {}

  @override
  void onConnectionRestored() {}

  void _ended() {
    _joinedAt = null;
    _audioToggledAt = null;
    unawaited(CometChatVoip._sessionChanged(active: false, joined: false));
  }

  // ── Media, mirrored onto the CallKit call ──

  @override
  void onAudioMuted() => _mirrorUserMute(true);

  @override
  void onAudioUnMuted() => _mirrorUserMute(false);

  /// A mute the user asked for on the call screen, mirrored onto the CallKit
  /// call. One the Calls SDK reported on its own is not the user's, and
  /// mirroring it left the native screen out of step with the call — see
  /// [_muteSettle]. A mute made on the native screen arrives through CallKit
  /// and needs no mirror.
  void _mirrorUserMute(bool muted) {
    if (_settling || !_userAskedToMute) return;
    unawaited(CometChatVoip.reportMuted(muted));
  }

  @override
  void onVideoPaused() => unawaited(CometChatVoip.reportVideoPaused(true));

  @override
  void onVideoResumed() => unawaited(CometChatVoip.reportVideoPaused(false));

  @override
  void onRecordingStarted() {}

  @override
  void onRecordingStopped() {}

  @override
  void onScreenShareStarted() {}

  @override
  void onScreenShareStopped() {}

  @override
  void onAudioModeChanged(calls.AudioMode audioMode) {}

  @override
  void onCameraFacingChanged(calls.CameraFacing facing) {}

  // ── The call screen's buttons ──

  @override
  void onToggleAudioButtonClicked() => _audioToggledAt = DateTime.now();

  // The rest of the call screen's buttons say nothing about the CallKit call.
  // `implements` makes every member of the listener this watcher's to declare,
  // so they are here as no-ops.

  @override
  void onLeaveSessionButtonClicked() {}

  @override
  void onRaiseHandButtonClicked() {}

  @override
  void onShareInviteButtonClicked() {}

  @override
  void onChangeLayoutButtonClicked() {}

  @override
  void onParticipantListButtonClicked() {}

  @override
  void onToggleVideoButtonClicked() {}

  @override
  void onSwitchCameraButtonClicked() {}

  @override
  void onRecordingToggleButtonClicked() {}

  @override
  void onChatButtonClicked() {}
}

/// Who is on the live session, watched for the one thing the ringer needs from
/// it: the name of the other party of an outgoing call it reported on its own.
///
/// The native iOS SDK watches the same two events for the same reason.
class _ParticipantWatcher implements calls.ParticipantEventListeners {
  @override
  void onParticipantConnected(calls.Participant participant) =>
      unawaited(CometChatVoip._reportRemoteParticipant(participant));

  @override
  void onParticipantJoined(calls.Participant participant) =>
      unawaited(CometChatVoip._reportRemoteParticipant(participant));

  // The rest say nothing about the CallKit call. `implements` makes every
  // member of the listener this watcher's to declare, so they are no-ops here.

  @override
  void onParticipantListChanged(List<calls.Participant> participants) {}

  @override
  void onParticipantLeft(calls.Participant participant) {}

  @override
  void onParticipantAudioMuted(calls.Participant participant) {}

  @override
  void onParticipantAudioUnmuted(calls.Participant participant) {}

  @override
  void onParticipantVideoPaused(calls.Participant participant) {}

  @override
  void onParticipantVideoResumed(calls.Participant participant) {}

  @override
  void onParticipantHandRaised(calls.Participant participant) {}

  @override
  void onParticipantHandLowered(calls.Participant participant) {}

  @override
  void onParticipantStartedScreenShare(calls.Participant participant) {}

  @override
  void onParticipantStoppedScreenShare(calls.Participant participant) {}

  @override
  void onParticipantStartedRecording(calls.Participant participant) {}

  @override
  void onParticipantStoppedRecording(calls.Participant participant) {}

  @override
  void onDominantSpeakerChanged(calls.Participant participant) {}
}

/// Registers the push token whenever someone logs in to the Calls SDK.
class _LoginWatcher implements calls.LoginListener {
  const _LoginWatcher();

  @override
  void loginSuccess(calls.User user) {
    // The ring gates read this from disk on a process no SDK came up in.
    CometChatVoip._myUid = user.uid;
    unawaited(CometChatVoip._platform.setLoggedInUid(user.uid));
    unawaited(CometChatVoip._registerQuietly());
  }

  @override
  void loginFailure(calls.CometChatCallsException exception) {}

  @override
  void logoutSuccess() {
    CometChatVoip._registeredToken = null;
    CometChatVoip._myUid = null;
    unawaited(CometChatVoip._platform.setLoggedInUid(null));
  }

  @override
  void logoutFailure(calls.CometChatCallsException exception) {}
}

/// A broadcast stream that holds what arrives while nothing listens.
///
/// A call that arrived with the push that launched the app lands before the
/// app has subscribed, and a plain broadcast stream would hand it to nobody.
class _HeldEvents<T> {
  _HeldEvents() {
    _controller = StreamController<T>.broadcast(onListen: _flush);
  }

  late StreamController<T> _controller;
  final List<T> _held = [];

  /// More than this and the oldest are dropped: a stale call is worse than
  /// none.
  static const _limit = 8;

  Stream<T> get stream => _controller.stream;

  void add(T event) {
    if (_controller.hasListener) {
      _controller.add(event);
      return;
    }
    _held.add(event);
    if (_held.length > _limit) _held.removeAt(0);
  }

  /// Scheduled rather than delivered inline: `onListen` runs before the
  /// subscription is wired up, so adding here would drop every one of them.
  void _flush() {
    if (_held.isEmpty) return;
    final held = List<T>.of(_held);
    _held.clear();
    scheduleMicrotask(() => held.forEach(_controller.add));
  }

  void reset() {
    _held.clear();
    _controller.close();
    _controller = StreamController<T>.broadcast(onListen: _flush);
  }
}
