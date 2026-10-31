import AppKit
import SwiftUI
import UserNotifications

@main
struct DevNullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session = Session()

    var body: some Scene {
        WindowGroup("/dev/null", id: "main") {
            RootView()
                .environment(session)
                .onOpenURL { session.handle(url: $0) }
                .frame(minWidth: 760, minHeight: 480)
                // The sign-in callback goes to the open window instead of opening another.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands(session: session) }

        // "Open in New Window" for a sidebar item: the same layout without the sidebar.
        WindowGroup(id: "item", for: SidebarItem.self) { $item in
            SignedIn { WorkspaceView(item: item, showsSidebar: false) }
                .environment(session)
                .frame(minWidth: 520, minHeight: 480)
        }
        .defaultSize(width: 900, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .handlesExternalEvents(matching: [])

        // "Open in New Window" for a commit page.
        WindowGroup(id: "commit", for: String.self) { $id in
            SignedIn { WorkspaceView(item: nil, route: id.map(Route.commit), showsSidebar: false) }
                .environment(session)
                .frame(minWidth: 520, minHeight: 480)
        }
        .defaultSize(width: 760, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .handlesExternalEvents(matching: [])

        Window("New Commit", id: "composer") {
            SignedIn { CommitComposerWindow() }
                .environment(session)
                .frame(minWidth: 420, minHeight: 260)
        }
        .defaultSize(width: 560, height: 360)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environment(session)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Opens the main window, set by the menu commands, which SwiftUI keeps around while no window is open.
    static var openMainWindow: (() -> Void)?

    /// The conversation a banner was clicked for while the window was closed, opened once the window is back.
    static var pendingConversation: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Appearance.current != .system { Appearance.current.apply() }

        // The App Store updates its own build, and App Review rejects apps that check for updates themselves.
        #if !APP_STORE
            Updates.shared.start()
        #endif

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Reply and mark as pulled right from the banner, as in Telegram. The banner still never shows the message.
        center.setNotificationCategories([UNNotificationCategory(identifier: "message", actions: [
            UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Push", textInputPlaceholder: "Push a reply"),
            UNNotificationAction(identifier: "read", title: "Mark as Pulled", options: []),
        ], intentIdentifiers: [])])
    }

    /// Quitting mid-call hangs up first, so the other side isn't left ringing or waiting, but never for more than 2 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let calls = MainActor.assumeIsolated({ CallCenter.current }), MainActor.assumeIsolated({ calls.isOnCall }) else { return .terminateNow }

        Task { @MainActor in
            var replied = false
            let reply = {
                guard !replied else { return }
                replied = true
                sender.reply(toApplicationShouldTerminate: true)
            }

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                reply()
            }

            await calls.hangUpBeforeQuitting()
            reply()
        }

        return .terminateLater
    }

    /// Clicking the Dock icon brings the window back after it was closed: SwiftUI doesn't open it again by itself, and the
    /// New Window item it would otherwise use is replaced by New Remote.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }

        // A minimized window comes back as it was instead of a second one opening.
        if let window = sender.windows.first(where: \.isMiniaturized) {
            window.deminiaturize(nil)
        } else {
            Self.openMainWindow?()
        }

        return false
    }

    /// Banners show while the app is in front too, unless the conversation is the one being read (the inbox skips those).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["conversation"] as? String else { return }

        let reply = (response as? UNTextInputNotificationResponse)?.userText

        await MainActor.run {
            switch response.actionIdentifier {
            case "reply":
                NotificationCenter.default.post(name: .replyFromBanner, object: id, userInfo: ["text": reply ?? ""])
            case "read":
                NotificationCenter.default.post(name: .markReadFromBanner, object: id)
            default:
                NSApp.activate(ignoringOtherApps: true)

                if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    NotificationCenter.default.post(name: .openConversation, object: id)
                } else {
                    Self.pendingConversation = id
                    Self.openMainWindow?()
                }
            }
        }
    }
}

extension Notification.Name {
    static let openConversation = Notification.Name("devnull.openConversation")
    static let newRemote = Notification.Name("devnull.newRemote")
    static let newOrg = Notification.Name("devnull.newOrg")
    static let focusSearch = Notification.Name("devnull.focusSearch")
    static let showInfo = Notification.Name("devnull.showInfo")
    static let replyFromBanner = Notification.Name("devnull.replyFromBanner")
    static let markReadFromBanner = Notification.Name("devnull.markReadFromBanner")
}
