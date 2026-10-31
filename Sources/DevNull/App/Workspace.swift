import AppKit
import Foundation
import Observation

/// One commit as every list in the app shows it. Lists hold ids and rows read their box, so starring a commit in the
/// replies pane updates it in the log too, and a change redraws that row only.
@MainActor
@Observable
final class CommitBox: Identifiable {
    let id: String
    var commit: Commit
    /// The `rm` collapse runs while this is set; the row is dropped from its lists once it ends.
    var isDeleting = false
    /// Deleted by the user, and still undoable.
    var isRemoved = false
    var translation: Translation?

    init(_ commit: Commit) {
        id = commit.id
        self.commit = commit
    }
}

/// Everything the app reads besides Remotes: the logs, threads, notifications, profiles, Starred, the queue, search and
/// drafts. Created on sign-in and dropped on sign-out, so nothing outlives the session. Nothing here is written to disk
/// except `HEAD@{last visit}` per log, a timestamp.
@MainActor
@Observable
final class Workspace {
    let session: Session
    let api: APIClient

    @ObservationIgnored private var boxes: [String: CommitBox] = [:]
    @ObservationIgnored private(set) var logs: [LogKind: LogStore] = [:]
    @ObservationIgnored private var threadStores: [String: ThreadStore] = [:]
    @ObservationIgnored private var profileStores: [String: ProfileStore] = [:]
    @ObservationIgnored private var threadPrefetch: Task<Void, Never>?

    let notifications: NotificationStore
    let starred: StarredStore
    let scheduled: ScheduledStore
    let search: SearchStore
    let drafts = DraftStore()
    let toasts = ToastCenter()
    private(set) var settings: AccountSettings?
    /// The people the user follows who are streaming, for the sidebar's Live now.
    private(set) var liveFollowing: [User] = []
    @ObservationIgnored private var livePolling: Task<Void, Never>?

    /// Whether the last poll of anything failed, which the sidebar footer says until one succeeds.
    var isOffline = false

    init(session: Session, api: APIClient) {
        self.session = session
        self.api = api
        notifications = NotificationStore(api: api)
        starred = StarredStore(api: api)
        scheduled = ScheduledStore(api: api)
        search = SearchStore(api: api)

        for kind in LogKind.allCases {
            logs[kind] = LogStore(kind: kind, workspace: self)
        }

        notifications.workspace = self
        starred.workspace = self
        scheduled.workspace = self
        search.workspace = self

        logs[.following]?.startPolling()
        logs[.latest]?.startPolling()
        notifications.startPolling()

        Task { await loadSettings() }

        // Streams start and end on their own schedule, so a couple of minutes behind is close enough.
        livePolling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadLiveFollowing()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func stop() {
        livePolling?.cancel()
        logs.values.forEach { $0.stop() }
        notifications.stop()
        scheduled.stop()
        NSApp.dockTile.badgeLabel = nil
    }

    func log(_ kind: LogKind) -> LogStore {
        logs[kind]!
    }

    // MARK: Commits

    /// The box for a commit, filled with what the API sent last.
    @discardableResult
    func box(_ commit: Commit) -> CommitBox {
        if let box = boxes[commit.id] {
            if box.commit != commit { box.commit = commit.merging(box.commit) }
            return box
        }

        let box = CommitBox(commit)
        boxes[commit.id] = box

        // The commits a commit quotes or replies to get boxes of their own, so their rows stay in step too.
        return box
    }

    func existingBox(_ id: String) -> CommitBox? {
        boxes[id]
    }

    func ingest(_ commits: [Commit]) -> [String] {
        commits.map { box($0).id }
    }

    func thread(_ commitId: String) -> ThreadStore {
        if let store = threadStores[commitId] { return store }

        let store = ThreadStore(commitId: commitId, workspace: self)
        threadStores[commitId] = store

        return store
    }

    /// Starts loading the thread of the commit the pointer rests on, so its replies are there when it opens. The
    /// pointer has to stay a moment: sweeping it across the log loads nothing.
    func prefetchThread(_ commitId: String) {
        threadPrefetch?.cancel()
        threadPrefetch = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let store = thread(commitId)
            if !store.hasLoaded { Task { await store.load() } }
        }
    }

    func cancelThreadPrefetch() {
        threadPrefetch?.cancel()
    }

    /// Someone whose commits are already on screen, so their profile can show their face before it loads.
    func knownUser(_ handle: String) -> User? {
        if let user = session.user?.asUser, user.handle.caseInsensitiveCompare(handle) == .orderedSame { return user }

        return boxes.values.lazy.compactMap(\.commit.author).first { $0.handle.caseInsensitiveCompare(handle) == .orderedSame }
    }

