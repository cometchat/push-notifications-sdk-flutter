import 'dart:convert';

/// What a call push says happened to the call.
enum CometChatCallAction {
  /// The call started ringing.
  initiated('initiated'),

  /// Answered, possibly on another of this user's devices: stop ringing, and
  /// it is not a missed call.
  ongoing('ongoing'),

  /// The call is over.
  ended('ended'),

  /// Nobody answered before the ring window closed.
  unanswered('unanswered'),

  /// The server's name for a ring that expired; v1 sends `unanswered`.
  timedOut('timed_out'),

  /// Declined.
  rejected('rejected'),

  /// Declined because the callee was already on a call.
  busy('busy'),

  /// The caller hung up before anyone answered.
  cancelled('cancelled'),

  /// An action this version does not know.
  unknown('unknown');

  const CometChatCallAction(this.wireName);

  /// The name the backend sends.
  final String wireName;

  /// Whether this ends the ringing on the callee's side.
  bool get isTerminal =>
      this != CometChatCallAction.initiated &&
      this != CometChatCallAction.unknown;

  /// The action named [wire], or [unknown].
  static CometChatCallAction fromWire(String? wire) {
    final value = wire?.trim().toLowerCase();
    if (value == null || value.isEmpty) return unknown;
    return values.firstWhere(
      (action) => action.wireName == value,
      orElse: () => unknown,
    );
  }
}

/// The CometChat call push, parsed. Never throws: a crash here costs a ring.
///
/// Two shapes are in the field and both have to work:
///  - **Flat keys**, from Push Notifications (enhanced): `type=call`,
///    `callAction`, `sessionId`, `callType`, `sender`, `senderName`,
///    `senderAvatar`, `receiver`, `receiverType`, `conversationId`, `sentAt`.
///  - **The legacy extension**, which wraps the whole message in a `message`
///    JSON string (`category=call`, `action`, `sessionid`, `type`, `sender`).
///
/// Keys match case-insensitively and through a few aliases, so a template tweak
/// on the dashboard cannot silently stop calls ringing. `initiatedAt` and
/// `ringTimeout` are read when the backend sends them; until then the deadline
/// falls back to `sentAt`, then to when the push arrived, and the 45 s default.
class CallPushPayload {
  /// What happened to the call.
  final CometChatCallAction action;

  /// The action as received, for logs and for actions this build does not know.
  final String rawAction;

  /// The session the call runs in.
  final String sessionId;

  /// `audio` or `video`.
  final String callType;

  /// The caller's UID.
  final String? senderUid;

  /// The caller's display name.
  final String? senderName;

  /// The caller's avatar URL.
  final String? senderAvatar;

  /// The UID or GUID the call was placed to.
  final String? receiverUid;

  /// `user` or `group`.
  final String? receiverType;

  /// The conversation the call belongs to.
  final String? conversationId;

  /// When the push was sent, in milliseconds since the epoch.
  final int? sentAtMs;

  /// When the caller started ringing, in milliseconds since the epoch.
  final int? initiatedAtMs;

  /// How long the call rings, in milliseconds, when the push says.
  final int? ringTimeoutMs;

  /// The payload as received, which is what the Calls SDK is handed.
  final Map<String, String> raw;

  /// Creates a [CallPushPayload].
  const CallPushPayload({
    required this.action,
    required this.rawAction,
    required this.sessionId,
    required this.callType,
    required this.raw,
    this.senderUid,
    this.senderName,
    this.senderAvatar,
    this.receiverUid,
    this.receiverType,
    this.conversationId,
    this.sentAtMs,
    this.initiatedAtMs,
    this.ringTimeoutMs,
  });

  /// `callType` of an audio call.
  static const typeAudio = 'audio';

  /// `callType` of a video call.
  static const typeVideo = 'video';

  /// How long a call rings when the push does not say.
  static const defaultRingTimeoutMs = 45000;

  /// A ring window outside this range is a malformed payload, not an
  /// instruction.
  static const minRingTimeoutMs = 1000;

  /// The longest ring window a payload may ask for.
  static const maxRingTimeoutMs = 600000;

  /// `sentAt` arrives in seconds, and sometimes in millis. Anything below this
  /// is seconds. Reading seconds as millis puts the deadline in 1970, which
  /// silently drops every call.
  static const _secondsMillisThreshold = 100000000000;

  static const _callType = 'call';

  /// What the ring shows as the caller. Never empty.
  String get displayName {
    final name = senderName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final uid = senderUid?.trim();
    if (uid != null && uid.isNotEmpty) return uid;
    return 'Unknown caller';
  }

