import Foundation

/// A CometChat push payload, as it arrives in a notification's `userInfo`.
///
/// The APNs payload is flat: the server puts `sender`, `receiverType` and the
/// rest at the top level alongside `aps`. Everything here is read defensively —
/// a payload from a newer server, or one that is not CometChat's at all, must
/// not crash the notification path.
struct CometChatPayload {

    let type: String
    let sender: String
    let senderName: String
    let senderAvatar: String?
    let receiver: String
    let receiverType: String
    let messageId: String
    let unreadCount: Int?

    /// Whether this is a chat message, as opposed to a call or a campaign push.
    var isChat: Bool { type == "chat" }

    /// What identifies the conversation: the other person for a 1:1 chat, the
    /// group for a group chat.
    var conversationId: String {
        (receiverType == "group" ? receiver : sender)
    }

    /// Reads a payload out of `userInfo`, or nil if it is not one of ours.
    init?(userInfo: [AnyHashable: Any]) {
        func string(_ key: String) -> String? {
            if let value = userInfo[key] as? String { return value }
            if let value = userInfo[key] as? NSNumber { return value.stringValue }
            return nil
        }

        // A CometChat payload always names a sender. Without one there is no
        // conversation to attribute the notification to, so it is not ours.
        guard let sender = string("sender") else { return nil }

        self.sender = sender
        self.type = string("type") ?? ""
        self.senderName = string("senderName") ?? sender
        self.senderAvatar = string("senderAvatar")
        self.receiver = string("receiver") ?? ""
        self.receiverType = string("receiverType") ?? "user"
        self.messageId = string("tag") ?? string("messageId") ?? ""

        if let count = userInfo["unreadMessageCount"] as? Int {
            self.unreadCount = count
        } else if let count = userInfo["unreadMessageCount"] as? NSNumber {
            self.unreadCount = count.intValue
        } else {
            self.unreadCount = nil
        }
    }

    /// The event map sent to Dart when the notification is tapped.
    func responseMap() -> [String: Any?] {
        [
            "conversationId": conversationId,
            "receiverType": receiverType,
            "sender": sender,
            "senderName": senderName,
            "senderAvatar": senderAvatar,
            "messageId": messageId
        ]
    }
}
