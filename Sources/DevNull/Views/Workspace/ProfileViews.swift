import AppKit
import SwiftUI

/// The signed-in user's own profile, the sidebar's Profile item.
struct OwnProfileView: View {
    @Environment(Session.self) private var session

    var body: some View {
        if let handle = session.user?.handle {
            ProfileView(handle: handle)
        }
    }
}

/// A profile: the header mirrored from GitHub, the activity graph and streaks, rank and achievements, the pinned
/// commit, and the Commits · Replies (· Starred on your own) tabs on the rail. Nothing here edits identity.
struct ProfileView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    let handle: String

    @State private var tab = ProfileStore.Tab.commits

    private var store: ProfileStore { workspace.profile(handle) }
    private var isOwn: Bool { handle.lowercased() == workspace.session.user?.handle.lowercased() }

    var body: some View {
        Group {
            if let organization = store.organization {
                OrganizationView(page: organization, store: store)
            } else if let profile = store.profile {
                CommitList(ids: store.commits[tab] ?? [], isLoading: store.commits[tab] == nil, hasMore: tab != .starred && store.cursors[tab] != nil) {
                    await store.loadTab(tab, more: true)
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        ProfileHeader(profile: profile, isOwn: isOwn)
                            .padding(.horizontal, DS.Metrics.railWidth + DS.Spacing.xs)
                            .padding(.vertical, DS.Spacing.xl)

                        if let pinned = profile.pinnedCommit, let box = workspace.existingBox(pinned.id), tab == .commits {
                            Text("pinned")
                                .font(DS.Fonts.monoCaption)
                                .foregroundStyle(DS.Colors.inkMuted)
                                .padding(.leading, DS.Metrics.railWidth + DS.Spacing.xs)
                            CommitRow(box: box, hasTail: false)
                        }

                        PageTabs(tabs: isOwn ? ProfileStore.Tab.allCases : [.commits, .replies], selection: $tab) { $0.title }
                    }
                } empty: {
                    switch tab {
                    case .commits: EmptyState(fatal: "fatal: no commits yet", message: isOwn ? "Your first commit lands here." : "@\(handle) hasn't committed anything yet.")
                    case .replies: EmptyState(fatal: "fatal: no replies yet", message: "Replies to other commits land here.")
                    case .starred: EmptyState(fatal: "fatal: no starred commits", message: "Star a commit and it waits for you here.")
                    }
                }
                .task(id: tab) { await store.loadTab(tab) }
            } else if let error = store.error {
                EmptyState(fatal: "fatal: could not fetch @\(handle)", message: error) {
                    Button("Try Again") { Task { await store.reload() } }
                        .buttonStyle(LinkButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Colors.surface)
            } else {
                ProfileSkeleton(user: workspace.knownUser(handle))
            }
        }
        .task(id: handle) { await store.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDestination)) { note in
            guard note.object as? Navigation === navigation else { return }
            Task { await store.reload() }
        }
    }
}

