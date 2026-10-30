import Foundation

/// Turns the markdown a message may contain into the plain text a notification
/// should show.
///
/// A notification renders no formatting, so `**shipped**` would otherwise reach
/// the user with the asterisks intact. Foundation only, because this runs inside
/// an app extension.
enum MarkdownStripper {

    /// Every pattern, in the order it must run: multi-character markers before
    /// the single-character ones they contain, or `**bold**` loses one asterisk
    /// to the italic rule and keeps the other.
    private static let patterns: [(pattern: String, options: String.CompareOptions)] = [
        (#"\*{3}(.+?)\*{3}"#, .regularExpression),      // ***bold italic***
        (#"_{3}(.+?)_{3}"#, .regularExpression),
        (#"\*{2}(.+?)\*{2}"#, .regularExpression),      // **bold**
        (#"_{2}(.+?)_{2}"#, .regularExpression),
        (#"\*(.+?)\*"#, .regularExpression),            // *italic*
        (#"\b_(.+?)_\b"#, .regularExpression),
        (#"~~(.+?)~~"#, .regularExpression),            // ~~strikethrough~~
        (#"`(.+?)`"#, .regularExpression),              // `code`
        (#"!\[([^\]]*)\]\([^\)]+\)"#, .regularExpression), // ![alt](url)
        (#"\[([^\]]+)\]\([^\)]+\)"#, .regularExpression),  // [text](url)
        (#"<u>(.+?)</u>"#, [.regularExpression, .caseInsensitive])
    ]

    /// [text] with its markdown markers removed.
    static func strip(_ text: String) -> String {
        var result = text
        for (pattern, options) in patterns {
            result = result.replacingOccurrences(of: pattern, with: "$1", options: options)
        }
        // Line-leading markers, which have nothing to keep.
        result = result.replacingOccurrences(
            of: #"(?m)^>\s?"#, with: "", options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
