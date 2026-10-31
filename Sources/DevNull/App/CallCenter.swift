import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - What the API answers

struct IncomingCall: Decodable {
    let partner: User
    let sdp: String
    let isMuted: Bool
}

struct CallMember: Decodable, Hashable {
    let user: User
    let joinedAt: Int64
}

/// A call going on in one of the user's orgs, which anyone in it can join.
struct OngoingOrgCall: Decodable, Hashable, Identifiable {
    let org: OrgInfo
    let startedAt: Int64
    let isRinging: Bool
    let isMuted: Bool
    let members: [CallMember]

    var id: String { "\(org.id):\(startedAt)" }
}

struct CallSignal: Codable, Hashable {
    let id: String
    let type: String
    let sdp: String
}

/// The org's call as a member checking in sees it, with what the others left for them. No signals come as `[]`.
struct OrgRoom: Decodable {
    let startedAt: Int64
    let isRinging: Bool
    let members: [CallMember]
    let signals: [String: CallSignal]

    private enum CodingKeys: String, CodingKey { case startedAt, isRinging, members, signals }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Int64.self, forKey: .startedAt)
        isRinging = try container.decode(Bool.self, forKey: .isRinging)
        members = try container.decode([CallMember].self, forKey: .members)
        signals = (try? container.decode([String: CallSignal].self, forKey: .signals)) ?? [:]
    }
}

private struct IceServers: Decodable {
    struct Server: Decodable {
        let urls: [String]
        let username: String?
        let credential: String?
    }

    let iceServers: [Server]
    let isRelayOnly: Bool

    var json: [[String: Any]] {
        iceServers.map { server in
            var entry: [String: Any] = ["urls": server.urls]
            if let username = server.username { entry["username"] = username }
            if let credential = server.credential { entry["credential"] = credential }
            return entry
        }
    }
}

// MARK: - The call center

/// Calls, as the web's call.ts and org-call.ts run them: a 1:1 call rings the partner through the server, which only
/// ever holds the two SDPs, and an org's call is a mesh of 1:1 connections whose offers and answers ride on each
/// member's check-in every 2 s. The incoming-calls poll runs every 3 s while nothing else is going on. One call at a
/// time, whichever kind.
@MainActor
@Observable
final class CallCenter {
    enum Direct: Equatable {
        case idle
        case calling(User, since: Date)
        case ringing(User, sdp: String)
        case connecting(User)
        case connected(User, startedAt: Date)
        case ended(User, reason: String)

        var partner: User? {
            switch self {
            case .idle: nil
            case let .calling(user, _), let .ringing(user, _), let .connecting(user), let .connected(user, _), let .ended(user, _): user
            }
        }

        var isActive: Bool {
            switch self {
            case .calling, .connecting, .connected: true
            default: false
            }
        }
    }

    enum Org: Equatable {
        case idle
        case joining(OrgInfo)
        case joined(OrgInfo, joinedAt: Date)
        case ended(OrgInfo, reason: String)

        var org: OrgInfo? {
            switch self {
            case .idle: nil
            case let .joining(org), let .joined(org, _), let .ended(org, _): org
            }
        }

        var isActive: Bool {
            switch self {
            case .joining, .joined: true
            default: false
            }
        }
    }

    struct Peer: Identifiable, Equatable {
        let user: User
        var isConnected = false
        var isCameraOn = false
        var code = ""

        var id: String { user.id }
    }

    static let ringFor: TimeInterval = 45
    static let connectFor: TimeInterval = 20

    /// The one call center of the running app, for hanging up on quit.
    static weak var current: CallCenter?

    let api: APIClient
    let engine = CallEngine()
    @ObservationIgnored private weak var inbox: Inbox?
    @ObservationIgnored private let me: () -> CurrentUser?

