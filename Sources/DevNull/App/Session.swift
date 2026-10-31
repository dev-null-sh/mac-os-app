import AppKit
import CryptoKit
import Foundation
import Observation

/// Who is signed in on this Mac. Signing in works like the mobile app: the browser opens /mobile/authorize with this
/// key's fingerprint and a PKCE challenge, the user approves the device, the web sends a one-time code back to
/// devnull://mac/auth, and the app redeems it with a request signed by the key.
@MainActor
@Observable
final class Session {
    enum Phase: Equatable {
        case loading
        case signedOut
        case waitingForBrowser
        case signedIn
    }

    static let redirectURI = "devnull://mac/auth"

    private(set) var phase: Phase = .loading
    private(set) var user: CurrentUser?
    private(set) var api: APIClient? {
        didSet {
            inbox?.stop()
            workspace?.stop()
            calls?.stop()
            inbox = api.map { Inbox(session: self, api: $0) }
            workspace = api.map { Workspace(session: self, api: $0) }
            calls = api.map { [inbox] api in CallCenter(api: api, inbox: inbox, me: { [weak self] in self?.user }) }
        }
    }

    /// One inbox for the app, whichever windows show it, so polling and alerts don't run twice.
    private(set) var inbox: Inbox?
    /// The logs, threads, notifications, profiles, queue, search and drafts, shared by every window like the inbox.
    private(set) var workspace: Workspace?
    /// Calls ring every window, so there is one call center for the app, like the inbox.
    private(set) var calls: CallCenter?
    var error: String?

    private var pending: (state: String, verifier: String)?

    init() {
        Task { await restore() }
    }

    /// A key that was approved before signs right back in. One the web revoked since gets the sign-in screen.
    private func restore() async {
        #if DEBUG
            if Preview.isEnabled {
                api = APIClient(key: DeviceKey(privateKey: .init()))
                user = Preview.me
                phase = .signedIn
                PreviewCommands.start(self)
                return
            }
        #endif

        guard let key = DeviceKey.load() else {
            phase = .signedOut
            return
        }

        let api = APIClient(key: key)

        do {
            let response: DataEnvelope<CurrentUser> = try await api.get("me")
            self.api = api
            user = response.data
            phase = .signedIn
        } catch let error as APIError where error.requiresSignIn {
            phase = .signedOut
        } catch {
            // Offline: keep the key and let the user try again from the sign-in screen.
            self.error = error.localizedDescription
            phase = .signedOut
        }
    }

    func signIn() {
        do {
            let key = try DeviceKey.loadOrCreate()
            let verifier = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }).base64URLEncoded
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
            let state = UUID().uuidString

            pending = (state, verifier)

            var components = URLComponents(url: APIClient.baseURL.appending(path: "mobile/authorize"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "fingerprint", value: key.fingerprint),
                URLQueryItem(name: "device_name", value: String((Host.current().localizedName ?? "Mac").prefix(100))),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            ]
            // URLComponents leaves "+" as is, which the web reads back as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

            error = nil
            phase = .waitingForBrowser
            NSWorkspace.shared.open(components.url!)
        } catch {
            self.error = "Couldn't create a key in your Keychain."
        }
    }

    func cancelSignIn() {
        pending = nil
        phase = .signedOut
    }

    /// The browser hands the code back through the app's URL scheme.
    func handle(url: URL) {
        guard url.scheme == "devnull", url.host() == "mac", let pending else {
            return
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        NSApp.activate(ignoringOtherApps: true)

        guard value("state") == pending.state else {
            return
        }

        self.pending = nil

        guard let code = value("code") else {
            error = value("error") == "access_denied" ? nil : "The browser didn't approve this Mac."
            phase = .signedOut
            return
        }

        Task {
            do {
                let api = APIClient(key: try DeviceKey.loadOrCreate())
                user = try await api.redeem(code: code, verifier: pending.verifier)
                self.api = api
                phase = .signedIn
            } catch {
                self.error = error.localizedDescription
                phase = .signedOut
            }
        }
    }

    func update(user: CurrentUser) {
        self.user = user
    }

    /// Forgets the key, so this Mac can't sign anything anymore. The device stays listed on the web until it is revoked
    /// there, but nothing can use it.
    func signOut() {
        DeviceKey.delete()
        // The account's preferences go with it: where each log was last read and the notification filter.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("head-last-visit-") || key == "notification-filter" || key == "last-conversation" {
            UserDefaults.standard.removeObject(forKey: key)
        }
        api = nil
        user = nil
        phase = .signedOut
        NSApp.dockTile.badgeLabel = nil
    }

    /// The device was revoked on the web, or the account is gone.
    func expire(_ error: APIError) {
        signOut()
        self.error = error.message
    }
}
