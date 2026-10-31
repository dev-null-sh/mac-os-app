import Foundation

/// A lane is a palette index, or the hex color someone picked.
enum Lane: Codable, Hashable {
    case palette(Int)
    case custom(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let index = try? container.decode(Int.self) {
            self = .palette(index)
        } else {
            self = .custom(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .palette(index): try container.encode(index)
        case let .custom(hex): try container.encode(hex)
        }
    }
}

struct User: Codable, Hashable, Identifiable {
    let id: String
    let handle: String
    let name: String?
    let avatarUrl: String?
    let bio: String?
    let htmlUrl: String?
    let lane: Lane?
    let isFollowed: Bool?
    let followsYou: Bool?
    /// The stream they're on until it runs out, so a list can mark who is live without asking for each profile.
    var live: LiveStream? = nil

    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return handle
        }

        return name
    }

    var avatarURL: URL? {
        avatarUrl.flatMap(URL.init(string:))
    }

    /// Tom and @world never sign in; replies from them carry a `bot` chip.
    var isBot: Bool {
        ["tom", "world", "devnull-world"].contains(handle.lowercased())
    }
}

/// A YouTube or Twitch stream someone said they're live on, until `endsAt`.
struct LiveStream: Codable, Hashable {
    let platform: String
    let url: String
    let thumbnailUrl: String?
    let endsAt: Date

    var isOn: Bool { endsAt > .now }
    var platformName: String { platform == "twitch" ? "Twitch" : "YouTube" }
}

struct RemotesSettings: Codable, Hashable {
    let from: String
    let pullReceipts: Bool
    let requests: Bool
    let everyone: Bool
    let unreadCount: Int
}

struct CurrentUser: Codable, Hashable {
    let id: String
    let handle: String
    let name: String?
    let avatarUrl: String?
    let htmlUrl: String?
    let lane: Lane?
    let remotes: RemotesSettings?
    var bio: String? = nil
    var company: String? = nil
    var location: String? = nil
    var website: String? = nil
    var createdAt: Date? = nil
    var commitsCount: Int? = nil
    var followersCount: Int? = nil
    var followingCount: Int? = nil
    var pasteisMode: Bool? = nil
    var pasteisRemaining: Int? = nil
    /// The lane or color the user picked, or nil for Automatic, and the lane Automatic gives them.
    var preferredLane: Lane? = nil
    var automaticLane: Int? = nil
    var githubSyncedAt: Date? = nil
    var live: LiveStream? = nil

    var asUser: User {
        User(id: id, handle: handle, name: name, avatarUrl: avatarUrl, bio: bio, htmlUrl: htmlUrl, lane: lane, isFollowed: nil, followsYou: nil, live: live)
    }
}

enum ConversationKind: String, Codable {
    case direct
    case org
}

enum OrgRole: String, Codable {
    case maintainer
    case contributor
}

enum PushAccess: String, Codable {
    case open
    case request
    case waiting
    case restricted
    case closed
}

enum InboxTab: String, CaseIterable, Identifiable {
    case open
    case fetched
    case stashed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .fetched: "Fetched"
        case .stashed: "Stashed"
        }
    }
}

enum MuteDuration: String, CaseIterable {
    case hour
    case tomorrow
    case week
    case forever
    case off

    var title: String {
        switch self {
        case .hour: "For One Hour"
        case .tomorrow: "Until Tomorrow"
        case .week: "For One Week"
        case .forever: "Forever"
        case .off: "Unmute"
        }
    }
}

struct Member: Codable, Hashable {
    let user: User
    let role: OrgRole?
    let readThroughId: Int?
}

struct Reaction: Codable, Hashable {
    let userId: String
    let emoji: String
}

/// A message body split into prose, inline code and highlighted code blocks.
struct BodySegment: Codable, Hashable {
    let type: String
    let text: String?
    let code: String?
    let language: String?
    let html: String?
    /// The name a code block was given after its language, as in ```php title="app.php".
    var filename: String? = nil
}

struct Mention: Codable, Hashable {
    let handle: String
    let offset: Int
    let length: Int
    /// "user" or "organization".
    var kind: String? = nil
}

