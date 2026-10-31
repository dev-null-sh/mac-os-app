import AppKit
import Foundation
import Observation
import UserNotifications

/// The conversation list, polled like the web's inbox: often while the app is in front, rarely behind other windows.
/// It also keeps the Dock badge at the unread count and posts a notification when someone writes in a remote that
/// isn't muted and isn't the one being read.
@MainActor
@Observable
final class Inbox {
    let session: Session
    let api: APIClient

    var tab: InboxTab = .open {
        didSet { reload() }
    }

    var search = "" {
        didSet { scheduleSearch() }
    }

    var selection: ThreadReference? {
        didSet {
            if let selection { openedReference = selection }
            Preferences.lastConversation = selection?.id
        }
    }

    private(set) var conversations: [ConversationSummary] = []
    private(set) var hasMore = false
    private(set) var unreadCount = 0
    private(set) var requestsCount = 0
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    var error: String?

    /// The Open tab as the sidebar lists it, whichever tab or search All Remotes shows.
    private(set) var sidebarOpen: [ConversationSummary] = []
    /// Fetched requests, which the sidebar always lists, and how many remotes are stashed.
    private(set) var requests: [ConversationSummary] = []
    private(set) var stashedCount = 0
    @ObservationIgnored private var extrasAt = Date.distantPast
    /// The requests count the fetched tab was last loaded for; a new request reloads it at once.
    @ObservationIgnored private var extrasRequestsCount: Int?
    @ObservationIgnored private var sidebarAt = Date.distantPast

    /// Threads stay loaded while the app runs, so switching back to one is instant.
    @ObservationIgnored private var threads: [String: ThreadModel] = [:]
    @ObservationIgnored private var lastSeenIncoming: [String: Int] = [:]
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var readLocally: [String: Int] = [:]
    @ObservationIgnored private var openedReference: ThreadReference?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var hovered: ThreadReference?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restored = false

    init(session: Session, api: APIClient) {
        self.session = session
        self.api = api

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        reload()
        startPolling()

        Task { await loadReactionUsage() }

        // Replies typed and "Mark as Pulled" clicked in banners.
        NotificationCenter.default.addObserver(forName: .replyFromBanner, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String, let text = note.userInfo?["text"] as? String else { return }
            MainActor.assumeIsolated { self?.reply(conversationId: id, text: text) }
        }

        NotificationCenter.default.addObserver(forName: .markReadFromBanner, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            MainActor.assumeIsolated { self?.markRead(conversationId: id) }
        }
    }

    /// The emoji this user reacts with most, as the server counts them across devices, for the quick reactions.
    private func loadReactionUsage() async {
        struct Usage: Decodable {
            struct Entry: Decodable { let emoji: String; let count: Int }
            let usage: [Entry]
        }

        if let response: Usage = try? await api.get("remotes/reactions") {
            Reactions.serverUsage = response.usage.sorted { $0.count > $1.count }.map(\.emoji)
        }
    }

    func thread(for reference: ThreadReference) -> ThreadModel {
        if let existing = threads[reference.id] {
            return existing
        }

        let model = ThreadModel(reference: reference, inbox: self)
        threads[reference.id] = model

        return model
    }

    func stop() {
        poller?.cancel()
        prefetchTask?.cancel()
        hoverTask?.cancel()
        threads.values.forEach { $0.stop() }
    }

    // MARK: - Loading

    func reload() {
        generation += 1
        isLoading = conversations.isEmpty
        Task { await refresh(replacing: true) }
    }

