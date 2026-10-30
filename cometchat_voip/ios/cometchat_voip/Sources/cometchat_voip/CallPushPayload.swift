import Foundation

/// The CometChat call push, parsed. Never throws and never traps: this runs on
/// a VoIP push, where a crash costs the app its VoIP delivery.
///
/// Two shapes are in the field and both have to work:
/// - **Flat keys**, from Push Notifications (enhanced): `type=call`,
///   `callAction`, `sessionId`, `callType`, `sender`, `senderName`,
///   `senderAvatar`, `receiver`, `receiverType`, `conversationId`, `sentAt`.
/// - **The legacy extension**, which wraps the whole message in a `message`
///   JSON string.
struct CallPushPayload: Equatable {

    enum Action: String, Equatable, CaseIterable {
        case initiated
        /// Answered, possibly on another of this user's devices: stop ringing, not missed.
        case ongoing
        case ended
        case unanswered
        /// The server's name for a ring that expired; v1 sends `unanswered`.
        case timedOut = "timed_out"
        case rejected
        case busy
        case cancelled
        case unknown

        /// Whether this ends the ringing on the callee's side.
        var isTerminal: Bool { self != .initiated && self != .unknown }

        static func from(_ raw: String?) -> Action {
            guard let value = raw?.trimmed.lowercased(), !value.isEmpty else { return .unknown }
            return Action(rawValue: value) ?? .unknown
        }

        /// The reason a ringing call ends with when this arrives for it. `ended`
        /// for a call still ringing is the caller's device saying it is over:
        /// not a missed call.
        var endReason: CallEndReason {
            switch self {
            case .cancelled: return .cancelled
            case .unanswered, .timedOut: return .timedOut
            case .ongoing: return .answeredElsewhere
            case .rejected, .busy, .ended: return .declined
            case .initiated, .unknown: return .remoteEnded
            }
        }
    }

    enum ParseResult: Equatable {
        case call(CallPushPayload)
        /// A push, but not a call to act on: a chat message, or malformed.
        case ignored(reason: String)
    }

    let action: Action
    /// The action as received, for logs and for actions this build does not know.
    let rawAction: String
    let sessionId: String
    let callType: String
    let senderUid: String?
    let senderName: String?
    let senderAvatar: String?
    let receiverUid: String?
    let receiverType: String?
    let conversationId: String?
    let sentAtMs: Int64?
    let initiatedAtMs: Int64?
    let ringTimeoutMs: Int64?

    /// What CallKit shows as the caller. Never empty.
    var displayName: String {
        senderName?.nonBlank ?? senderUid?.nonBlank ?? "Unknown caller"
    }

    var isVideo: Bool { callType == IncomingCall.typeVideo }

    /// `receivedAtMs` is the last fallback for the ring deadline;
    /// `defaultRingTimeoutMs`, the app's `defaultRingTimeout`, is the window for
    /// a push without its own `ringTimeout`.
    func toIncomingCall(
        receivedAtMs: Int64,
        defaultRingTimeoutMs: Int64 = RingConstants.defaultRingTimeoutMs
    ) -> IncomingCall {
        IncomingCall(
            sessionId: sessionId,
            callerUid: senderUid,
            callerName: displayName,
            callerAvatarUrl: senderAvatar,
            callType: callType,
            receiverType: receiverType ?? IncomingCall.receiverTypeUser,
            receiverUid: receiverUid,
            conversationId: conversationId,
            initiatedAtMs: initiatedAtMs ?? sentAtMs ?? receivedAtMs,
            ringTimeoutMs: ringTimeoutMs ?? defaultRingTimeoutMs
        )
    }

    /// `sentAt` arrives in seconds, and sometimes in millis. Anything below this
    /// is seconds; reading seconds as millis would drop every call as expired.
    private static let secondsMillisThreshold: Int64 = 100_000_000_000

