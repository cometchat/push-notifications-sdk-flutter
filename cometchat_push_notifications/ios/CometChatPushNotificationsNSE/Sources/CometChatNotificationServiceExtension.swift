import Foundation
import UserNotifications
import CometChatSDK

/// The base class for a Notification Service Extension.
///
/// An extension runs in its own process with no Flutter engine, so none of this
/// can be written in Dart. Subclassing it is the whole integration:
///
/// ```swift
/// import CometChatPushNotificationsNSE
///
/// class NotificationService: CometChatNotificationServiceExtension {}
/// ```
///
/// What it does to every CometChat push before iOS shows it:
///
/// - marks the message delivered, which is the only way a receipt is sent while
///   the app is backgrounded or killed — Dart is not running then;
/// - attaches the sender's avatar, so the notification shows who it is from;
/// - groups the notification with the rest of its conversation;
/// - strips markdown, which a notification cannot render.
///
/// The push must set `mutable-content: 1` for iOS to run this at all. CometChat
/// sends it; a notification that arrives without it simply skips all of the
/// above and is shown as sent.
///
/// This file must stay extension-safe: no `UIApplication`.
open class CometChatNotificationServiceExtension: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    // MARK: - Customization

    /// The App Group shared with the main app, which the CometChat SDK uses to
    /// keep the extension's delivery receipts from duplicating the app's.
    ///
    /// Read from the extension's `Info.plist` key `CometChatExtensionGroupID`.
    /// Override to supply it in code instead.
    open var extensionGroupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "CometChatExtensionGroupID") as? String
    }

    /// Whether markdown is stripped from the body. Defaults to true.
    open var stripsMarkdown: Bool { true }

    /// Whether the sender's avatar is attached. Defaults to true.
    open var attachesAvatar: Bool { true }

    /// Whether notifications from one conversation are grouped together.
    /// Defaults to true.
    open var groupsByConversation: Bool { true }

    /// The last chance to change the notification before iOS shows it.
    ///
    /// Called after everything above. The default returns it unchanged.
    open func finalize(_ content: UNMutableNotificationContent) -> UNMutableNotificationContent {
        content
    }

    // MARK: - UNNotificationServiceExtension

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        if let groupID = extensionGroupID {
            CometChat.setExtensionGroupID(id: groupID)
        }

        CometChat.markAsDeliveredFromNotification(payload: content.userInfo)

        if stripsMarkdown {
            content.body = MarkdownStripper.strip(content.body)
        }
        if groupsByConversation, let conversation = conversationIdentifier(in: content.userInfo) {
            content.threadIdentifier = conversation
        }

        guard attachesAvatar,
              let urlString = content.userInfo["senderAvatar"] as? String,
              let url = URL(string: urlString) else {
            deliver(content)
            return
        }
        attachAvatar(from: url, to: content) { [weak self] in self?.deliver(content) }
    }

    /// Called when the extension's time is nearly up.
    ///
    /// iOS gives roughly 30 seconds, and a notification that misses the deadline
    /// is shown unmodified — so whatever has been done so far is delivered here
    /// rather than losing it.
    open override func serviceExtensionTimeWillExpire() {
        guard let contentHandler, let content = bestAttemptContent else { return }
        contentHandler(finalize(content))
    }

    // MARK: - Internals

    private func deliver(_ content: UNMutableNotificationContent) {
        contentHandler?(finalize(content))
        contentHandler = nil
    }

    /// The conversation a payload belongs to: the sender for a 1:1 chat, the
    /// group for a group chat.
    private func conversationIdentifier(in userInfo: [AnyHashable: Any]) -> String? {
        let receiverType = userInfo["receiverType"] as? String
        if receiverType == "group" {
            return userInfo["receiver"] as? String
        }
        return userInfo["sender"] as? String
    }

    /// Downloads the avatar and attaches it. Best-effort: `completion` always
    /// runs, so a slow or missing avatar never costs the notification.
    private func attachAvatar(
        from url: URL,
        to content: UNMutableNotificationContent,
        completion: @escaping () -> Void
    ) {
        URLSession.shared.downloadTask(with: url) { localURL, _, error in
            defer { completion() }
            guard let localURL, error == nil else { return }

            do {
                let fileManager = FileManager.default
                var name = url.lastPathComponent
                if name.isEmpty { name = "avatar.png" }
                // An attachment without a recognizable extension is rejected.
                if (name as NSString).pathExtension.isEmpty { name += ".png" }

                let destination = fileManager.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString)-\(name)")
                try fileManager.moveItem(at: localURL, to: destination)

                content.attachments = [
                    try UNNotificationAttachment(
                        identifier: "cometchat-avatar",
                        url: destination,
                        options: nil
                    )
                ]
            } catch {
                // The notification is still worth showing without it.
            }
        }.resume()
    }
}
