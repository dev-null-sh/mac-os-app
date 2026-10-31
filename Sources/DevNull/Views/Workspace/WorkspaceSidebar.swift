import SwiftUI

/// The map of the app: every place a person can read, in three sections. Logs carry a quiet mono count, things
/// addressed to the user carry the blue badge, and nothing is red.
struct WorkspaceSidebar: View {
    @Environment(Session.self) private var session
    @Environment(Inbox.self) private var inbox
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorSchemeContrast) private var contrast
    @Bindable var navigation: Navigation

    @AppStorage("sidebar-logs-expanded") private var logsExpanded = true
    @AppStorage("sidebar-remotes-expanded") private var remotesExpanded = true
    @AppStorage("sidebar-you-expanded") private var youExpanded = true
    @AppStorage("settings-tab") private var settingsTab = "general"

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
                .padding(.horizontal, DS.Spacing.l + 2)
                .padding(.top, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.s)

            List(selection: selection) {
                Section(isExpanded: $logsExpanded) {
                    ForEach(LogKind.allCases, id: \.self) { kind in
                        let store = workspace.log(kind)

                        SidebarRow(item: .log(kind), isSelected: navigation.item == .log(kind), isUnread: store.newCount > 0) {
                            Image(systemName: kind.symbol)
                        } accessory: {
                            if kind != .trending, store.newCount > 0 {
                                QuietCount(count: store.newCount)
                            }
                        }
                        .contextMenu {
                            Button("Open in New Window") { openWindow(id: "item", value: SidebarItem.log(kind)) }
                            Button("Mark All as Seen") { store.markSeen() }
                        }
                        .accessibilityLabel(store.newCount > 0 ? "\(kind.title), \(store.newCount) new commits" : kind.title)
                    }
                } header: {
                    SidebarSectionHeader(title: "Logs")
                }

                Section(isExpanded: $remotesExpanded) {
                    remotes
                } header: {
                    HStack {
                        SidebarSectionHeader(title: "Remotes")
                        Spacer()
                        if session.user?.remotes != nil {
                            Menu {
                                Button("New Remote…") { NotificationCenter.default.post(name: .newRemote, object: nil) }
                                Button("New Org…") { NotificationCenter.default.post(name: .newOrg, object: nil) }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DS.Colors.inkFaint)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("New Remote or New Org")
                            .accessibilityLabel("New Remote or New Org")
                        }
                    }
                }

                LiveNowSection()

                Section(isExpanded: $youExpanded) {
                    SidebarRow(item: .notifications, isSelected: navigation.item == .notifications, isUnread: workspace.notifications.unreadCount > 0) {
                        Image(systemName: "bell")
                    } accessory: {
                        if workspace.notifications.unreadCount > 0 {
                            CountBadge(count: workspace.notifications.unreadCount)
                        }
                    }
                    .accessibilityLabel(workspace.notifications.unreadCount > 0 ? "Notifications, \(workspace.notifications.unreadCount) unread" : "Notifications")

                    SidebarRow(item: .starred, isSelected: navigation.item == .starred) {
                        Image(systemName: "star")
                    } accessory: { EmptyView() }

                    SidebarRow(item: .scheduled, isSelected: navigation.item == .scheduled) {
                        Image(systemName: "calendar.badge.clock")
                    } accessory: {
                        if workspace.scheduled.queuedCount > 0 {
                            QuietCount(count: workspace.scheduled.queuedCount)
                        }
                    }

                    SidebarRow(item: .profile, isSelected: navigation.item == .profile) {
                        Image(systemName: "person")
                    } accessory: { EmptyView() }
                } header: {
                    SidebarSectionHeader(title: "You")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(contrast == .increased ? .hidden : .automatic)
            .background(contrast == .increased ? DS.Colors.sidebar : .clear)
            .hidesSystemSelection()
            .environment(\.defaultMinListRowHeight, DS.Metrics.sidebarRow)

            SidebarFooter()
        }
        .task { await workspace.scheduled.reload() }
        .toolbar {
            ToolbarItem {
                ComposeMenu()
            }
        }
    }

    /// Selection goes through the navigation; a remote also becomes the inbox's selection, which marks it read.
    private var selection: Binding<SidebarItem?> {
        Binding(get: { navigation.item }, set: { item in
            guard let item else { return }

            if NSEvent.modifierFlags.contains(.command) {
                openWindow(id: "item", value: item)
            } else {
                navigation.select(item)
            }
        })
    }

    // MARK: Remotes

    @ViewBuilder
    private var remotes: some View {
        if session.user?.remotes == nil {
            Button {
                settingsTab = "remotes"
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Text("Remotes are off")
                    .font(DS.Fonts.sidebarItem)
                    .foregroundStyle(DS.Colors.inkFaint)
            }
            .buttonStyle(.plain)
            .selectionDisabled()
        } else {
            ForEach(listedRemotes) { conversation in
                RemoteSidebarRow(conversation: conversation, isSelected: navigation.item == .remote(conversation.reference))
                    .contextMenu { remoteMenu(conversation) }
                    .onHover { $0 ? inbox.prefetch(conversation.reference) : inbox.cancelPrefetch(conversation.reference) }
                    .draggable(conversation.reference.id)
                    .dropDestination(for: String.self) { ids, _ in pinByDrop(ids, onto: conversation) }
            }

            SidebarRow(item: .allRemotes, isSelected: navigation.item == .allRemotes) {
                Image(systemName: "ellipsis.bubble")
            } accessory: {
                if unreadElsewhere > 0 {
                    CountBadge(count: unreadElsewhere)
                }
            }
            .accessibilityLabel(unreadElsewhere > 0 ? "All Remotes, \(unreadElsewhere) unread" : "All Remotes")

            SidebarRow(item: .stashed, isSelected: navigation.item == .stashed) {
                Image(systemName: "archivebox")
            } accessory: {
                if inbox.stashedCount > 0 {
                    QuietCount(count: inbox.stashedCount)
                }
            }
        }
    }

    /// Pinned remotes first, by their latest message, then the most recent ones up to seven rows, then any fetched
    /// request, which always shows.
    private var listedRemotes: [ConversationSummary] {
        let open = inbox.sidebarOpen
        let pinned = open.filter(\.isPinned).sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        let recent = open.filter { !$0.isPinned }.prefix(max(0, 7 - pinned.count))

        return Array(pinned.prefix(7)) + recent + inbox.requests
    }

    /// Unread remotes the sidebar doesn't list, for the All Remotes badge.
    private var unreadElsewhere: Int {
        let listed = Set(listedRemotes.map(\.id))

        return inbox.sidebarOpen.filter { !listed.contains($0.id) && !$0.isMuted }.map(\.ahead).reduce(0, +)
    }

    /// Dropping a remote onto a pinned one pins it; dropping a pinned one onto an unpinned one unpins it.
    private func pinByDrop(_ ids: [String], onto target: ConversationSummary) -> Bool {
        guard let id = ids.first, let dragged = inbox.sidebarOpen.first(where: { $0.reference.id == id }), dragged.id != target.id else { return false }

        if dragged.isPinned != target.isPinned {
            Task { await inbox.setPinned(target.isPinned, dragged.reference) }
        }

        return true
    }

    @ViewBuilder
    private func remoteMenu(_ conversation: ConversationSummary) -> some View {
        Button("Open in New Window") { openWindow(id: "item", value: SidebarItem.remote(conversation.reference)) }

        Divider()

        ConversationMenu(conversation: conversation)

        Divider()

        Button("Show Info") {
            navigation.select(.remote(conversation.reference))
            navigation.pane = .info
            navigation.isPaneVisible = true
        }

        if let partner = conversation.partner {
            Divider()

            Button("Block @\(partner.handle)…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "Block @\(partner.handle)?"
                alert.informativeText = "They won't be able to push to you or see your commits. You can unblock them from their profile."
                alert.addButton(withTitle: "Block").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    Task { await inbox.block(partner) }
                }
            }
        }
    }
}

