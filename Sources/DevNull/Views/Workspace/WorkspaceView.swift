import SwiftUI

/// The window: the sidebar, the center showing the selected item or the page pushed over it, and the replies pane. An
/// item window ("Open in New Window") is the same without the sidebar.
struct WorkspaceView: View {
    @Environment(Session.self) private var session
    @Environment(Inbox.self) private var inbox
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var navigation: Navigation
    @State private var window = WindowReference()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var autoHidSidebar = false
    /// Too narrow for the center and the pane side by side: the pane floats over the center instead.
    @State private var paneOverlays = false
    @State private var showsNewRemote = false
    @State private var showsNewOrg = false
    @State private var sharing: CommitSheetItem?
    @State private var reporting: CommitSheetItem?
    @State private var showsSwitcher = false
    @State private var toolbarSearch = ""
    @State private var toolbarSearchFocused = false
    let showsSidebar: Bool

    init(item: SidebarItem? = .following, route: Route? = nil, showsSidebar: Bool = true) {
        let navigation = Navigation(item: item)
        if let route { navigation.path = [route] }
        _navigation = State(initialValue: navigation)
        self.showsSidebar = showsSidebar
    }

    var body: some View {
        Group {
            if showsSidebar {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    WorkspaceSidebar(navigation: navigation)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
                } detail: {
                    detail
                }
            } else {
                detail
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            guard let resized = note.object as? NSWindow, resized === window.window else { return }
            fit(resized.frame.width)
        }
        .onChange(of: navigation.isPaneVisible) { fit(window.window?.frame.width ?? 1240) }
        .background(WindowReader(reference: window))
        .focusedSceneValue(\.navigation, navigation)
        .focusedSceneValue(\.workspaceActions, actions)
        .environment(navigation)
        .environment(\.workspaceActions, actions)
        .environment(\.openURL, OpenURLAction { url in WorkspaceLink.handle(url, navigation: navigation, openProfile: openProfile) })
        .sheet(isPresented: $showsNewRemote) {
            PeoplePicker(mode: .remote) { users, _, _ in
                if let user = users.first { navigation.select(.remote(.direct(user))) }
            }
        }
        .sheet(item: $sharing) { shared in
            PeoplePicker(mode: .share) { users, _, _ in
                if let user = users.first { share(shared.id, with: user) }
            }
        }
        .sheet(item: $reporting) { reported in
            if let commit = workspace.existingBox(reported.id)?.commit { ReportSheet(commit: commit) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reportCommit)) { note in
            if window.isFrontmost, let id = note.object as? String { reporting = CommitSheetItem(id: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shareCommit)) { note in
            if window.isFrontmost, let id = note.object as? String { sharing = CommitSheetItem(id: id) }
        }
        .sheet(isPresented: $showsNewOrg) {
            PeoplePicker(mode: .newOrg) { users, name, _ in
                Task { await createOrg(users, name: name) }
            }
        }
        .onChange(of: navigation.item, initial: true) { _, item in syncInbox(item) }
        .onChange(of: inbox.selection) { _, selection in
            // A banner, Mark as Pulled or the last remote reopened on launch picks a remote for the frontmost window.
            guard window.isFrontmost, let selection, navigation.item != .remote(selection) else { return }
            navigation.item = .remote(selection)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object as? NSWindow === window.window else { return }
            syncInbox(navigation.item)
        }
        .onAppear(perform: openPendingConversation)
        .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { note in
            guard window.isFrontmost, let id = note.object as? String else { return }
            inbox.open(conversationId: id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newRemote)) { _ in if window.isFrontmost { showsNewRemote = true } }
        .onReceive(NotificationCenter.default.publisher(for: .newOrg)) { _ in if window.isFrontmost { showsNewOrg = true } }
        .onReceive(NotificationCenter.default.publisher(for: .showInfo)) { _ in
            guard window.isFrontmost, case .remote = navigation.item else { return }
            toggleInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProfile)) { note in
            guard window.isFrontmost, let handle = note.object as? String else { return }
            openProfile(handle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in if window.isFrontmost { showsSwitcher = true } }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .previewWorkspaceAction)) { note in
                guard window.isFrontmost || NSApp.keyWindow == nil, let command = note.object as? String else { return }
                previewAction(command)
            }
        #endif
    }

    // MARK: Columns

    private var detail: some View {
        // The pane is a column of the detail rather than an `.inspector`: the inspector's minimum width fights
        // AppKit's window constraints when the window shrinks with it open, which crashes the layout cycle.
        HStack(spacing: 0) {
            CenterView()
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { ToastView() }
                .overlay(alignment: .top) { CallBar() }

            if !paneOverlays, navigation.isPaneVisible, navigation.pane != nil {
                DS.Colors.hairline.frame(width: 1)
                RepliesPane()
                    .frame(width: 372)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                if paneOverlays, navigation.isPaneVisible, navigation.pane != nil {
                    RepliesPane()
                        .frame(width: 320)
                        .frame(maxHeight: .infinity)
                        .background(.background)
                        .overlay(alignment: .leading) { DS.Colors.hairline.frame(width: 1) }
                        .elevation(DS.Elevation.floating)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if showsSwitcher {
                    SwitcherPanel(isPresented: $showsSwitcher)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(DS.Motion.respecting(reduceMotion, DS.Motion.standard), value: showsSwitcher)
            .toolbar { toolbar }
            // The toolbar's search field is the way into the switcher: focusing it opens the switcher, which takes
            // the typing from there.
            .searchable(text: $toolbarSearch, isPresented: $toolbarSearchFocused, placement: .toolbar, prompt: "Search people, commits, remotes")
            .onChange(of: toolbarSearchFocused) { _, focused in
                guard focused else { return }
                toolbarSearchFocused = false
                showsSwitcher = true
            }

    }

    /// Hides the sidebar when the window can't fit it beside the center and an open pane, and brings it back once it
    /// can. A sidebar the user hid stays hidden.
    private func fit(_ width: CGFloat) {
        let overlays = width < 440 + 372 + 8
        if overlays != paneOverlays { paneOverlays = overlays }

        guard showsSidebar else { return }

        let needed = 248 + 440 + (navigation.isPaneVisible && !overlays ? 372 : 0)

        if width < CGFloat(needed), columnVisibility != .detailOnly {
            autoHidSidebar = columnVisibility != .detailOnly
            columnVisibility = .detailOnly
        } else if width >= CGFloat(needed), autoHidSidebar {
            autoHidSidebar = false
            columnVisibility = .all
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            HistoryButtons()

            if !isRemote {
                ToolbarTitle()
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                togglePane()
            } label: {
                Label("Replies Pane", systemImage: "sidebar.right")
            }
            .help("Show or Hide the Replies Pane (⌥⌘0)")
            .accessibilityLabel(navigation.isPaneVisible ? "Hide the replies pane" : "Show the replies pane")
        }
    }

    private var isRemote: Bool {
        guard navigation.route == nil, case .remote = navigation.item else { return false }

        return true
    }

    private var actions: WorkspaceActions {
        WorkspaceActions(
            togglePane: togglePane,
            showSwitcher: { showsSwitcher = true },
            openProfile: openProfile,
            openCommitWindow: { openWindow(id: "commit", value: $0) },
            openItemWindow: { openWindow(id: "item", value: $0) }
        )
    }

    private func togglePane() {
        if case .remote = navigation.item, navigation.route == nil {
            toggleInfo()
        } else {
            navigation.togglePane()
        }
    }

    private func toggleInfo() {
        if navigation.isPaneVisible, navigation.pane == .info {
            navigation.closePane()
        } else {
            navigation.pane = .info
            navigation.isPaneVisible = true
        }
    }

    private func openProfile(_ handle: String) {
        if handle.caseInsensitiveCompare(session.user?.handle ?? "") == .orderedSame, navigation.route == nil {
            navigation.select(.profile)
        } else {
            navigation.push(.profile(handle))
        }
    }

    // MARK: Remotes

    /// The inbox's selection follows the window in front, so the chat code, read receipts and banners keep working.
    private func syncInbox(_ item: SidebarItem?) {
        let remote: ThreadReference? = if case let .remote(reference) = item { reference } else { nil }

        if inbox.selection != remote { inbox.selection = remote }

        switch item {
        case .allRemotes where inbox.tab == .stashed: inbox.tab = .open
        case .stashed where inbox.tab != .stashed: inbox.tab = .stashed
        default: break
        }
    }

    private func openPendingConversation() {
        if let id = AppDelegate.pendingConversation {
            AppDelegate.pendingConversation = nil
            inbox.open(conversationId: id)
        }
    }

    /// Asks before sending, as the web does, then pushes the commit's link to them and opens the remote.
    private func share(_ id: String, with user: User) {
        guard let commit = workspace.existingBox(id)?.commit else { return }

        // The picker's sheet closes first, so the confirmation isn't stacked on it.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Send commit to @\(user.handle)?"
            alert.informativeText = "Send a link to this commit in Remotes."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let reference = ThreadReference.direct(user)
            inbox.thread(for: reference).send(commit.webURL.absoluteString)
            navigation.select(.remote(reference))
        }
    }

    private func createOrg(_ users: [User], name: String) async {
        struct Created: Decodable { struct Org: Decodable { let id: String }; let org: Org }

        do {
            let created: Created = try await inbox.api.send("POST", "remotes/orgs", json: [
                "name": name.isEmpty ? NSNull() : name,
                "members": users.map(\.handle),
            ])

            await inbox.refresh()
            navigation.select(.remote(.org(id: created.org.id, name: name.isEmpty ? nil : name)))
        } catch {
            presentAlert(error.localizedDescription)
        }
    }

    #if DEBUG
        private func previewAction(_ command: String) {
            let (name, argument) = command.firstIndex(of: ":").map { (String(command[..<$0]), String(command[command.index(after: $0)...])) } ?? (command, "")
            let commits = workspace.log(.following).commits
            let firstCommit = argument == "replied" ? commits.first { $0.commit.replies > 0 }?.id : commits.first?.id

            switch name {
            case "item":
                let items: [String: SidebarItem] = ["following": .following, "latest": .latest, "trending": .trending, "remotes": .allRemotes, "stashed": .stashed, "notifications": .notifications, "starred": .starred, "scheduled": .scheduled, "profile": .profile]
                if let item = items[argument] { navigation.select(item) }
            case "thread":
                if let id = ["first", "replied", ""].contains(argument) ? firstCommit : argument { navigation.openThread(id) }
            case "commit":
                if let id = ["first", "replied", ""].contains(argument) ? firstCommit : argument { navigation.push(.commit(id)) }
            case "profile":
                openProfile(argument.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
            case "results":
                navigation.push(.search(argument))
            case "switcher":
                showsSwitcher = argument != "off"
            case "composer":
                openWindow(id: "composer")
            case "settings":
                UserDefaults.standard.set(argument.isEmpty ? "general" : argument, forKey: "settings-tab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            case "pane":
                togglePane()
            case "back":
                navigation.back()
            case "compose":
                workspace.drafts.commit.body = argument
            case "rm":
                // Deletes the user's newest commit in Following, skipping the confirmation alert.
                if let own = workspace.log(.following).commits.first(where: { $0.commit.author?.id == session.user?.id }) { workspace.delete(own.id) }
            case "undo":
                workspace.toasts.performAction()
            default:
                break
            }
        }
    #endif
}

// MARK: - Center

/// What the center shows: the page on top of the history, or the sidebar item's destination.
struct CenterView: View {
    @Environment(Navigation.self) private var navigation
    @Environment(Inbox.self) private var inbox

    var body: some View {
        Group {
            if let route = navigation.route {
                switch route {
                case let .profile(handle): ProfileView(handle: handle)
                case let .commit(id): CommitPageView(commitId: id)
                case let .search(query): SearchResultsView(query: query)
                case let .followers(handle): PeopleListView(handle: handle, followers: true)
                case let .following(handle): PeopleListView(handle: handle, followers: false)
                }
            } else {
                switch navigation.item {
                case let .log(kind): LogView(kind: kind, anchor: navigation.logAnchors[kind])
                case let .remote(reference): ChatView(thread: inbox.thread(for: reference)).id(reference.id)
                case .allRemotes, .stashed: AllRemotesView(selection: remoteSelection)
                case .notifications: NotificationsView()
                case .starred: StarredView()
                case .scheduled: ScheduledView()
                case .profile: OwnProfileView()
                case nil: EmptyChatView(showsNewRemote: .constant(false))
                }
            }
        }
        .id(navigation.route.map { "\($0)" } ?? navigation.item?.id ?? "none")
        .transition(.opacity)
    }

    /// Picking a row in All Remotes opens its chat in place.
    private var remoteSelection: Binding<ThreadReference?> {
        Binding(get: { nil }, set: { reference in
            if let reference { navigation.select(.remote(reference)) }
        })
    }
}

/// Back and Forward, with the history menu on a long press.
struct HistoryButtons: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        HStack(spacing: 0) {
            Button {
                navigation.back()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!navigation.canGoBack)
            .opacity(navigation.canGoBack ? 1 : 0.4)
            .help("Back (⌘[)")
            .contextMenu {
                ForEach(Array(navigation.path.dropLast().enumerated().reversed()), id: \.offset) { index, route in
                    Button(route.title) { while navigation.path.count > index + 1 { navigation.back() } }
                }
                Button(navigation.item?.title ?? "Start") { while navigation.canGoBack { navigation.back() } }
            }

            Button {
                navigation.forward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!navigation.canGoForward)
            .opacity(navigation.canGoForward ? 1 : 0.4)
            .help("Forward (⌘])")
        }
    }
}

/// The 13.5pt title with its symbol over the mono subtitle each destination defines.
struct ToolbarTitle: View {
    @Environment(Navigation.self) private var navigation
    @Environment(Workspace.self) private var workspace
    @Environment(Inbox.self) private var inbox
    @Environment(Session.self) private var session

    var body: some View {
        let (title, symbol, subtitle) = content

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.xs + 1) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.inkMuted)
                }
                Text(title)
                    .font(DS.Fonts.toolbarTitle)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(DS.Fonts.monoMeta)
                .foregroundStyle(DS.Colors.inkMuted)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 140, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var content: (String, String?, String) {
        if let route = navigation.route {
            switch route {
            case let .profile(handle):
                return (workspace.profile(handle).profile?.user.displayName ?? "@" + handle, nil, "@" + handle)
            case let .commit(id):
                return ("Commit", "point.3.connected.trianglepath.dotted", workspace.existingBox(id)?.commit.hash ?? String(id.replacingOccurrences(of: "-", with: "").suffix(7)))
            case let .search(query):
                let count = workspace.search.resultsQuery == query ? workspace.search.results.count : 0
                return ("“\(query)”", "magnifyingglass", "commits by meaning · \(count) result\(count == 1 ? "" : "s")")
            case let .followers(handle):
                return ("Followers", "person.2", "@" + handle)
            case let .following(handle):
                return ("Following", "person.2", "@" + handle)
            }
        }

        switch navigation.item {
        case let .log(kind):
            let store = workspace.log(kind)
            let subtitle: String = switch kind {
            case .following: store.newCount > 0 ? "log · \(store.newCount) new since HEAD@{last visit}" : "log · up to date"
            case .latest: "log · polled " + Formatting.relative(store.polledAt).replacingOccurrences(of: "now", with: "just now") + (store.polledAt.map { Date.now.timeIntervalSince($0) < 60 ? "" : " ago" } ?? "")
            case .trending: "log · last 7 days"
            }
            return (kind.title, kind.symbol, subtitle)
        case .allRemotes, .stashed:
            return (navigation.item == .stashed ? "Stashed" : "Remotes", "bubble.left.and.bubble.right", "\(inbox.unreadCount) unread · \(inbox.requestsCount) fetched")
        case .notifications:
            return ("Notifications", "bell", "\(workspace.notifications.unreadCount) unread")
        case .starred:
            return ("Starred", "star", "\(workspace.starred.ids.count) commits")
        case .scheduled:
            return ("Scheduled", "calendar.badge.clock", "\(workspace.scheduled.queuedCount) queued")
        case .profile:
            return (session.user?.displayName ?? "Profile", nil, "@" + (session.user?.handle ?? ""))
        case .remote, nil:
            return ("", nil, "")
        }
    }
}