    func profile(_ handle: String) -> ProfileStore {
        let key = handle.lowercased()

        if let store = profileStores[key] { return store }

        let store = ProfileStore(handle: handle, workspace: self)
        profileStores[key] = store

        return store
    }

    // MARK: Actions on commits

    /// Stars or unstars at once, and rolls back with a toast when the API refuses.
    func toggleStar(_ id: String) {
        guard let box = boxes[id], box.commit.author?.id != session.user?.id else { return }

        let before = box.commit
        let starring = !before.isStarred
        box.commit.starred = starring
        box.commit.starsCount = max(0, before.stars + (starring ? 1 : -1))

        Task {
            do {
                let response: DataEnvelope<Commit> = try await api.send(starring ? "POST" : "DELETE", "commits/\(id)/star", json: nil)
                box.commit = response.data.merging(box.commit)

                if starring { starred.prepend(id) }
            } catch {
                box.commit = before
                toasts.fatal(error)
            }
        }
    }

    func copyLink(_ id: String) {
        guard let box = boxes[id] else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(box.commit.webURL.absoluteString, forType: .string)
        toasts.show("Copied link to \(box.commit.hash)")
    }

    func givePastel(_ id: String) {
        Task {
            do {
                let response: DataEnvelope<Commit> = try await api.send("POST", "commits/\(id)/pasteis", json: nil)
                box(response.data)
                toasts.show("pastel given to \(response.data.hash)")
            } catch {
                toasts.fatal(error)
            }
        }
    }

    func vote(_ id: String, option: String) {
        Task {
            do {
                let response: DataEnvelope<Commit> = try await api.send("POST", "commits/\(id)/poll/votes", json: ["option": option])
                box(response.data)
            } catch {
                toasts.fatal(error)
            }
        }
    }

    func setPinned(_ pinned: Bool, _ id: String) {
        Task {
            do {
                let response: DataEnvelope<Commit> = try await api.send(pinned ? "PUT" : "DELETE", "commits/\(id)/pin", json: nil)
                box(response.data)
                toasts.show(pinned ? "pinned \(response.data.hash) to your profile" : "unpinned \(response.data.hash)")

                if let handle = session.user?.handle { await profile(handle).reload() }
            } catch {
                toasts.fatal(error)
            }
        }
    }

    func translate(_ id: String) {
        guard let box = boxes[id] else { return }

        if box.translation != nil {
            box.translation = nil
            return
        }

        let language = settings?.translationLanguage ?? Locale.current.language.languageCode?.identifier ?? "en"

        Task {
            struct Response: Decodable { let translation: Translation? }

            do {
                let response: Response = try await api.send("POST", "commits/\(id)/translation", json: ["language": language])
                box.translation = response.translation
            } catch {
                toasts.fatal(error)
            }
        }
    }

    /// Reports a commit, with the images that show what's wrong, as multipart when there are any.
    func report(_ id: String, reason: String, details: String, images: [Attachment]) async throws {
        var json: [String: Any] = ["reason": reason, "details": details.isEmpty ? NSNull() : details]

        if images.isEmpty {
            try await api.perform("POST", "commits/\(id)/reports", json: json)
        } else {
            json["image_descriptions"] = images.map(\.description)
            let _: Empty = try await api.sendMultipart("POST", "commits/\(id)/reports", json: json, field: "images", files: images.map { Upload(data: $0.data, filename: $0.filename, mimeType: $0.mimeType) })
        }

        toasts.show("reported. Thanks, a moderator will look at it.")
    }

    /// Deletes the user's commit: the row prints `rm <hash>` and collapses, and the toast offers Undo for the server's
    /// undo window.
    func delete(_ id: String) {
        guard let box = boxes[id] else { return }

        box.isDeleting = true

        Task {
            do {
                try await api.perform("DELETE", "commits/\(id)")
                try? await Task.sleep(for: .milliseconds(450))
                box.isRemoved = true
                toasts.show("rm \(box.commit.hash)", action: ToastAction(title: "Undo (⌘Z)", duration: 30) { self.restore(id) })
            } catch {
                box.isDeleting = false
                toasts.fatal(error)
            }
        }
    }

    func restore(_ id: String) {
        Task {
            do {
                let response: DataEnvelope<Commit> = try await api.send("POST", "commits/\(id)/restoration", json: nil)
                let box = box(response.data)
                box.isDeleting = false
                box.isRemoved = false
                toasts.show("restored \(response.data.hash)")
            } catch {
                toasts.fatal(error)
            }
        }
    }

