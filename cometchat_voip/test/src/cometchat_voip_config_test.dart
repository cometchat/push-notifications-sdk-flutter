import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart' as calls;
import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  calls.CallAppSettings settings({
    String? appId = 'APP',
    String? region = 'us',
    String? clientHost,
  }) {
    final builder = calls.CallAppSettingBuilder()
      ..appId = appId
      ..region = region;
    if (clientHost != null) builder.overrideClientHost(clientHost);
    return builder.build();
  }

  group('fromCallAppSettings', () {
    test('takes the app id and region the Calls SDK already has', () {
      final config = CometChatVoipConfig.fromCallAppSettings(
        settings(),
        providerId: 'provider-1',
      );
      expect(config.appId, 'APP');
      expect(config.region, 'us');
      expect(config.providerId, 'provider-1');
    });

    test('carries the Calls SDK client-host override across', () {
      final config = CometChatVoipConfig.fromCallAppSettings(
        settings(clientHost: 'staging.example.com/v3.0'),
      );
      expect(config.clientHost, 'staging.example.com/v3.0');
    });

    test('keeps the same defaults as the plain constructor', () {
      final fromSettings = CometChatVoipConfig.fromCallAppSettings(settings());
      const plain = CometChatVoipConfig(appId: 'APP', region: 'us');
      expect(fromSettings.autoRegisterPushToken, plain.autoRegisterPushToken);
      expect(fromSettings.dropExpiredCalls, plain.dropExpiredCalls);
      expect(fromSettings.callKitAudio, plain.callKitAudio);
      expect(fromSettings.acceptOnAnswer, plain.acceptOnAnswer);
      expect(fromSettings.defaultRingTimeout, plain.defaultRingTimeout);
    });

    test('refuses settings with nothing to read', () {
      expect(
        () => CometChatVoipConfig.fromCallAppSettings(settings(appId: null)),
        throwsArgumentError,
      );
      expect(
        () => CometChatVoipConfig.fromCallAppSettings(settings(region: '')),
        throwsArgumentError,
      );
    });
  });

  test('the default ring window is 45 s, and configurable', () {
    const plain = CometChatVoipConfig(appId: 'APP', region: 'us');
    expect(plain.defaultRingTimeout, const Duration(seconds: 45));

    const shorter = CometChatVoipConfig(
      appId: 'APP',
      region: 'us',
      defaultRingTimeout: Duration(seconds: 20),
    );
    expect(shorter.defaultRingTimeout, const Duration(seconds: 20));
  });
}
