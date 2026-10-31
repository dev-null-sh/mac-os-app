import AppKit
import SwiftUI

// MARK: - Starred

/// Saved commits, newest star first. Unstarring keeps the row until the user navigates away, so nothing jumps.
struct StarredView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    var body: some View {
        let starred = workspace.starred

        Group {
            if let error = starred.error, starred.ids.isEmpty {
                EmptyState(fatal: "fatal: could not fetch your starred commits", message: error) {
                    Button("Try Again") { Task { await starred.reload() } }
                        .buttonStyle(LinkButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Colors.surface)
            } else {
                CommitList(ids: starred.ids, isLoading: !starred.hasLoaded, hasMore: starred.hasMore) {
                    await starred.loadMore()
                } empty: {
                    EmptyState(fatal: "fatal: no starred commits", message: "Star a commit and it waits for you here.")
                }
            }
        }
        .task { await starred.reload() }
        .onDisappear { starred.prune() }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDestination)) { note in
            guard note.object as? Navigation === navigation else { return }
            Task { await starred.reload() }
        }
    }
}

// MARK: - Scheduled

/// The queue: each scheduled commit as a staged node, with when it goes out and Post Now, Edit Time… and Cancel.
struct ScheduledView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    var body: some View {
        let scheduled = workspace.scheduled

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !scheduled.hasLoaded, scheduled.error == nil {
                    ForEach(0 ..< 3, id: \.self) { _ in SkeletonCommitRow() }
                } else if let error = scheduled.error, scheduled.items.isEmpty {
                    EmptyState(fatal: "fatal: could not fetch the queue", message: error) {
                        Button("Try Again") { Task { await scheduled.reload() } }
                            .buttonStyle(LinkButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Spacing.xxl)
                } else if scheduled.items.isEmpty {
                    EmptyState(fatal: "fatal: nothing scheduled", message: "Pick a time in the composer's calendar button to queue a commit.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, DS.Spacing.xxl)
                } else {
                    ForEach(scheduled.items) { item in
                        ScheduledRow(item: item)
                    }
                }
            }
        }
        .background(DS.Colors.surface)
        .task { await scheduled.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDestination)) { note in
            guard note.object as? Navigation === navigation else { return }
            Task { await scheduled.reload() }
        }
    }
}

private struct ScheduledRow: View {
    @Environment(Workspace.self) private var workspace

    let item: ScheduledCommit