    // MARK: People

    func setFollowing(_ following: Bool, _ user: User) async -> Bool {
        do {
            try await api.perform(following ? "POST" : "DELETE", "users/\(user.handle)/follow")
            profileStores[user.handle.lowercased()]?.profile?.isFollowing = following
            return true
        } catch {
            toasts.fatal(error)
            return false
        }
    }

    func setFollowing(_ following: Bool, organization: Organization) async -> Bool {
        do {
            try await api.perform(following ? "POST" : "DELETE", "organizations/\(organization.handle)/follow")

            if let store = profileStores[organization.handle.lowercased()], var page = store.organization, page.isFollowing != following {
                page.isFollowing = following
                page.data.followersCount = max(0, (page.data.followersCount ?? 0) + (following ? 1 : -1))
                store.organization = page
            }

            return true
        } catch {
            toasts.fatal(error)
            return false
        }
    }

    func loadLiveFollowing() async {
        if let page: Page<User> = try? await api.get("me/live-following") { liveFollowing = page.data }
    }

    /// Goes live on a stream for some hours, or ends the stream with nil, as the web's profile button does.
    func setLive(url: String?, hours: Int = 2) async throws {
        let response: DataEnvelope<CurrentUser> = if let url {
            try await api.send("PUT", "me/live", json: ["url": url, "hours": hours])
        } else {
            try await api.send("DELETE", "me/live", json: nil)
        }

        session.update(user: response.data)
        await profile(response.data.handle).reload()
    }

    func setMuted(_ muted: Bool, _ user: User) {
        Task {
            do {
                try await api.perform(muted ? "POST" : "DELETE", "users/\(user.handle)/mute")
                profileStores[user.handle.lowercased()]?.profile?.isMuting = muted
                toasts.show(muted ? "muted @\(user.handle)" : "unmuted @\(user.handle)")
            } catch {
                toasts.fatal(error)
            }
        }
    }

    func block(_ user: User) {
        Task {
            do {
                try await api.perform("POST", "users/\(user.handle)/block")
                toasts.show("blocked @\(user.handle)")
                await session.inbox?.refresh()
            } catch {
                toasts.fatal(error)
            }
        }
    }

    // MARK: Settings

    func loadSettings() async {
        if let response: DataEnvelope<AccountSettings> = try? await api.get("me/settings") {
            settings = response.data
        }
    }

    func updateSettings(_ path: String, _ json: [String: Any]) async {
        do {
            try await api.perform("PUT", path, json: json)
            await loadSettings()
        } catch {
            toasts.fatal(error)
        }
    }

    /// The Dock badge: unread remotes plus unread notifications, capped at 99+.
    func updateDockBadge() {
        let total = (session.inbox?.unreadCount ?? 0) + notifications.unreadCount
        NSApp.dockTile.badgeLabel = total > 0 ? (total > 99 ? "99+" : String(total)) : nil
    }
}

extension Commit {
    /// A commit from a list that loads fewer fields than its page keeps what the page loaded, so a poll never blanks
    /// the counts or the replier avatars.
    func merging(_ older: Commit) -> Commit {
        var merged = self
        merged.starsCount = starsCount ?? older.starsCount
        merged.repliesCount = repliesCount ?? older.repliesCount
        merged.starred = starred ?? older.starred
        merged.linkPreview = linkPreview ?? older.linkPreview
        merged.images = images ?? older.images
        merged.poll = poll ?? older.poll
        merged.replyPreview = replyPreview ?? older.replyPreview
        merged.parent = parent ?? older.parent
        merged.quotedCommit = quotedCommit ?? older.quotedCommit
        return merged
    }
}

// MARK: - Logs

/// Following, Latest or Trending. Following and Latest poll every 30s while the app is in front and every 5 minutes
/// behind other windows; a poll inserts arrivals above without moving what's on screen. Trending only reloads on open
/// and ⌘R, when the server draws it again.
@MainActor
@Observable
final class LogStore {
    let kind: LogKind
    @ObservationIgnored unowned let workspace: Workspace

    private(set) var ids: [String] = []
    private(set) var suggestions: [String] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var reachedRoot = false
    private(set) var error: String?
    /// Arrivals inserted above since the user last looked at the top, newest first, for "↑ N new commits".
    var unseen: [String] = []
    /// The last time the poll checked, for the subtitle.
    private(set) var polledAt: Date?
    /// `HEAD@{last visit}` when the log was opened, which places the HEAD marker and stays put while reading.
    private(set) var markerAt: Date?

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(kind: LogKind, workspace: Workspace) {
        self.kind = kind
        self.workspace = workspace
    }

