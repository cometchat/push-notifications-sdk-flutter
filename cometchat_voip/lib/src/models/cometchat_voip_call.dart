import 'package:cometchat_calls_sdk/cometchat_calls_sdk.dart' as calls;

import '../push/call_push_payload.dart';
import 'cometchat_voip_enums.dart';

/// A call ringing on this device.
///
/// Join it with the Calls SDK once it is answered:
///
/// ```dart
/// CometChatVoip.onCallAnswered.listen((call) {
///   CometChatCalls.joinSession(sessionId: call.sessionId, ...);
/// });
/// ```
class CometChatVoipCall {
  /// `callType` of an audio call.
  static const String typeAudio = CallPushPayload.typeAudio;

  /// `callType` of a video call.
  static const String typeVideo = CallPushPayload.typeVideo;

  /// `receiverType` of a one-to-one call.
  static const String receiverTypeUser = 'user';

  /// `receiverType` of a group call.
  static const String receiverTypeGroup = 'group';

  /// The session to join.
  final String sessionId;

  /// The caller's UID, when the push carried it.
  final String? callerUid;

  /// The caller's display name. Never empty: the UID stands in for a missing
  /// name, and "Unknown caller" for both.
  final String callerName;

  /// The caller's avatar URL, when the push carried it.
  final String? callerAvatarUrl;

  /// [typeAudio] or [typeVideo].
  final String callType;

  /// [receiverTypeUser] or [receiverTypeGroup].
  final String receiverType;

  /// The UID or GUID the call was placed to.
  final String? receiverUid;

  /// The conversation the call belongs to.
  final String? conversationId;

  /// When the caller started ringing. Falls back to when the push was sent,
  /// then to when it arrived, for a backend that does not report it.
  final DateTime initiatedAt;

  /// How long the call rings before it counts as missed.
  final Duration ringTimeout;

  /// How the call reached this device.
  final CometChatCallSource source;

  /// Every key of the push this call was built from that the model does not
  /// already name, so an app can read a field the backend added without
  /// waiting for this package.
  final Map<String, String> extras;

  /// Creates a [CometChatVoipCall].
  const CometChatVoipCall({
    required this.sessionId,
    required this.callerName,
    required this.callType,
    required this.receiverType,
    required this.initiatedAt,
    required this.ringTimeout,
    this.callerUid,
    this.callerAvatarUrl,
    this.receiverUid,
    this.conversationId,
    this.source = CometChatCallSource.push,
    this.extras = const {},
  });

  /// Keys the model names itself, and so leaves out of [extras].
  static const _knownKeys = {
    'type',
    'category',
    'callaction',
    'call_action',
    'action',
    'sessionid',
    'session_id',
    'calltype',
    'call_type',
    'sender',
    'senderuid',
    'sender_uid',
    'sendername',
    'sender_name',
    'title',
    'senderavatar',
    'sender_avatar',
    'receiver',
    'receiveruid',
    'receiver_uid',
    'receivertype',
    'receiver_type',
    'conversationid',
    'conversation_id',
    'sentat',
    'sent_at',
    'initiatedat',
    'initiated_at',
    'ringtimeout',
    'ring_timeout',
    'message',
    'source',
  };

  static Map<String, String> _extrasOf(Map<String, String>? payload) => {
    if (payload != null)
      for (final MapEntry(:key, :value) in payload.entries)
        if (!_knownKeys.contains(key.toLowerCase())) key: value,
  };

  /// Whether this is a video call.
  bool get isVideo => callType.toLowerCase() == typeVideo;

  /// Whether this is a one-to-one call rather than a group call.
  bool get isPeerCall => receiverType.toLowerCase() == receiverTypeUser;

  /// When the call stops ringing.
  DateTime get expiresAt => initiatedAt.add(ringTimeout);

  /// Up to two upper-case initials for an avatar: "Alice Demo" to "AD", "bob"
  /// to "B", and "?" for a name with nothing in it.
  String get initials {
    final parts = callerName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    final letters = parts
        .take(2)
        .map((part) => String.fromCharCode(part.runes.first).toUpperCase())
        .join();
    return letters.isEmpty ? '?' : letters;
  }

  /// Reads the call the Calls SDK reported to an `IncomingCallListener`.
  ///
  /// The ring window comes from the push payload the SDK carries back, since
  /// the SDK's own model does not model one.
  static CometChatVoipCall? fromInitiatedCall(
    calls.InitiatedCall call, {
    Duration defaultRingTimeout = const Duration(
      milliseconds: CallPushPayload.defaultRingTimeoutMs,
    ),
  }) {
    final sessionId = call.sessionId.trim();
    if (sessionId.isEmpty) return null;

    final payload = call.payload == null
        ? null
        : CallPushPayload.parse(call.payload!);

    final name = _nonEmpty(call.callerName) ?? _nonEmpty(call.sender);
    final initiatedAtMs = call.initiatedAt > 0
        ? call.initiatedAt
        : (payload?.initiatedAtMs ??
              payload?.sentAtMs ??
              DateTime.now().millisecondsSinceEpoch);

    return CometChatVoipCall(
      sessionId: sessionId,
      callerUid: _nonEmpty(call.sender),
      callerName: name ?? payload?.displayName ?? 'Unknown caller',
      callerAvatarUrl: _nonEmpty(call.callerAvatarUrl) ?? payload?.senderAvatar,
      callType: _nonEmpty(call.type) ?? payload?.callType ?? typeAudio,
      receiverType:
          _nonEmpty(call.receiverType) ??
          payload?.receiverType ??
          receiverTypeUser,
      receiverUid: _nonEmpty(call.receiver) ?? payload?.receiverUid,
      conversationId: _nonEmpty(call.conversationId) ?? payload?.conversationId,
      initiatedAt: DateTime.fromMillisecondsSinceEpoch(initiatedAtMs),
      ringTimeout: Duration(
        milliseconds:
            payload?.ringTimeoutMs ?? defaultRingTimeout.inMilliseconds,
      ),
      source: CometChatCallSource.fromWire(call.payload?['source']),
      extras: _extrasOf(call.payload),
    );
  }