/// Avatar, name, handle, bio, metadata and counts, with Follow, Push and `…` (or Edit on GitHub on your own).
struct ProfileHeader: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.openURL) private var openURL

    let profile: Profile
    let isOwn: Bool

    @State private var showsGoLive = false
    @State private var isEndingStream = false

    private var user: User { profile.user }
    private var profileURL: URL { APIClient.baseURL.appending(path: "@\(user.handle)") }
    /// Your own stream comes from the signed-in user, which going live updates right away.
    private var liveStream: LiveStream? { isOwn ? workspace.session.user?.asUser.liveStream : user.liveStream }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(alignment: .top) {
                Avatar(user: user, size: 80)
                    .laneRing(user, width: 2, gap: 4)

                Spacer()

                actions
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(user.displayName)
                    .font(DS.Fonts.profileName)
                    .foregroundStyle(DS.Colors.ink)
                    .textSelection(.enabled)
                HStack(spacing: DS.Spacing.s) {
                    LaneDot(user: user)
                    Text("@\(user.handle)")
                        .font(DS.Fonts.monoHandle)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .textSelection(.enabled)
                    if let stream = liveStream {
                        LiveBadge(stream: stream)
                    }
                    if profile.followsYou, !isOwn {
                        StatusLabel(text: "Follows you")
                    }
                    if user.isBot {
                        StatusLabel(text: "bot")
                    }
                }
            }

            if let bio = user.bio, !bio.isEmpty {
                Text(CommitText.prose(bio, size: 14, profiles: profile.bioProfiles))
                    .font(DS.Fonts.commitBody)
                    .foregroundStyle(DS.Colors.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: DS.Metrics.readingMeasure, alignment: .leading)
            }

            metadata

            HStack(spacing: DS.Spacing.l) {
                HStack(spacing: DS.Spacing.xs) {
                    Text((profile.counts.commitsCount ?? 0).formatted(.number.locale(Locale(identifier: "en_US"))))
                        .font(DS.Fonts.monoCaption.weight(.semibold))
                        .foregroundStyle(DS.Colors.ink)
                    Text("commits")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkMuted)
                }
                CountLink(count: profile.counts.followersCount ?? 0, label: "followers") { navigation.push(.followers(user.handle)) }
                CountLink(count: profile.counts.followingCount ?? 0, label: "following") { navigation.push(.following(user.handle)) }
            }

            if let activity = profile.activity, !activity.buckets.isEmpty {
                ActivityGraph(activity: activity, lane: LaneColor.of(user))
            }

            if let streaks = profile.streaks {
                StreakStrip(streaks: streaks, lane: LaneColor.of(user))
            }

            if let achievements = profile.achievements {
                AchievementsView(handle: user.handle, achievements: achievements)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: DS.Spacing.s) {
            if isOwn {
                if liveStream != nil {
                    Button(isEndingStream ? "Ending…" : "End Stream") {
                        isEndingStream = true
                        Task {
                            do { try await workspace.setLive(url: nil) } catch { workspace.toasts.fatal(error) }
                            isEndingStream = false
                        }
                    }
                    .buttonStyle(.dsOutline)
                    .disabled(isEndingStream)
                } else {
                    Button("Go Live") { showsGoLive = true }
                        .buttonStyle(.dsOutline)
                        .help("Share your YouTube or Twitch stream on your avatar")
                        .sheet(isPresented: $showsGoLive) { GoLiveSheet() }
                }

                Button("Edit on GitHub") { openURL(URL(string: "https://github.com/settings/profile")!) }
                    .buttonStyle(.dsOutline)
                    .help("Your name, bio and picture come from GitHub")
            } else {
                FollowButton(user: user.with(isFollowed: profile.isFollowing))

                if !user.isBot {
                    Button("Push") { navigation.select(.remote(.direct(user))) }
                        .buttonStyle(.dsOutline)
                }

                Menu {
                    Button(profile.isMuting ? "Unmute @\(user.handle)" : "Mute @\(user.handle)") { workspace.setMuted(!profile.isMuting, user) }
                    Button("Block @\(user.handle)…") {
                        if Confirmations.confirm("Block @\(user.handle)?", "They won't see your commits or push to you, and you won't see theirs. You can unblock them in Settings → Privacy.", action: "Block") {
                            workspace.block(user)
                        }
                    }
                    Divider()
                    Button("Copy Profile Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(profileURL.absoluteString, forType: .string)
                        workspace.toasts.show("Copied link to @\(user.handle)")
                    }
                    Button("Open on the Web") { openURL(profileURL) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: DS.Metrics.controlHeight, height: DS.Metrics.controlHeight)
                }
                .menuStyle(.button)
                .buttonStyle(DSButtonStyle(kind: .outline))
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: DS.Spacing.l) {
            if let company = profile.counts.company, !company.isEmpty {
                meta("building.2", company)
            }
            if let location = profile.counts.location, !location.isEmpty {
                meta("mappin.and.ellipse", location)
            }
            if let website = profile.counts.website, !website.isEmpty, let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                Button { openURL(url) } label: {
                    meta("link", url.host() ?? website, tint: DS.Colors.primary)
                }
                .buttonStyle(.plain)
            }
            if let joined = profile.counts.createdAt {
                meta("calendar", "Joined \(joined.formatted(.dateTime.month(.wide).year()))")
            }
        }
    }

    private func meta(_ symbol: String, _ text: String, tint: Color = DS.Colors.inkMuted) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.inkMuted)
            Text(text)
                .font(DS.Fonts.body)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