    @State private var showsTime = false
    @State private var newTime = Date.now
    @State private var confirmsCancel = false
    @State private var isBusy = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: DS.Metrics.railWidth)

            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                HStack(spacing: DS.Spacing.s) {
                    Text(item.isQueued ? Formatting.scheduleTime(item.scheduledAt) : item.status)
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(item.isQueued ? DS.Colors.ink : DS.Colors.inkMuted)
                    if !item.isQueued, let submitted = item.submittedAt {
                        Text("· sent \(Formatting.relative(submitted))")
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(DS.Colors.inkFaint)
                    }
                }

                if let body = item.body {
                    CommitBodyView(commit: Commit(id: "scheduled-\(item.id)", body: body, bodySegments: item.bodySegments), foldable: false)
                }

                if item.imageCount > 0 {
                    Label("\(item.imageCount) image\(item.imageCount == 1 ? "" : "s")", systemImage: "photo")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                }

                if let options = item.pollOptions {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        ForEach(options, id: \.self) { option in
                            Text(option)
                                .font(DS.Fonts.body)
                                .padding(.horizontal, DS.Spacing.m)
                                .frame(maxWidth: 420, minHeight: 28, alignment: .leading)
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.Colors.hairline))
                        }
                    }
                }

                if item.isQueued {
                    actions
                }
            }
            .padding(.vertical, 12)
            .padding(.leading, DS.Spacing.xs)
            .padding(.trailing, DS.Metrics.commitGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .leading) {
            GraphRail(above: DS.Colors.rail, lane: LaneColor.of(workspace.session.user?.asUser), dashedTail: true)
        }
        .overlay(alignment: .bottom) { RowHairline() }
        .opacity(isBusy ? 0.5 : 1)
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.s) {
            Button("Post Now") { run { await workspace.scheduled.postNow(item) } }
                .buttonStyle(.dsOutline)

            Button("Edit Time…") {
                newTime = item.scheduledAt
                showsTime = true
            }
            .buttonStyle(.dsOutline)
            .disabled(!ScheduledStore.isReschedulable(item))
            .help(ScheduledStore.isReschedulable(item) ? "Edit Time" : "Commits with images or a poll can't be moved; cancel and schedule again on the web.")
            .popover(isPresented: $showsTime, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    DatePicker("Commit at", selection: $newTime, in: Date.now.addingTimeInterval(300) ... Date.now.addingTimeInterval(30 * 86400), displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    HStack {
                        Spacer()
                        Button("Move") {
                            showsTime = false
                            run { await workspace.scheduled.reschedule(item, to: newTime) }
                        }
                        .buttonStyle(.dsPrimary)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(DS.Spacing.xl)
                .frame(width: 300)
            }

            // The confirmation takes the button's own slot, so nothing beside it moves.
            ZStack {
                Button("Cancel") { confirmsCancel = true }
                    .buttonStyle(.dsGhost)
                    .opacity(confirmsCancel ? 0 : 1)
                Button("Cancel It?") { run { await workspace.scheduled.cancel(item) } }
                    .buttonStyle(.dsDestructive)
                    .opacity(confirmsCancel ? 1 : 0)
                    .disabled(!confirmsCancel)
            }
            .onHover { hovering in if !hovering { confirmsCancel = false } }
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

// MARK: - Search results

/// Commits by meaning for a query, in relevance order, without day markers.
struct SearchResultsView: View {
    @Environment(Workspace.self) private var workspace

    let query: String

    var body: some View {
        let search = workspace.search

        CommitList(ids: search.resultsQuery == query ? search.results : [], isLoading: search.isLoadingResults || search.resultsQuery != query) {
            Text(headerText(search))
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
                .padding(.horizontal, DS.Metrics.railWidth + DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { RowHairline() }
        } empty: {
            if let error = search.resultsError {
                EmptyState(fatal: "fatal: search failed", message: error) {
                    Button("Try Again") { Task { await search.loadResults(query) } }
                        .buttonStyle(LinkButtonStyle())
                }
            } else {
                EmptyState(fatal: "fatal: no commits match", message: "Nothing close in meaning to “\(query)”.")
            }
        }
        .task(id: query) {
            if SearchStore.isSearchable(query) { await search.loadResults(query) }
        }
    }

    private func headerText(_ search: SearchStore) -> String {
        guard SearchStore.isSearchable(query) else { return "queries need 3 to 100 characters" }

        if search.isLoadingResults { return "commits by meaning · searching…" }

        return "commits by meaning · \(search.results.count) result\(search.results.count == 1 ? "" : "s") · may miss some"
    }
}

// MARK: - Notifications

/// Notifications on the hollow-node rail, under page tabs. Opening it marks everything read, as on the web.
struct NotificationsView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    var body: some View {
        let store = workspace.notifications

        VStack(spacing: 0) {
            PageTabs(tabs: NotificationFilter.allCases, selection: Binding(get: { store.filter }, set: { store.filter = $0 })) { $0.title }
                .background(DS.Colors.surface)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.isLoading, store.items.isEmpty {
                        ForEach(0 ..< 6, id: \.self) { _ in NotificationSkeleton() }
                    } else if let error = store.error, store.items.isEmpty {
                        EmptyState(fatal: "fatal: could not fetch notifications", message: error) {
                            Button("Try Again") { Task { await store.reload() } }
                                .buttonStyle(LinkButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, DS.Spacing.xxl)
                    } else if store.items.isEmpty {
                        EmptyState(fatal: "fatal: no notifications", message: store.filter == .all ? "Stars, replies, mentions and follows land here." : "Nothing under \(store.filter.title) yet.")
                            .frame(maxWidth: .infinity)
                            .padding(.top, DS.Spacing.xxl)
                    } else {
                        ForEach(store.items) { item in
                            NotificationRow(notification: item)
                        }

                        Color.clear
                            .frame(height: 1)
                            .onAppear { Task { await store.loadMore() } }
                    }
                }
            }
        }
        .background(DS.Colors.surface)
        .task(id: store.filter) { await store.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .reloadDestination)) { note in
            guard note.object as? Navigation === navigation else { return }
            Task { await store.reload() }
        }
    }
}

/// One notification, or a group led by its newest: the type in a hollow node, who, what, when, and the commit.
struct NotificationRow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.workspaceActions) private var actions

    let notification: ActivityNotification
    var isNested = false

    @State private var isExpanded = false
    @State private var isHovered = false

    private var actors: [User] { notification.actors ?? notification.actor.map { [$0] } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(DS.Colors.shell)
                            .overlay(Circle().strokeBorder(DS.Colors.rail, lineWidth: 2))
                        Image(systemName: notification.type.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(notification.type == .rejected ? DS.Colors.destructive : DS.Colors.inkMuted)
                    }
                    .frame(width: DS.Metrics.notificationNode, height: DS.Metrics.notificationNode)
                    .frame(width: 52)
                    .padding(.top, 10)

                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        if !actors.isEmpty, notification.type != .approved, notification.type != .rejected, notification.type != .leveledUp {
                            HStack(spacing: -6) {
                                ForEach(Array(actors.prefix(5).enumerated()), id: \.element.id) { index, user in
                                    Avatar(user: user, size: 24)
                                        .padding(1.5)
                                        .background(DS.Colors.surface, in: Circle())
                                        .zIndex(Double(5 - index))
                                }
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                            Text(sentence)
                                .font(DS.Fonts.body)
                                .foregroundStyle(DS.Colors.ink)
                                .multilineTextAlignment(.leading)
                            Text(Formatting.relative(notification.createdAt))
                                .font(DS.Fonts.monoCaption)
                                .foregroundStyle(DS.Colors.inkFaint)
                        }

                        if notification.type == .rejected, let reason = notification.reason {
                            Text("reason: \(reason)")
                                .font(DS.Fonts.monoCaption)
                                .foregroundStyle(DS.Colors.inkMuted)
                        }

                        if let commit = notification.commit, !commit.text.isEmpty {
                            // Notifications carry the same rendered segments as commit rows. Reuse the renderer so
                            // fenced and inline code, links, and mentions don't fall back to their Markdown source.
                            CommitBodyView(commit: commit, foldable: false, lineLimit: 2)
                        }

                        if notification.type == .followed, !notification.isGroup, let actor = notification.actor, actor.isFollowed != true {
                            FollowButton(user: actor)
                        }

                        if notification.isGroup, !isNested {
                            Button(isExpanded ? "Hide" : "Show all \(notification.eventCount ?? 0)") {
                                isExpanded.toggle()
                                if isExpanded { Task { await workspace.notifications.expand(notification) } }
                            }
                            .buttonStyle(LinkButtonStyle())
                            .font(DS.Fonts.caption)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.trailing, DS.Metrics.commitGutter)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if notification.isUnread {
                        Circle()
                            .fill(DS.Colors.primaryFill)
                            .frame(width: 6, height: 6)
                            .padding(.top, 22)
                            .padding(.trailing, DS.Metrics.commitGutter)
                            .accessibilityLabel("Unread")
                    }
                }
                .background(isHovered ? DS.Colors.wash : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .background(alignment: .leading) {
                DS.Colors.rail
                    .frame(width: 2)
                    .padding(.leading, 25)
            }
            .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1).padding(.leading, 52) }

            if isExpanded, let group = workspace.notifications.groups[notification.id] {
                ForEach(group) { item in
                    NotificationRow(notification: item, isNested: true)
                        .padding(.leading, DS.Spacing.xl)
                }
            }
        }
    }

    private var sentence: AttributedString {
        var names = AttributedString(actors.first?.displayName ?? "Someone")
        names.font = DS.Fonts.body.weight(.semibold)

        let others = max(0, (notification.actorsCount ?? actors.count) - 1)
        // Two people are both named; "and N others" is kept for three or more.
        if others == 1, actors.count > 1, actors[1].id != actors[0].id {
            var second = AttributedString(actors[1].displayName)
            second.font = DS.Fonts.body.weight(.semibold)
            names += AttributedString(" and ") + second
        } else if others > 0 {
            var rest = AttributedString(" and ")
            var count = AttributedString("\(others) other\(others == 1 ? "" : "s")")
            count.font = DS.Fonts.body.weight(.semibold)
            rest += count
            names += rest
        }

        let action: String = switch notification.type {
        case .followed: " followed you"
        case .replied: " replied to your commit"
        case .mentioned: " mentioned you"
        case .quoted: " quoted your commit"
        case .starred: " starred your commit"
        case .firstCommit: " made their first commit"
        case .approved: "Your commit was approved"
        case .rejected: "Your commit was not approved"
        case .leveledUp: "You leveled up"
        case .unknown: " did something"
        }

        if [.approved, .rejected, .leveledUp].contains(notification.type) {
            return AttributedString(action)
        }

        return names + AttributedString(action)
    }

    private func open() {
        switch notification.type {
        case .replied, .quoted, .mentioned, .firstCommit:
            if let commit = notification.commit {
                workspace.box(commit)
                navigation.openThread(commit.id)
            }
        case .starred, .approved, .rejected:
            if let commit = notification.commit {
                workspace.box(commit)
                navigation.push(.commit(commit.id))
            }
        case .followed:
            if !notification.isGroup, let handle = notification.actor?.handle { actions?.openProfile(handle) }
        case .leveledUp, .unknown:
            navigation.select(.profile)
        }
    }
}

private struct NotificationSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle().fill(DS.Colors.wash).frame(width: DS.Metrics.notificationNode, height: DS.Metrics.notificationNode).frame(width: 52)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                SkeletonBar(width: 120, height: 20)
                SkeletonBar(width: 260, height: 10)
                SkeletonBar(width: 200, height: 9)
            }
        }
        .padding(.vertical, 12)
        .skeleton()
    }
}