    static func parse(_ data: [String: String?]) -> ParseResult {
        if data.isEmpty { return .ignored(reason: "empty payload") }
        let flat = Lookup(data)

        let nested = flat["message"].flatMap(parseJSONObject)
        let nestedSender = nested?["sender"].flatMap(parseJSONObject)

        let type = flat["type", "category"] ?? nested?["category"]
        let isCall = type?.trimmed.lowercased() == "call"
            || (type == nil && flat["callAction", "callaction", "call_action"] != nil)
        guard isCall else { return .ignored(reason: "not a call push (type=\(type ?? "?"))") }

        guard let rawAction = flat["callAction", "callaction", "call_action", "action"] ?? nested?["action"] else {
            return .ignored(reason: "call push without callAction")
        }
        guard let sessionId = (flat["sessionId", "sessionid", "session_id"]
                                ?? nested?["sessionid"]
                                ?? nested?["sessionId"])?.nonBlank else {
            return .ignored(reason: "call push without sessionId (action=\(rawAction))")
        }

        let callTypeRaw = flat["callType", "calltype", "call_type"] ?? nested?["type"]
        let callType = callTypeRaw?.trimmed.caseInsensitiveCompare(IncomingCall.typeVideo) == .orderedSame
            ? IncomingCall.typeVideo
            : IncomingCall.typeAudio

        let ringTimeoutMs = (flat["ringTimeout", "ringtimeout", "ring_timeout"] ?? nested?["ringTimeout"])
            .flatMap { Int64($0.trimmed) }
            .flatMap { $0 >= RingConstants.minRingTimeoutMs && $0 <= RingConstants.maxRingTimeoutMs ? $0 : nil }

        return .call(CallPushPayload(
            action: Action.from(rawAction),
            rawAction: rawAction.trimmed,
            sessionId: sessionId,
            callType: callType,
            senderUid: (flat["sender", "senderUid", "sender_uid"] ?? nestedSender?["uid"])?.nonBlank,
            senderName: (flat["senderName", "sendername", "sender_name"] ?? nestedSender?["name"] ?? flat["title"])?.nonBlank,
            senderAvatar: (flat["senderAvatar", "senderavatar", "sender_avatar"] ?? nestedSender?["avatar"])?.nonBlank,
            receiverUid: (flat["receiver", "receiverUid", "receiver_uid"] ?? nested?["receiver"])?.nonBlank,
            receiverType: (flat["receiverType", "receivertype", "receiver_type"] ?? nested?["receiverType"])?.nonBlank,
            conversationId: (flat["conversationId", "conversationid", "conversation_id"] ?? nested?["conversationId"])?.nonBlank,
            sentAtMs: normaliseEpoch(flat["sentAt", "sentat", "sent_at"] ?? nested?["sentAt"]),
            initiatedAtMs: normaliseEpoch(flat["initiatedAt", "initiatedat", "initiated_at"] ?? nested?["initiatedAt"]),
            ringTimeoutMs: ringTimeoutMs
        ))
    }

    /// Flattens a PushKit dictionary: `aps` is dropped, numbers become text,
    /// nested objects become JSON text, and a nested `data` object is merged in.
    static func parse(pushDictionary: [AnyHashable: Any]) -> ParseResult {
        var out: [String: String?] = [:]
        if let data = pushDictionary["data"] as? [AnyHashable: Any] {
            for (key, value) in data {
                guard let key = key as? String, key != "aps" else { continue }
                out[key] = string(from: value)
            }
        }
        for (key, value) in pushDictionary {
            guard let key = key as? String, key != "aps" else { continue }
            out[key] = string(from: value)
        }
        return parse(out)
    }

    private static func normaliseEpoch(_ raw: String?) -> Int64? {
        guard let value = raw.flatMap({ Int64($0.trimmed) }), value > 0 else { return nil }
        return value < secondsMillisThreshold ? value * 1000 : value
    }

    private static func string(from value: Any) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case is NSNull:
            return nil
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return String(describing: value)
        }
    }

    private static func parseJSONObject(_ text: String) -> [String: String]? {
        let trimmed = text.trimmed
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (key, value) in object {
            if let value = string(from: value) { out[key] = value }
        }
        return out
    }

    /// Case-insensitive lookup through aliases, listed at each use.
    private struct Lookup {
        private let map: [String: String]

        init(_ source: [String: String?]) {
            var map: [String: String] = [:]
            for (key, value) in source {
                if let value = value { map[key.lowercased()] = value }
            }
            self.map = map
        }

        subscript(keys: String...) -> String? {
            for key in keys {
                if let value = map[key.lowercased()] { return value }
            }
            return nil
        }
    }
}