struct ReplyGhost: Codable, Hashable {
    let id: Int
    let userId: String?
    let body: String?
    let imagesCount: Int?
    let hasVoice: Bool?
}

struct LinkPreview: Codable, Hashable {
    let url: String
    let title: String?
    let description: String?
    let imageUrl: String?
    let siteName: String?
    /// The server is still fetching the page; the card is asked for again until it has it.
    let isPending: Bool?
}

struct MessageImage: Codable, Hashable, Identifiable {
    let id: String
    let width: Int?
    let height: Int?
    let description: String?
    let url: String
}

struct MessageVoice: Codable, Hashable {
    let id: String
    let durationMs: Int
    let waveform: [Int]
    let url: String
}

struct Message: Codable, Hashable, Identifiable {
    let id: Int
    let userId: String?
    let clientId: String?
    let body: String?
    let bodySegments: [BodySegment]?
    var mentions: [Mention]? = nil
    let replyToId: Int?
    let replyTo: ReplyGhost?
    var linkPreview: LinkPreview?
    let images: [MessageImage]?
    let voice: MessageVoice?
    var reactions: [Reaction]?
    let event: String?
    let subjectId: String?
    let user: User?
    let subject: User?
    let createdAt: Date

    var isEvent: Bool { event != nil }
    var isPing: Bool { event == "ping" }
}

struct ConversationSummary: Codable, Hashable, Identifiable {
    let id: String
    let kind: ConversationKind
    let name: String?
    let partner: User?
    let members: [Member]?
    let lastMessage: Message?
    let lastMessageAt: Date?
    let ahead: Int
    let lastIncomingMessageId: Int?
    let lastIncomingSender: String?
    let partnerReadThroughId: Int?
    var partnerReadAt: Date? = nil
    let isArchived: Bool
    let pinnedAt: Date?
    let mutedUntilAt: Date?

    var isOrg: Bool { kind == .org }
    var isPinned: Bool { pinnedAt != nil }
    var isMuted: Bool { mutedUntilAt.map { $0 > .now } ?? false }

    var reference: ThreadReference {
        if isOrg || partner == nil {
            return .org(id: id, name: name)
        }

        return .direct(partner!)
    }
}

struct InboxPage: Codable {
    let data: [ConversationSummary]
    let hasMore: Bool
    let unreadCount: Int
    let requestsCount: Int
}

struct ReactionChange: Codable, Hashable {
    let id: Int
    let reactions: [Reaction]
}

struct OrgInfo: Codable, Hashable {
    let id: String
    let name: String?
}

/// A one-to-one thread or an org's, as GET .../messages answers it. The fields that only one kind has are optional.
struct ChatThread: Codable {
    let messages: [Message]
    let hasOlder: Bool
    let reactionsVersion: Int
    let reactionChanges: [ReactionChange]
    let readThroughId: Int
    let isArchived: Bool
    let pinnedAt: Date?
    let mutedUntilAt: Date?
    let access: PushAccess

    let partner: User?
    let partnerReadThroughId: Int?
    let partnerReadAt: Date?
    let partnerTyping: Bool?

    let org: OrgInfo?
    let members: [Member]?
    let typing: [String]?
    let role: OrgRole?
}

struct Candidate: Codable, Hashable, Identifiable {
    let user: User
    let reason: String?

    var id: String { user.id }
}

/// Which thread the user is looking at: someone they push to directly, or an org. Two references to the same thread
/// are equal even when the partner's profile changed in between, so the selection survives a refresh.
enum ThreadReference: Hashable, Identifiable {
    case direct(User)
    case org(id: String, name: String?)

    var id: String {
        switch self {
        case let .direct(user): "@" + user.handle
        case let .org(id, _): "org:" + id
        }
    }

    static func == (lhs: ThreadReference, rhs: ThreadReference) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// The path of the thread under /api/v1/remotes.
    var path: String {
        switch self {
        case let .direct(user): "remotes/@" + user.handle
        case let .org(id, _): "remotes/orgs/" + id
        }
    }
}
