import Foundation

/// A value held by reference, so a commit can carry the commit it replies to or quotes without the struct containing
/// itself.
final class Indirect<Value: Codable & Hashable>: Codable, Hashable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    required init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    static func == (lhs: Indirect, rhs: Indirect) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}

// MARK: - Commits

enum CommitStatus: String, Codable, Hashable {
    case pending
    case approved
    case rejected
}

struct CommitImage: Codable, Hashable, Identifiable {
    let id: String
    let width: Int?
    let height: Int?
    let description: String?
    let url: String
}

struct PollOption: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let votesCount: Int?
    let voted: Bool
    let percentage: Int?
}

/// A poll as the web shows it: counts stay null until the user voted, wrote it, or it closed.
struct Poll: Codable, Hashable {
    let id: String
    let closesAt: Date?
    let isClosed: Bool
    let hasVoted: Bool
    let totalVotes: Int?
    let options: [PollOption]

    var showsResults: Bool { totalVotes != nil }
}

/// The newest replies the web shows under a commit in a list, for the replier avatars.
struct ReplyPreview: Codable, Hashable {
    let data: [Commit]
}

/// A commit as CommitResource sends it to a signed request. A deleted commit that still has replies comes as a
/// tombstone: its id, parent, deletion time and reply count only.
struct Commit: Codable, Hashable, Identifiable {
    let id: String
    var shortHash: String?
    var body: String?
    var parentId: String?
    var htmlUrl: String?
    var createdAt: Date?
    var starsCount: Int?
    var repliesCount: Int?
    var linkPreview: LinkPreview?
    var images: [CommitImage]?
    var author: User?
    var bodySegments: [BodySegment]?
    var previewSegments: [BodySegment]?
    var mentions: [Mention]?
    var status: CommitStatus?
    var isPinned: Bool?
    var starred: Bool?
    var pasteisCount: Int?
    var deletedAt: Date?
    var parent: Indirect<Commit>?
    var quotedCommitId: String?
    var quotedCommit: Indirect<Commit>?
    var poll: Poll?
    var replyPreview: ReplyPreview?

    var isTombstone: Bool { deletedAt != nil || author == nil }
    var hash: String { shortHash ?? String(id.replacingOccurrences(of: "-", with: "").suffix(7)) }
    var isStarred: Bool { starred ?? false }
    var stars: Int { starsCount ?? 0 }
    var replies: Int { repliesCount ?? 0 }
    var text: String { body ?? "" }

    /// The web's address of the commit, for Copy Link and Open on the Web.
    var webURL: URL {
        htmlUrl.flatMap(URL.init(string:)) ?? APIClient.baseURL.appending(path: "@\(author?.handle ?? "")/commits/\(id)")
    }

    /// The people who replied last, newest first, at most three, for the action row.
    var repliers: [User] {
        var seen = Set<String>()

        return (replyPreview?.data ?? []).compactMap(\.author).filter { seen.insert($0.id).inserted }.prefix(3).map { $0 }
    }

    var lastReplyAt: Date? {
        replyPreview?.data.compactMap(\.createdAt).max()
    }
}

/// A cursor page from a Laravel resource collection.
struct Page<Item: Decodable>: Decodable {
    struct Meta: Decodable {
        let nextCursor: String?
        let currentPage: Int?
        let lastPage: Int?
        let total: Int?
    }

    let data: [Item]
    let meta: Meta?
}

/// GET log/{log}: a page of the log, with how many commits are newer than ?since=, and suggestions while Following is
/// empty.
struct LogPage: Decodable {
    let data: [Commit]
    let meta: Page<Commit>.Meta?
    let newCommitsCount: Int?
    let isRanked: Bool?
    let suggestions: [Commit]?
}

/// GET commits/{id}: the commit with the visible commits it replies to.
struct CommitPage: Decodable {
    let data: Commit
    let ancestors: [Commit]?
    /// Who a reply can go to besides the author: the people the commit's thread already addresses.
    var replyParticipants: [User]? = nil
}

struct Translation: Codable, Hashable {
    let language: String
    let sourceLanguage: String?
    let sourceName: String?
    let available: Bool?
    let body: String?
}

// MARK: - People

struct ActivityBucket: Codable, Hashable {
    let date: String
    let count: Int
}

struct Activity: Codable, Hashable {
    let scale: String
    let buckets: [ActivityBucket]
}

struct Streaks: Codable, Hashable {
    let longest: Int
    let current: Int
}

struct Badge: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String?
    let unlocked: Bool
    let progress: Int
    let target: Int
}

struct Achievements: Codable, Hashable {
    let level: Int
    let rank: String
    let xp: Int
    let badges: [Badge]
}

/// The profile as GET users/{handle} answers a signed request: the user with their counts under `data`, and what only
/// a signed request gets beside it.
struct Profile: Decodable {
    struct Counts: Decodable {
        let commitsCount: Int?
        let followersCount: Int?
        let followingCount: Int?
        let company: String?
        let location: String?
        let website: String?
        let githubUrl: String?
        let createdAt: Date?
    }

