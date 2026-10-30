import 'dart:async';

import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart';
import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:flutter/material.dart';

/// A tour of the package, driven by the pushes the CometChat server sends.
///
/// In `CometChatCallMode.auto` — the default, and what this example uses — the
/// package rings Android calls itself, as a full-screen call notification, with
/// the app open, backgrounded or killed. On iOS it owns PushKit and the ring
/// gates and hands the call to the Calls SDK, which rings it through CallKit.
/// A real app then does two things:
///
///  - hands Android's call pushes to [CometChatVoip.handlePushNotification]
///    from both of `firebase_messaging`'s handlers. iOS needs nothing: the
///    package owns the `PKPushRegistry`;
///  - joins the session on [CometChatVoip.onCallAnswered].
///
/// The buttons below feed it the pushes the server would send, so the ring, the
/// lock-screen answer, the decline and the missed call are all the real thing.
///
/// Fill in [_appId] and [_region] to watch it against a real app.
const _appId = 'APP_ID';
const _region = 'us';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CometChat VoIP',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6851D6)),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _log = <String>[];
  final _subscriptions = <StreamSubscription<Object>>[];
  bool _ready = false;
  int _callId = 1;

  /// The call this app is showing its own incoming-call UI for.
  CometChatVoipCall? _ringing;

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  Future<void> _setUp() async {
    // The Calls SDK is what rings, so it comes up first.
    final settings =
        (CallAppSettingBuilder()
              ..appId = _appId
              ..region = _region)
            .build();
    CometChatCalls.init(
      settings,
      onSuccess: (_) => _write('Calls SDK ready'),
      onError: (e) => _write('Calls SDK: ${e.message}'),
    );

    // Built from the settings above, so the app id and region cannot drift.
    await CometChatVoip.init(
      CometChatVoipConfig.fromCallAppSettings(
        settings,
        // Nobody logs in here, so there is nothing to register a token for.
        autoRegisterPushToken: false,
        // `CometChatCallMode.autoCustomScreen` keeps everything below and
        // sends the ring's full-screen alert here instead of to the package's
        // own screen — see onRingScreenRequested.
        callMode: CometChatCallMode.auto,
      ),
    );

    _subscriptions
      ..add(
        CometChatVoip.onCallRinging.listen((call) {
          // A real app shows its incoming-call screen here. On iOS the call is
          // also ringing in CallKit, which answers it without any of this.
          setState(() => _ringing = call);
          _write('Ringing: ${call.callerName} (${call.callType})');
        }),
      )
      ..add(
        // Only in `CometChatCallMode.autoCustomScreen`: the ring's full-screen
        // alert, or its tap, asking this app for its own ring screen. A real
        // app pushes that screen here.
        CometChatVoip.onRingScreenRequested.listen((request) {
          setState(() => _ringing = request.call);
          _write(
            'Ring screen for ${request.call.callerName}'
            '${request.answerEndsActiveCall ? ' — answering ends the live call' : ''}',
          );
        }),
      )
      ..add(
        CometChatVoip.onCallAnswered.listen((call) {
          // A real app joins here:
          // CometChatCalls.joinSession(sessionId: call.sessionId, ...)
          setState(() => _ringing = null);
          _write('Answered ${call.callerName} — join ${call.sessionId}');
        }),
      )
      ..add(
        CometChatVoip.onCallEnded.listen((ended) {
          setState(() => _ringing = null);
          _write(
            '${ended.call.callerName}: ${ended.reason.name}'
            '${ended.reason.isMissed ? ' (missed)' : ''}',
          );
        }),
      );

    setState(() => _ready = true);
  }

  void _write(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  /// One call push, in the shape the CometChat server sends it.
  ///
  /// This is what `firebase_messaging` hands over on Android, and what the
  /// app's PushKit delegate hands over on iOS.
  Future<void> _ring({required bool video}) async {
    final sessionId =
        'v1.$_region.example.${DateTime.now().millisecondsSinceEpoch}';
    final id = _callId++;
    final handled = await CometChatVoip.handlePushNotification({
      'type': 'call',
      'callAction': 'initiated',
      'sessionId': sessionId,
      'callType': video ? 'video' : 'audio',
      'sender': 'alex',
      'senderName': 'Alex Okonjo',
      'receiver': 'cameron',
      'receiverType': 'user',
      'conversationId': 'alex_user_cameron',
      'sentAt': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    }, sentTime: DateTime.now());
    _write(
      handled ? 'Pushed call #$id (${video ? 'video' : 'audio'})' : 'Ignored',
    );
  }

  /// What the package and the OS can tell about this device's push setup.
  Future<void> _checkSetup() async {
    final result = await CometChatVoip.verifyPushSetup();
    _write('Setup: ${result.name}');

    final readiness = await CometChatVoip.checkRingReadiness();
    _write('Ring readiness: ${readiness.name}');
    if (readiness != CometChatRingReadiness.ready) {
      // In a real app, explain it first, then offer the settings page.
      await CometChatVoip.openSettings(readiness);
    }

    final diagnostics = await CometChatVoip.getDiagnostics();
    _write(
      'Pushes seen ${diagnostics['pushesSeen']}, '
      'rung ${diagnostics['pushesRung']}, '
      'dropped ${diagnostics['pushesDropped']}',
    );
    // Android only: connecting while ringing belongs to whoever rings, and on
    // iOS that is the Calls SDK.
    _write('Last wake: ${await CometChatVoip.lastWakeTiming()}');
  }

  /// Android 13+ needs this before a call can ring.
  Future<void> _askPermission() async {
    final granted = await CometChatVoip.requestNotificationPermission();
    _write(granted ? 'Notifications allowed' : 'Notifications denied');
  }

  /// The PushKit token the package got itself. iOS only.
  Future<void> _showVoipToken() async {
    final token = await CometChatVoip.getVoipToken();
    _write(
      token == null
          ? 'No VoIP token yet (iOS device only)'
          : 'VoIP token: ${token.length} characters',
    );
  }

  /// A call this device placed itself, which must never ring here.
  Future<void> _ringSelf() async {
    final handled = await CometChatVoip.handlePushNotification({
      'type': 'call',
      'callAction': 'initiated',
      'sessionId': 'v1.$_region.self.${DateTime.now().millisecondsSinceEpoch}',
      'callType': 'audio',
      // The gate only fires once the Calls SDK knows who is logged in.
      'sender': 'cameron',
      'senderName': 'Cameron (me)',
      'receiver': 'alex',
      'receiverType': 'user',
      'sentAt': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    }, sentTime: DateTime.now());
    _write(handled ? 'Pushed a call from myself' : 'Ignored');
  }

  /// A chat push, to show it comes straight back.
  Future<void> _chatPush() async {
    final handled = await CometChatVoip.handlePushNotification({
      'type': 'chat',
      'sender': 'alex',
      'body': 'Hello',
    });
    _write(handled ? 'Taken for a call' : 'Not a call push — still yours');
  }

  /// The caller hanging up before anyone answered.
  Future<void> _cancelActive() async {
    final call = CometChatVoip.activeCall ?? _ringing;
    if (call == null) {
      _write('Nothing is ringing');
      return;
    }
    await CometChatVoip.handlePushNotification({
      'type': 'call',
      'callAction': 'cancelled',
      'sessionId': call.sessionId,
      'callType': call.callType,
      'sender': call.callerUid,
      'senderName': call.callerName,
      'receiver': call.receiverUid,
      'receiverType': call.receiverType,
    });
  }

  Future<void> _accept(CometChatVoipCall call) async {
    try {
      // answer(), not accept(): it stops the native ring as well, so the
      // notification and CallKit stay in step with the in-app tap.
      await CometChatVoip.answer(call.sessionId);
    } on CometChatVoipException catch (e) {
      _write('Accept failed: ${e.message}');
    }
  }

  Future<void> _decline(CometChatVoipCall call) async {
    setState(() => _ringing = null);
    try {
      await CometChatVoip.decline(call.sessionId);
      _write('Declined ${call.callerName}');
    } on CometChatVoipException catch (e) {
      _write('Decline failed: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ringing = _ringing;
    return Scaffold(
      appBar: AppBar(title: const Text('CometChat VoIP')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: () => _ring(video: false),
                        child: const Text('Audio call'),
                      ),
                      FilledButton.tonal(
                        onPressed: () => _ring(video: true),
                        child: const Text('Video call'),
                      ),
                      OutlinedButton(
                        onPressed: _cancelActive,
                        child: const Text('Caller hangs up'),
                      ),
                      OutlinedButton(
                        onPressed: _chatPush,
                        child: const Text('Chat push'),
                      ),
                      OutlinedButton(
                        onPressed: _ringSelf,
                        child: const Text('Call from myself'),
                      ),
                      OutlinedButton(
                        onPressed: _checkSetup,
                        child: const Text('Check setup'),
                      ),
                      OutlinedButton(
                        onPressed: _askPermission,
                        child: const Text('Ask permission'),
                      ),
                      OutlinedButton(
                        onPressed: _showVoipToken,
                        child: const Text('VoIP token'),
                      ),
                    ],
                  ),
                ),
                if (ringing != null)
                  _IncomingCallCard(
                    call: ringing,
                    onAccept: () => _accept(ringing),
                    onDecline: () => _decline(ringing),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: _log.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Ring yourself, then lock the phone and try '
                              'again. With an app ID filled in you get the '
                              'real ring: CallKit on iOS, a full-screen call '
                              'notification on Android.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _log.length,
                          itemBuilder: (context, index) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.chevron_right, size: 18),
                            title: Text(_log[index]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

/// The app's own incoming-call UI, for a call the Calls SDK reported ringing.
class _IncomingCallCard extends StatelessWidget {
  const _IncomingCallCard({
    required this.call,
    required this.onAccept,
    required this.onDecline,
  });

  final CometChatVoipCall call;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(call.isVideo ? Icons.videocam : Icons.call),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  call.callerName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'Incoming ${call.callType} call',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton.filled(
            onPressed: onAccept,
            icon: const Icon(Icons.call),
            tooltip: 'Accept',
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: onDecline,
            icon: const Icon(Icons.call_end),
            tooltip: 'Decline',
          ),
        ],
      ),
    ),
  );
}