    func refresh(replacing: Bool = false) async {
        let generation = generation

        do {
            let page: InboxPage = try await api.get("remotes", query: ["tab": tab.rawValue, "q": search.isEmpty ? nil : search])

            guard generation == self.generation else { return }

            notifyAboutNewMessages(in: page.data)

            // A poll that left before the user read a thread still counts it unread: what was read here wins.
            let received = page.data.map { conversation in
                (conversation.lastIncomingMessageId ?? 0) <= (readLocally[conversation.reference.id] ?? -1) ? conversation.with(ahead: 0) : conversation
            }
            let unread = max(0, page.unreadCount - zip(page.data, received).map { $0.ahead - $1.ahead }.reduce(0, +))

            // Keep the pages loaded further down, refreshing the ones the poll brought back.
            let fresh = Set(received.map(\.id))
            let next = replacing ? received : received + conversations.dropFirst(received.count).filter { !fresh.contains($0.id) }

            // Only what changed is assigned, so a quiet poll doesn't redraw the list.
            if next != conversations { conversations = next }
            if replacing || conversations.count <= page.data.count, hasMore != page.hasMore { hasMore = page.hasMore }
            if unreadCount != unread { unreadCount = unread }
            if requestsCount != page.requestsCount { requestsCount = page.requestsCount }
            if error != nil { error = nil }
            session.workspace?.updateDockBadge()

            if tab == .open, search.isEmpty {
                if sidebarOpen != conversations { sidebarOpen = conversations }
            } else if replacing || Date.now.timeIntervalSince(sidebarAt) > 30, let open: InboxPage = try? await api.get("remotes", query: ["tab": InboxTab.open.rawValue]) {
                // The sidebar's open remotes while another tab or a search is showing, on the extras' cadence.
                sidebarAt = .now
                if open.data != sidebarOpen { sidebarOpen = open.data }
            }

            await refreshExtras(force: replacing)

            if replacing { prefetch() }
            restoreLastConversation()
        } catch let error as APIError where error.requiresSignIn {
            session.expire(error)
        } catch let error as APIError where error.status == 404 {
            // Remotes are turned off for this account.
            conversations = []
            self.error = "Remotes are turned off. Turn them on in Settings to push and pull messages."
        } catch {
            if conversations.isEmpty {
                self.error = error.localizedDescription
            }
        }

        if isLoading { isLoading = false }
    }

    /// The fetched and stashed tabs, for the sidebar's request rows and Stashed count: every 30 seconds, or at once when
    /// the requests count changed.
    private func refreshExtras(force: Bool) async {
        guard force || Date.now.timeIntervalSince(extrasAt) > 30 || extrasRequestsCount != requestsCount else { return }

        extrasAt = .now
        extrasRequestsCount = requestsCount

        if let fetched: InboxPage = try? await api.get("remotes", query: ["tab": InboxTab.fetched.rawValue]), fetched.data != requests {
            requests = fetched.data
        }

        if let stashed: InboxPage = try? await api.get("remotes", query: ["tab": InboxTab.stashed.rawValue]), stashed.data.count != stashedCount {
            stashedCount = stashed.data.count
        }
    }

    /// Opens the conversation that was open when the app last quit, once the inbox lists it.
    private func restoreLastConversation() {
        guard !restored else { return }

        restored = true

        if selection == nil, let id = Preferences.lastConversation, let conversation = conversations.first(where: { $0.reference.id == id }) {
            selection = conversation.reference
        }
    }

    /// The thread already loaded for a conversation, if any, without loading it.
    func loadedThread(_ reference: ThreadReference) -> ThreadModel? {
        threads[reference.id]
    }

    /// What the user started writing in a conversation and left there, which the inbox shows as a draft.
    func draft(for reference: ThreadReference) -> String? {
        guard selection?.id != reference.id, let draft = threads[reference.id]?.draft.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else {
            return nil
        }

        return draft
    }

    /// Shows a message the thread just sent or received as the conversation's last one right away, moving it to the
    /// top of its group, before the next poll confirms it.
    /// `alerted` says the thread already chimed for the message. A thread that took it in without chiming, such as one
    /// loaded earlier and no longer on screen, leaves the alert to the inbox.
    func showLocally(_ message: Message, in reference: ThreadReference, alerted: Bool) {
        guard let index = conversations.firstIndex(where: { $0.reference.id == reference.id }) else { return }

        let current = conversations[index]

        guard (current.lastMessage?.id ?? 0) < message.id else { return }

        let incoming = message.userId != session.user?.id && (!message.isEvent || message.isPing)
        let updated = ConversationSummary(id: current.id, kind: current.kind, name: current.name, partner: current.partner, members: current.members, lastMessage: message, lastMessageAt: message.createdAt, ahead: current.ahead, lastIncomingMessageId: incoming ? message.id : current.lastIncomingMessageId, lastIncomingSender: current.lastIncomingSender, partnerReadThroughId: current.partnerReadThroughId, partnerReadAt: current.partnerReadAt, isArchived: current.isArchived, pinnedAt: current.pinnedAt, mutedUntilAt: current.mutedUntilAt)

        // Pinned conversations keep the order they were pinned in; the others move up to the first unpinned place.
        var next = conversations
        next.remove(at: index)
        next.insert(updated, at: current.isPinned ? index : next.firstIndex { !$0.isPinned } ?? next.count)

        if incoming, alerted { lastSeenIncoming[current.id] = max(lastSeenIncoming[current.id] ?? 0, message.id) }
        conversations = next
    }

