import 'dart:convert';

import 'package:cometchat_voip/src/push/call_push_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a flat Push Notifications payload', () {
    test('is read whole', () {
      final push = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 'session-1',
        'callType': 'video',
        'sender': 'alice',
        'senderName': 'Alice',
        'senderAvatar': 'https://example.com/a.png',
        'receiver': 'bob',
        'receiverType': 'user',
        'conversationId': 'alice_bob',
        'sentAt': '1700000000',
        'ringTimeout': '30000',
      })!;

      expect(push.action, CometChatCallAction.initiated);
      expect(push.sessionId, 'session-1');
      expect(push.callType, CallPushPayload.typeVideo);
      expect(push.senderUid, 'alice');
      expect(push.senderName, 'Alice');
      expect(push.senderAvatar, 'https://example.com/a.png');
      expect(push.receiverUid, 'bob');
      expect(push.receiverType, 'user');
      expect(push.conversationId, 'alice_bob');
      expect(push.sentAtMs, 1700000000000);
      expect(push.ringTimeoutMs, 30000);
    });

    test('matches keys whatever case or separator the template used', () {
      final push = CallPushPayload.parse({
        'TYPE': 'Call',
        'call_action': 'initiated',
        'SESSION_ID': 'session-2',
        'call_type': 'AUDIO',
        'sender_uid': 'carol',
      })!;

      expect(push.sessionId, 'session-2');
      expect(push.callType, CallPushPayload.typeAudio);
      expect(push.senderUid, 'carol');
    });

    test('is a call even when only callAction names it', () {
      final push = CallPushPayload.parse({
        'callAction': 'initiated',
        'sessionId': 'session-3',
      });
      expect(push, isNotNull);
    });
  });

  group('the legacy extension payload', () {
    test('is read out of the nested message JSON', () {
      final push = CallPushPayload.parse({
        'message': jsonEncode({
          'category': 'call',
          'action': 'initiated',
          'sessionid': 'session-4',
          'type': 'video',
          'sender': {
            'uid': 'dave',
            'name': 'Dave',
            'avatar': 'https://example.com/d.png',
          },
          'receiver': 'erin',
          'receiverType': 'user',
          'conversationId': 'dave_erin',
        }),
      })!;

      expect(push.sessionId, 'session-4');
      expect(push.callType, CallPushPayload.typeVideo);
      expect(push.senderUid, 'dave');
      expect(push.senderName, 'Dave');
      expect(push.senderAvatar, 'https://example.com/d.png');
      expect(push.receiverUid, 'erin');
      expect(push.conversationId, 'dave_erin');
    });

    test('malformed JSON is ignored rather than thrown', () {
      expect(CallPushPayload.parse({'message': '{not json'}), isNull);
    });
  });

  group('what is not a call', () {
    test('an empty payload', () {
      expect(CallPushPayload.parse({}), isNull);
    });

    test('a chat message', () {
      expect(
        CallPushPayload.parse({
          'type': 'chat',
          'sessionId': 'session-5',
          'body': 'hello',
        }),
        isNull,
      );
    });

    test('a call push with no action', () {
      expect(
        CallPushPayload.parse({'type': 'call', 'sessionId': 'session-6'}),
        isNull,
      );
    });

    test('a call push with no session, which could not be joined', () {
      expect(
        CallPushPayload.parse({
          'type': 'call',
          'callAction': 'initiated',
          'sessionId': '   ',
        }),
        isNull,
      );
    });
  });

  group('actions', () {
    test('only initiated keeps the call ringing', () {
      expect(CometChatCallAction.initiated.isTerminal, isFalse);
      expect(CometChatCallAction.unknown.isTerminal, isFalse);
      for (final action in [
        CometChatCallAction.ongoing,
        CometChatCallAction.ended,
        CometChatCallAction.unanswered,
        CometChatCallAction.timedOut,
        CometChatCallAction.rejected,
        CometChatCallAction.busy,
        CometChatCallAction.cancelled,
      ]) {
        expect(action.isTerminal, isTrue, reason: action.name);
      }
    });

    test('an action this build does not know is kept raw', () {
      final push = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'teleported',
        'sessionId': 'session-7',
      })!;
      expect(push.action, CometChatCallAction.unknown);
      expect(push.rawAction, 'teleported');
    });
  });

  group('the ring deadline', () {
    test('seconds and millis both read as millis', () {
      final seconds = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 's',
        'initiatedAt': '1700000000',
      })!;
      final millis = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 's',
        'initiatedAt': '1700000000000',
      })!;
      expect(seconds.initiatedAtMs, 1700000000000);
      expect(millis.initiatedAtMs, 1700000000000);
    });

    test('a ring window outside the sane range is ignored', () {
      for (final timeout in ['0', '500', '900000', 'soon']) {
        final push = CallPushPayload.parse({
          'type': 'call',
          'callAction': 'initiated',
          'sessionId': 's',
          'ringTimeout': timeout,
        })!;
        expect(push.ringTimeoutMs, isNull, reason: timeout);
      }
    });

    test('falls back to sentAt, then to arrival, then to 45 s', () {
      final none = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 's',
      })!;
      expect(none.expiresAtMs(1000), 1000 + 45000);

      final sent = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 's',
        'sentAt': '1700000000',
      })!;
      expect(sent.expiresAtMs(1000), 1700000000000 + 45000);
    });
  });

  group('the caller shown on the ring', () {
    test('is the name, then the uid, then unknown', () {
      CallPushPayload push(Map<String, String> extra) => CallPushPayload.parse({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 's',
        ...extra,
      })!;

      expect(
        push({'senderName': 'Alice', 'sender': 'alice'}).displayName,
        'Alice',
      );
      expect(push({'sender': 'alice'}).displayName, 'alice');
      expect(push({}).displayName, 'Unknown caller');
      expect(push({'senderName': '  '}).displayName, 'Unknown caller');
    });

    test('the notification title stands in for a missing sender name', () {
      final push = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'initiated',
        'sessionId': 's',
        'title': 'Incoming call from Alice',
      })!;
      expect(push.senderName, 'Incoming call from Alice');
    });
  });

  test('the payload is kept as received, for the Calls SDK', () {
    final push = CallPushPayload.parse({
      'type': 'call',
      'callAction': 'initiated',
      'sessionId': 'session-8',
      'extra': 'kept',
    })!;
    expect(push.raw, {
      'type': 'call',
      'callAction': 'initiated',
      'sessionId': 'session-8',
      'extra': 'kept',
    });
  });
}
