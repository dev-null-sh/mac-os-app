import AppKit
import SwiftUI

// MARK: - Images

/// Avatars and message images, cached in memory so lists scroll without flashing. Never on disk: message images are
/// private, and the About window promises that nothing but preferences is saved on this Mac.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 0)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        #if DEBUG
            if Preview.isEnabled { configuration.protocolClasses = [PreviewServer.self] }
        #endif
        return URLSession(configuration: configuration)
    }()

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Shows an image the app already has under a URL, like a picked image under the URL of the message it became.
    func seed(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) {
            return image
        }

        guard let (data, _) = try? await session.data(from: url), let image = NSImage(data: data) else {
            return nil
        }

        cache.setObject(image, forKey: url as NSURL)

        return image
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? url.flatMap({ ImageLoader.shared.cached($0) }) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            image = await ImageLoader.shared.load(url)
        }
    }
}

/// A person's picture, or their initials on a disc in their lane color while it loads or when they have none, as the
/// web's link previews draw it. The disc uses the saturated light-mode lane in both appearances so white initials read.
struct Avatar: View {
    let user: User?
    var size: CGFloat = 36

    var body: some View {
        RemoteImage(url: user?.avatarURL) {
            ZStack {
                Circle().fill(LaneColor.disc(user).gradient)
                Text(initials)
                    .font(.system(size: size * (initials.count > 1 ? 0.36 : 0.42), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(DS.Colors.ink.opacity(0.06)))
        .accessibilityHidden(true)
    }

    /// Two initials, or one on small discs (reaction chips, receipts) where two can't be read.
    private var initials: String {
        let words = (user?.displayName ?? "?").split(separator: " ").prefix(size < 24 ? 1 : 2)

        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// An org's picture: up to two members' avatars overlapping, like group chats show it.
struct OrgAvatar: View {
    let members: [User]
    var size: CGFloat = 36

    var body: some View {
        let shown = Array(members.prefix(2))

        ZStack {
            if shown.count < 2 {
                ZStack {
                    Circle().fill(DS.Colors.primarySoft)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: size * 0.34))
                        .foregroundStyle(DS.Colors.primary)
                }
                .frame(width: size, height: size)
            } else {
                // The back avatar gets a transparent bite where the front one sits, so the gap reads on any row
                // background, selected or not.
                Avatar(user: shown[1], size: size * 0.7)
                    .mask {
                        Rectangle()
                            .overlay {
                                Circle()
                                    .frame(width: size * 0.7 + 4, height: size * 0.7 + 4)
                                    .offset(x: -size * 0.3, y: size * 0.3)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                    .offset(x: size * 0.15, y: -size * 0.15)
                Avatar(user: shown[0], size: size * 0.7)
                    .offset(x: -size * 0.15, y: size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Colors

/// The lane colors the web draws people in, for names in orgs and avatars without a picture.
enum LaneColor {
    static func of(_ user: User?) -> Color {
        of(lane: user?.lane)
    }

    /// A lane's color, or the primary blue for none, as an organization without a chosen color shows.
    static func of(lane: Lane?) -> Color {
        switch lane {
        case let .custom(hex):
            return Color(nsColor: NSColor(hex: Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x3B6FE0))
        case let .palette(index):
            return DS.Colors.lane(index)
        case nil:
            return DS.Colors.primary
        }
    }

    /// The lane as a fill under white text: the light lane in both appearances, since the dark lifts are too pale.
    static func disc(_ user: User?) -> Color {
        guard case let .palette(index) = user?.lane else { return of(user) }

        return Color(nsColor: NSColor(hex: DS.Colors.lanesLight[((index % 6) + 6) % 6]))
    }
}

/// The chat surfaces' colors, kept under their original names for the chat views; each is a design-system token.
enum Palette {
    /// The bubble of the user's own messages, in /dev/null's primary blue.
    static let outgoing = DS.Colors.bubbleOutgoing
    static let incoming = DS.Colors.bubbleIncoming
    static let chatBackground = DS.Colors.chat
    /// The composer's bar and the suggestions above it.
    static let composer = DS.Colors.surface
    /// Day headers, org events and hover actions: a pill that reads on the chat background in both appearances.
    static let servicePill = DS.Colors.servicePill
}

// MARK: - Formatting

enum Formatting {
    static func inboxTime(_ date: Date?) -> String {
        guard let date else { return "" }

        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }

        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }

        return date.formatted(date: .numeric, time: .omitted)
    }

    static func daySeparator(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }

        return date.formatted(date: .long, time: .omitted)
    }

    /// When a message was pulled: the time today, "yesterday 14:32", or the date.
    static func pulledTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)

        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "yesterday \(time)" }

        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }

    /// A recording's length with tenths, as Telegram counts while recording.
    static func preciseDuration(_ seconds: TimeInterval) -> String {
        let tenths = Int(seconds * 10)

        return String(format: "%d:%02d,%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())

        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