/// A GitHub organization's page, as on the web: the header mirrored from GitHub with its color, followers and admins,
/// Claim while nobody has, Settings for its admins and members (on the web), then the commits mentioning it.
private struct OrganizationView: View {
    /// The page's one tab, as on the web.
    enum Tab: Identifiable {
        case mentions

        var id: Self { self }
    }

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL
    @Environment(\.workspaceActions) private var actions

    let page: OrganizationPage
    let store: ProfileStore

    @State private var isClaiming = false

    private var organization: Organization { page.data }
    private var lane: Color { LaneColor.of(lane: organization.lane) }

    var body: some View {
        CommitList(ids: store.mentions ?? [], isLoading: store.mentions == nil, hasMore: store.mentionsCursor != nil) {
            await store.loadMentions(more: true)
        } header: {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, DS.Metrics.railWidth + DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xl)

                PageTabs(tabs: [Tab.mentions], selection: .constant(.mentions)) { _ in "Mentions" }
            }
        } empty: {
            EmptyState(fatal: "$ git log --grep=@\(organization.handle)", message: "Nobody has mentioned @\(organization.handle) yet. Commits that do land here.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(alignment: .top) {
                OrganizationAvatar(organization: organization, size: 80)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg + 4, style: .continuous).strokeBorder(lane, lineWidth: 2))

                Spacer()

                buttons
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(organization.name)
                    .font(DS.Fonts.profileName)
                    .foregroundStyle(DS.Colors.ink)
                    .textSelection(.enabled)
                HStack(spacing: DS.Spacing.s) {
                    Circle().fill(lane).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text("@\(organization.handle)")
                        .font(DS.Fonts.monoHandle)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .textSelection(.enabled)
                    StatusLabel(text: "Organization")
                }
            }

            if let bio = organization.bio, !bio.isEmpty {
                Text(CommitText.prose(bio, size: 14))
                    .font(DS.Fonts.commitBody)
                    .foregroundStyle(DS.Colors.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: DS.Metrics.readingMeasure, alignment: .leading)
            }

            metadata

            if let count = organization.followersCount {
                HStack(spacing: DS.Spacing.xs) {
                    Text(count.formatted(.number.locale(Locale(identifier: "en_US"))))
                        .font(DS.Fonts.monoCaption.weight(.semibold))
                        .foregroundStyle(DS.Colors.ink)
                    Text(count == 1 ? "follower" : "followers")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkMuted)
                }
            }

            if let admins = organization.admins, !admins.isEmpty {
                HStack(spacing: DS.Spacing.m) {
                    Text(admins.count == 1 ? "Admin" : "Admins")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkMuted)
                    ForEach(admins) { admin in
                        Button { actions?.openProfile(admin.handle) } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                Avatar(user: admin, size: 20)
                                Text("@\(admin.handle)")
                                    .font(DS.Fonts.monoHandle)
                                    .foregroundStyle(DS.Colors.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(admin.displayName)
                    }
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: DS.Spacing.s) {
            if page.canClaim == true {
                Button(isClaiming ? "Claiming…" : "Claim") {
                    isClaiming = true
                    Task {
                        await store.claim()
                        isClaiming = false
                    }
                }
                .buttonStyle(.dsOutline)
                .disabled(isClaiming)
                .help("GitHub confirms you belong to @\(organization.handle), and you become its first admin")
            }

            if let settings = page.settingsUrl.flatMap(URL.init(string:)) {
                Button("Settings") { openURL(settings) }
                    .buttonStyle(.dsOutline)
                    .help("Members and color are managed on the web")
            }

            OrganizationFollowButton(organization: organization.with(isFollowed: page.isFollowing))

            Menu {
                Button("Copy Profile Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(organization.htmlUrl, forType: .string)
                    workspace.toasts.show("Copied link to @\(organization.handle)")
                }
                if let url = URL(string: organization.htmlUrl) {
                    Button("Open on the Web") { openURL(url) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: DS.Metrics.controlHeight, height: DS.Metrics.controlHeight)
            }
            .menuStyle(.button)
            .buttonStyle(DSButtonStyle(kind: .outline))
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private var metadata: some View {
        HStack(spacing: DS.Spacing.l) {
            if let location = organization.location, !location.isEmpty {
                meta("mappin.and.ellipse", location)
            }
            if let website = organization.website, !website.isEmpty, let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                link("link", url.host() ?? website, to: url)
            }
            if let url = URL(string: organization.githubUrl) {
                link("chevron.left.forwardslash.chevron.right", "github.com/\(organization.handle)", to: url)
            }
        }
    }

    private func link(_ symbol: String, _ text: String, to url: URL) -> some View {
        Button { openURL(url) } label: {
            meta(symbol, text, tint: DS.Colors.primary)
        }
        .buttonStyle(.plain)
    }

    private func meta(_ symbol: String, _ text: String, tint: Color = DS.Colors.inkMuted) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.inkMuted)
            Text(text)
                .font(DS.Fonts.body)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

/// Follow or Following for an organization, as FollowButton is for a person.
struct OrganizationFollowButton: View {
    @Environment(Workspace.self) private var workspace
    let organization: Organization

    @State private var isFollowing: Bool?
    @State private var isBusy = false

    var body: some View {
        Group {
            if isFollowing ?? organization.isFollowed ?? false {
                Menu("Following") {
                    Button("Unfollow @\(organization.handle)") { toggle(to: false) }
                }
                .menuStyle(.button)
                .buttonStyle(DSButtonStyle(kind: .outline))
                .menuIndicator(.hidden)
            } else {
                Button("Follow") { toggle(to: true) }
                    .buttonStyle(.dsPrimary)
            }
        }
        .fixedSize()
        .disabled(isBusy)
    }

    private func toggle(to value: Bool) {
        isBusy = true

        Task {
            if await workspace.setFollowing(value, organization: organization) { isFollowing = value }
            isBusy = false
        }
    }
}

/// An organization in a Following list: its picture, name, handle, one line of bio, and Follow.
struct OrganizationRow: View {
    @Environment(\.workspaceActions) private var actions

    let organization: Organization

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Button { actions?.openProfile(organization.handle) } label: {
                HStack(spacing: DS.Spacing.m) {
                    OrganizationAvatar(organization: organization, size: DS.Metrics.commitAvatar)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(organization.name)
                                .font(DS.Fonts.commitAuthor)
                                .foregroundStyle(DS.Colors.ink)
                            Text("@\(organization.handle)")
                                .font(DS.Fonts.monoHandle)
                                .foregroundStyle(DS.Colors.inkMuted)
                            StatusLabel(text: "organization")
                        }
                        .lineLimit(1)
                        if let bio = organization.bio, !bio.isEmpty {
                            Text(bio)
                                .font(DS.Fonts.body)
                                .foregroundStyle(DS.Colors.inkMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: DS.Spacing.m)

            OrganizationFollowButton(organization: organization)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DS.Metrics.commitGutter)
        .background(isHovered ? DS.Colors.wash : .clear)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1).padding(.leading, DS.Metrics.commitGutter) }
    }
}

