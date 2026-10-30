import 'dart:async';

import 'dart:ui' as ui;

import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart' as calls;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

/// Serves the ringer's Calls SDK requests from Dart.
///
/// The ringer is native — it has to be, because it runs where no Dart does: a
/// notification action, an alarm, a WorkManager job, a PushKit wake. But this
/// package links **only** `cometchat_calls_sdk`, never the native Calls SDK, so
/// the ringer cannot call the Calls SDK itself. Everything it needs comes back
/// here instead, and Dart calls `CometChatCalls`.
///
/// Two isolates serve the same requests:
///
///  - the **app's** isolate, whenever it is alive. `CometChatVoip.init`
///    attaches this to the plugin's channel.
///  - a **background** isolate the ringer starts when nothing is alive — a
///    Decline tapped on the lock screen after the app process died. Android
///    launches [cometchatVoipBackgroundDispatcher] for that.
///
/// Native queues a request until one of them answers, so a request that lands
/// on a cold process is served rather than dropped.
class NativeCallsBridge {
  const NativeCallsBridge._();

  /// The Calls SDK's own channel.
  ///
  /// Used for one thing: handing it the CallKit audio session. Its Dart API
  /// gained `notifyCallKitAudioActivated` after this package needed it, so the
  /// call goes by name and tolerates an SDK that does not know it.
  static const _callsSdkChannel = MethodChannel('cometchatcalls_plugin');

  /// The plugin's channel.
  ///
  /// The background isolate uses this same name, not one of its own: a
  /// background `FlutterEngine` registers the app's plugins, so the ringer's
  /// plugin attaches to that engine too and handles this channel there. A
  /// separate channel would have no native side at all, and the isolate's
  /// `dartReady` would go nowhere — which is how the headless decline was
  /// broken before.
  static const pluginChannel = MethodChannel('cometchat_voip');

  /// Not-ready conditions worth retrying on a cold process, as opposed to a
  /// real refusal. Mirrors the native ringer's own list.
  static const _retryableCodes = {
    'USER_NOT_LOGGED_IN',
    'SDK_INIT',
    'ERR_SDK_NOT_INITIALIZED',
    'ERR_CALLS_SDK_NOT_INITIALIZED',
  };

  /// Installs the handler on [channel] and tells native this isolate can serve
  /// requests, which flushes whatever was queued.
  static Future<void> attach(MethodChannel channel) async {
    channel.setMethodCallHandler(_handle);
    try {
      await channel.invokeMethod<void>('dartReady');
    } on MissingPluginException {
      // Either there is no ringer on this platform — fine, nothing was queued
      // — or this is a background isolate whose engine did not register the
      // plugin, in which case whatever the ringer queued is stranded. Say so:
      // the symptom otherwise is a decline that silently never sends.
      calls.CometChatCallsLogger.error(
        'CometChatVoip: nothing answered dartReady on '
        '${channel.name}. If this is a background isolate, the ringer cannot '
        'reach the Calls SDK from here and whatever it queued will time out.',
      );
    }
  }

