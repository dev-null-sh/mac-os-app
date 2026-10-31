import AppKit
import SwiftUI

/// Turns a commit's body segments into what a row shows: prose with links, mentions and GitHub references, inline
/// code on `wash`, and fenced code blocks, as the web renders them.
enum CommitText {
    enum Block: Hashable {
        case text(AttributedString)
        case code(language: String?, code: String)
    }

    /// Bodies longer than this, or than `foldLines` lines, fold behind "Show more".
    static let foldLength = 280
    static let foldLines = 8

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let mention = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))")
    private static let reference = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_/])([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100})#([0-9]{1,7})\\b")

    @MainActor private static var cache: [String: [Block]] = [:]

    @MainActor static func blocks(_ commit: Commit, size: CGFloat, folded: Bool) -> [Block] {
        let segments = (folded ? commit.previewSegments : nil) ?? commit.bodySegments ?? [BodySegment(type: "text", text: commit.body ?? "", code: nil, language: nil, html: nil)]
        let key = "\(commit.id):\(size):\(folded):\(segments.hashValue)"

        if let cached = cache[key] { return cached }

        let blocks = format(segments, size: size)
        cache[key] = blocks

        return blocks
    }

    /// Whether a body is long enough to fold, never cutting through a code block: the server's preview segments
    /// already stop before one.
    static func isFoldable(_ commit: Commit) -> Bool {
        let text = commit.body ?? ""

        return commit.previewSegments != nil && (text.count > foldLength || text.split(separator: "\n", omittingEmptySubsequences: false).count > foldLines)
    }

    private static func format(_ segments: [BodySegment], size: CGFloat) -> [Block] {
        var blocks: [Block] = []
        var line = AttributedString()

        func flush() {
            while line.characters.last == "\n" { line.removeSubrange(line.index(beforeCharacter: line.endIndex) ..< line.endIndex) }
            while line.characters.first == "\n" { line.removeSubrange(line.startIndex ..< line.index(afterCharacter: line.startIndex)) }

            if !line.characters.isEmpty { blocks.append(.text(line)) }

            line = AttributedString()
        }

        for segment in segments {
            switch segment.type {
            case "block":
                flush()
                blocks.append(.code(language: segment.filename ?? segment.language, code: MessageText.plain(fromHTML: segment.html ?? segment.code ?? "")))
            case "code":
                var code = AttributedString(segment.code ?? "")
                code.font = .system(size: size - 1, design: .monospaced)
                code.backgroundColor = DS.Colors.wash
                line += code
            default:
                line += prose(segment.text ?? "", size: size)
            }
        }

        flush()

        return blocks
    }

    /// Prose with URLs, `@handle` mentions and `owner/repo#123` references made into links. A bio passes the handles
    /// on /dev/null it mentions, lowercased, and every other mention goes to GitHub, as the web's bios link them.
    static func prose(_ text: String, size: CGFloat, profiles: [String: String]? = nil) -> AttributedString {
        let text = MessageText.emojify(text)
        var result = AttributedString(text)
        let range = NSRange(text.startIndex..., in: text)

        func link(_ nsRange: NSRange, to url: URL, font: Font? = nil) {
            guard let swiftRange = Range(nsRange, in: text), let attributed = Range(swiftRange, in: result) else { return }

            result[attributed].link = url
            result[attributed].foregroundColor = DS.Colors.primary
            if let font { result[attributed].font = font }
        }

        for match in detector?.matches(in: text, range: range) ?? [] {
            if let url = match.url { link(match.range, to: url) }
        }

        for match in reference?.matches(in: text, range: range) ?? [] {
            guard let whole = Range(match.range, in: text) else { continue }

            let parts = text[whole].split(separator: "#")
            if let url = URL(string: "https://github.com/\(parts[0])/issues/\(parts[1])") {
                link(match.range, to: url, font: .system(size: size - 1, design: .monospaced))
            }
        }

        for match in mention?.matches(in: text, range: range) ?? [] {
            guard let handle = Range(match.range(at: 1), in: text) else { continue }

            let mentioned = String(text[handle])

            if let profiles, profiles[mentioned.lowercased()] == nil {
                link(match.range, to: URL(string: "https://github.com/\(mentioned)")!)
            } else {
                link(match.range, to: WorkspaceLink.profile(profiles?[mentioned.lowercased()] ?? mentioned))
            }
        }

        return result
    }
}

/// The app's own links inside commit text, which open in the workspace instead of the browser.
enum WorkspaceLink {
    static let scheme = "devnull-workspace"

    static func profile(_ handle: String) -> URL {
        URL(string: "\(scheme)://profile/\(handle)")!
    }

    static func commit(_ id: String) -> URL {
        URL(string: "\(scheme)://commit/\(id)")!
    }

    /// A /dev/null address the app can show itself: a commit's permalink, as one shared in a remote, or a profile.
    static func inApp(_ url: URL) -> URL? {
        guard url.scheme == "https", url.host() == APIClient.baseURL.host() else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }

        guard let handle = parts.first, handle.hasPrefix("@"), handle.count > 1 else { return nil }

        switch parts.count {
        case 1: return profile(String(handle.dropFirst()))
        case 3 where parts[1] == "commits" && UUID(uuidString: parts[2]) != nil: return commit(parts[2])
        default: return nil
        }
    }

    /// Opens a workspace link in the frontmost window's navigation, and leaves every other URL to the browser.
    @MainActor static func handle(_ url: URL, navigation: Navigation, openProfile: (String) -> Void) -> OpenURLAction.Result {
        let url = inApp(url) ?? url

        guard url.scheme == scheme, let host = url.host() else { return .systemAction }

        let value = url.lastPathComponent

        switch host {
        case "profile": openProfile(value)
        case "commit": navigation.push(.commit(value))
        default: return .discarded
        }

        return .handled
    }
}

/// A commit's text: prose, inline code and fenced code blocks, selectable, folded behind "Show more" when long.
struct CommitBodyView: View {
    let commit: Commit
    var size: CGFloat = 14
    var foldable = true
    var lineLimit: Int?

    @State private var isExpanded = false

    var body: some View {
        let folded = foldable && !isExpanded && CommitText.isFoldable(commit)

        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            ForEach(Array(CommitText.blocks(commit, size: size, folded: folded).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(text):
                    Text(text)
                        .font(.system(size: size))
                        .lineSpacing(DS.Fonts.commitLineSpacing)
                        .foregroundStyle(DS.Colors.ink)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: DS.Metrics.readingMeasure, alignment: .leading)
                case let .code(language, code):
                    CodeBlock(language: language, code: code)
                }
            }

            if folded {
                Button("Show more") { isExpanded = true }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .textSelection(.enabled)
    }
}

/// A fenced code block: mono on `wash` under its filename or language, scrolling sideways, with a copy button on hover
/// that copies the whole block.
struct CodeBlock: View {
    let language: String?
    let code: String

    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(language)
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 36))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(DS.Fonts.code)
                    .foregroundStyle(DS.Colors.ink)
                    .fixedSize()
                    .padding(EdgeInsets(top: language == nil ? 10 : 6, leading: 12, bottom: 10, trailing: 12))
            }
        }
        .frame(maxWidth: DS.Metrics.readingMeasure, alignment: .leading)
        .background(DS.Colors.wash, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(IconButtonStyle())
                .help("Copy code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
                .padding(4)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
    }
}
