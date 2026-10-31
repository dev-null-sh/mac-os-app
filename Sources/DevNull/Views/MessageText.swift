import AppKit
import SwiftUI

/// Turns message bodies into what the thread shows: prose with links, mentions and emoji shortcodes, inline code,
/// quote blocks, and code blocks, like the web renders them.
enum MessageText {
    enum Block: Hashable {
        case text(AttributedString)
        case quote(AttributedString)
        case code(language: String?, code: String)
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let shortcodes: [String: String] = Dictionary(Reactions.all.map { ($0.name, $0.emoji) }, uniquingKeysWith: { first, _ in first })

    @MainActor private static var cache: [String: [Block]] = [:]

    /// Formatting runs once per message: rows redraw often while scrolling and polling, and link detection isn't cheap.
    @MainActor static func blocks(_ message: Message, mentioned: Set<String>, outgoing: Bool) -> [Block] {
        let key = "\(message.id):\(outgoing):\(mentioned.sorted())"

        if let cached = cache[key] {
            return cached
        }

        let blocks = format(message, mentioned: mentioned, outgoing: outgoing)
        cache[key] = blocks

        return blocks
    }

    private static func format(_ message: Message, mentioned: Set<String>, outgoing: Bool) -> [Block] {
        let segments = message.bodySegments ?? (message.body.map { [BodySegment(type: "text", text: $0, code: nil, language: nil, html: nil)] } ?? [])

        var blocks: [Block] = []
        var line = AttributedString()
        var quoting = false

        func flush() {
            guard !line.characters.isEmpty else { return }

            // Trim the newlines a block boundary leaves on either side, which would show as empty lines.
            while line.characters.last == "\n" {
                line.removeSubrange(line.index(beforeCharacter: line.endIndex) ..< line.endIndex)
            }

            while line.characters.first == "\n" {
                line.removeSubrange(line.startIndex ..< line.index(afterCharacter: line.startIndex))
            }

            if !line.characters.isEmpty {
                blocks.append(quoting ? .quote(line) : .text(line))
            }

            line = AttributedString()
        }

        for segment in segments {
            switch segment.type {
            case "block":
                flush()
                blocks.append(.code(language: segment.filename ?? segment.language, code: plain(fromHTML: segment.html ?? "")))
            case "code":
                var code = AttributedString(segment.code ?? "")
                code.font = .system(size: 13, design: .monospaced)
                code.backgroundColor = outgoing ? Color.white.opacity(0.18) : DS.Colors.bubbleInset
                line += code
            default:
                // A quote is a run of lines starting with ">", so prose is split by line to find where they start and end.
                let text = segment.text ?? ""
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

                for (index, raw) in lines.enumerated() {
                    let isQuote = raw.hasPrefix(">")
                    let atLineStart = line.characters.isEmpty || line.characters.last == "\n"

                    if atLineStart, isQuote != quoting, !(raw.isEmpty && index == lines.count - 1) {
                        flush()
                        quoting = isQuote
                    }

                    let content = isQuote && atLineStart ? String(raw.dropFirst()).trimmingPrefix(" ") : Substring(raw)
                    line += prose(String(content), mentioned: mentioned, outgoing: outgoing)

                    if index < lines.count - 1 {
                        line += AttributedString("\n")
                    }
                }
            }
        }

        flush()

        return blocks
    }

    /// Prose with its links and mentions clickable and its :shortcodes: as emoji.
    static func prose(_ text: String, mentioned: Set<String>, outgoing: Bool) -> AttributedString {
        let text = emojify(text)
        var result = AttributedString(text)
        let range = NSRange(text.startIndex..., in: text)
        let linkColor: Color = outgoing ? .white : DS.Colors.primary

        for match in detector?.matches(in: text, range: range) ?? [] {
            guard let url = match.url, let swiftRange = Range(match.range, in: text), let attributed = Range(swiftRange, in: result) else { continue }

            result[attributed].link = url
            result[attributed].foregroundColor = linkColor
            result[attributed].underlineStyle = outgoing ? .single : nil
        }

        if !mentioned.isEmpty, let regex = try? NSRegularExpression(pattern: "@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))") {
            for match in regex.matches(in: text, range: range) {
                guard let handleRange = Range(match.range(at: 1), in: text),
                      mentioned.contains(text[handleRange].lowercased()),
                      let swiftRange = Range(match.range, in: text),
                      let attributed = Range(swiftRange, in: result)
                else { continue }

                result[attributed].link = APIClient.baseURL.appending(path: "@" + text[handleRange])
                result[attributed].foregroundColor = linkColor
                result[attributed].font = .system(size: 14, weight: .semibold)
            }
        }

        return result
    }

