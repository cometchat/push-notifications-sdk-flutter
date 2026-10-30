// Integration tests run in a full Flutter application, so unlike Dart unit
// tests they reach the plugin's native side.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a chat push is not taken for a call', (tester) async {
    await CometChatVoip.init(
      const CometChatVoipConfig(
        appId: 'APP_ID',
        region: 'us',
        autoRegisterPushToken: false,
      ),
    );
    final handled = await CometChatVoip.handlePushNotification({
      'type': 'chat',
      'sender': 'alex',
    });
    expect(handled, isFalse);
  });
}
