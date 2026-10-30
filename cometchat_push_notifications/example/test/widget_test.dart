import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cometchat_push_notifications_example/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cometchat_push_notifications');

  setUp(() {
    // No native side in a widget test, so every call would throw
    // MissingPluginException and the example would never finish starting up.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('the example renders its controls once set-up finishes', (
    tester,
  ) async {
    await tester.pumpWidget(const ExampleApp());

    // init() crosses the method channel, so the first frame is the spinner.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Not pumpAndSettle: the spinner animates forever, so it never settles.
    await tester.pump();
    await tester.pump();

    expect(find.text('Ask permission'), findsOneWidget);
    expect(find.text('Send yourself a message to begin.'), findsOneWidget);
  });
}