extension Route {
    var title: String {
        switch self {
        case let .profile(handle): "@" + handle
        case .commit: "Commit"
        case let .search(query): "“\(query)”"
        case let .followers(handle): "Followers of @\(handle)"
        case let .following(handle): "Followed by @\(handle)"
        }
    }
}

extension CurrentUser {
    var displayName: String { asUser.displayName }
}

// MARK: - Windows and focus

/// The window a view lives in, so app-wide notifications only act on the frontmost one.
final class WindowReference {
    weak var window: NSWindow?

    var isFrontmost: Bool {
        guard let window else { return false }

        return window.isKeyWindow || NSApp.keyWindow == nil || !(NSApp.keyWindow?.isMainWindow ?? true) && window.isMainWindow
    }
}

struct WindowReader: NSViewRepresentable {
    let reference: WindowReference

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { reference.window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if reference.window == nil {
            DispatchQueue.main.async { reference.window = view.window }
        }
    }
}

/// What the menu bar can ask of the frontmost workspace window.
struct WorkspaceActions {
    let togglePane: () -> Void
    let showSwitcher: () -> Void
    let openProfile: (String) -> Void
    let openCommitWindow: (String) -> Void
    let openItemWindow: (SidebarItem) -> Void
}

struct NavigationFocusKey: FocusedValueKey {
    typealias Value = Navigation
}

struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var navigation: Navigation? {
        get { self[NavigationFocusKey.self] }
        set { self[NavigationFocusKey.self] = newValue }
    }

    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

extension Notification.Name {
    static let openProfile = Notification.Name("devnull.openProfile")
}

/// A key cap, as the web draws shortcuts: a bordered mono label.
struct Kbd: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DS.Fonts.monoMeta)
            .foregroundStyle(DS.Colors.inkMuted)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 16)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).strokeBorder(DS.Colors.rail))
            .fixedSize()
    }
}

/// The commit a sheet acts on: sending its link in Remotes, or reporting it.
struct CommitSheetItem: Identifiable {
    let id: String
}