    private(set) var direct: Direct = .idle { didSet { refreshRing() } }
    private(set) var org: Org = .idle { didSet { refreshRing() } }
    private(set) var isMicMuted = false
    private(set) var isCameraOn = false
    private(set) var isPartnerCameraOn = false
    private(set) var code = ""
    private(set) var orgIsRinging = false { didSet { refreshRing() } }
    private(set) var peers: [Peer] = [] { didSet { refreshRing() } }
    /// The calls going on in the user's orgs, and the one ringing them.
    private(set) var ongoing: [OngoingOrgCall] = []
    private(set) var ringingOrgCall: OngoingOrgCall? { didSet { refreshRing() } }
    /// How tall the video tiles are at the width they're shown at, or 0 while every camera is off.
    private(set) var videoHeight: CGFloat = 0
    /// The thread whose composer asked "Call @x?", until the user confirms or cancels.
    var confirming: ThreadReference?
    /// Why the camera didn't turn on, shown under the call for a moment.
    private(set) var notice: String?

    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var directTask: Task<Void, Never>?
    @ObservationIgnored private var connectTimer: Task<Void, Never>?
    @ObservationIgnored private var dismissTimer: Task<Void, Never>?
    @ObservationIgnored private var orgDismissTimer: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    /// The offer the user declined, so the poll doesn't ring for it again.
    @ObservationIgnored private var seenOffer: String?
    @ObservationIgnored private var ringsAloud = false

    // The org mesh, as org-call.ts keeps it.
    @ObservationIgnored private var links: [String: Link] = [:]
    @ObservationIgnored private var answered: [String: String] = [:]
    @ObservationIgnored private var outbox: [String: CallSignal] = [:]
    @ObservationIgnored private var declined: Set<String> = []
    @ObservationIgnored private var orgSession = 0
    @ObservationIgnored private var joinedKey: String?
    @ObservationIgnored private var orgTimer: Task<Void, Never>?

    @ObservationIgnored private var ringing: NSSound?
    @ObservationIgnored private var ringingKey: String?
    @ObservationIgnored private var notifiedKey: String?

    private struct Link {
        let offerId: String
        let isOfferer: Bool
        var isAnswered = false
        let openedAt = Date()
    }

    init(api: APIClient, inbox: Inbox?, me: @escaping () -> CurrentUser?) {
        self.api = api
        self.inbox = inbox
        self.me = me
        Self.current = self

        engine.onEvent = { [weak self] event in self?.receive(event) }
        startPolling()
    }

    func stop() {
        poller?.cancel()
        hangUpEverything()
    }

    /// On a call or joining one, so nothing else can start.
    var isBusy: Bool {
        switch direct {
        case .idle, .ended: org.isActive
        default: true
        }
    }

    var isOnCall: Bool { direct.isActive || org.isActive }

    /// Ends whatever call is going on, telling the server, for quitting and signing out.
    func hangUpBeforeQuitting() async {
        if case let .calling(partner, _) = direct {
            try? await api.perform("DELETE", ThreadReference.direct(partner).path + "/call")
        }

        if org.isActive, let org = org.org {
            try? await api.perform("DELETE", "remotes/orgs/\(org.id)/call")
        }

        hangUpEverything()
    }

    private func hangUpEverything() {
        if direct.isActive, let partner = direct.partner { endDirect(partner, "Call ended.") }
        if org.isActive { endOrg("You left the call.") }
    }

    // MARK: - Incoming calls

    private func startPolling() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollIncoming()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// On a call, nothing else can ring and there's no other call to join, so there's nothing to check.
    private var isFree: Bool {
        guard !org.isActive else { return false }

        switch direct {
        case .idle, .ended, .ringing: return true
        default: return false
        }
    }

    private func pollIncoming() async {
        guard isFree, me()?.remotes != nil else { return }

        struct Response: Decodable {
            let call: IncomingCall?
            let orgCalls: [OngoingOrgCall]
        }

        guard let response: Response = try? await api.get("remotes/call"), isFree else { return }

        takeIncomingCall(response.call)
        receiveOrgCalls(response.orgCalls)
    }

    private func takeIncomingCall(_ call: IncomingCall?) {
        guard let call, call.sdp != seenOffer else {
            if case let .ringing(partner, _) = direct {
                endDirect(partner, "Missed call from @\(partner.handle).")
            }
            return
        }

        if case let .ringing(_, sdp) = direct, sdp == call.sdp { return }

        dismissTimer?.cancel()
        ringsAloud = !call.isMuted && Preferences.soundEnabled
        direct = .ringing(call.partner, sdp: call.sdp)

        if !call.isMuted {
            notify(key: "call:" + call.sdp.suffix(32), title: call.partner.displayName, body: "Is calling you", conversation: conversationId(with: call.partner))
        }
    }

