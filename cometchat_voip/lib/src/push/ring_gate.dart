import '../models/cometchat_voip_enums.dart';
import 'call_push_payload.dart';

/// Why a call push was dropped instead of rung.
class RingDrop {
  /// A sentence for the log, naming the gate that dropped it.
  final String reason;

  /// The end reason the call is reported with, so the app still hears about it.
  final CometChatCallEndReason endAs;

  /// Whether the session is remembered as over, so a later duplicate cannot
  /// revive it.
  final bool markTerminal;

  /// Creates a [RingDrop].
  const RingDrop({
    required this.reason,
    required this.endAs,
    this.markTerminal = false,
  });

  @override
  String toString() => 'RingDrop($reason, endAs: ${endAs.name})';
}

/// Decides whether a parsed call push deserves to ring at all.
///
/// A port of the native SDKs' `RingGate`. The gates matter most on a process
/// the system created to deliver a push, where nothing is in memory and no SDK
/// is logged in — so each one is written to be weaker, never wrong, when it
/// cannot tell: an unknown local UID or a payload without a receiver is not
/// evidence of a mismatch, and neither fails open nor fails closed.
///
/// Ringing the caller's own phone for their own call is the most visible bug
/// of the lot, which is why the self-ring gate comes first.
class RingGate {
  const RingGate._();

  /// Decides on [push]. Returns null to ring it.
  ///
  /// [myUid] is the logged-in user, or null when this process does not know
  /// whose device it is. [ledger] remembers the sessions already over.
  /// [nowMs] and [receivedAtMs] bound the ring window.
  static RingDrop? decide(
    CallPushPayload push, {
    required String? myUid,
    required TerminalLedger ledger,
    required int nowMs,
    required int receivedAtMs,
    bool dropExpired = true,
  }) {
    // The backend fans a call out to every device of every participant,
    // including the caller's own.
    if (myUid != null && push.senderUid != null && push.senderUid == myUid) {
      return const RingDrop(
        reason: 'self-ring: the caller is this user',
        endAs: CometChatCallEndReason.filtered,
      );
    }

    // Addressed to someone else. Only enforced for a one-to-one call with both
    // sides known: a group call rings for every member, and a missing receiver
    // or an unknown local UID proves nothing.
    final receiver = push.receiverUid;
    final isPeerCall = (push.receiverType ?? 'user').toLowerCase() == 'user';
    if (myUid != null && receiver != null && isPeerCall && receiver != myUid) {
      return RingDrop(
        reason: 'addressed to $receiver, not this user',
        endAs: CometChatCallEndReason.filtered,
      );
    }

    // A terminal push overtook its initiated, or this is a redelivery.
    if (ledger.wasTerminal(push.sessionId)) {
      return RingDrop(
        reason:
            'session already ended '
            '(${ledger.reasonFor(push.sessionId) ?? '?'})',
        endAs: CometChatCallEndReason.filtered,
      );
    }

    // Past its absolute deadline. FCM and APNs queue while a device dozes, so
    // a push can arrive long after the caller gave up.
    final expiresAtMs = push.expiresAtMs(receivedAtMs);
    if (dropExpired && nowMs >= expiresAtMs) {
      return RingDrop(
        reason: 'expired ${nowMs - expiresAtMs}ms ago',
        endAs: CometChatCallEndReason.timedOut,
        markTerminal: true,
      );
    }

    return null;
  }
}

/// The sessions this process knows are over.
///
/// Bounded and in memory, which is the one place this falls short of the
/// native SDKs: they persist the ledger, so a duplicate push that arrives on a
/// cold process is still caught. Here a cold process starts empty, and the gate
/// that catches a redelivery only works while the process lives. Persisting it
/// would need a storage plugin, which this package deliberately does not have.
class TerminalLedger {
  /// How many sessions are remembered. The native SDKs keep the same number.
  static const maxEntries = 20;

  final Map<String, String> _reasons = {};

  /// Remembers [sessionId] as over, because of [reason].
  void markTerminal(String sessionId, String reason) {
    if (sessionId.isEmpty) return;
    _reasons.remove(sessionId);
    _reasons[sessionId] = reason;
    while (_reasons.length > maxEntries) {
      _reasons.remove(_reasons.keys.first);
    }
  }

  /// Whether [sessionId] is remembered as over.
  bool wasTerminal(String sessionId) => _reasons.containsKey(sessionId);

  /// Why [sessionId] is remembered as over, if it is.
  String? reasonFor(String sessionId) => _reasons[sessionId];

  /// Forgets everything.
  void clear() => _reasons.clear();

  /// How many sessions are remembered, for diagnostics.
  int get length => _reasons.length;
}
