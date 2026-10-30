import 'package:cometchat_voip_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Neither the ringer nor the Calls SDK has a native side in a widget test,
  // so every call would throw MissingPluginException and the example would
  // never finish starting up.
  const callsChannel = MethodChannel('cometchatcalls_plugin');
  const voipChannel = MethodChannel('cometchat_voip');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(callsChannel, (call) async => null)
      ..setMockMethodCallHandler(voipChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(callsChannel, null)
      ..setMockMethodCallHandler(voipChannel, null);
  });

  testWidgets('the example renders its controls once set-up finishes', (
    tester,
  ) async {
    await tester.pumpWidget(const ExampleApp());

    // init() awaits the Calls SDK, so the first frame is the spinner.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Not pumpAndSettle: the spinner animates forever, so it never settles.
    await tester.pump();
    await tester.pump();

    expect(find.text('Audio call'), findsOneWidget);
    expect(find.text('Video call'), findsOneWidget);
  });
}