    private func receiveOrgCalls(_ calls: [OngoingOrgCall]) {
        let isFree = !isBusy
        let myId = me()?.id

        ongoing = calls
        ringingOrgCall = isFree ? calls.first { $0.isRinging && !declined.contains($0.id) && !$0.members.contains { $0.user.id == myId } } : nil

        if let call = ringingOrgCall, !call.isMuted {
            notify(key: "org-call:" + call.id, title: call.org.name ?? "Org", body: "\(call.members.first?.user.displayName ?? "Someone") started a call", conversation: call.org.id)
        } else if ringingOrgCall == nil, notifiedKey?.hasPrefix("org-call:") == true {
            withdrawNotification()
        }
    }

    // MARK: - 1:1 calls

    /// Rings the partner. The offer carries this Mac's addresses, so it's only sent once the user confirmed.
    func startCall(_ partner: User) {
        guard !org.isActive else { return }

        switch direct {
        case .idle, .ended: break
        default: return
        }

        confirming = nil
        dismissTimer?.cancel()
        declineOrgCall()
        let since = Date()
        direct = .calling(partner, since: since)
        let path = ThreadReference.direct(partner).path + "/call"

        directTask = Task { [weak self] in
            guard let self else { return }

            do {
                let servers: IceServers = try await api.get(path + "/ice-servers")
                try await engine.start(iceServers: servers.json, isRelayOnly: servers.isRelayOnly, mode: "direct")
                let sdp = try await engine.offer(partner.id, label: "@" + partner.handle)
                guard isCalling(partner) else { return }
                try await api.perform("POST", path, json: ["sdp": sdp])
            } catch {
                guard isCalling(partner) else { return }
                endDirect(partner, Self.failure(error, microphone: "Allow the microphone to call.", fallback: "Could not call @\(partner.handle)."))
                return
            }

            struct Response: Decodable {
                struct Call: Decodable { let answer: String? }
                let call: Call?
            }

            while !Task.isCancelled, isCalling(partner) {
                try? await Task.sleep(for: .milliseconds(1500))
                guard isCalling(partner) else { return }

                guard let response: Response = try? await api.get(path), isCalling(partner) else { continue }

                if let answer = response.call?.answer {
                    direct = .connecting(partner)
                    giveUpConnecting(partner)

                    do {
                        try await engine.accept(partner.id, answer: answer)
                    } catch {
                        if isConnecting(partner) { endDirect(partner, "Couldn't connect the call.") }
                    }

                    // The call was answered, so the server logs nothing more: this only clears it.
                    try? await api.perform("DELETE", path)
                    return
                }

                if response.call == nil || Date().timeIntervalSince(since) >= Self.ringFor {
                    try? await api.perform("DELETE", path)
                    endDirect(partner, "No answer.")
                    return
                }
            }
        }
    }

    private func isConnecting(_ partner: User) -> Bool {
        if case let .connecting(user) = direct { return user.id == partner.id }
        return false
    }

    private func isCalling(_ partner: User) -> Bool {
        if case let .calling(user, _) = direct { return user.id == partner.id }
        return false
    }

    func acceptCall() {
        guard case let .ringing(partner, sdp) = direct else { return }

        withdrawNotification()
        direct = .connecting(partner)
        declineOrgCall()
        let path = ThreadReference.direct(partner).path + "/call"

        directTask = Task { [weak self] in
            guard let self else { return }

            do {
                let servers: IceServers = try await api.get(path + "/ice-servers")
                try await engine.start(iceServers: servers.json, isRelayOnly: servers.isRelayOnly, mode: "direct")
                let answer = try await engine.answer(partner.id, label: "@" + partner.handle, offer: sdp)
                guard isConnecting(partner) else { return }
                try await api.perform("PUT", path, json: ["sdp": answer])
                giveUpConnecting(partner)
            } catch {
                // Unless the user hung up while it answered, which already ended the call.
                guard isConnecting(partner) else { return }
                try? await api.perform("DELETE", path, json: ["failed": true])
                endDirect(partner, Self.failure(error, microphone: "Allow the microphone to call.", fallback: "Could not answer the call."))
            }
        }
    }

    func declineCall() {
        guard case let .ringing(partner, sdp) = direct else { return }

        withdrawNotification()
        seenOffer = sdp
        direct = .idle
        Task { try? await api.perform("DELETE", ThreadReference.direct(partner).path + "/call", json: ["failed": false]) }
    }

