import AppKit
import SwiftUI

// MARK: - Page tabs

/// The web's page tabs: 13 medium labels, muted until active, the active one in ink over a 3pt primary underline that
/// hugs the label and slides between tabs.
struct PageTabs<Tab: Hashable & Identifiable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline

    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xl) {
                ForEach(tabs) { tab in
                    let isActive = tab == selection

                    Button {
                        withAnimation(DS.Motion.respecting(reduceMotion, DS.Motion.slide)) { selection = tab }
                    } label: {
                        Text(title(tab))
                            .font(DS.Fonts.bodyMedium)
                            .foregroundStyle(isActive ? DS.Colors.ink : DS.Colors.inkMuted)
                            .padding(.vertical, DS.Spacing.m)
                            .overlay(alignment: .bottom) {
                                if isActive {
                                    DS.Colors.primary
                                        .frame(height: 3)
                                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, DS.Metrics.railWidth + DS.Spacing.xs)
        }
        .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1) }
    }
}

// MARK: - Commit lists

/// A list of commits on the rail with paging, for Starred, profile tabs and search results.
struct CommitList<Header: View, Empty: View>: View {
    @Environment(Workspace.self) private var workspace

    let ids: [String]
    var isLoading = false
    var hasMore = false
    var loadMore: () async -> Void = {}
    @ViewBuilder var header: () -> Header
    @ViewBuilder var empty: () -> Empty

    @State private var highlight = RailHighlight()
    @State private var width: CGFloat = 800

    var body: some View {
        let commits = ids.compactMap { workspace.existingBox($0) }.filter { !$0.isRemoved }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header()

                if isLoading, commits.isEmpty {
                    ForEach(0 ..< 5, id: \.self) { _ in SkeletonCommitRow() }
                } else if commits.isEmpty {
                    empty()
                        .frame(maxWidth: .infinity)
                        .padding(.top, DS.Spacing.xxl)
                } else {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { index, box in
                        let previous = index > 0 ? commits[index - 1] : nil

                        CommitRow(box: box, above: previous.map { (LaneColor.of($0.commit.author), $0.commit.author?.id) } ?? (DS.Colors.rail, nil), showsHash: width >= 520, hasTail: index < commits.count - 1 || hasMore)
                    }

                    if hasMore {
                        SkeletonCommitRow()
                            .onAppear { Task { await loadMore() } }
                    }
                }
            }
            .padding(.bottom, DS.Spacing.xl)
        }
        .background(DS.Colors.surface)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { width = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, value in width = value }
            }
        }
        .environment(highlight)
    }
}

extension CommitList where Header == EmptyView {
    init(ids: [String], isLoading: Bool = false, hasMore: Bool = false, loadMore: @escaping () async -> Void = {}, @ViewBuilder empty: @escaping () -> Empty) {
        self.init(ids: ids, isLoading: isLoading, hasMore: hasMore, loadMore: loadMore, header: { EmptyView() }, empty: empty)
    }
}

// MARK: - User preview

/// Hovering an avatar, name or handle opens the person's preview after 450ms, with 200ms of grace to move into it.
/// Mouse only: keyboard focus never opens it; `K` on a focused row does, through `isPresented`.
struct UserPreviewModifier: ViewModifier {
    let user: User?
    @Binding var isPresented: Bool

    @State private var isHoveringAnchor = false
    @State private var isHoveringPreview = false
    @State private var timer: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHoveringAnchor = hovering
                schedule()
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                if let user {
                    UserPreview(user: user)
                        .onHover { hovering in
                            isHoveringPreview = hovering
                            schedule()
                        }
                }
            }
    }

    private func schedule() {
        timer?.cancel()

        guard user != nil else { return }

        timer = Task {
            if isHoveringAnchor, !isPresented {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, isHoveringAnchor else { return }
                isPresented = true
            } else if !isHoveringAnchor, !isHoveringPreview, isPresented {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, !isHoveringAnchor, !isHoveringPreview else { return }
                isPresented = false
            }
        }
    }
}

extension View {
    func userPreview(_ user: User?, isPresented: Binding<Bool>) -> some View {
        modifier(UserPreviewModifier(user: user, isPresented: isPresented))
    }
}

/// The preview itself: avatar with its lane ring, Follow, name, handle, "Follows you", three lines of bio, the counts,
/// and Push.
struct UserPreview: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation: Navigation?
    @Environment(\.workspaceActions) private var actions

    let user: User

    var body: some View {
        let store = workspace.profile(user.handle)
        let profile = store.profile
        let isOwn = user.id == workspace.session.user?.id

        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .top) {
                Button { actions?.openProfile(user.handle) } label: {
                    Avatar(user: user, size: 56).laneRing(user)
                }
                .buttonStyle(.plain)
                Spacer()
                if !isOwn {
                    FollowButton(user: profile.map { $0.user.with(isFollowed: $0.isFollowing) } ?? user)
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(user.displayName)
                    .font(DS.Fonts.section)
                    .foregroundStyle(DS.Colors.ink)
                HStack(spacing: DS.Spacing.s) {
                    LaneDot(user: user)
                    Text("@\(user.handle)")
                        .font(DS.Fonts.monoHandle)
                        .foregroundStyle(DS.Colors.inkMuted)
                    if let stream = (profile?.user ?? user).liveStream {
                        LiveBadge(stream: stream)
                    }
                    if profile?.followsYou ?? user.followsYou ?? false {
                        StatusLabel(text: "Follows you")
                    }
                }
            }

            if let bio = profile?.user.bio ?? user.bio, !bio.isEmpty {
                Text(CommitText.prose(bio, size: 13, profiles: profile?.bioProfiles))
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(3)
            }

            if let counts = profile?.counts {
                HStack(spacing: DS.Spacing.l) {
                    CountLink(count: counts.followersCount ?? 0, label: "followers") { navigation?.push(.followers(user.handle)) }
                    CountLink(count: counts.followingCount ?? 0, label: "following") { navigation?.push(.following(user.handle)) }
                }
            }

            if !isOwn, user.isBot == false {
                Button("Push") { navigation?.select(.remote(.direct(user))) }
                    .buttonStyle(.dsOutline)
            }
        }
        .padding(DS.Spacing.l)
        .frame(width: DS.Metrics.previewWidth, alignment: .leading)
        .task { if store.profile == nil { await store.reload() } }
    }
}

/// A person's lane as a small dot before their handle.
struct LaneDot: View {
    let user: User?

    var body: some View {
        Circle()
            .fill(LaneColor.of(user))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// A mono count with its sans label, which pushes the list it counts.
struct CountLink: View {
    let count: Int
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                Text(count.formatted(.number.locale(Locale(identifier: "en_US"))))
                    .font(DS.Fonts.monoCaption.weight(.semibold))
                    .foregroundStyle(DS.Colors.ink)
                Text(label)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(label)")
    }
}

extension User {
    /// The same person with a follow state the profile knows better.
    func with(isFollowed: Bool) -> User {
        User(id: id, handle: handle, name: name, avatarUrl: avatarUrl, bio: bio, htmlUrl: htmlUrl, lane: lane, isFollowed: isFollowed, followsYou: followsYou)
    }
}