extension Organization {
    func with(isFollowed: Bool?) -> Organization {
        var copy = self
        copy.isFollowed = isFollowed ?? self.isFollowed
        return copy
    }
}

/// An organization's picture, in a rounded square like GitHub draws them so it never reads as a person.
struct OrganizationAvatar: View {
    let organization: Organization
    var size: CGFloat = 36

    private var radius: CGFloat { size > 40 ? DS.Radius.lg : DS.Radius.sm }

    var body: some View {
        RemoteImage(url: organization.avatarURL) {
            ZStack {
                DS.Colors.wash
                Text(organization.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Colors.inkMuted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.Colors.ink.opacity(0.06)))
        .accessibilityHidden(true)
    }
}

// MARK: - Activity, streaks, achievements

/// The web's activity graph: 53 weeks of seven days for a year, or one row of cells for shorter windows, in the
/// owner's lane at four opacities.
struct ActivityGraph: View {
    let activity: Activity
    let lane: Color

    var body: some View {
        let buckets = activity.buckets
        let maximum = max(1, buckets.map(\.count).max() ?? 1)
        let isYear = buckets.count > 31

        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                if isYear {
                    let columns = stride(from: 0, to: buckets.count, by: 7).map { Array(buckets[$0 ..< min($0 + 7, buckets.count)]) }

                    HStack(alignment: .top, spacing: DS.Metrics.activityGap) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: DS.Metrics.activityGap) {
                                ForEach(week, id: \.date) { cell($0, maximum: maximum) }
                            }
                        }
                    }
                } else {
                    HStack(spacing: DS.Metrics.activityGap) {
                        ForEach(buckets, id: \.date) { cell($0, maximum: maximum) }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)

            Text("\(buckets.map(\.count).reduce(0, +)) commits in the last \(isYear ? "year" : activity.scale)")
                .font(DS.Fonts.monoMeta)
                .foregroundStyle(DS.Colors.inkFaint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity: \(buckets.map(\.count).reduce(0, +)) commits")
    }

    private func cell(_ bucket: ActivityBucket, maximum: Int) -> some View {
        let level = bucket.count == 0 ? 0 : min(4, Int(ceil(Double(bucket.count) / Double(maximum) * 4)))

        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(level == 0 ? DS.Colors.wash : lane.opacity(Double(level) * 0.25))
            .frame(width: DS.Metrics.activityCell, height: DS.Metrics.activityCell)
            .help("\(bucket.count) commit\(bucket.count == 1 ? "" : "s") on \(Self.day(bucket.date))")
    }

    private static func day(_ value: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"

        guard let date = parser.date(from: String(value.prefix(10))) else { return value }

        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// `longest streak 41 days · current 6`, with a lane dot before an active streak.
struct StreakStrip: View {
    let streaks: Streaks
    let lane: Color

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text("longest streak").foregroundStyle(DS.Colors.inkMuted)
            Text("\(streaks.longest) day\(streaks.longest == 1 ? "" : "s")").foregroundStyle(DS.Colors.ink)
            Text("·").foregroundStyle(DS.Colors.inkFaint)
            if streaks.current > 0 {
                Circle().fill(lane).frame(width: 6, height: 6)
            }
            Text("current").foregroundStyle(DS.Colors.inkMuted)
            Text("\(streaks.current)").foregroundStyle(DS.Colors.ink)
        }
        .font(DS.Fonts.monoCaption)
        .accessibilityElement(children: .combine)
    }
}