    /// The newest commit time seen in this log, kept per log as a timestamp only.
    var lastVisit: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: "head-last-visit-" + kind.rawValue)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "head-last-visit-" + kind.rawValue)
            newCount = countNew()
        }
    }

    /// Commits newer than `HEAD@{last visit}`, the sidebar's quiet count. Trending is ranked, so it has none.
    private(set) var newCount = 0

    private func countNew() -> Int {
        guard kind != .trending, let lastVisit else { return 0 }

        return ids.compactMap { workspace.existingBox($0)?.commit.createdAt }.filter { $0 > lastVisit }.count
    }

    var commits: [CommitBox] {
        ids.compactMap { workspace.existingBox($0) }.filter { !$0.isRemoved }
    }

    func open() {
        markerAt = lastVisit

        if kind == .trending || !hasLoaded {
            Task { await reload() }
        }
    }

    func reload() async {
        isLoading = !hasLoaded || kind == .trending
        error = nil

        do {
            let page: LogPage = try await workspace.api.get("log/\(kind.rawValue)")
            ids = workspace.ingest(page.data)
            suggestions = workspace.ingest(page.suggestions ?? [])
            cursor = page.meta?.nextCursor
            reachedRoot = cursor == nil
            hasLoaded = true
            unseen = []
            polledAt = .now
            workspace.isOffline = false

            if lastVisit == nil { markSeen() }
            newCount = countNew()
        } catch {
            if ids.isEmpty { self.error = error.localizedDescription }
            workspace.isOffline = true
        }

        isLoading = false
    }

    func loadMore() async {
        guard let cursor, !isLoadingMore else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page: LogPage = try await workspace.api.get("log/\(kind.rawValue)", query: ["cursor": cursor])
            let known = Set(ids)
            ids += workspace.ingest(page.data).filter { !known.contains($0) }
            self.cursor = page.meta?.nextCursor
            reachedRoot = self.cursor == nil
        } catch {
            workspace.isOffline = true
        }
    }

    /// Takes the first page again and inserts what is new above; nothing already listed moves.
    func poll() async {
        guard hasLoaded, kind != .trending else { return }

        do {
            let page: LogPage = try await workspace.api.get("log/\(kind.rawValue)")
            let known = Set(ids)
            let arrivals = workspace.ingest(page.data).filter { !known.contains($0) }

            if !arrivals.isEmpty {
                ids = arrivals + ids
                unseen = arrivals + unseen
            }

            polledAt = .now
            workspace.isOffline = false
            newCount = countNew()
        } catch {
            workspace.isOffline = true
        }
    }

    /// Puts the user's own new commit at the top at once.
    func insertOwn(_ id: String) {
        guard !ids.contains(id) else { return }

        ids.insert(id, at: 0)
    }

    /// Moves `HEAD@{last visit}` to the newest commit, as Mark All as Seen and reaching the top do.
    func markSeen() {
        let newest = ids.compactMap { workspace.existingBox($0)?.commit.createdAt }.max()

        if let newest, newest > (lastVisit ?? .distantPast) {
            lastVisit = newest
        }

        unseen = []
    }

    func startPolling() {
        poller = Task { [weak self] in
            var polledAt = Date.now

            if self?.hasLoaded == false { await self?.reload() }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let interval: TimeInterval = NSApp.isActive ? 30 : 300
                guard Date.now.timeIntervalSince(polledAt) >= interval else { continue }
                await self.poll()
                polledAt = .now
            }
        }
    }

    func stop() {
        poller?.cancel()
    }
}

// MARK: - Threads

/// A commit's page: the commit, the visible commits it replies to, its replies, and related commits by meaning.
@MainActor
@Observable
final class ThreadStore {
    let commitId: String
    @ObservationIgnored unowned let workspace: Workspace

    private(set) var ancestors: [String] = []
    private(set) var replies: [String] = []
    private(set) var related: [String] = []
    /// Who a reply to this commit can go to, the author first, never the user, as the web's "Replying to" lists them.
    private(set) var participants: [User] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var hasMoreReplies = false
    private(set) var error: String?
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(commitId: String, workspace: Workspace) {
        self.commitId = commitId
        self.workspace = workspace
    }

    var commit: CommitBox? { workspace.existingBox(commitId) }

