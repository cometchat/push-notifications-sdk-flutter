import 'dart:async';

import 'package:cometchat_push_notifications/cometchat_push_notifications_export.dart';
import 'package:flutter/material.dart';

/// A tour of the package that runs without a CometChat account or a push
/// provider behind it.
///
/// Real apps receive payloads from `firebase_messaging` (or APNs) and forward
/// them to [CometChatPushNotifications.handlePushNotification]. Wiring that up
/// needs Firebase credentials this example cannot ship, so the buttons below
/// feed it the same payloads the CometChat server sends. Everything downstream
/// — parsing, the Android notification, grouping, tap — is the real path.
void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CometChat Push Notifications',
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
  StreamSubscription<CometChatNotificationResponse>? _responses;
  bool _ready = false;
  int _messageId = 1;

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  @override
  void dispose() {
    _responses?.cancel();
    CometChatPushNotifications.dispose();
    super.dispose();
  }

  Future<void> _setUp() async {
    await CometChatPushNotifications.init(
      const CometChatNotificationConfig(
        appId: 'APP_ID',
        region: 'us',
        // Nothing is logged in here, so a receipt would only fail noisily.
        sendDeliveryReceipts: false,
      ),
    );

    _responses = CometChatPushNotifications.onNotificationTap.listen((
      response,
    ) {
      _write('Tapped ${response.senderName}\'s notification');
    });

    setState(() => _ready = true);
  }

  void _write(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  Future<void> _requestPermission() async {
    final granted = await CometChatPushNotifications.requestPermission();
    _write(granted ? 'Notifications allowed' : 'Notifications denied');
  }

  /// One push, in the shape the CometChat server sends it.
  Future<void> _simulate({required bool group}) async {
    final id = _messageId++;
    final handled = await CometChatPushNotifications.handlePushNotification({
      'data': {
        'to': {'uid': 'cameron'},
        'notificationDetails': {
          'type': 'chat',
          'title': group ? 'Engineering' : 'Alex Okonjo',
          'body': group ? 'Standup in five' : 'Message $id',
          'sender': 'alex',
          'senderName': 'Alex Okonjo',
          'receiver': group ? 'engineering' : 'cameron',
          'receiverName': group ? 'Engineering' : 'Cameron Diaz',
          'receiverType': group ? 'group' : 'user',
          'conversationId': group ? 'group_engineering' : 'alex_user_cameron',
          'tag': '$id',
        },
      },
    });
    _write(
      handled
          ? 'Posted a ${group ? 'group' : '1:1'} notification'
          : 'Payload was not a chat push',
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('CometChat Push Notifications')),
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
                    FilledButton(
                      onPressed: _requestPermission,
                      child: const Text('Ask permission'),
                    ),
                    FilledButton.tonal(
                      onPressed: () => _simulate(group: false),
                      child: const Text('1:1 message'),
                    ),
                    FilledButton.tonal(
                      onPressed: () => _simulate(group: true),
                      child: const Text('Group message'),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        await CometChatPushNotifications.clearNotifications();
                        _write('Cleared this package\'s notifications');
                      },
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _log.isEmpty
                    ? const Center(
                        child: Text('Send yourself a message to begin.'),
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