/// `/usr/local/maya — level 7 · sysadmin`, then the unlocked achievements as chips with their story in a popover.
struct AchievementsView: View {
    let handle: String
    let achievements: Achievements

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("/usr/local/\(handle) — level \(achievements.level) · \(achievements.rank)")
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
                .textSelection(.enabled)

            let unlocked = achievements.badges.filter(\.unlocked)

            if !unlocked.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(unlocked) { BadgeChip(badge: $0) }
                }
            }
        }
    }
}

private struct BadgeChip: View {
    let badge: Badge

    @State private var showsStory = false

    var body: some View {
        Button { showsStory = true } label: {
            Text(badge.name)
                .font(DS.Fonts.monoMeta)
                .foregroundStyle(DS.Colors.ink)
                .padding(.horizontal, DS.Spacing.s)
                .padding(.vertical, 3)
                .background(DS.Colors.wash, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsStory, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(badge.name)
                    .font(DS.Fonts.monoCaption.weight(.semibold))
                Text(badge.description)
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.l)
            .frame(width: 260, alignment: .leading)
        }
        .accessibilityLabel("Achievement: \(badge.name)")
    }
}

// MARK: - People lists

/// Followers or following, each with Follow.
struct PeopleListView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.workspaceActions) private var actions

    let handle: String
    let followers: Bool

    var body: some View {
        let store = workspace.profile(handle)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let people = followers ? store.followers : store.following {
                    let organizations = followers ? [] : store.followedOrganizations ?? []

                    ForEach(organizations) { organization in
                        OrganizationRow(organization: organization)
                    }

                    if people.isEmpty, organizations.isEmpty {
                        EmptyState(fatal: followers ? "fatal: no followers yet" : "fatal: not following anyone", message: followers ? "Nobody follows @\(handle) yet." : "@\(handle) doesn't follow anyone yet.")
                            .frame(maxWidth: .infinity)
                            .padding(.top, DS.Spacing.xxl)
                    } else {
                        ForEach(people) { person in
                            PersonRow(user: person)
                        }
                    }
                } else {
                    ForEach(0 ..< 6, id: \.self) { _ in PersonSkeleton() }
                }
            }
        }
        .background(DS.Colors.surface)
        .task(id: "\(handle)-\(followers)") { await store.loadPeople(followers: followers) }
    }
}