  /// Reads the call a push announced, for a call the Calls SDK did not report
  /// back — a terminal push for a call that was never ringing here.
  static CometChatVoipCall fromPushPayload(
    CallPushPayload payload, {
    DateTime? receivedAt,
    Duration defaultRingTimeout = const Duration(
      milliseconds: CallPushPayload.defaultRingTimeoutMs,
    ),
  }) {
    final receivedAtMs = (receivedAt ?? DateTime.now()).millisecondsSinceEpoch;
    return CometChatVoipCall(
      sessionId: payload.sessionId,
      callerUid: payload.senderUid,
      callerName: payload.displayName,
      callerAvatarUrl: payload.senderAvatar,
      callType: payload.callType,
      receiverType: payload.receiverType ?? receiverTypeUser,
      receiverUid: payload.receiverUid,
      conversationId: payload.conversationId,
      initiatedAt: DateTime.fromMillisecondsSinceEpoch(
        payload.initiatedAtMs ?? payload.sentAtMs ?? receivedAtMs,
      ),
      ringTimeout: Duration(
        milliseconds:
            payload.ringTimeoutMs ?? defaultRingTimeout.inMilliseconds,
      ),
      source: CometChatCallSource.fromWire(payload.raw['source']),
      extras: _extrasOf(payload.raw),
    );
  }

  /// Reads the map the native side sends, in which every value is a string.
  ///
  /// Returns null when there is no session ID, since a call without one cannot
  /// be joined.
  static CometChatVoipCall? fromMap(
    Map<Object?, Object?> map, {
    Duration defaultRingTimeout = const Duration(
      milliseconds: CallPushPayload.defaultRingTimeoutMs,
    ),
  }) {
    String? read(String key) {
      final value = map[key]?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }

    final sessionId = read('sessionId');
    if (sessionId == null) return null;

    final initiatedAtMs = int.tryParse(read('initiatedAtMs') ?? '') ?? 0;
    final ringTimeoutMs =
        int.tryParse(read('ringTimeoutMs') ?? '') ??
        defaultRingTimeout.inMilliseconds;

    // Anything the native side sent that this version does not name.
    final extras = {
      for (final MapEntry(:key, :value) in map.entries)
        if (value != null && !_nativeKeys.contains(key.toString()))
          key.toString(): value.toString(),
    };

    return CometChatVoipCall(
      sessionId: sessionId,
      callerUid: read('callerUid'),
      callerName: read('callerName') ?? read('callerUid') ?? 'Unknown caller',
      callerAvatarUrl: read('callerAvatarUrl'),
      callType: read('callType') ?? typeAudio,
      receiverType: read('receiverType') ?? receiverTypeUser,
      receiverUid: read('receiverUid'),
      conversationId: read('conversationId'),
      initiatedAt: DateTime.fromMillisecondsSinceEpoch(initiatedAtMs),
      ringTimeout: Duration(milliseconds: ringTimeoutMs),
      source: CometChatCallSource.fromWire(read('source')),
      extras: extras,
    );
  }

  /// The inverse of [fromMap].
  Map<String, String> toMap() => {
    'sessionId': sessionId,
    'callerUid': ?callerUid,
    'callerName': callerName,
    'callerAvatarUrl': ?callerAvatarUrl,
    'callType': callType,
    'receiverType': receiverType,
    'receiverUid': ?receiverUid,
    'conversationId': ?conversationId,
    'initiatedAtMs': initiatedAt.millisecondsSinceEpoch.toString(),
    'ringTimeoutMs': ringTimeout.inMilliseconds.toString(),
    'source': source.wireName,
    ...extras,
  };

  /// The keys [toMap] writes itself, and so leaves out of [extras].
  static const _nativeKeys = {
    'sessionId',
    'callerUid',
    'callerName',
    'callerAvatarUrl',
    'callType',
    'receiverType',
    'receiverUid',
    'conversationId',
    'initiatedAtMs',
    'ringTimeoutMs',
    'source',
  };

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is CometChatVoipCall &&
      other.sessionId == sessionId &&
      other.callerUid == callerUid &&
      other.callerName == callerName &&
      other.callerAvatarUrl == callerAvatarUrl &&
      other.callType == callType &&
      other.receiverType == receiverType &&
      other.receiverUid == receiverUid &&
      other.conversationId == conversationId &&
      other.initiatedAt == initiatedAt &&
      other.ringTimeout == ringTimeout;

  @override
  int get hashCode => Object.hash(
    sessionId,
    callerUid,
    callerName,
    callerAvatarUrl,
    callType,
    receiverType,
    receiverUid,
    conversationId,
    initiatedAt,
    ringTimeout,
  );

  @override
  String toString() =>
      'CometChatVoipCall($sessionId from ${callerUid ?? '?'}, $callType, '
      '$receiverType)';
}