    /// Loads the threads at the top of the inbox in the background, one after another, so opening one is instant.
    private func prefetch() {
        let references = conversations.prefix(5).map(\.reference)

        // Switching tabs again drops the previous tab's run instead of running both.
        prefetchTask?.cancel()
        prefetchTask = Task {
            for reference in references {
                guard !Task.isCancelled else { return }
                await thread(for: reference).prefetch()
            }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let last = conversations.last else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        if let page: InboxPage = try? await api.get("remotes", query: ["tab": tab.rawValue, "q": search.isEmpty ? nil : search, "before": last.id]) {
            let known = Set(conversations.map(\.id))
            conversations += page.data.filter { !known.contains($0.id) }
            hasMore = page.hasMore
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private func startPolling() {
        poller = Task { [weak self] in
            var refreshedAt = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                // Behind other windows, once a minute; back in front, within one tick.
                guard NSApp.isActive || Date.now.timeIntervalSince(refreshedAt) >= 60 else { continue }
                await self.refresh()
                refreshedAt = .now
            }
        }
    }

    // MARK: - Notifications

    private func notifyAboutNewMessages(in page: [ConversationSummary]) {
        defer {
            primed = true

            for conversation in page {
                if let id = conversation.lastIncomingMessageId {
                    lastSeenIncoming[conversation.id] = max(lastSeenIncoming[conversation.id] ?? 0, id)
                }
            }
        }

        // The first load only learns where everyone is: what was unread before the app opened doesn't alert.
        guard primed, Preferences.notificationsEnabled || Preferences.soundEnabled else { return }

        for conversation in page {
            guard let id = conversation.lastIncomingMessageId,
                  let seen = lastSeenIncoming[conversation.id] ?? (conversation.ahead > 0 ? 0 : nil),
                  id > seen,
                  conversation.ahead > 0,
                  !conversation.isMuted,
                  !isReading(conversation),
                  // A call rings on its own; the lines it leaves in the history aren't messages to alert about.
                  conversation.lastMessage?.event?.hasPrefix("call_") != true
            else { continue }

            let content = UNMutableNotificationContent()
            let sender = conversation.lastIncomingSender ?? conversation.partner?.displayName ?? "Someone"
            let pinged = conversation.lastMessage.map { $0.isPing && $0.userId != session.user?.id } ?? false
            content.title = conversation.isOrg ? (conversation.name ?? "Org") : sender
            // As on the web, alerts never carry the message itself.
            content.body = switch (pinged, conversation.isOrg) {
            case (true, true): "\(sender) sent a ping"
            case (true, false): "Pinged you"
            case (false, true): "\(sender) sent a message"
            case (false, false): "Sent you a message"
            }
            content.threadIdentifier = conversation.id
            content.categoryIdentifier = "message"
            content.userInfo = ["conversation": conversation.id]

            if pinged {
                Sounds.ping()
            } else {
                Sounds.newMessage()
            }

            // The banner stays silent: the app plays the web's own sound itself.
            if Preferences.notificationsEnabled {
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(conversation.id)-\(id)", content: content, trigger: nil))
            }
        }
    }

    private func isReading(_ conversation: ConversationSummary) -> Bool {
        NSApp.isActive && NSApp.keyWindow?.isVisible == true && selection?.id == conversation.reference.id
    }

    /// Moves the selection to the remote above or below the open one, wrapping at neither end.
    func selectAdjacent(_ offset: Int) {
        let references = conversations.map(\.reference)

        guard !references.isEmpty else { return }

        guard let current = selection, let index = references.firstIndex(of: current) else {
            selection = references.first
            return
        }

        selection = references[min(max(index + offset, 0), references.count - 1)]
    }

    /// Pushes a reply typed in a notification banner, without opening the window.
    func reply(conversationId: String, text: String) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return }

        thread(for: conversation.reference).send(text)
    }