    /// One load at a time: the hover prefetch, the pane and the commit page can all ask for it at once. Leaving the
    /// view never cancels it, so the next visit finds it loaded.
    func load() async {
        if let loading {
            return await loading.value
        }

        let task = Task { await fetch() }
        loading = task
        await task.value
        loading = nil
    }

    private func fetch() async {
        isLoading = !hasLoaded
        error = nil

        do {
            async let page: CommitPage = workspace.api.get("commits/\(commitId)")
            async let replyPage: Page<Commit> = workspace.api.get("commits/\(commitId)/replies")
            let (loaded, loadedReplies) = try await (page, replyPage)

            workspace.box(loaded.data)
            ancestors = workspace.ingest(loaded.ancestors ?? [])
            var seen = Set([workspace.session.user?.id ?? ""])
            participants = ([loaded.data.author].compactMap { $0 } + (loaded.replyParticipants ?? [])).filter { seen.insert($0.id).inserted }
            replies = workspace.ingest(loadedReplies.data)
            cursor = loadedReplies.meta?.nextCursor
            hasMoreReplies = cursor != nil
            hasLoaded = true
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func loadRelated() async {
        guard related.isEmpty, let page: Page<Commit> = try? await workspace.api.get("commits/\(commitId)/related") else { return }

        related = workspace.ingest(page.data)
    }

    func loadMoreReplies() async {
        guard let cursor else { return }

        if let page: Page<Commit> = try? await workspace.api.get("commits/\(commitId)/replies", query: ["cursor": cursor]) {
            let known = Set(replies)
            replies += workspace.ingest(page.data).filter { !known.contains($0) }
            self.cursor = page.meta?.nextCursor
            hasMoreReplies = self.cursor != nil
        }
    }

    func appendReply(_ id: String) {
        guard !replies.contains(id) else { return }

        replies.append(id)

        if let box = commit {
            box.commit.repliesCount = box.commit.replies + 1
        }
    }
}

// MARK: - Profiles

@MainActor
@Observable
final class ProfileStore {
    enum Tab: String, CaseIterable, Identifiable {
        case commits
        case replies
        case starred

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    let handle: String
    @ObservationIgnored unowned let workspace: Workspace

    var profile: Profile?
    /// Set instead of the profile when the handle is a GitHub organization's, whose page lists the commits mentioning it.
    var organization: OrganizationPage?
    private(set) var mentions: [String]?
    private(set) var mentionsCursor: String?
    /// The organizations someone follows, listed above the people on their Following list, as on the web.
    private(set) var followedOrganizations: [Organization]?
    private(set) var commits: [Tab: [String]] = [:]
    private(set) var cursors: [Tab: String] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    /// Nil until loaded, so a list shown before keeps showing while it refreshes.
    private(set) var followers: [User]?
    private(set) var following: [User]?

    init(handle: String, workspace: Workspace) {
        self.handle = handle
        self.workspace = workspace
    }

    func reload() async {
        isLoading = profile == nil
        error = nil

        do {
            let loaded: Profile = try await workspace.api.get("users/\(handle)")
            profile = loaded

            if let pinned = loaded.pinnedCommit { workspace.box(pinned) }

            // The tabs already shown are fetched again in place, so what's on screen stays until the new page lands.
            for tab in Tab.allCases where tab == .commits || commits[tab] != nil {
                await fetchTab(tab)
            }
        } catch let error as APIError where error.status == 404 {
            // Organizations share the "@handle" pages with users, so a handle no user has may be one.
            do {
                organization = try await workspace.api.get("organizations/\(handle)")
                await loadMentions()
            } catch let error as APIError where error.status == 404 {
                self.error = "No one on /dev/null goes by @\(handle)."
            } catch {
                self.error = error.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func loadTab(_ tab: Tab, more: Bool = false) async {
        if !more, commits[tab] != nil { return }

        await fetchTab(tab, more: more)
    }

    private func fetchTab(_ tab: Tab, more: Bool = false) async {
        if tab == .starred {
            await workspace.starred.reload()
            commits[tab] = workspace.starred.ids
            return
        }

        var query: [String: String?] = ["replies": tab == .replies ? "1" : nil]
        if more { query["cursor"] = cursors[tab] }

        guard let page: Page<Commit> = try? await workspace.api.get("users/\(handle)/commits", query: query) else { return }

        let ids = workspace.ingest(page.data)
        commits[tab] = more ? (commits[tab] ?? []) + ids : ids
        cursors[tab] = page.meta?.nextCursor
    }

    func loadPeople(followers: Bool) async {
        if !followers {
            followedOrganizations = (try? await workspace.api.get("users/\(handle)/following/organizations", as: Page<Organization>.self))?.data ?? followedOrganizations
        }

        guard let page: Page<User> = try? await workspace.api.get("users/\(handle)/\(followers ? "followers" : "following")") else { return }

        if followers { self.followers = page.data } else { following = page.data }
    }

    /// The commits mentioning the organization, 20 a page, as its Mentions tab on the web.
    func loadMentions(more: Bool = false) async {
        if more, mentionsCursor == nil { return }

        guard let page: Page<Commit> = try? await workspace.api.get("organizations/\(handle)/mentions", query: ["cursor": more ? mentionsCursor : nil]) else {
            if mentions == nil { mentions = [] }
            return
        }

        let ids = workspace.ingest(page.data)
        mentions = more ? (mentions ?? []) + ids : ids
        mentionsCursor = page.meta?.nextCursor
    }

    /// Asks GitHub, through /dev/null, whether the user belongs to the organization, making them its first admin.
    func claim() async {
        do {
            try await workspace.api.perform("POST", "organizations/\(handle)/claim")
            organization = try await workspace.api.get("organizations/\(handle)")
            workspace.toasts.show("You claimed @\(handle)")
        } catch {
            presentAlert(error.localizedDescription)
        }
    }
}

// MARK: - Notifications

/// The unread count comes from GET me, which marks nothing read; the list loads when Notifications opens, which marks
/// everything read, as on the web.
@MainActor
@Observable
final class NotificationStore {
    let api: APIClient
    @ObservationIgnored weak var workspace: Workspace?

    private(set) var items: [ActivityNotification] = []
    private(set) var unreadCount = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var groups: [String: [ActivityNotification]] = [:]
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var poller: Task<Void, Never>?

    var filter: NotificationFilter {
        get { NotificationFilter(rawValue: UserDefaults.standard.string(forKey: "notification-filter") ?? "all") ?? .all }
        set {
            guard newValue != filter else { return }

            UserDefaults.standard.set(newValue.rawValue, forKey: "notification-filter")
            // Another tab's notifications are not this tab's: the skeleton shows until they land.
            items = []
            cursor = nil
            Task { await reload() }
        }
    }

    init(api: APIClient) {
        self.api = api
    }

    func reload() async {
        isLoading = items.isEmpty
        error = nil

        do {
            let page: NotificationPage = try await api.get("notifications", query: ["type": filter.rawValue])
            items = page.data
            cursor = page.meta?.nextCursor
            unreadCount = 0
            workspace?.updateDockBadge()
            page.data.compactMap(\.commit).forEach { workspace?.box($0) }
        } catch {
            if items.isEmpty { self.error = error.localizedDescription }
        }

        isLoading = false
    }

    func loadMore() async {
        guard let cursor, let page: NotificationPage = try? await api.get("notifications", query: ["type": filter.rawValue, "cursor": cursor]) else { return }

        items += page.data
        self.cursor = page.meta?.nextCursor
    }

    func expand(_ notification: ActivityNotification) async {
        guard groups[notification.id] == nil, let page: Page<ActivityNotification> = try? await api.get("notifications/\(notification.id)/group") else { return }

        groups[notification.id] = page.data
    }

    func pollCount() async {
        struct Me: Decodable { let data: CurrentUser; let unreadNotificationsCount: Int? }

        do {
            let me: Me = try await api.get("me")
            unreadCount = me.unreadNotificationsCount ?? 0
            workspace?.session.update(user: me.data)
            workspace?.isOffline = false
            workspace?.updateDockBadge()
        } catch let error as APIError where error.requiresSignIn {
            workspace?.session.expire(error)
        } catch {
            workspace?.isOffline = true
        }
    }

    func startPolling() {
        poller = Task { [weak self] in
            var polledAt = Date.distantPast

            while !Task.isCancelled {
                guard let self else { return }
                if Date.now.timeIntervalSince(polledAt) >= (NSApp.isActive ? 30 : 300) {
                    await self.pollCount()
                    polledAt = .now
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        poller?.cancel()
    }
}

// MARK: - Starred

/// Starred commits, newest star first. Unstarring keeps the row until the user navigates away.
@MainActor
@Observable
final class StarredStore {
    let api: APIClient
    @ObservationIgnored weak var workspace: Workspace?

    private(set) var ids: [String] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    @ObservationIgnored private var cursor: String?

    init(api: APIClient) {
        self.api = api
    }

    /// Whether another page waits; the ids change with it, so views redraw.
    var hasMore: Bool { cursor != nil }

    func reload() async {
        guard let workspace else { return }

        isLoading = !hasLoaded
        error = nil

        do {
            let page: Page<Commit> = try await api.get("starred")
            ids = workspace.ingest(page.data)
            cursor = page.meta?.nextCursor
            hasLoaded = true
        } catch {
            if ids.isEmpty { self.error = error.localizedDescription }
        }

        isLoading = false
    }

    func loadMore() async {
        guard let workspace, let cursor, let page: Page<Commit> = try? await api.get("starred", query: ["cursor": cursor]) else { return }

        let known = Set(ids)
        ids += workspace.ingest(page.data).filter { !known.contains($0) }
        self.cursor = page.meta?.nextCursor
    }

    func prepend(_ id: String) {
        guard hasLoaded, !ids.contains(id) else { return }

        ids.insert(id, at: 0)
    }

    /// Drops the commits unstarred while the list was open, once the user leaves it.
    func prune() {
        ids.removeAll { workspace?.existingBox($0)?.commit.isStarred == false }
    }
}

// MARK: - Scheduled

/// The queue of scheduled commits: loaded on open, then every 60s while it is on screen.
@MainActor
@Observable
final class ScheduledStore {
    let api: APIClient
    @ObservationIgnored weak var workspace: Workspace?

    private(set) var items: [ScheduledCommit] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
    }

    var queuedCount: Int { items.filter(\.isQueued).count }

    func reload() async {
        isLoading = !hasLoaded
        error = nil

        do {
            let page: Page<ScheduledCommit> = try await api.get("scheduled-commits")
            items = page.data
            hasLoaded = true
        } catch {
            if items.isEmpty { self.error = error.localizedDescription }
        }

        isLoading = false
    }

    func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            await self?.reload()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                await self.reload()
            }
        }
    }

    func stop() {
        poller?.cancel()
    }

    func postNow(_ item: ScheduledCommit) async {
        do {
            let _: DataEnvelope<ScheduledCommit> = try await api.send("POST", "scheduled-commits/\(item.id)/submission", json: nil)
            workspace?.toasts.show("committed early. It goes through the usual review.")
        } catch {
            workspace?.toasts.fatal(error)
        }

        await reload()
    }

    func cancel(_ item: ScheduledCommit) async {
        do {
            try await api.perform("DELETE", "scheduled-commits/\(item.id)")
            workspace?.toasts.show("canceled the scheduled commit")
        } catch {
            workspace?.toasts.fatal(error)
        }

        await reload()
    }

    /// There is no way to move a scheduled commit, as on the web: it is canceled and queued again at the new time. One
    /// with images or a poll can't be queued again from here, since the images and the poll's duration only live on
    /// the server.
    static func isReschedulable(_ item: ScheduledCommit) -> Bool {
        item.isQueued && item.imageCount == 0 && item.pollOptions == nil && item.body != nil
    }

    func reschedule(_ item: ScheduledCommit, to date: Date) async {
        guard Self.isReschedulable(item), let body = item.body else { return }

        do {
            // Queued again first, so a refused time or a throttle leaves the original where it was.
            let json: [String: Any] = ["body": body, "scheduled_at": Formatting.apiDate(date)]
            let _: DataEnvelope<ScheduledCommit> = try await api.send("POST", "scheduled-commits", json: json)
            try await api.perform("DELETE", "scheduled-commits/\(item.id)")
            workspace?.toasts.show("rescheduled for \(Formatting.scheduleTime(date))")
        } catch {
            workspace?.toasts.fatal(error)
        }

        await reload()
    }
}

// MARK: - Search

/// People, remotes and logs by name, and commits by meaning, for the switcher and the results page. Recent searches
/// live in memory for the session only.
@MainActor
@Observable
final class SearchStore {
    let api: APIClient
    @ObservationIgnored weak var workspace: Workspace?

    private(set) var people: [User] = []
    private(set) var commits: [String] = []
    private(set) var results: [String] = []
    private(set) var isSearchingCommits = false
    private(set) var resultsError: String?
    private(set) var resultsQuery = ""
    private(set) var isLoadingResults = false
    private(set) var recent: [String] = []

    init(api: APIClient) {
        self.api = api
    }

    static func isSearchable(_ query: String) -> Bool {
        (3 ... 100).contains(query.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    /// Looks people up as the user types, and commits once the query is long enough, after a short pause.
    func update(_ query: String) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !term.isEmpty else {
            people = []
            commits = []
            return
        }

        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        if let page: DataEnvelope<[User]> = try? await api.get("search/users", query: ["q": term]) {
            guard !Task.isCancelled else { return }
            people = page.data
        }

        guard Self.isSearchable(term) else {
            commits = []
            return
        }

        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let workspace else { return }

        isSearchingCommits = true
        defer { isSearchingCommits = false }

        if let page: DataEnvelope<[Commit]> = try? await api.get("search/commits", query: ["q": term, "limit": "3"]) {
            guard !Task.isCancelled else { return }
            commits = workspace.ingest(page.data)
        }
    }

    func remember(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !term.isEmpty else { return }

        recent.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        recent.insert(term, at: 0)
        recent = Array(recent.prefix(3))
    }

    func loadResults(_ query: String) async {
        guard let workspace, Self.isSearchable(query) else { return }

        resultsQuery = query
        isLoadingResults = true
        resultsError = nil
        remember(query)

        do {
            let page: DataEnvelope<[Commit]> = try await api.get("search/commits", query: ["q": query])
            results = workspace.ingest(page.data)
        } catch {
            results = []
            resultsError = error.localizedDescription
        }

        isLoadingResults = false
    }
}

// MARK: - Drafts

/// What the user started writing: the commit composer's draft and one reply draft per commit. Memory only: drafts
/// survive navigation and closed windows, and are gone when the app quits.
@MainActor
@Observable
final class DraftStore {
    struct CommitDraft: Equatable {
        var body = ""
        /// Each image carries its own description for screen readers.
        var images: [Attachment] = []
        var pollOptions: [String]? = nil
        /// Minutes, as the API takes them: an hour, a day, three days or a week.
        var pollDuration = 1440
        var scheduledAt: Date? = nil
        var quotedCommitId: String? = nil

        var isEmpty: Bool {
            body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && pollOptions == nil
        }
    }

    var commit = CommitDraft()
    /// The quote composer's draft, kept apart from the staged one so quoting never eats a draft.
    var quote = CommitDraft()
    /// One reply draft per commit.
    var replies: [String: CommitDraft] = [:]

    func clear() {
        commit = CommitDraft()
        quote = CommitDraft()
        replies = [:]
    }
}

// MARK: - Toasts

struct ToastAction {
    let title: String
    /// How long the toast stays for the action, in seconds: the whole undo window for Undo.
    var duration: Double = 4
    let perform: @MainActor () -> Void
}

struct Toast: Identifiable {
    let id = UUID()
    let text: String
    var detail: String? = nil
    var action: ToastAction? = nil
}

/// Toasts speak git, in mono, at the bottom of the center column. Hovering pauses the timer.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?
    var isHovered = false {
        didSet { if !isHovered { schedule() } }
    }

    @ObservationIgnored private var timer: Task<Void, Never>?

    func show(_ text: String, detail: String? = nil, action: ToastAction? = nil) {
        current = Toast(text: text, detail: detail, action: action)
        schedule()
    }

    func fatal(_ error: Error) {
        show("fatal: \((error as? APIError)?.status == 0 ? "offline" : "request failed")", detail: error.localizedDescription)
    }

    func dismiss() {
        current = nil
        timer?.cancel()
    }

    /// Runs the current toast's action, as ⌘Z does for Undo.
    func performAction() {
        guard let action = current?.action else { return }

        dismiss()
        action.perform()
    }

    private func schedule() {
        timer?.cancel()

        guard let toast = current, !isHovered else { return }

        timer = Task {
            try? await Task.sleep(for: .seconds(toast.action?.duration ?? 4))
            guard !Task.isCancelled, current?.id == toast.id else { return }
            current = nil
        }
    }
}

extension Formatting {
    /// A time as the API validates it, `2026-10-29T09:30:00+01:00`.
    static func apiDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"

        return formatter.string(from: date)
    }

    /// When a scheduled commit goes out: `today 18:00`, `Thu 29 · 09:30`.
    static func scheduleTime(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))

        if Calendar.current.isDateInToday(date) { return "today \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "tomorrow \(time)" }

        return date.formatted(.dateTime.weekday(.abbreviated).day()) + " · " + time
    }

    /// A commit's relative time in mono: `now`, `4m`, `3h`, `2d`, then the date.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }

        let seconds = Date.now.timeIntervalSince(date)

        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(86400 * 7): return "\(Int(seconds / 86400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    /// The stamp under a thread's commit: `14:28 · Tue, Oct 27, 2026`.
    static func stamp(_ date: Date?) -> String {
        guard let date else { return "" }

        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) + " · " + date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    /// A day marker in a log: "Today", "Yesterday", "Tue, Oct 13".
    static func dayMarker(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