  static Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    switch (call.method) {
      case 'calls.connect':
        return _connect(args);
      case 'calls.endCall':
        return _endCall(args);
      case 'calls.injectIncomingCall':
        return _inject(args, ended: false);
      case 'calls.injectIncomingCallEnded':
        return _inject(args, ended: true);
      case 'calls.sessionState':
        return _sessionState();
      case 'calls.leaveSession':
        return leaveActiveSession();
      case 'calls.muteAudio':
        return _setAudioMuted(true);
      case 'calls.unmuteAudio':
        return _setAudioMuted(false);
      case 'calls.pauseVideo':
        return _setVideoPaused(true);
      case 'calls.resumeVideo':
        return _setVideoPaused(false);
      case 'calls.loggedInUid':
        return _loggedInUid();
      case 'calls.callKitAudioActivated':
        return _callKitAudio(activated: true);
      case 'calls.callKitAudioDeactivated':
        return _callKitAudio(activated: false);
      default:
        throw MissingPluginException('${call.method} is not a bridge method');
    }
  }

  // ──────────────────────────────────────────────

  /// Joins the conference without media while the phone rings, so answering
  /// only adds media and the caller's `onParticipantConnected` fires.
  ///
  /// The Calls SDK keeps the settings a session is prepared with and ignores
  /// the ones passed to a later join, so the call's own type is set here — a
  /// default would open the camera for an audio call.
  static Future<Map<String, Object?>> _connect(
    Map<String, Object?> args,
  ) async {
    final sessionId = args['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return _failed('INVALID_ARGUMENTS', 'connect needs a sessionId');
    }
    final isVideo = args['isVideo'] as bool? ?? false;

    if (!await _ensureInitialised()) {
      return _failed('SDK_INIT', 'the Calls SDK is not up', retryable: true);
    }

    try {
      final settings = calls.SessionSettingsBuilder()
          .setPeerCall(args['isPeerCall'] as bool? ?? true)
          .setType(isVideo ? calls.SessionType.video : calls.SessionType.audio)
          .startVideoPaused(!isVideo)
          // The answered call keeps the settings it was prepared with, so the
          // audio route is chosen here: earpiece for a voice call, loudspeaker
          // for a video call. Left unset it was the builder's loudspeaker.
          .setAudioMode(
            isVideo ? calls.AudioMode.speaker : calls.AudioMode.earpiece,
          )
          .build();

      final completer = Completer<Map<String, Object?>>();
      await calls.CometChatCalls.connect(
        sessionId: sessionId,
        sessionSettings: settings,
        onSuccess: (_) {
          if (!completer.isCompleted) {
            completer.complete({'status': 'connected'});
          }
        },
        onError: (e) {
          if (!completer.isCompleted) {
            completer.complete(
              _failed(
                e.code,
                e.message,
                retryable: _retryableCodes.contains(e.code),
              ),
            );
          }
        },
      );
      return completer.future;
    } catch (e) {
      return _failed('EXCEPTION', '$e');
    }
  }

  static Map<String, Object?> _failed(
    String code,
    String? message, {
    bool retryable = false,
  }) => {
    'status': 'failed',
    'code': code,
    'message': message,
    'retryable': retryable,
  };

  /// Declines (`rejected` or `busy`) before the call is joined.
  ///
  /// This is the one request that reaches a background isolate: a Decline
  /// tapped on a notification that outlived its process.
  /// The Calls SDK's code for a call the server has already ended.
  static const _callTerminated = 'ERR_CALL_TERMINATED';

  static Future<bool> _endCall(Map<String, Object?> args) async {
    final sessionId = args['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) return false;
    final status = args['status'] as String? ?? calls.EndCallStatus.rejected;

    if (!await _ensureInitialised()) return false;

    final completer = Completer<bool>();
    try {
      await calls.CometChatCalls.endCall(
        sessionId: sessionId,
        status: status,
        onSuccess: () {
          if (!completer.isCompleted) completer.complete(true);
        },
        onError: (e) {
          if (completer.isCompleted) return;
          // Already over on the server (the caller cancelled or gave up while
          // this was on its way): there is nothing left to end, and retrying
          // would only repeat the refusal until the queue gives up.
          if (e.code == _callTerminated) {
            completer.complete(true);
            return;
          }
          calls.CometChatCallsLogger.error(
            'CometChatVoip: declining $sessionId failed: ${e.message}',
          );
          completer.complete(false);
        },
      );
    } catch (e) {
      if (!completer.isCompleted) completer.complete(false);
    }
    return completer.future;
  }

  /// Hands the call to the Calls SDK, whose `IncomingCallListener` then hears
  /// it exactly as it hears any other incoming call.
  static Future<bool> _inject(
    Map<String, Object?> args, {
    required bool ended,
  }) async {
    final payload =
        (args['payload'] as Map?)?.map(
          (key, value) => MapEntry('$key', '${value ?? ''}'),
        ) ??
        const <String, String>{};
    if (payload['sessionId']?.isEmpty ?? true) return false;
    if (!await _ensureInitialised()) return false;

    try {
      if (ended) {
        await calls.CometChatCalls.injectIncomingCallEnded(
          payload,
          args['reason'] as String? ?? 'ended',
        );
      } else {
        await calls.CometChatCalls.injectIncomingCall(payload);
      }
      return true;
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: the Calls SDK refused ${payload['sessionId']}: $e',
      );
      return false;
    }
  }

  /// Preparing, prepared, joining or joined: anything a connect for another
  /// call would disturb.
  static Future<Map<String, Object?>> _sessionState() async {
    try {
      final session = await calls.CometChatCalls.getActiveSession();
      if (session == null) {
        return {'active': false, 'joined': false, 'sessionId': null};
      }
      return {
        'active': await session.isSessionActive(),
        'joined': await session.isSessionJoined(),
        'sessionId': await session.getSessionId(),
      };
    } catch (_) {
      return {'active': false, 'joined': false, 'sessionId': null};
    }
  }

  /// Leaves whatever session the Calls SDK has — a session prepared while
  /// ringing that nobody joined, or the live call the user is in, which is
  /// what answering a second call has to do first.
  ///
  /// With [waitUntilIdle], returns only once the Calls SDK reports no session
  /// at all — the leave itself returns before the session is torn down — or
  /// after [idleWait]. Waits even when there was nothing to leave here: on
  /// iOS, CallKit's End on the live call may already have started its leave.
  /// Mirrors a mute made outside the app onto the live session.
  ///
  /// CallKit's mute button reaches the ringer natively, which asks for this.
  /// Without it the native call screen shows muted while the microphone is
  /// still open — the two disagree and the caller is still heard.
  static Future<bool> _setAudioMuted(bool muted) async {
    try {
      final session = await calls.CometChatCalls.getActiveSession();
      if (session == null) return false;
      if (muted) {
        await session.muteAudio();
      } else {
        await session.unMuteAudio();
      }
      return true;
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: ${muted ? 'muting' : 'unmuting'} from the native call '
        'screen failed: $e',
      );
      return false;
    }
  }

  /// Mirrors a video pause made outside the app onto the live session — a
  /// cellular hold, which the ringer takes as mute and pause together.
  static Future<bool> _setVideoPaused(bool paused) async {
    try {
      final session = await calls.CometChatCalls.getActiveSession();
      if (session == null) return false;
      if (paused) {
        await session.pauseVideo();
      } else {
        await session.resumeVideo();
      }
      return true;
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: ${paused ? 'pausing' : 'resuming'} video from the '
        'native call screen failed: $e',
      );
      return false;
    }
  }

  static Future<bool> leaveActiveSession({bool waitUntilIdle = false}) async {
    var left = false;
    try {
      final session = await calls.CometChatCalls.getActiveSession();
      if (session != null) {
        await session.leave();
        left = true;
      }
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: leaving the prepared session failed: $e',
      );
    }
    if (waitUntilIdle) await _waitUntilIdle();
    return left;
  }

  /// How long [leaveActiveSession] waits for the session to be gone.
  static const idleWait = Duration(seconds: 3);

  static Future<void> _waitUntilIdle() async {
    const busy = {'preparing', 'prepared', 'joining', 'joined'};
    final deadline = DateTime.now().add(idleWait);
    while (true) {
      try {
        if (!busy.contains(await calls.CometChatCalls.getSessionState())) {
          return;
        }
      } catch (_) {
        // Nothing to ask: as good as gone.
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        calls.CometChatCallsLogger.error(
          'CometChatVoip: the session was still up ${idleWait.inSeconds}s '
          'after leaving it',
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Whether this Calls SDK can take the CallKit audio session at all.
  ///
  /// `setCallKitAudioEnabled(true)` is only safe on an SDK that also exposes
  /// `notifyCallKitAudioActivated`: the flag makes WebRTC wait to be told the
  /// session is live, and without the binding nothing can tell it — the call
  /// rings, connects and is silent, with no error anywhere. That is why this
  /// is asked **before** the flag goes on rather than discovered on the first
  /// call, by which time the silence has already happened.
  ///
  /// Probed with the deactivation half, which is inert with no call up: an SDK
  /// that has the binding deactivates an already-inactive session, and one
  /// that does not throws [MissingPluginException]. Returns null while a
  /// session is live, where a deactivation would not be inert — the caller
  /// then leaves the flag alone rather than risk a running call.
  static Future<bool?> callKitAudioHandoffAvailable() async {
    final state = await _sessionState();
    if (state['active'] == true || state['joined'] == true) return null;
    try {
      await _callsSdkChannel.invokeMethod<void>(
        'notifyCallKitAudioDeactivated',
      );
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      // `platformNotSupported` off iOS, or any other refusal. Either way the
      // handoff is not available here.
      return false;
    }
  }

  /// Hands the CallKit audio session to WebRTC, or reports that this Calls SDK
  /// cannot be told.
  ///
  /// `setCallKitAudioEnabled(true)` makes WebRTC wait to be told the session is
  /// live. The only thing that can tell it is `CometChatAudioSession.activate`
  /// in the **native** Calls SDK, which this package does not link — so the
  /// Calls SDK exposes it in Dart as `notifyCallKitAudioActivated`.
  ///
  /// Returns false on a Calls SDK without that method, which is how
  /// `CometChatVoip` knows never to turn the flag on: enabled with no way to
  /// make the handoff, the call rings, connects and is silent.
  static Future<bool> _callKitAudio({required bool activated}) async {
    // Invoked over the Calls SDK's own channel rather than its Dart API,
    // because a released SDK that predates `notifyCallKitAudioActivated` would
    // not compile against it. The method name is the contract; an SDK without
    // it replies notImplemented and `_handle` reports false.
    try {
      await _callsSdkChannel.invokeMethod<void>(
        activated
            ? 'notifyCallKitAudioActivated'
            : 'notifyCallKitAudioDeactivated',
      );
      return true;
    } on MissingPluginException {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: this Calls SDK cannot take the CallKit audio session — '
        'it predates notifyCallKitAudioActivated. Leave '
        'CometChatVoipConfig.callKitAudio off.',
      );
      return false;
    } catch (e) {
      // `platformNotSupported` off iOS, or a Calls SDK too old to know the
      // method. Either way the handoff did not happen.
      calls.CometChatCallsLogger.error(
        'CometChatVoip: the Calls SDK could not take the CallKit audio '
        'session: $e',
      );
      return false;
    }
  }

  static Future<String?> _loggedInUid() async {
    if (!await _ensureInitialised()) return null;
    try {
      final user = await calls.CometChatCalls.getLoggedInUser();
      final uid = user?.uid.trim();
      return uid == null || uid.isEmpty ? null : uid;
    } catch (_) {
      return null;
    }
  }

  // ──────────────────────────────────────────────

  /// Brings the Calls SDK up, which a background isolate always has to do: it
  /// starts empty.
  ///
  /// The configuration comes from the native store, which `init` wrote, so this
  /// works on a process that started for nothing but a Decline tap. The Calls
  /// SDK restores its own login from disk, which is what lets the decline be
  /// sent as the right user.
  static Future<bool> _ensureInitialised() async {
    if (calls.CometChatCalls.isInitialized) return true;

    final stored = await _storedConfig();
    final appId = stored['appId'];
    final region = stored['region'];
    if (appId == null || appId.isEmpty || region == null || region.isEmpty) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: no stored configuration, so the Calls SDK cannot be '
        'brought up here. Has CometChatVoip.init ever run?',
      );
      return false;
    }

    final builder = calls.CallAppSettingBuilder()
      ..appId = appId
      ..region = region;
    final clientHost = stored['clientHost'];
    if (clientHost != null && clientHost.isNotEmpty) {
      builder.overrideClientHost(clientHost);
    }

    final completer = Completer<bool>();
    calls.CometChatCalls.init(
      builder.build(),
      onSuccess: (_) {
        if (!completer.isCompleted) completer.complete(true);
      },
      onError: (e) {
        if (!completer.isCompleted) {
          calls.CometChatCallsLogger.error(
            'CometChatVoip: the Calls SDK would not start: ${e.message}',
          );
          completer.complete(false);
        }
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => false,
    );
  }

  /// The configuration the native side persisted, read over whichever channel
  /// this isolate owns.
  static Future<Map<String, String?>> _storedConfig() async {
    try {
      final map = await pluginChannel.invokeMapMethod<String, Object?>(
        'storedConfig',
      );
      if (map != null && map['appId'] != null) {
        return map.map((key, value) => MapEntry(key, value?.toString()));
      }
    } catch (e) {
      calls.CometChatCallsLogger.error(
        'CometChatVoip: could not read the stored configuration: $e',
      );
    }
    return const {};
  }
}

/// The entry point the ringer starts when no isolate is alive to serve it.
///
/// Registered by `CometChatVoip.init`, which writes its callback handle where
/// the native side can find it later. `@pragma('vm:entry-point')` is what keeps
/// it out of the tree shaker's way in a release build — without it, a
/// lock-screen decline on a killed app would find nothing to run.
@pragma('vm:entry-point')
Future<void> cometchatVoipBackgroundDispatcher() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The engine the ringer starts registers the app's plugins natively, so this
  // package's own plugin — and `cometchat_calls_sdk` — attach to it and
  // [NativeCallsBridge.pluginChannel] has a native side here.
  await NativeCallsBridge.attach(NativeCallsBridge.pluginChannel);
}

/// The raw handle of [cometchatVoipBackgroundDispatcher], for the native side
/// to store and start later. Null on a platform with no callback registry.
int? cometchatVoipBackgroundHandle() => ui.PluginUtilities.getCallbackHandle(
  cometchatVoipBackgroundDispatcher,
)?.toRawHandle();