    let user: User
    let counts: Counts
    var isFollowing: Bool
    let followsYou: Bool
    var isMuting: Bool
    let activity: Activity?
    let streaks: Streaks?
    let achievements: Achievements?
    var pinnedCommit: Commit?
    /// The handles the bio mentions that are on /dev/null, lowercased, so the rest link to GitHub.
    let bioProfiles: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case data, isFollowing, followsYou, isMuting, activity, streaks, achievements, pinnedCommit, bioProfiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(User.self, forKey: .data)
        counts = try container.decode(Counts.self, forKey: .data)
        isFollowing = try container.decodeIfPresent(Bool.self, forKey: .isFollowing) ?? false
        followsYou = try container.decodeIfPresent(Bool.self, forKey: .followsYou) ?? false
        isMuting = try container.decodeIfPresent(Bool.self, forKey: .isMuting) ?? false
        activity = try container.decodeIfPresent(Activity.self, forKey: .activity)
        streaks = try container.decodeIfPresent(Streaks.self, forKey: .streaks)
        achievements = try container.decodeIfPresent(Achievements.self, forKey: .achievements)
        pinnedCommit = try container.decodeIfPresent(Commit.self, forKey: .pinnedCommit)
        bioProfiles = try? container.decodeIfPresent([String: String].self, forKey: .bioProfiles)
    }
}

/// A GitHub organization at an "@handle" no user has, mirrored from GitHub, as its page on the web shows it. Its page
/// also says who follows it, its admins and the color they chose; a list says whether the user follows each one.
struct Organization: Decodable, Hashable, Identifiable {
    let handle: String
    let name: String
    let avatarUrl: String?
    let bio: String?
    let location: String?
    let website: String?
    let githubUrl: String
    let htmlUrl: String
    var isFollowed: Bool? = nil
    var followersCount: Int? = nil
    var lane: Lane? = nil
    var admins: [User]? = nil

    var id: String { handle }
    var avatarURL: URL? { avatarUrl.flatMap(URL.init(string:)) }
}

/// GET organizations/{handle}: the page, with what only a signed request gets beside it.
struct OrganizationPage: Decodable {
    var data: Organization
    var isFollowing: Bool? = nil
    var canClaim: Bool? = nil
    var settingsUrl: String? = nil
}

// MARK: - Notifications

enum NotificationKind: String, Codable, Hashable {
    case followed
    case replied
    case mentioned
    case approved
    case rejected
    case quoted
    case starred
    case leveledUp = "leveled_up"
    case firstCommit = "first_commit"
    case unknown

    init(from decoder: Decoder) throws {
        self = NotificationKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    var symbol: String {
        switch self {
        case .followed: "person.badge.plus"
        case .replied: "bubble.left"
        case .quoted: "arrow.2.squarepath"
        case .starred: "star"
        case .mentioned: "at"
        case .firstCommit: "arrow.triangle.branch"
        case .approved: "checkmark"
        case .rejected: "xmark"
        case .leveledUp, .unknown: "chevron.up.2"
        }
    }
}

/// The page tabs over Notifications, as the web's filters name them.
enum NotificationFilter: String, CaseIterable, Identifiable {
    case all
    case replies
    case quotes
    case stars
    case mentions
    case follows
    case moderation

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A group of notifications, led by its newest one.
struct ActivityNotification: Codable, Hashable, Identifiable {
    let id: String
    let type: NotificationKind
    let subjectId: String?
    let reason: String?
    let readAt: Date?
    let createdAt: Date
    let actor: User?
    let actors: [User]?
    let groupId: String?
    let eventCount: Int?
    let actorsCount: Int?
    let unreadCount: Int?
    let commit: Commit?

    var isUnread: Bool { (unreadCount ?? 0) > 0 || readAt == nil }
    var isGroup: Bool { (eventCount ?? 1) > 1 }
}

struct NotificationPage: Decodable {
    let data: [ActivityNotification]
    let meta: Page<ActivityNotification>.Meta?
    let readAt: Date?
}

// MARK: - The queue, devices, search

struct ScheduledCommit: Codable, Hashable, Identifiable {
    let id: String
    let body: String?
    let bodySegments: [BodySegment]?
    let pollOptions: [String]?
    let imageCount: Int
    let scheduledAt: Date
    let submittedAt: Date?
    let status: String

    var isQueued: Bool { status == "scheduled" }
}

struct Device: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let fingerprint: String
    let approvedAt: Date
    let lastUsedAt: Date?
}

struct IssueSuggestion: Codable, Hashable {
    let number: Int
    let title: String
    let url: String
}

/// GET me/settings: what the web's settings show only the user.
struct AccountSettings: Codable, Hashable {
    struct Language: Codable, Hashable, Identifiable {
        let code: String
        let name: String
        let nativeName: String

        var id: String { code }
    }

    var timezone: String?
    var showLocalTime: Bool?
    var translationLanguage: String?
    var automaticTranslation: Bool
    var translationLanguages: [Language]
    var isAdmin: Bool
}
