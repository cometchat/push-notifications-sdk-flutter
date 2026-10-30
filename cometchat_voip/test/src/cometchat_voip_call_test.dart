import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart' as calls;
import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:cometchat_voip/src/push/call_push_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('from the call the Calls SDK reported', () {
    test('every field carries over', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(
          sessionId: 'session-1',
          sender: 'alice',
          callerName: 'Alice',
          callerAvatarUrl: 'https://example.com/a.png',
          type: 'video',
          receiver: 'bob',
          receiverType: 'user',
          conversationId: 'alice_bob',
          initiatedAt: 1700000000000,
        ),
      )!;

      expect(call.sessionId, 'session-1');
      expect(call.callerUid, 'alice');
      expect(call.callerName, 'Alice');
      expect(call.callerAvatarUrl, 'https://example.com/a.png');
      expect(call.callType, CometChatVoipCall.typeVideo);
      expect(call.isVideo, isTrue);
      expect(call.receiverUid, 'bob');
      expect(call.isPeerCall, isTrue);
      expect(call.conversationId, 'alice_bob');
      expect(call.initiatedAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('is nothing without a session', () {
      expect(
        CometChatVoipCall.fromInitiatedCall(calls.InitiatedCall(sessionId: '')),
        isNull,
      );
    });

    test('an unnamed caller shows by uid, then as unknown', () {
      final byUid = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(sessionId: 's', sender: 'alice'),
      )!;
      expect(byUid.callerName, 'alice');

      final unknown = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(sessionId: 's'),
      )!;
      expect(unknown.callerName, 'Unknown caller');
    });

    test('the ring window comes from the payload the SDK carried back', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(
          sessionId: 'session-2',
          initiatedAt: 1700000000000,
          payload: {
            'type': 'call',
            'callAction': 'initiated',
            'sessionId': 'session-2',
            'ringTimeout': '30000',
          },
        ),
      )!;
      expect(call.ringTimeout, const Duration(seconds: 30));
      expect(call.expiresAt.millisecondsSinceEpoch, 1700000000000 + 30000);
    });

    test('a payload fills in what the SDK model left null', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(
          sessionId: 'session-3',
          payload: {
            'type': 'call',
            'callAction': 'initiated',
            'sessionId': 'session-3',
            'senderName': 'Dave',
            'senderAvatar': 'https://example.com/d.png',
            'callType': 'video',
            'receiverType': 'group',
            'receiver': 'team',
            'conversationId': 'team-call',
          },
        ),
      )!;

      expect(call.callerName, 'Dave');
      expect(call.callerAvatarUrl, 'https://example.com/d.png');
      expect(call.callType, CometChatVoipCall.typeVideo);
      expect(call.receiverType, CometChatVoipCall.receiverTypeGroup);
      expect(call.isPeerCall, isFalse);
      expect(call.receiverUid, 'team');
      expect(call.conversationId, 'team-call');
    });

    test('a call with no ring window at all rings for the default 45 s', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(sessionId: 's'),
      )!;
      expect(
        call.ringTimeout,
        Duration(milliseconds: CallPushPayload.defaultRingTimeoutMs),
      );
    });
  });

  group('from a push the Calls SDK never rang', () {
    test('the push alone describes the call', () {
      final push = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'cancelled',
        'sessionId': 'session-4',
        'sender': 'alice',
        'senderName': 'Alice',
        'callType': 'video',
        'initiatedAt': '1700000000',
      })!;

      final call = CometChatVoipCall.fromPushPayload(push);
      expect(call.sessionId, 'session-4');
      expect(call.callerUid, 'alice');
      expect(call.callerName, 'Alice');
      expect(call.isVideo, isTrue);
      expect(call.initiatedAt.millisecondsSinceEpoch, 1700000000000);
    });

    test('with no timestamp at all it falls back to arrival', () {
      final push = CallPushPayload.parse({
        'type': 'call',
        'callAction': 'cancelled',
        'sessionId': 's',
      })!;
      final receivedAt = DateTime.fromMillisecondsSinceEpoch(1234567);
      final call = CometChatVoipCall.fromPushPayload(
        push,
        receivedAt: receivedAt,
      );
      expect(call.initiatedAt, receivedAt);
    });
  });

  group('CometChatCallEndReason', () {
    test('reads the names this package reports', () {
      for (final reason in CometChatCallEndReason.values) {
        expect(CometChatCallEndReason.fromWire(reason.wireName), reason);
      }
    });

    test("reads Android's call statuses", () {
      expect(
        CometChatCallEndReason.fromWire('cancelled'),
        CometChatCallEndReason.cancelled,
      );
      expect(
        CometChatCallEndReason.fromWire('rejected'),
        CometChatCallEndReason.declined,
      );
      expect(
        CometChatCallEndReason.fromWire('busy'),
        CometChatCallEndReason.declined,
      );
      expect(
        CometChatCallEndReason.fromWire('ended'),
        CometChatCallEndReason.declined,
      );
      expect(
        CometChatCallEndReason.fromWire('unanswered'),
        CometChatCallEndReason.timedOut,
      );
      expect(
        CometChatCallEndReason.fromWire('ongoing'),
        CometChatCallEndReason.answeredElsewhere,
      );
    });

    test('an unknown name is a remote end, not a crash', () {
      expect(
        CometChatCallEndReason.fromWire('teleported'),
        CometChatCallEndReason.remoteEnded,
      );
      expect(
        CometChatCallEndReason.fromWire(null),
        CometChatCallEndReason.remoteEnded,
      );
    });

    test('only a cancel and a timeout are missed calls', () {
      expect(CometChatCallEndReason.cancelled.isMissed, isTrue);
      expect(CometChatCallEndReason.timedOut.isMissed, isTrue);
      expect(CometChatCallEndReason.declined.isMissed, isFalse);
      expect(CometChatCallEndReason.answeredElsewhere.isMissed, isFalse);
      expect(CometChatCallEndReason.filtered.isMissed, isFalse);
    });

    test('a terminal action maps to the reason it ends with', () {
      expect(
        CometChatCallEndReason.fromAction(CometChatCallAction.cancelled),
        CometChatCallEndReason.cancelled,
      );
      expect(
        CometChatCallEndReason.fromAction(CometChatCallAction.timedOut),
        CometChatCallEndReason.timedOut,
      );
      expect(
        CometChatCallEndReason.fromAction(CometChatCallAction.ongoing),
        CometChatCallEndReason.answeredElsewhere,
      );
      expect(
        CometChatCallEndReason.fromAction(CometChatCallAction.busy),
        CometChatCallEndReason.declined,
      );
    });
  });

  group('initials', () {
    test('are up to two upper-case letters', () {
      CometChatVoipCall withName(String name) =>
          CometChatVoipCall.fromInitiatedCall(
            calls.InitiatedCall(sessionId: 's', callerName: name),
          )!;

      expect(withName('Alice Demo').initials, 'AD');
      expect(withName('bob').initials, 'B');
      expect(withName('alice demo cooper').initials, 'AD');
      expect(withName('  spaced   out  ').initials, 'SO');
    });

    test('fall back to a question mark', () {
      final unnamed = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(sessionId: 's'),
      )!;
      expect(unnamed.callerName, 'Unknown caller');
      expect(unnamed.initials, 'UC');

      final blank = CometChatVoipCall(
        sessionId: 's',
        callerName: '   ',
        callType: 'audio',
        receiverType: 'user',
        initiatedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ringTimeout: const Duration(seconds: 45),
      );
      expect(blank.initials, '?');
    });
  });

  group('extras', () {
    test('carry the payload keys the model does not name', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(
          sessionId: 's',
          payload: {
            'type': 'call',
            'callAction': 'initiated',
            'sessionId': 's',
            'sender': 'alice',
            'senderName': 'Alice',
            'tenantId': 'acme',
            'priority': 'high',
          },
        ),
      )!;
      expect(call.extras, {'tenantId': 'acme', 'priority': 'high'});
    });

    test('are empty when the payload holds nothing new', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(sessionId: 's'),
      )!;
      expect(call.extras, isEmpty);
    });
  });

  group('source', () {
    test('defaults to the push it arrived on', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(sessionId: 's'),
      )!;
      expect(call.source, CometChatCallSource.push);
    });

    test('reads the websocket source the native SDKs report', () {
      final call = CometChatVoipCall.fromInitiatedCall(
        calls.InitiatedCall(
          sessionId: 's',
          payload: {
            'type': 'call',
            'callAction': 'initiated',
            'sessionId': 's',
            'source': 'WEBSOCKET',
          },
        ),
      )!;
      expect(call.source, CometChatCallSource.webSocket);
      expect(call.extras, isEmpty, reason: 'source is a named field');
    });
  });

  test('a configurable default ring window is honoured', () {
    final call = CometChatVoipCall.fromInitiatedCall(
      calls.InitiatedCall(sessionId: 's'),
      defaultRingTimeout: const Duration(seconds: 20),
    )!;
    expect(call.ringTimeout, const Duration(seconds: 20));
  });
}