/// "/dev/null ▾" and the handle: the workspace menu.
struct WorkspaceHeader: View {
    @Environment(Session.self) private var session
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settings-tab") private var settingsTab = "general"

    var body: some View {
        Menu {
            Button("Your Profile") { NotificationCenter.default.post(name: .openProfile, object: session.user?.handle) }
            Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            #if !APP_STORE
                Button("Check for Updates…") { Updates.shared.checkFromMenu() }
            #endif

            Divider()

            Button("Open /dev/null on the Web") { NSWorkspace.shared.open(APIClient.baseURL) }
            Button("Manage Devices…") {
                settingsTab = "devices"
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            if workspace.settings?.isAdmin == true {
                Divider()

                Button("Moderation on dev-null.sh ↗") { NSWorkspace.shared.open(APIClient.baseURL.appending(path: "moderation")) }
                Button("Operations on dev-null.sh ↗") { NSWorkspace.shared.open(APIClient.baseURL.appending(path: "operations")) }
            }

            Divider()

            Button("Sign Out") { session.signOut() }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text("/dev/null")
                    .font(DS.Fonts.workspace)
                    .tracking(-0.5)
                    .foregroundStyle(DS.Colors.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Colors.inkMuted)
                Spacer(minLength: DS.Spacing.m)
                Text("@" + (session.user?.handle ?? ""))
                    .font(DS.Fonts.monoHandle)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Workspace menu, signed in as @\(session.user?.handle ?? "")")
    }
}

struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DS.Fonts.sidebarSection)
            .foregroundStyle(DS.Colors.inkFaint)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A log's count of new commits: a muted mono number, never a badge.
struct QuietCount: View {
    @Environment(\.backgroundProminence) private var prominence
    let count: Int

