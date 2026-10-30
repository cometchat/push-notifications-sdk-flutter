import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cometchat_push_notifications/src/errors/cometchat_notification_exception.dart';
import 'package:cometchat_push_notifications/src/models/cometchat_enums.dart';
import 'package:cometchat_push_notifications/src/parser/cometchat_payload_parser.dart';

/// Characterization tests for [CometChatPayloadParser], written before the v2
/// strip edits it.
///
/// They assert only on chat and shape-detection behaviour — nothing here
/// touches `callAction`, `sessionId` or `callType`, because those fields are
/// being removed and tests asserting on them would have to be deleted in the
/// same change they are meant to protect.
///
/// Both wire shapes are real: the dashboard and webhooks send the nested form,
/// and Firebase's `RemoteMessage.data` arrives flat with every nested object
/// JSON-encoded as a string.
void main() {
  group('shape detection', () {
    test(
      'parses the nested form with data.to and data.notificationDetails',
      () {
        final payload = {
          'trigger': 'push-notification-payload-generated',
          'data': {
            'to': {'uid': 'cameron'},
            'notificationDetails': {
              'title': 'Alex Okonjo',
              'body': 'Are we still on for 3?',
              'sender': 'alex',
              'senderName': 'Alex Okonjo',
              'receiver': 'cameron',
              'receiverName': 'Cameron Diaz',
              'receiverType': 'user',
              'type': 'chat',
              'conversationId': 'alex_user_cameron',
              'tag': 'message',
              'sentAt': '1758499200',
            },
          },
        };

        final result = CometChatPayloadParser.parse(payload);

        expect(result.toUid, 'cameron');
        expect(result.notificationDetails.title, 'Alex Okonjo');
        expect(result.notificationDetails.body, 'Are we still on for 3?');
        expect(result.notificationDetails.sender, 'alex');
        expect(result.notificationDetails.conversationId, 'alex_user_cameron');
        expect(result.notificationDetails.type, CometChatPayloadType.chat);
        expect(result.rawPayload, same(payload));
      },
    );

    test('parses the flat form, detected by "type"', () {
      final payload = {
        'type': 'chat',
        'title': 'Alex Okonjo',
        'body': 'Are we still on for 3?',
        'sender': 'alex',
        'senderName': 'Alex Okonjo',
        'receiver': 'cameron',
        'receiverType': 'user',
        'conversationId': 'alex_user_cameron',
      };

      final result = CometChatPayloadParser.parse(payload);

      // The flat form has no `to` object; the recipient comes from `receiver`.
      expect(result.toUid, 'cameron');
      expect(result.notificationDetails.senderName, 'Alex Okonjo');
      expect(result.notificationDetails.type, CometChatPayloadType.chat);
    });

    test('parses the flat form when only "sender" identifies it', () {
      final payload = {
        'sender': 'alex',
        'senderName': 'Alex Okonjo',
        'body': 'no type key here',
        'receiver': 'cameron',
      };

      final result = CometChatPayloadParser.parse(payload);

      expect(result.toUid, 'cameron');
      expect(result.notificationDetails.sender, 'alex');
      // No `type` key means the enum falls through to unknown, not chat.
      expect(result.notificationDetails.type, CometChatPayloadType.unknown);
    });

    test('nested wins over flat when both could match', () {
      final payload = {
        'sender': 'top-level-sender',
        'data': {
          'to': {'uid': 'cameron'},
          'notificationDetails': {'sender': 'nested-sender'},
        },
      };

      final result = CometChatPayloadParser.parse(payload);

      expect(result.notificationDetails.sender, 'nested-sender');
    });
  });

  group('Firebase string-encoding', () {
    test('decodes "data" when it arrives as a JSON string', () {
      final payload = {
        'data': json.encode({
          'to': {'uid': 'cameron'},
          'notificationDetails': {
            'sender': 'alex',
            'senderName': 'Alex Okonjo',
            'type': 'chat',
          },
        }),
      };

      final result = CometChatPayloadParser.parse(payload);

      expect(result.toUid, 'cameron');
      expect(result.notificationDetails.senderName, 'Alex Okonjo');
    });

    test('decodes nested "to" and "notificationDetails" strings', () {
      final payload = {
        'data': {
          'to': json.encode({'uid': 'cameron'}),
          'notificationDetails': json.encode({
            'sender': 'alex',
            'type': 'chat',
          }),
        },
      };

      final result = CometChatPayloadParser.parse(payload);

      expect(result.toUid, 'cameron');
      expect(result.notificationDetails.sender, 'alex');
    });

    test('decodes "message" and "custom" objects from JSON strings', () {
      final payload = {
        'type': 'chat',
        'sender': 'alex',
        'message': json.encode({'id': '42', 'text': 'hello'}),
        'custom': json.encode({'campaign': 'launch'}),
      };

      final result = CometChatPayloadParser.parse(payload);

      expect(result.notificationDetails.message, {'id': '42', 'text': 'hello'});
      expect(result.notificationDetails.custom, {'campaign': 'launch'});
    });

    test('leaves message null when its string is not valid JSON', () {
      final payload = {
        'type': 'chat',
        'sender': 'alex',
        'message': 'not json at all',
      };

      expect(
        CometChatPayloadParser.parse(payload).notificationDetails.message,
        isNull,
      );
    });

    test('falls through to flat when "data" is an undecodable string', () {
      final payload = {
        'data': 'definitely not json',
        'type': 'chat',
        'sender': 'alex',
        'receiver': 'cameron',
      };

      final result = CometChatPayloadParser.parse(payload);

      expect(result.toUid, 'cameron');
      expect(result.notificationDetails.sender, 'alex');
    });
  });

  group('defaults and coercion', () {
    test('missing string fields default to empty, not null', () {
      final payload = {
        'data': {
          'to': {'uid': 'cameron'},
          'notificationDetails': {'type': 'chat'},
        },
      };

      final details = CometChatPayloadParser.parse(payload).notificationDetails;

      expect(details.title, '');
      expect(details.body, '');
      expect(details.sender, '');
      expect(details.senderName, '');
      expect(details.receiver, '');
      expect(details.receiverName, '');
      expect(details.tag, '');
      expect(details.conversationId, '');
      expect(details.sentAt, '');
    });

    test('nullable avatars stay null when absent', () {
      final details = CometChatPayloadParser.parse({
        'type': 'chat',
        'sender': 'alex',
      }).notificationDetails;

      expect(details.senderAvatar, isNull);
      expect(details.receiverAvatar, isNull);
    });

    test('missing "to.uid" yields an empty toUid rather than throwing', () {
      final payload = {
        'data': {
          'to': <String, dynamic>{},
          'notificationDetails': {'type': 'chat'},
        },
      };

      expect(CometChatPayloadParser.parse(payload).toUid, '');
    });

    test('receiverType maps user, group and anything else', () {
      CometChatPushReceiverType typeOf(String? raw) =>
          CometChatPayloadParser.parse({
            'type': 'chat',
            'sender': 'alex',
            'receiverType': ?raw,
          }).notificationDetails.receiverType;

      expect(typeOf('user'), CometChatPushReceiverType.user);
      expect(typeOf('group'), CometChatPushReceiverType.group);
      expect(
        typeOf('Group'),
        CometChatPushReceiverType.unknown,
      ); // case-sensitive
      expect(typeOf('squad'), CometChatPushReceiverType.unknown);
      expect(typeOf(null), CometChatPushReceiverType.unknown);
    });
  });

  group('rejection', () {
    test(
      'throws invalidPayload when nested "to" exists but details do not',
      () {
        expect(
          () => CometChatPayloadParser.parse({
            'data': {
              'to': {'uid': 'cameron'},
            },
          }),
          throwsA(
            isA<CometChatNotificationException>().having(
              (e) => e.code,
              'code',
              CometChatErrorCode.invalidPayload,
            ),
          ),
        );
      },
    );

    test(
      'throws invalidPayload on a flat map with neither type nor sender',
      () {
        expect(
          () => CometChatPayloadParser.parse({'title': 'orphan'}),
          throwsA(
            isA<CometChatNotificationException>().having(
              (e) => e.code,
              'code',
              CometChatErrorCode.invalidPayload,
            ),
          ),
        );
      },
    );

    test('throws invalidPayload on an empty map', () {
      expect(
        () => CometChatPayloadParser.parse(<String, dynamic>{}),
        throwsA(isA<CometChatNotificationException>()),
      );
    });
  });
}
