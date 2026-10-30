import Foundation

/// A call announced to this device by a VoIP push.
///
/// `toMap` and `fromMap` are the persistence contract: a flat `[String:
/// String]` survives `UserDefaults` unchanged, so a call written by the process
/// PushKit woke is readable by the one relaunched to answer it. Dart reads the
/// same map.
struct IncomingCall: Equatable {

    static let typeAudio = "audio"
    static let typeVideo = "video"
    static let receiverTypeUser = "user"
    static let receiverTypeGroup = "group"

    let sessionId: String
    let callerUid: String?
    let callerName: String
    let callerAvatarUrl: String?
    /// `typeAudio` or `typeVideo`.
    let callType: String
    /// `receiverTypeUser` or `receiverTypeGroup`.
    let receiverType: String
    let receiverUid: String?
    let conversationId: String?
    /// When the caller started ringing. Falls back to when the push was sent,
    /// then to when it arrived.
    let initiatedAtMs: Int64
    let ringTimeoutMs: Int64

    /// The instant this call stops being ringable.
    var expiresAtMs: Int64 { initiatedAtMs + ringTimeoutMs }

    /// A one-to-one call, which the Calls SDK ends for both sides when one leaves.
    var isPeerCall: Bool { receiverType.caseInsensitiveCompare(IncomingCall.receiverTypeUser) == .orderedSame }

    var isVideo: Bool { callType.caseInsensitiveCompare(IncomingCall.typeVideo) == .orderedSame }

    func toMap() -> [String: String] {
        var map: [String: String] = [
            "sessionId": sessionId,
            "callerName": callerName,
            "callType": callType,
            "receiverType": receiverType,
            "initiatedAtMs": String(initiatedAtMs),
            "ringTimeoutMs": String(ringTimeoutMs),
        ]
        if let callerUid = callerUid { map["callerUid"] = callerUid }
        if let callerAvatarUrl = callerAvatarUrl { map["callerAvatarUrl"] = callerAvatarUrl }
        if let receiverUid = receiverUid { map["receiverUid"] = receiverUid }
        if let conversationId = conversationId { map["conversationId"] = conversationId }
        return map
    }

    /// The inverse of `toMap`. Nil without a session id: nothing rings without one.
    static func fromMap(_ map: [String: String]) -> IncomingCall? {
        guard let sessionId = map["sessionId"]?.nonBlank else { return nil }
        return IncomingCall(
            sessionId: sessionId,
            callerUid: map["callerUid"]?.nonBlank,
            callerName: map["callerName"] ?? "",
            callerAvatarUrl: map["callerAvatarUrl"]?.nonBlank,
            callType: map["callType"]?.nonBlank ?? typeAudio,
            receiverType: map["receiverType"]?.nonBlank ?? receiverTypeUser,
            receiverUid: map["receiverUid"]?.nonBlank,
            conversationId: map["conversationId"]?.nonBlank,
            initiatedAtMs: map["initiatedAtMs"].flatMap { Int64($0) } ?? 0,
            ringTimeoutMs: map["ringTimeoutMs"].flatMap { Int64($0) } ?? RingConstants.defaultRingTimeoutMs
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The trimmed string, or nil when nothing is left: a blank push field is
    /// treated exactly like a missing one.
    var nonBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