  /// When the call stops ringing, given [receivedAtMs] as the last fallback.
  int expiresAtMs(int receivedAtMs) =>
      (initiatedAtMs ?? sentAtMs ?? receivedAtMs) +
      (ringTimeoutMs ?? defaultRingTimeoutMs);

  /// Reads one push. Returns null when it is not a call to act on — a chat
  /// message, say, which is still the caller's to handle.
  static CallPushPayload? parse(Map<String, String?> data) {
    if (data.isEmpty) return null;
    final flat = _Lookup(data);

    final nested = _parseJsonObject(flat.get(['message']));
    final nestedSender = _parseJsonObject(nested?['sender']);

    final type = flat.get(['type', 'category']) ?? nested?['category'];
    final isCall =
        type?.trim().toLowerCase() == _callType ||
        (type == null &&
            flat.get(['callAction', 'callaction', 'call_action']) != null);
    if (!isCall) return null;

    final rawAction =
        flat.get(['callAction', 'callaction', 'call_action', 'action']) ??
        nested?['action'];
    if (rawAction == null) return null;

    final sessionId = _blankToNull(
      flat.get(['sessionId', 'sessionid', 'session_id']) ??
          nested?['sessionid'] ??
          nested?['sessionId'],
    );
    if (sessionId == null) return null;

    final callTypeRaw =
        flat.get(['callType', 'calltype', 'call_type']) ?? nested?['type'];
    final callType = callTypeRaw?.trim().toLowerCase() == typeVideo
        ? typeVideo
        : typeAudio;

    final ringTimeout = int.tryParse(
      flat.get(['ringTimeout', 'ringtimeout', 'ring_timeout'])?.trim() ??
          nested?['ringTimeout']?.trim() ??
          '',
    );

    return CallPushPayload(
      action: CometChatCallAction.fromWire(rawAction),
      rawAction: rawAction.trim(),
      sessionId: sessionId,
      callType: callType,
      senderUid: _blankToNull(
        flat.get(['sender', 'senderUid', 'sender_uid']) ?? nestedSender?['uid'],
      ),
      senderName: _blankToNull(
        flat.get(['senderName', 'sendername', 'sender_name']) ??
            nestedSender?['name'] ??
            flat.get(['title']),
      ),
      senderAvatar: _blankToNull(
        flat.get(['senderAvatar', 'senderavatar', 'sender_avatar']) ??
            nestedSender?['avatar'],
      ),
      receiverUid: _blankToNull(
        flat.get(['receiver', 'receiverUid', 'receiver_uid']) ??
            nested?['receiver'],
      ),
      receiverType: _blankToNull(
        flat.get(['receiverType', 'receivertype', 'receiver_type']) ??
            nested?['receiverType'],
      ),
      conversationId: _blankToNull(
        flat.get(['conversationId', 'conversationid', 'conversation_id']) ??
            nested?['conversationId'],
      ),
      sentAtMs: _normaliseEpoch(
        flat.get(['sentAt', 'sentat', 'sent_at']) ?? nested?['sentAt'],
      ),
      initiatedAtMs: _normaliseEpoch(
        flat.get(['initiatedAt', 'initiatedat', 'initiated_at']) ??
            nested?['initiatedAt'],
      ),
      ringTimeoutMs:
          ringTimeout != null &&
              ringTimeout >= minRingTimeoutMs &&
              ringTimeout <= maxRingTimeoutMs
          ? ringTimeout
          : null,
      raw: {for (final MapEntry(:key, :value) in data.entries) key: ?value},
    );
  }

  /// An epoch in seconds or millis, as millis.
  static int? _normaliseEpoch(String? raw) {
    final value = int.tryParse(raw?.trim() ?? '');
    if (value == null || value <= 0) return null;
    return value < _secondsMillisThreshold ? value * 1000 : value;
  }

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// A JSON object as strings; nested objects stay JSON text.
  static Map<String, String>? _parseJsonObject(String? text) {
    final trimmed = text?.trim();
    if (trimmed == null || !trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return null;
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          key.toString(): value == null
              ? ''
              : (value is Map || value is List
                    ? jsonEncode(value)
                    : value.toString()),
      };
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'CallPushPayload($sessionId, $rawAction, $callType, '
      'from ${senderUid ?? '?'})';
}

/// Case-insensitive lookup through aliases, listed at each use.
class _Lookup {
  _Lookup(Map<String, String?> source) {
    for (final MapEntry(:key, :value) in source.entries) {
      if (value != null) _map[key.toLowerCase()] = value;
    }
  }

  final Map<String, String> _map = {};

  String? get(List<String> keys) {
    for (final key in keys) {
      final value = _map[key.toLowerCase()];
      if (value != null) return value;
    }
    return null;
  }
}