    var body: some View {
        Text(count > DS.Metrics.badgeCap ? "\(DS.Metrics.badgeCap)+" : String(count))
            .font(DS.Fonts.monoCaption)
            .foregroundStyle(prominence == .increased ? DS.Colors.onPrimary.opacity(0.8) : DS.Colors.inkFaint)
            .frame(minWidth: DS.Metrics.badgeHeight, alignment: .trailing)
            .fixedSize()
    }
}

/// A 28pt sidebar row: a 16pt glyph or an 18pt avatar, the label (semibold while unread) and a trailing accessory.
struct SidebarRow<Glyph: View, Accessory: View>: View {
    @Environment(\.backgroundProminence) private var prominence
    let item: SidebarItem
    let isSelected: Bool
    var isUnread = false
    var title: String? = nil
    @ViewBuilder var glyph: () -> Glyph
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Content(item: item, title: title ?? item.title, isUnread: isUnread, glyph: glyph, accessory: accessory)
            .sidebarSelection(isSelected)
            .tag(item)
    }

    private struct Content: View {
        @Environment(\.backgroundProminence) private var prominence
        let item: SidebarItem
        let title: String
        let isUnread: Bool
        let glyph: () -> Glyph
        let accessory: () -> Accessory

        var body: some View {
            let selected = prominence == .increased

            HStack(spacing: DS.Spacing.m) {
                glyph()
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? DS.Colors.onPrimary : DS.Colors.inkMuted)
                    .frame(width: DS.Metrics.sidebarAvatar, height: DS.Metrics.sidebarAvatar)

                Text(title)
                    .font(isUnread ? DS.Fonts.sidebarItemUnread : DS.Fonts.sidebarItem)
                    .foregroundStyle(selected ? DS.Colors.onPrimary : DS.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: DS.Spacing.xs)

                accessory()
            }
            .frame(height: DS.Metrics.sidebarRow)
            .contentShape(Rectangle())
        }
    }
}

/// A remote or org in the sidebar: its avatar, its name, and the unread badge, the pin, the muted bell, or the
/// `fetched` chip for a request.
struct RemoteSidebarRow: View {
    @Environment(Session.self) private var session
    let conversation: ConversationSummary
    let isSelected: Bool

    var body: some View {
        SidebarRow(item: .remote(conversation.reference), isSelected: isSelected, isUnread: conversation.ahead > 0 && !conversation.isMuted, title: title) {
            if conversation.isOrg {
                OrgAvatar(members: (conversation.members ?? []).map(\.user).filter { $0.id != session.user?.id }, size: DS.Metrics.sidebarAvatar)
            } else {
                Avatar(user: conversation.partner, size: DS.Metrics.sidebarAvatar)
            }
        } accessory: {
            if isRequest {
                Text("fetched")
                    .font(DS.Fonts.monoMeta)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .padding(.horizontal, DS.Spacing.xs + 1)
                    .padding(.vertical, 1)
                    .background(DS.Colors.wash, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            } else if conversation.ahead > 0 {
                CountBadge(count: conversation.ahead, muted: conversation.isMuted)
            } else if conversation.isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.inkFaint)
            } else if conversation.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .rotationEffect(.degrees(45))
                    .foregroundStyle(DS.Colors.inkFaint)
            }
        }
        .help(conversation.partner.map { "\(title) · @\($0.handle)" } ?? title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, conversation.ahead > 0 ? "\(conversation.ahead) unread" : nil, conversation.isPinned ? "pinned" : nil, conversation.isMuted ? "muted" : nil, isRequest ? "fetched request" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var title: String { conversation.title(excluding: session.user?.id) }
    private var isRequest: Bool { inbox.requests.contains { $0.id == conversation.id } }

    @Environment(Inbox.self) private var inbox
}

/// The signed-in person, whether polling works, and Settings.
struct SidebarFooter: View {
    @Environment(Session.self) private var session
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Avatar(user: session.user?.asUser, size: 24)
                .laneRing(session.user?.asUser, width: 1.5, gap: 1.5)

            VStack(alignment: .leading, spacing: 0) {
                Text(session.user?.name ?? session.user?.handle ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Text(workspace.isOffline ? "fatal: offline · retrying" : "polling · 30s")
                    .font(DS.Fonts.monoMeta)
                    .foregroundStyle(workspace.isOffline ? DS.Colors.destructive : DS.Colors.inkFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, DS.Spacing.l)
        .frame(height: 44)
        .overlay(alignment: .top) { DS.Colors.hairline.frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

/// The Compose toolbar button: a new commit, a new remote or a new org.
struct ComposeMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button("New Commit…") { openWindow(id: "composer") }
                .keyboardShortcut("n")
            Button("New Remote…") { NotificationCenter.default.post(name: .newRemote, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Org…") { NotificationCenter.default.post(name: .newOrg, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
        } label: {
            Label("Compose", systemImage: "square.and.pencil")
        }
        .help("New Commit, Remote or Org")
    }
}

extension View {
    /// A ring in the person's lane, offset from the avatar by `gap` so the surface shows between them. Only for the
    /// profile header, the replies pane's commit, the user preview and the footer, never in lists.
    func laneRing(_ user: User?, width: CGFloat = 2, gap: CGFloat = 2) -> some View {
        padding(gap)
            .overlay(Circle().strokeBorder(LaneColor.of(user), lineWidth: width))
    }
}
