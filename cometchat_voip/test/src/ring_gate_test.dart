import 'package:cometchat_voip/cometchat_voip.dart';
import 'package:cometchat_voip/src/push/call_push_payload.dart';
import 'package:cometchat_voip/src/push/ring_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const nowMs = 1700000000000;

  CallPushPayload push({
    String sessionId = 'session-1',
    String? sender = 'alice',
    String? receiver = 'bob',
    String receiverType = 'user',
    int initiatedAtMs = nowMs,
    int ringTimeoutMs = 45000,
  }) => CallPushPayload.parse({
    'type': 'call',
    'callAction': 'initiated',
    'sessionId': sessionId,
    'sender': sender,
    'receiver': receiver,
    'receiverType': receiverType,
    'initiatedAt': '$initiatedAtMs',
    'ringTimeout': '$ringTimeoutMs',
  })!;

  RingDrop? decide(
    CallPushPayload p, {
    String? myUid = 'bob',
    TerminalLedger? ledger,
    int now = nowMs,
    bool dropExpired = true,
  }) => RingGate.decide(
    p,
    myUid: myUid,
    ledger: ledger ?? TerminalLedger(),
    nowMs: now,
    receivedAtMs: nowMs,
    dropExpired: dropExpired,
  );

  group('a call meant for this device', () {
    test('rings', () {
      expect(decide(push()), isNull);
    });

    test('rings when this process does not know whose device it is', () {
      // A background isolate before the Calls SDK restored its session. The
      // gates weaken rather than guess.
      expect(decide(push(receiver: 'someone-else'), myUid: null), isNull);
    });
  });

  group('the self-ring gate', () {
    test('drops a call this user placed', () {
      final drop = decide(push(sender: 'bob'), myUid: 'bob');
      expect(drop, isNotNull);
      expect(drop!.reason, contains('self-ring'));
      expect(drop.endAs, CometChatCallEndReason.filtered);
      expect(drop.markTerminal, isFalse);
    });

    test('says nothing about a call from someone else', () {
      expect(decide(push(sender: 'alice'), myUid: 'bob'), isNull);
    });

    test('cannot fire without a sender', () {
      expect(decide(push(sender: null), myUid: 'bob'), isNull);
    });
  });

  group('the misaddressed gate', () {
    test('drops a one-to-one call addressed to someone else', () {
      final drop = decide(push(receiver: 'carol'), myUid: 'bob');
      expect(drop, isNotNull);
      expect(drop!.reason, contains('addressed to carol'));
      expect(drop.endAs, CometChatCallEndReason.filtered);
    });

    test('never drops a group call: it rings for every member', () {
      expect(decide(push(receiver: 'the-team', receiverType: 'group')), isNull);
    });

    test('a missing receiver is not evidence of a mismatch', () {
      expect(decide(push(receiver: null), myUid: 'bob'), isNull);
    });
  });

  group('the duplicate gate', () {
    test('drops a session already known to be over', () {
      final ledger = TerminalLedger()..markTerminal('session-1', 'cancelled');
      final drop = decide(push(), ledger: ledger);
      expect(drop, isNotNull);
      expect(drop!.reason, contains('already ended'));
      expect(drop.reason, contains('cancelled'));
      expect(drop.endAs, CometChatCallEndReason.filtered);
    });

    test('says nothing about a different session', () {
      final ledger = TerminalLedger()..markTerminal('session-9', 'cancelled');
      expect(decide(push(), ledger: ledger), isNull);
    });
  });

  group('the ring-window gate', () {
    test('drops a call past its deadline, as a missed one', () {
      final drop = decide(push(ringTimeoutMs: 30000), now: nowMs + 60000);
      expect(drop, isNotNull);
      expect(drop!.reason, contains('expired'));
      expect(drop.endAs, CometChatCallEndReason.timedOut);
      expect(drop.markTerminal, isTrue);
    });

    test('can be turned off', () {
      expect(
        decide(
          push(ringTimeoutMs: 30000),
          now: nowMs + 60000,
          dropExpired: false,
        ),
        isNull,
      );
    });
  });

  test('the self-ring gate is checked before the others', () {
    // A call this user placed to themselves, past its deadline, on a session
    // already over: the most useful reason is the first one.
    final ledger = TerminalLedger()..markTerminal('session-1', 'ended');
    final drop = decide(
      push(sender: 'bob', receiver: 'carol', ringTimeoutMs: 1000),
      myUid: 'bob',
      ledger: ledger,
      now: nowMs + 60000,
    );
    expect(drop!.reason, contains('self-ring'));
  });

  group('TerminalLedger', () {
    test('remembers a session and why', () {
      final ledger = TerminalLedger()..markTerminal('s', 'rejected');
      expect(ledger.wasTerminal('s'), isTrue);
      expect(ledger.reasonFor('s'), 'rejected');
      expect(ledger.wasTerminal('other'), isFalse);
    });

    test('keeps the newest entries and drops the oldest', () {
      final ledger = TerminalLedger();
      for (var i = 0; i < TerminalLedger.maxEntries + 5; i++) {
        ledger.markTerminal('s$i', 'ended');
      }
      expect(ledger.length, TerminalLedger.maxEntries);
      expect(ledger.wasTerminal('s0'), isFalse);
      expect(ledger.wasTerminal('s${TerminalLedger.maxEntries + 4}'), isTrue);
    });

    test('re-marking a session moves it to the newest end', () {
      final ledger = TerminalLedger()..markTerminal('keep', 'ended');
      for (var i = 0; i < TerminalLedger.maxEntries - 1; i++) {
        ledger.markTerminal('s$i', 'ended');
      }
      ledger.markTerminal('keep', 'rejected');
      ledger.markTerminal('one-more', 'ended');
      expect(ledger.wasTerminal('keep'), isTrue);
      expect(ledger.reasonFor('keep'), 'rejected');
    });

    test('ignores an empty session id', () {
      final ledger = TerminalLedger()..markTerminal('', 'ended');
      expect(ledger.length, 0);
    });
  });
}
