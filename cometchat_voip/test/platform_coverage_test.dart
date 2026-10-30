import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every method Dart sends must be handled by both native sides.
///
/// This has gone wrong twice. Once the background isolate announced itself on a
/// channel with no native handler, so a lock-screen decline queued for ever.
/// Once `sdkEndedCall` was sent and never received, so a caller's cancel
/// arriving through the Calls SDK left the phone ringing to its deadline.
/// Neither showed up in a unit test, a build, or `dart analyze`: an
/// unimplemented method just replies null.
///
/// So this reads the sources and compares them. Crude, and worth it — it is the
/// only thing standing between a renamed method and a silent half-wired
/// feature.
void main() {
  /// Methods a platform deliberately does not implement, with the reason.
  const intentionallyUnhandled = <String, Set<String>>{
    // iOS has no à-la-carte ring: reporting a call to CXProvider IS the ring.
    // It answers these with `unsupported_platform`, which the Dart side turns
    // into a CometChatVoipException — handled, just not by name.
    // CallKit draws the ring and cannot be styled; Dart does not send this on
    // iOS.
    'ios': {'setIncomingCallTheme'},
    'android': {},
  };

  late Set<String> dartSends;
  late Set<String> androidHandles;
  late Set<String> iosHandles;

  String read(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: '$path is missing — did the native layer move?',
    );
    return file.readAsStringSync();
  }

  setUpAll(() {
    final channel = read('lib/cometchat_voip_method_channel.dart');
    dartSends = RegExp(
      r"""invoke(?:Map|List)?Method<[^>]*>\(\s*'([a-zA-Z.]+)'""",
    ).allMatches(channel).map((m) => m.group(1)!).toSet();

    final kotlin = read(
      'android/src/main/kotlin/com/cometchat/voip/CometchatVoipPlugin.kt',
    );
    // `"name" ->` for a single case, `"name",` for one of several.
    androidHandles = RegExp(
      r'"([a-zA-Z.]+)"\s*(?:->|,)',
    ).allMatches(kotlin).map((m) => m.group(1)!).toSet();

    final swift = read(
      'ios/cometchat_voip/Sources/cometchat_voip/CometchatVoipPlugin.swift',
    );
    // `case "name":` and the continuation lines of a multi-pattern case.
    iosHandles = RegExp(
      r'(?:case\s+)?"([a-zA-Z.]+)"\s*(?:,|:)',
    ).allMatches(swift).map((m) => m.group(1)!).toSet();
  });

  test('Dart sends something at all', () {
    // Guards the regex itself: a silent zero would make every check below pass.
    expect(dartSends.length, greaterThan(20));
    expect(dartSends, contains('initialize'));
  });

  test('every method Dart sends is handled on Android', () {
    final missing = dartSends
        .difference(androidHandles)
        .difference(intentionallyUnhandled['android']!);
    expect(
      missing,
      isEmpty,
      reason:
          'CometchatVoipPlugin.kt handles none of these, so they reply null '
          'and whatever depends on them silently does nothing: $missing',
    );
  });

  test('every method Dart sends is handled on iOS', () {
    final missing = dartSends
        .difference(iosHandles)
        .difference(intentionallyUnhandled['ios']!);
    expect(
      missing,
      isEmpty,
      reason:
          'CometchatVoipPlugin.swift handles none of these, so they reply null '
          'and whatever depends on them silently does nothing: $missing',
    );
  });

  test('the background isolate talks on a channel the plugin registers', () {
    final bridge = read('lib/src/calls/native_calls_bridge.dart');
    final channels = RegExp(
      r"MethodChannel\('([^']+)'\)",
    ).allMatches(bridge).map((m) => m.group(1)!).toSet();

    // 'cometchat_voip' is the plugin's own, which a background engine
    // registers. 'cometchatcalls_plugin' is the Calls SDK's, for the audio
    // handoff. A third name would have no native side, which is how the
    // headless decline was broken once.
    expect(
      channels.difference({'cometchat_voip', 'cometchatcalls_plugin'}),
      isEmpty,
      reason:
          'a channel with no native handler strands whatever the ringer queued '
          'on it — the lock-screen decline on a killed app',
    );
  });

  test('the ringer can still reach the Calls SDK for everything it needs', () {
    final bridge = read('lib/src/calls/native_calls_bridge.dart');
    final served = RegExp(
      r"case '(calls\.[a-zA-Z]+)'",
    ).allMatches(bridge).map((m) => m.group(1)!).toSet();

    // What the native ringers ask for. Kept here because the asks live in
    // Kotlin and Swift, where a Dart test cannot see a typo.
    const asked = {
      'calls.connect',
      'calls.endCall',
      'calls.injectIncomingCall',
      'calls.injectIncomingCallEnded',
      'calls.sessionState',
      'calls.leaveSession',
      'calls.loggedInUid',
      'calls.callKitAudioActivated',
      'calls.callKitAudioDeactivated',
    };
    expect(
      asked.difference(served),
      isEmpty,
      reason:
          'NativeCallsBridge serves none of these, so the ringer asking '
          'for them gets nothing back',
    );
  });
}
