import AppKit
import SwiftUI

/// The actions on a commit, shared by the Commit menu, the keyboard, the row's menu and its buttons.
enum CommitCommand: String {
    case reply
    case quote
    case star
    case showReplies
    case openPage
    case openWindow
    case copyLink
    case share
    case pastel
    case translate
    case pin
    case report
    case delete
    case mute
    case block
    case preview

    @MainActor
    static func perform(_ command: CommitCommand, on id: String, workspace: Workspace, navigation: Navigation?, actions: WorkspaceActions?, openWindow: OpenWindowAction? = nil) {
        guard let box = workspace.existingBox(id) else { return }

        let commit = box.commit
        let isOwn = commit.author?.id == workspace.session.user?.id

        switch command {
        case .reply:
            navigation?.openThread(id, focusComposer: true)
        case .quote:
            workspace.drafts.quote.quotedCommitId = id
            openWindow?(id: "composer")
        case .star:
            workspace.toggleStar(id)
        case .showReplies:
            navigation?.toggleThread(id)
        case .openPage:
            navigation?.push(.commit(id))
        case .openWindow:
            actions?.openCommitWindow(id)
        case .copyLink:
            workspace.copyLink(id)
        case .share:
            guard canShare(commit, workspace: workspace) else { return }
            NotificationCenter.default.post(name: .shareCommit, object: id)
        case .pastel:
            workspace.givePastel(id)
        case .translate:
            guard !isOwn else { return }
            workspace.translate(id)
        case .pin:
            guard isOwn else { return }
            workspace.setPinned(commit.isPinned != true, id)
        case .report:
            guard !isOwn else { return }
            NotificationCenter.default.post(name: .reportCommit, object: id)
        case .delete:
            guard isOwn else { return }
            if Confirmations.confirm("Delete this commit?", "Commits are never edited. You can undo for 30 seconds, then it's gone.", action: "Delete") {
                workspace.delete(id)
                if navigation?.selectedCommit == id { navigation?.closePane() }
            }
        case .mute:
            if let author = commit.author { workspace.setMuted(true, author) }
        case .block:
            if let author = commit.author, Confirmations.confirm("Block @\(author.handle)?", "They won't see your commits or push to you, and you won't see theirs. You can unblock them in Settings → Privacy.", action: "Block") {
                workspace.block(author)
            }
        case .preview:
            NotificationCenter.default.post(name: .showUserPreview, object: id)
        }
    }
}

extension Notification.Name {
    static let showUserPreview = Notification.Name("devnull.showUserPreview")
    static let findInList = Notification.Name("devnull.findInList")
    static let focusComposer = Notification.Name("devnull.focusComposer")
    static let reloadDestination = Notification.Name("devnull.reloadDestination")
    static let shareCommit = Notification.Name("devnull.shareCommit")
    static let reportCommit = Notification.Name("devnull.reportCommit")
}

extension CommitCommand {
    /// An approved commit can be sent to someone in Remotes, as a link, by anyone who has remotes.
    @MainActor static func canShare(_ commit: Commit, workspace: Workspace) -> Bool {
        commit.status == .approved && workspace.session.user?.remotes != nil
    }
}

/// The confirmations that guard destruction, as native alerts.
@MainActor
enum Confirmations {
    static func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The order of the sidebar, for ⌥↑ / ⌥↓ and ⌃Tab.
@MainActor
enum SidebarOrder {
    static func remotes(_ inbox: Inbox) -> [ConversationSummary] {
        let pinned = inbox.sidebarOpen.filter(\.isPinned).sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        let recent = inbox.sidebarOpen.filter { !$0.isPinned }.prefix(max(0, 7 - pinned.count))

        return Array(pinned.prefix(7)) + recent + inbox.requests
    }

    static func items(_ session: Session) -> [SidebarItem] {
        var items = LogKind.allCases.map(SidebarItem.log)

        if let inbox = session.inbox, session.user?.remotes != nil {
            items += remotes(inbox).map { .remote($0.reference) } + [.allRemotes, .stashed]
        }

        return items + [.notifications, .starred, .scheduled, .profile]
    }

    static func isUnread(_ item: SidebarItem, _ session: Session) -> Bool {
        switch item {
        case let .log(kind): (session.workspace?.log(kind).newCount ?? 0) > 0
        case let .remote(reference): session.inbox?.sidebarOpen.first { $0.reference == reference }.map { $0.ahead > 0 } ?? false
        case .notifications: (session.workspace?.notifications.unreadCount ?? 0) > 0
        default: false
        }
    }

