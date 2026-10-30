import 'dart:convert';

import '../errors/cometchat_notification_exception.dart';
import '../models/cometchat_enums.dart';
import '../models/cometchat_notification_details.dart';
import '../models/cometchat_push_payload.dart';

/// Parses raw CometChat push payloads into typed models.
///
/// Expected input structure (after decoding):
/// ```json
/// {
///   "trigger": "push-notification-payload-generated",
///   "data": {
///     "to": { "uid": "..." },
///     "notificationDetails": { ... }
///   }
/// }
/// ```
///
/// Firebase delivers `RemoteMessage.data` as `Map<String, String>`, so
/// nested objects arrive as JSON-encoded strings. This parser handles
/// both pre-decoded maps and string-encoded JSON values.
class CometChatPayloadParser {
  CometChatPayloadParser._();

  /// Parses a raw payload map into [CometChatPushPayload].
  ///
  /// Handles two payload formats:
  /// 1. **Nested format** (from CometChat webhook/test tools):
  ///    `{ "data": { "to": {...}, "notificationDetails": {...} } }`
  /// 2. **Flat format** (from Firebase `RemoteMessage.data`):
  ///    `{ "sender": "...", "receiver": "...", "title": "...", ... }`
  ///
  /// Throws [CometChatNotificationException] with
  /// [CometChatErrorCode.invalidPayload] if the payload cannot be parsed.
  static CometChatPushPayload parse(Map<String, dynamic> payload) {
    // Try nested format first: payload contains a "data" key with sub-objects.
    final rawData = payload['data'];
    Map<String, dynamic>? data;
    if (rawData is Map<String, dynamic>) {
      data = rawData;
    } else if (rawData is String) {
      try {
        data = json.decode(rawData) as Map<String, dynamic>?;
      } catch (_) {
        data = null;
      }
    }

    // If nested "data" exists with "notificationDetails", use nested format.
    if (data != null &&
        (data.containsKey('notificationDetails') || data.containsKey('to'))) {
      return _parseNested(data, payload);
    }

    // Otherwise treat the payload itself as flat notification details.
    return _parseFlat(payload);
  }

  /// Parses the nested format where `data` contains `to` and
  /// `notificationDetails`.
  static CometChatPushPayload _parseNested(
    Map<String, dynamic> data,
    Map<String, dynamic> rawPayload,
  ) {
    final toMap = _asMap(data['to']);
    final toUid = toMap?['uid'] as String? ?? '';

    final details = _asMap(data['notificationDetails']);
    if (details == null) {
      throw const CometChatNotificationException(
        code: CometChatErrorCode.invalidPayload,
        message: 'Missing "notificationDetails" in payload.',
      );
    }

    final notificationDetails = _buildDetails(details);

    return CometChatPushPayload(
      toUid: toUid,
      notificationDetails: notificationDetails,
      rawPayload: rawPayload,
    );
  }

  /// Parses the flat format where the payload itself contains notification
  /// fields directly (e.g., from Firebase `RemoteMessage.data`).
  static CometChatPushPayload _parseFlat(Map<String, dynamic> payload) {
    // Validate that it looks like a CometChat payload.
    if (!payload.containsKey('type') && !payload.containsKey('sender')) {
      throw const CometChatNotificationException(
        code: CometChatErrorCode.invalidPayload,
        message: 'Missing "data" field in payload.',
      );
    }

    final notificationDetails = _buildDetails(payload);

    return CometChatPushPayload(
      toUid: payload['receiver'] as String? ?? '',
      notificationDetails: notificationDetails,
      rawPayload: payload,
    );
  }

  /// Builds [CometChatNotificationDetails] from a details map.
  static CometChatNotificationDetails _buildDetails(
    Map<String, dynamic> details,
  ) {
    return CometChatNotificationDetails(
      title: details['title'] as String? ?? '',
      body: details['body'] as String? ?? '',
      sender: details['sender'] as String? ?? '',
      senderName: details['senderName'] as String? ?? '',
      senderAvatar: details['senderAvatar'] as String?,
      receiver: details['receiver'] as String? ?? '',
      receiverName: details['receiverName'] as String? ?? '',
      receiverAvatar: details['receiverAvatar'] as String?,
      receiverType: CometChatPushReceiverType.fromString(
        details['receiverType'] as String?,
      ),
      tag: details['tag'] as String? ?? '',
      conversationId: details['conversationId'] as String? ?? '',
      type: CometChatPayloadType.fromString(details['type'] as String?),
      sentAt: details['sentAt'] as String? ?? '',
      message: _asMap(details['message']),
      custom: _asMap(details['custom']),
    );
  }

  /// Safely converts a value to a Map, decoding from JSON string if needed.
  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    if (value is String) {
      try {
        final decoded = json.decode(value);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