/// A person in a list: avatar, name, handle, one line of bio, and Follow.
struct PersonRow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.workspaceActions) private var actions

    let user: User

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Button { actions?.openProfile(user.handle) } label: {
                HStack(spacing: DS.Spacing.m) {
                    Avatar(user: user, size: DS.Metrics.commitAvatar)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(user.displayName)
                                .font(DS.Fonts.commitAuthor)
                                .foregroundStyle(DS.Colors.ink)
                            Text("@\(user.handle)")
                                .font(DS.Fonts.monoHandle)
                                .foregroundStyle(DS.Colors.inkMuted)
                            if user.followsYou == true {
                                StatusLabel(text: "follows you")
                            }
                        }
                        .lineLimit(1)
                        if let bio = user.bio, !bio.isEmpty {
                            Text(bio)
                                .font(DS.Fonts.body)
                                .foregroundStyle(DS.Colors.inkMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: DS.Spacing.m)

            if user.id != workspace.session.user?.id {
                FollowButton(user: user)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DS.Metrics.commitGutter)
        .background(isHovered ? DS.Colors.wash : .clear)
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1).padding(.leading, DS.Metrics.commitGutter) }
    }
}

private struct PersonSkeleton: View {
    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Circle().fill(DS.Colors.wash).frame(width: DS.Metrics.commitAvatar, height: DS.Metrics.commitAvatar)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                SkeletonBar(width: 160, height: 10)
                SkeletonBar(width: 240, height: 9)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DS.Metrics.commitGutter)
        .skeleton()
    }
}

/// The profile's shape while it loads: the face and name of someone already on screen, bars for the rest, then the
/// commit rows on the rail.
private struct ProfileSkeleton: View {
    let user: User?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                if let user {
                    Avatar(user: user, size: 80)
                        .laneRing(user, width: 2, gap: 4)
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(user.displayName)
                            .font(DS.Fonts.profileName)
                            .foregroundStyle(DS.Colors.ink)
                        HStack(spacing: DS.Spacing.s) {
                            LaneDot(user: user)
                            Text("@\(user.handle)")
                                .font(DS.Fonts.monoHandle)
                                .foregroundStyle(DS.Colors.inkMuted)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.l) {
                        Circle().fill(DS.Colors.wash).frame(width: 88, height: 88)
                        SkeletonBar(width: 180, height: 16)
                        SkeletonBar(width: 120, height: 10)
                    }
                    .skeleton()
                }

                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    SkeletonBar(width: 320, height: 10)
                    SkeletonBar(width: 240, height: 10)
                }
                .skeleton()
            }
            .padding(.horizontal, DS.Metrics.railWidth + DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xl)

            ForEach(0 ..< 4, id: \.self) { _ in SkeletonCommitRow() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Colors.surface)
        .accessibilityLabel(user.map { "Loading @\($0.handle)" } ?? "Loading the profile")
    }
}