    static func emojify(_ text: String) -> String {
        guard text.contains(":"), let regex = try? NSRegularExpression(pattern: ":([a-z0-9_+-]+):") else { return text }

        var result = text

        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let emoji = shortcodes[String(text[nameRange])],
                  let whole = Range(match.range, in: result)
            else { continue }

            result.replaceSubrange(whole, with: emoji)
        }

        return result
    }

    /// Whether a text is nothing but emoji, which shows big without a bubble.
    static func isOnlyEmoji(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || character.unicodeScalars.count > 1 && character.unicodeScalars.first?.properties.isEmoji == true
        }
    }

    /// The code of a highlighted block, without the highlighter's markup.
    static func plain(fromHTML html: String) -> String {
        let stripped = html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#039;": "'", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]

        var decoded = entities.reduce(stripped) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        decoded = decoded.replacingOccurrences(of: "&amp;", with: "&")

        return decoded.trimmingCharacters(in: .newlines)
    }

    /// One line for the inbox and reply ghosts.
    static func preview(_ message: Message, members: [User], me: String?) -> String {
        if message.isEvent {
            return eventText(message, me: me, partner: members.first { $0.id == message.userId })
        }

        if let voice = message.voice {
            return "🎤 Voice note (\(Formatting.duration(Double(voice.durationMs) / 1000)))"
        }

        let body = emojify((message.body ?? "").replacingOccurrences(of: "\n", with: " "))
        let images = message.images?.count ?? 0

        if images > 0 {
            let label = images == 1 ? "📷 Photo" : "📷 \(images) photos"
            return body.isEmpty ? label : "\(label) · \(body)"
        }

        return body
    }

    /// What a logged org change or ping says, from the reader's point of view, worded as the web words it.
    static func eventText(_ message: Message, me: String?, partner: User? = nil) -> String {
        func handle(_ user: User?) -> String {
            guard let user else { return "someone" }
            return user.id == me ? "you" : "@" + user.handle
        }

        let actor = message.userId == me && me != nil ? "you" : handle(message.user ?? partner)
        let subject = handle(message.subject)
        let body = message.body ?? ""
        let text: String

        switch message.event {
        case "created": text = body.isEmpty ? "\(actor) created the org" : "\(actor) created \(body)"
        case "added": text = "\(actor) added \(subject)"
        case "removed": text = "\(actor) removed \(subject)"
        case "left": text = "\(actor) left"
        case "renamed": text = body.isEmpty ? "\(actor) cleared the org's name" : "\(actor) renamed the org to \(body)"
        case "promoted": text = "\(actor) made \(subject) a maintainer"
        case "demoted": text = "\(actor) made \(subject) a contributor"
        case "inherited": text = "\(actor) inherited maintainer"
        case "call_started": text = "\(actor) started a call"
        case "call_answered": text = "\(actor) answered the call"
        case "call_cancelled": text = "\(actor) cancelled the call"
        case "call_declined": text = "\(actor) declined the call"
        case "call_failed": text = "\(actor) couldn't answer the call"
        case "call_missed": text = message.userId == me ? "your call wasn't answered" : "missed call from \(actor)"
        // Direct threads leave the author out: there, it can only be the partner.
        case "ping": text = message.userId == me ? "you sent a ping" : message.user == nil ? "you got a ping" : "\(actor) sent a ping"
        default: text = body
        }

        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