    func hangUp() {
        guard let partner = direct.partner else { return }

        switch direct {
        case .calling:
            Task { try? await api.perform("DELETE", ThreadReference.direct(partner).path + "/call") }
        case .connecting, .connected:
            break
        default:
            return
        }

        endDirect(partner, "Call ended.")
    }

    func dismissDirect() {
        guard case .ended = direct else { return }
        direct = .idle
    }

    private func giveUpConnecting(_ partner: User) {
        connectTimer?.cancel()
        connectTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectFor))
            guard let self, !Task.isCancelled, case let .connecting(user) = direct, user.id == partner.id else { return }
            endDirect(partner, "Couldn't connect the call.")
        }
    }

    private func endDirect(_ partner: User, _ reason: String) {
        directTask?.cancel()
        connectTimer?.cancel()
        engine.stop()

        // A call that never rang through on this side, a missed one, ends quietly.
        if case .ringing = direct {
            withdrawNotification()
        } else {
            CallSounds.hangUp()
        }

        isMicMuted = false
        isCameraOn = false
        isPartnerCameraOn = false
        code = ""
        direct = .ended(partner, reason: reason)

        dismissTimer?.cancel()
        dismissTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismissDirect()
        }
    }

    // MARK: - Org calls

    /// Joins the org's call, or starts it, which rings everyone else in the org.
    func joinOrgCall(_ org: OrgInfo) {
        guard !self.org.isActive else { return }

        switch direct {
        case .idle, .ended: break
        default: return
        }

        confirming = nil
        orgDismissTimer?.cancel()
        orgSession += 1
        let current = orgSession
        ringingOrgCall = nil
        joinedKey = ongoing.first { $0.org.id == org.id }?.id
        self.org = .joining(org)
        let path = "remotes/orgs/\(org.id)/call"

        Task { [weak self] in
            guard let self else { return }

            do {
                let servers: IceServers = try await api.get(path + "/ice-servers")
                try await engine.start(iceServers: servers.json, isRelayOnly: servers.isRelayOnly, mode: "org")
                guard current == orgSession else { return }

                struct Response: Decodable { let call: OrgRoom? }
                let response: Response = try await api.send("POST", path, json: [:])

                // Left while joining: leaving had nothing to take the user out of yet.
                guard current == orgSession else {
                    if response.call != nil { try? await api.perform("DELETE", path) }
                    return
                }

                guard let room = response.call else {
                    endOrg("This call is full.", wasJoined: false)
                    return
                }

                joinedKey = "\(org.id):\(room.startedAt)"
                isMicMuted = false
                isCameraOn = false
                peers = []
                orgIsRinging = room.isRinging
                self.org = .joined(org, joinedAt: Date())
                await sync(room)
            } catch {
                guard current == orgSession else { return }
                endOrg(Self.failure(error, microphone: "Allow the microphone to join the call.", fallback: "Could not join the call."), wasJoined: false)
                return
            }

            checkInLater(current)
        }
    }

    func leaveOrgCall() {
        guard org.isActive, let org = org.org else { return }

        Task { try? await api.perform("DELETE", "remotes/orgs/\(org.id)/call") }
        endOrg("You left the call.")
    }

    func declineOrgCall() {
        guard let call = ringingOrgCall else { return }

        declined.insert(call.id)
        ringingOrgCall = nil
        withdrawNotification()
    }

    func dismissOrg() {
        guard case .ended = org else { return }
        org = .idle
    }

    private func checkInLater(_ current: Int) {
        orgTimer?.cancel()
        orgTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.checkIn(current)
        }
    }

    /// Hands over this Mac's offers and answers, and picks up the others'.
    private func checkIn(_ current: Int) async {
        guard case let .joined(org, _) = org, current == orgSession else { return }

        let signals = outbox
        outbox = [:]

        struct Response: Decodable { let call: OrgRoom? }

        do {
            let json = Dictionary(uniqueKeysWithValues: signals.map { ($0.key, ["id": $0.value.id, "type": $0.value.type, "sdp": $0.value.sdp]) })
            let response: Response = try await api.send("PUT", "remotes/orgs/\(org.id)/call", json: ["signals": json])
            guard current == orgSession else { return }

            guard let room = response.call else {
                endOrg("Call ended.")
                return
            }

            await sync(room)
        } catch {
            guard current == orgSession else { return }

            // Only being out of the call or the org ends it. Anything else, like a rate limit, is tried again.
            if let error = error as? APIError, error.status == 403 || error.status == 404 {
                endOrg("Call ended.")
                return
            }

            outbox = signals.merging(outbox) { _, newer in newer }
        }

        if current == orgSession { checkInLater(current) }
    }

    /// Connects to whoever joined and lets go of whoever left. Whoever joined later offers, so every two members agree
    /// on who starts without asking each other.
    private func sync(_ room: OrgRoom) async {
        guard let myId = me()?.id, let mine = room.members.first(where: { $0.user.id == myId }), case .joined = org else { return }

        let members = room.members.filter { $0.user.id != myId }

        for id in links.keys where !members.contains(where: { $0.user.id == id }) {
            close(id)
            answered[id] = nil
        }

        peers = members.map { member in peers.first { $0.id == member.user.id } ?? Peer(user: member.user) }

        await withTaskGroup(of: Void.self) { group in
            for member in members {
                group.addTask { @MainActor [weak self] in
                    await self?.sync(member, mine: mine, signal: room.signals[member.user.id])
                }
            }
        }

        if case .joined = org {
            orgIsRinging = room.isRinging
        }
    }

    private func sync(_ member: CallMember, mine: CallMember, signal: CallSignal?) async {
        let id = member.user.id
        let isOfferer = mine.joinedAt > member.joinedAt || (mine.joinedAt == member.joinedAt && mine.user.id > id)

        if links[id]?.isOfferer == !isOfferer {
            close(id)
        }

        do {
            if !isOfferer {
                if let signal, signal.type == "offer", signal.id != answered[id] {
                    close(id)
                    try await answer(member.user, signal)
                }
            } else if let link = links[id] {
                let isConnected = peers.first { $0.id == id }?.isConnected ?? false

                if !isConnected, Date().timeIntervalSince(link.openedAt) > Self.connectFor {
                    close(id)
                    try await offer(member.user)
                } else if let signal, signal.type == "answer", signal.id == link.offerId, !link.isAnswered {
                    links[id]?.isAnswered = true
                    try await engine.accept(id, answer: signal.sdp)
                }
            } else {
                try await offer(member.user)
            }
        } catch {
            // Start over with them on the next check-in.
            close(id)
        }
    }

    private func offer(_ user: User) async throws {
        let offerId = UUID().uuidString.lowercased()
        links[user.id] = Link(offerId: offerId, isOfferer: true)
        let sdp = try await engine.offer(user.id, label: "@" + user.handle)

        // Unless they left, or the user did, while WebKit gathered its addresses.
        if links[user.id]?.offerId == offerId {
            outbox[user.id] = CallSignal(id: offerId, type: "offer", sdp: sdp)
        }
    }

    private func answer(_ user: User, _ signal: CallSignal) async throws {
        links[user.id] = Link(offerId: signal.id, isOfferer: false)
        answered[user.id] = signal.id
        let sdp = try await engine.answer(user.id, label: "@" + user.handle, offer: signal.sdp)

        if links[user.id]?.offerId == signal.id {
            outbox[user.id] = CallSignal(id: signal.id, type: "answer", sdp: sdp)
        }
    }

    private func close(_ id: String) {
        guard links.removeValue(forKey: id) != nil else { return }

        engine.close(id)

        if let index = peers.firstIndex(where: { $0.id == id }) {
            peers[index].isConnected = false
            peers[index].isCameraOn = false
            peers[index].code = ""
        }
    }

    private func endOrg(_ reason: String, wasJoined: Bool = true) {
        guard self.org.isActive, let org = self.org.org else { return }

        orgSession += 1
        orgTimer?.cancel()

        if let joinedKey {
            declined.insert(joinedKey)
            self.joinedKey = nil
        }

        links = [:]
        answered = [:]
        outbox = [:]
        peers = []
        engine.stop()
        isMicMuted = false
        isCameraOn = false
        orgIsRinging = false

        if wasJoined { CallSounds.hangUp() }

        self.org = .ended(org, reason: reason)

        orgDismissTimer?.cancel()
        orgDismissTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismissOrg()
        }
    }

    // MARK: - Microphone and camera

    func toggleMicrophone() {
        guard case .connected = direct else {
            guard case .joined = org else { return }
            isMicMuted.toggle()
            engine.setMuted(isMicMuted)
            return
        }

        isMicMuted.toggle()
        engine.setMuted(isMicMuted)
    }

    func toggleCamera() {
        let isOn = !isCameraOn

        switch (direct, org) {
        case (.connected, _), (_, .joined): break
        default: return
        }

        Task {
            do {
                try await engine.setCamera(isOn)
                isCameraOn = isOn
            } catch let failure as CallEngine.Failure where failure.isNotAllowed {
                show("Allow the camera to turn it on.")
            } catch {
                show("Could not turn the camera on.")
            }
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    var hasVideo: Bool { videoHeight > 0 }

    // MARK: - From the engine

    private func receive(_ event: CallEngine.Event) {
        switch event {
        case let .connected(peer, code):
            if case let .connecting(partner) = direct, partner.id == peer {
                connectTimer?.cancel()
                isMicMuted = false
                isCameraOn = false
                isPartnerCameraOn = false
                self.code = code
                direct = .connected(partner, startedAt: Date())
            } else if let index = peers.firstIndex(where: { $0.id == peer }), links[peer] != nil {
                peers[index].isConnected = true
                peers[index].code = code
            }
        case let .failed(peer):
            if let partner = direct.partner, partner.id == peer, direct.isActive {
                if case .connected = direct { endDirect(partner, "Call ended.") } else { endDirect(partner, "Couldn't connect the call.") }
            } else {
                close(peer)
            }
        case let .closed(peer):
            // Hanging up closes the channel on both ends at once, with no server in between.
            if let partner = direct.partner, partner.id == peer, direct.isActive {
                endDirect(partner, "Call ended.")
            } else {
                close(peer)
            }
        case let .camera(peer, isOn):
            if direct.partner?.id == peer, case .connected = direct {
                isPartnerCameraOn = isOn
            } else if let index = peers.firstIndex(where: { $0.id == peer }) {
                peers[index].isCameraOn = isOn
            }
        case let .height(height):
            videoHeight = height
        }
    }

    // MARK: - Sounds and banners

    /// MSN's ring for an incoming call, and its outgoing ring while calling, or while alone in a ringing org call.
    private func refreshRing() {
        let next: String? = switch (direct, org) {
        case (.calling, _): "ringback"
        case (.ringing, _) where ringsAloud: "ring"
        case (_, .joined) where orgIsRinging && peers.isEmpty: "ringback"
        default: ringingOrgCall.flatMap { !$0.isMuted && Preferences.soundEnabled ? "ring:" + $0.id : nil }
        }

        guard next != ringingKey else { return }

        ringing?.stop()
        ringing = nil
        ringingKey = next

        if let next {
            ringing = CallSounds.loop(next == "ringback" ? "ringback" : "ring")
        }
    }

    /// A banner for a call ringing while the app is behind other windows, opening its remote when clicked.
    private func notify(key: String, title: String, body: String, conversation: String?) {
        guard notifiedKey != key else { return }

        notifiedKey = key
        NSApp.requestUserAttention(.criticalRequest)

        guard !NSApp.isActive, Preferences.notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let conversation { content.userInfo = ["conversation": conversation] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    private func withdrawNotification() {
        guard let key = notifiedKey else { return }

        notifiedKey = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
    }

    private func conversationId(with partner: User) -> String? {
        (inbox?.conversations ?? []).first { $0.partner?.id == partner.id }?.id
            ?? (inbox?.sidebarOpen ?? []).first { $0.partner?.id == partner.id }?.id
    }

    private static func failure(_ error: Error, microphone: String, fallback: String) -> String {
        if let failure = error as? CallEngine.Failure, failure.isNotAllowed { return microphone }
        if let error = error as? APIError, error.status != 0, error.status != 200 { return error.message }
        return fallback
    }
}

/// The web's call sounds: MSN's ring and ringback, looped, and its hang-up.
@MainActor
enum CallSounds {
    private static let hangUpSound = sound("hangup")

    private static func sound(_ name: String) -> NSSound? {
        let file = Bundle.main.url(forResource: name, withExtension: "mp3")
            ?? URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/\(name).mp3")

        return NSSound(contentsOf: file, byReference: false)
    }

    static func loop(_ name: String) -> NSSound? {
        let sound = sound(name)
        sound?.loops = true
        sound?.play()
        return sound
    }

    static func hangUp() {
        guard Preferences.soundEnabled else { return }

        hangUpSound?.stop()
        hangUpSound?.play()
    }
}