    func markRead(conversationId: String) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return }

        Task { await markRead(conversation) }
    }

    /// Opens the conversation a notification was about.
    func open(conversationId: String) {
        if let conversation = conversations.first(where: { $0.id == conversationId }) {
            selection = conversation.reference
        }
    }

    // MARK: - Actions on a conversation

    func setPinned(_ pinned: Bool, _ reference: ThreadReference) async {
        await run { try await self.api.perform("PUT", reference.path + "/pin", json: ["pinned": pinned]) }
    }

    func mute(_ duration: MuteDuration, _ reference: ThreadReference) async {
        await run { try await self.api.perform("PUT", reference.path + "/mute", json: ["duration": duration.rawValue]) }
    }

    func setStashed(_ stashed: Bool, _ reference: ThreadReference) async {
        await run { try await self.api.perform(stashed ? "POST" : "DELETE", reference.path + "/archive") }

        if stashed, selection == reference {
            selection = nil
        }
    }

    func merge(_ reference: ThreadReference) async {
        await run { try await self.api.perform("POST", reference.path + "/merge") }
        thread(for: reference).reload()
    }

    func drop(_ reference: ThreadReference) async {
        await run { try await self.api.perform("POST", reference.path + "/drop") }
        selection = nil
    }

    func markRead(_ conversation: ConversationSummary) async {
        let through = conversation.lastMessage?.id ?? conversation.lastIncomingMessageId ?? 0
        await run { try await self.api.perform("PUT", conversation.reference.path + "/read", json: ["through": through]) }
    }

    func block(_ user: User) async {
        await run { try await self.api.perform("POST", "users/\(user.handle)/block") }
        selection = nil
    }

    /// Runs an action and refreshes the list after it, surfacing what the API said if it refused.
    func run(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
        } catch {
            self.error = error.localizedDescription
            presentAlert(error.localizedDescription)
        }

        await refresh()
    }

    /// Marks a conversation read locally the moment it is read, before the next poll says so.
    func markLocallyRead(_ reference: ThreadReference, through: Int) {
        readLocally[reference.id] = max(readLocally[reference.id] ?? 0, through)

        guard let index = conversations.firstIndex(where: { $0.reference.id == reference.id }), conversations[index].ahead > 0 else {
            if let sidebarIndex = sidebarOpen.firstIndex(where: { $0.reference.id == reference.id }), sidebarOpen[sidebarIndex].ahead > 0 {
                sidebarOpen[sidebarIndex] = sidebarOpen[sidebarIndex].with(ahead: 0)
            }
            return
        }

        unreadCount = max(0, unreadCount - conversations[index].ahead)
        conversations[index] = conversations[index].with(ahead: 0)

        if let sidebarIndex = sidebarOpen.firstIndex(where: { $0.reference.id == reference.id }) {
            sidebarOpen[sidebarIndex] = sidebarOpen[sidebarIndex].with(ahead: 0)
        }

        session.workspace?.updateDockBadge()
    }

    /// Starts loading a thread the pointer rests on, so it is there by the time it is clicked. The pointer has to stay
    /// a moment: sweeping it across the list loads nothing.
    func prefetch(_ reference: ThreadReference) {
        hovered = reference
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await thread(for: reference).prefetch()
        }
    }

    /// The pointer left the row before the load started. Only that row's load is dropped, whichever of leaving one
    /// row and entering the next is reported first.
    func cancelPrefetch(_ reference: ThreadReference) {
        guard hovered == reference else { return }
        hoverTask?.cancel()
    }
}

func presentAlert(_ message: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")

    if let window = NSApp.keyWindow {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}

extension ConversationSummary {
    func with(ahead: Int) -> ConversationSummary {
        ConversationSummary(id: id, kind: kind, name: name, partner: partner, members: members, lastMessage: lastMessage, lastMessageAt: lastMessageAt, ahead: ahead, lastIncomingMessageId: lastIncomingMessageId, lastIncomingSender: lastIncomingSender, partnerReadThroughId: partnerReadThroughId, partnerReadAt: partnerReadAt, isArchived: isArchived, pinnedAt: pinnedAt, mutedUntilAt: mutedUntilAt)
    }

    /// The title the inbox and the window show: the partner, or the org's name or its members.
    func title(excluding me: String?) -> String {
        if let partner {
            return partner.displayName
        }

        if let name, !name.isEmpty {
            return name
        }

        let others = (members ?? []).map(\.user).filter { $0.id != me }

        return others.prefix(3).map(\.displayName).joined(separator: ", ") + (others.count > 3 ? " +\(others.count - 3)" : "")
    }
}