    static func move(_ navigation: Navigation, by offset: Int, unreadOnly: Bool, session: Session) {
        let items = items(session)
        let start = navigation.item.flatMap { items.firstIndex(of: $0) } ?? -1
        var index = start

        for _ in items.indices {
            index += offset

            if unreadOnly {
                index = (index + items.count) % items.count
            } else if !items.indices.contains(index) {
                return
            }

            if !unreadOnly || isUnread(items[index], session) {
                navigation.select(items[index])
                return
            }
        }
    }
}

struct AppCommands: Commands {
    let session: Session

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.navigation) private var navigation
    @FocusedValue(\.workspaceActions) private var actions

    var body: some Commands {
        let _ = AppDelegate.openMainWindow = { [openWindow] in openWindow(id: "main") }

        CommandGroup(replacing: .appInfo) {
            Button("About /dev/null") { AboutWindow.show() }
            #if !APP_STORE
                Button(Updates.shared.isInstalling ? "Updating…" : Updates.shared.available.map { "Update to /dev/null \($0.version)…" } ?? "Check for Updates…") { Updates.shared.checkFromMenu() }
                    .disabled(Updates.shared.isInstalling)
            #endif
        }

        CommandGroup(replacing: .newItem) {
            Button("New Commit…") { openWindow(id: "composer") }
                .keyboardShortcut("n")
            Button("New Remote…") { NotificationCenter.default.post(name: .newRemote, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session.user?.remotes == nil)
            Button("New Org…") { NotificationCenter.default.post(name: .newOrg, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift, .option])
                .disabled(session.user?.remotes == nil)

            Divider()

            Button("Open in New Window") {
                if let route = navigation?.route, case let .commit(id) = route {
                    actions?.openCommitWindow(id)
                } else if let item = navigation?.item {
                    actions?.openItemWindow(item)
                }
            }
            .keyboardShortcut("o")
            .disabled(navigation?.item == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Find…") { NotificationCenter.default.post(name: .findInList, object: nil) }
                .keyboardShortcut("f")
            Button("Search…") { actions?.showSwitcher() }
                .keyboardShortcut("k")
        }

        CommandGroup(after: .sidebar) {
            Button("Show/Hide Replies Pane") { actions?.togglePane() }
                .keyboardShortcut("0", modifiers: [.command, .option])

            Divider()

            Button("Following") { navigation?.select(.following) }.keyboardShortcut("1")
            Button("Latest") { navigation?.select(.latest) }.keyboardShortcut("2")
            Button("Trending") { navigation?.select(.trending) }.keyboardShortcut("3")
            Button("Notifications") { navigation?.select(.notifications) }.keyboardShortcut("4")
            Button("Remotes") { navigation?.select(.allRemotes) }.keyboardShortcut("5")

            Divider()

            Button("Reload") { NotificationCenter.default.post(name: .reloadDestination, object: navigation) }
                .keyboardShortcut("r")
        }

        CommandMenu("Go") {
            Button("Back") { navigation?.back() }
                .keyboardShortcut("[")
                .disabled(navigation?.canGoBack != true)
            Button("Forward") { navigation?.forward() }
                .keyboardShortcut("]")
                .disabled(navigation?.canGoForward != true)

            Divider()

            Button("Previous Item") { navigation.map { SidebarOrder.move($0, by: -1, unreadOnly: false, session: session) } }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next Item") { navigation.map { SidebarOrder.move($0, by: 1, unreadOnly: false, session: session) } }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Next Unread") { navigation.map { SidebarOrder.move($0, by: 1, unreadOnly: true, session: session) } }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Previous Unread") { navigation.map { SidebarOrder.move($0, by: -1, unreadOnly: true, session: session) } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            Button("Your Profile") { navigation?.select(.profile) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Starred") { navigation?.select(.starred) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Scheduled") { navigation?.select(.scheduled) }
                .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Jump to Newest") { NotificationCenter.default.post(name: .scrollToBottom, object: nil) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }

        CommandMenu("Commit") {
            commitButton("Reply", .reply)
            commitButton("Quote…", .quote)
            commitButton(isStarred ? "Unstar" : "Star", .star)
            commitButton("Show Replies", .showReplies)
            commitButton("Open Commit Page", .openPage, key: .return, modifiers: [.command, .shift])
            commitButton("Copy Link", .copyLink)
            commitButton("Send in Remotes…", .share)
                .disabled(!(focusedCommit.flatMap { commit in session.workspace.map { CommitCommand.canShare(commit, workspace: $0) } } ?? false))

            Divider()

            if session.user?.pasteisMode == true {
                commitButton("Give a Pastel", .pastel)
            }
            commitButton("Translate", .translate)
                .disabled(isOwnFocused)
            commitButton(focusedCommit?.isPinned == true ? "Unpin from Profile" : "Pin to Profile", .pin)
                .disabled(!isOwnFocused || focusedCommit?.parentId != nil)
            commitButton("Report…", .report)
                .disabled(isOwnFocused || focusedCommit == nil)
            commitButton("Delete…", .delete, key: .delete, modifiers: .command)
                .disabled(!isOwnFocused)

            Divider()

            Button("Undo Delete") { session.workspace?.toasts.performAction() }
                .keyboardShortcut("z")
                .disabled(session.workspace?.toasts.current?.action == nil)
        }

        CommandMenu("Remote") {
            let conversation = currentConversation

            Button("Show Info") { NotificationCenter.default.post(name: .showInfo, object: nil) }
                .keyboardShortcut("i")
                .disabled(conversation == nil)
            Button(conversation?.isPinned == true ? "Unpin" : "Pin") {
                if let conversation { Task { await session.inbox?.setPinned(!conversation.isPinned, conversation.reference) } }
            }
            .disabled(conversation == nil)
            Menu("Mute") {
                ForEach(MuteDuration.allCases, id: \.self) { duration in
                    Button(duration.title) {
                        if let conversation { Task { await session.inbox?.mute(duration, conversation.reference) } }
                    }
                }
            }
            .disabled(conversation == nil)
            Button(conversation?.isArchived == true ? "Pop" : "Stash") {
                if let conversation { Task { await session.inbox?.setStashed(!conversation.isArchived, conversation.reference) } }
            }
            .keyboardShortcut("e")
            .disabled(conversation == nil)
            Button("Mark as Pulled") {
                if let conversation { Task { await session.inbox?.markRead(conversation) } }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(conversation == nil)

            Divider()

            Button("Block…") {
                if let partner = conversation?.partner, Confirmations.confirm("Block @\(partner.handle)?", "They won't be able to push to you or see your commits. You can unblock them from their profile.", action: "Block") {
                    Task { await session.inbox?.block(partner) }
                }
            }
            .disabled(conversation?.partner == nil)
        }

        CommandGroup(replacing: .help) {
            Button("/dev/null on the Web") { NSWorkspace.shared.open(APIClient.baseURL) }

            // Moderation and Operations stay on the web; admins get a way there.
            if session.workspace?.settings?.isAdmin == true {
                Button("Moderation on the Web") { NSWorkspace.shared.open(APIClient.baseURL.appending(path: "moderation")) }
                Button("Operations on the Web") { NSWorkspace.shared.open(APIClient.baseURL.appending(path: "operations")) }
            }
            Button("What's New") { NSWorkspace.shared.open(APIClient.baseURL.appending(path: "changelog")) }
            Button("Manage Devices…") {
                UserDefaults.standard.set("devices", forKey: "settings-tab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    private var focusedId: String? {
        navigation?.focusedRow ?? navigation?.selectedCommit ?? navigation?.route.flatMap { if case let .commit(id) = $0 { id } else { nil } }
    }

    private var focusedCommit: Commit? {
        focusedId.flatMap { session.workspace?.existingBox($0)?.commit }
    }

    private var isStarred: Bool { focusedCommit?.isStarred ?? false }
    private var isOwnFocused: Bool { focusedCommit?.author?.id == session.user?.id && focusedCommit != nil }

    private var currentConversation: ConversationSummary? {
        guard case let .remote(reference) = navigation?.item, let inbox = session.inbox else { return nil }

        return (inbox.sidebarOpen + inbox.conversations + inbox.requests).first { $0.reference == reference }
    }

    private func commitButton(_ title: String, _ command: CommitCommand, key: KeyEquivalent? = nil, modifiers: EventModifiers = []) -> some View {
        let button = Button(title) {
            guard let id = focusedId, let workspace = session.workspace else { return }
            CommitCommand.perform(command, on: id, workspace: workspace, navigation: navigation, actions: actions, openWindow: openWindow)
        }
        .disabled(focusedId == nil)

        return Group {
            if let key {
                button.keyboardShortcut(key, modifiers: modifiers)
            } else {
                button
            }
        }
    }
}
