import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(Inbox.self) private var inbox
    @Environment(Session.self) private var session
    @Bindable var thread: ThreadModel

    @State private var chat = ChatState()
    @State private var atBottom = true
    @State private var newBelow = 0
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                MessageList(
                    thread: thread,
                    rows: ChatRow.rows(for: thread, me: session.user?.id),
                    controller: chat.list,
                    content: { row in
                        // Each row has its own identity, so a reused cell never keeps the hover or picker state of
                        // the message it showed before.
                        AnyView(ChatRowView(row: row, thread: thread)
                            .id(row.id)
                            .environment(session)
                            .environment(inbox)
                            .environment(chat))
                    },
                    menu: { message in MessageMenu.make(thread: thread, message: message, me: session.user?.id, chat: chat) },
                    onScroll: { bottom, count in
                        withAnimation(.easeOut(duration: 0.15)) {
                            atBottom = bottom
                            newBelow = count
                        }
                    }
                )
                .overlay {
                    if !thread.isLoaded {
                        ChatSkeleton()
                    } else if let error = thread.error, thread.messages.isEmpty {
                        EmptyState(fatal: "fatal: could not fetch the thread", message: error)
                    }
                }

                if !atBottom {
                    ScrollDownButton(count: newBelow) { chat.list.scrollToBottom() }
                        .padding(16)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }

            if let notice = thread.accessNotice, thread.isLoaded {
                AccessBanner(thread: thread, notice: notice)
            }

            CallConsole(thread: thread)

            if thread.canPush || !thread.isLoaded {
                Composer(thread: thread)
            }
        }
        .background(DS.Colors.chat)
        .toolbarBackground(.visible, for: .windowToolbar)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                    .strokeBorder(DS.Colors.primary, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(DS.Colors.primarySoft.opacity(0.85), in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
                    .overlay(Label("Drop images to push", systemImage: "photo").font(DS.Fonts.section).foregroundStyle(DS.Colors.primary))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            guard thread.canPush else { return false }
            AttachmentLoader.load(providers) { thread.attachments.append(contentsOf: $0.prefix(3 - thread.attachments.count)) }
            return true
        }
        .toolbar { toolbar }
        .navigationTitle(title)
        .onAppear {
            chat.openImage = { image in openLightbox(image) }
            chat.thread = thread
            thread.beginViewing()
            thread.activate()
            thread.markRead()
        }
        .onDisappear {
            thread.endViewing()
            thread.deactivate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            thread.markRead()
            Task { await thread.pollIfStale() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scrollToBottom)) { _ in chat.list.scrollToBottom() }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .previewChatAction)) { note in previewAction(note.object as? String) }
        #endif
        .sheet(isPresented: Binding(get: { !thread.attachments.isEmpty }, set: { if !$0 { thread.attachments = [] } })) {
            AttachmentSheet(thread: thread)
        }
    }

    #if DEBUG
        /// Opens what scripts can't click in the preview: the first image, or the last message's menu.
        private func previewAction(_ action: String?) {
            let (name, argument) = action.flatMap { action in action.firstIndex(of: ":").map { (String(action[..<$0]), String(action[action.index(after: $0)...])) } } ?? (action ?? "", "")

            if name == "hover" {
                chat.previewHover = Int(argument)
            } else if name == "react" {
                chat.previewPicker = Int(argument)
            } else if name == "scroll", let id = Int(argument) {
                chat.jump(to: id)
            } else if name == "scroll" {
                chat.list.previewScroll(argument)
            } else if name == "top", let first = thread.messages.first {
                _ = chat.list.scroll(toMessage: first.id)
            } else if action == "lightbox", let image = thread.messages.compactMap({ $0.images?.first }).first {
                openLightbox(image)
            } else if action == "menu", let message = thread.messages.last(where: { !$0.isEvent }), let (view, rect) = chat.list.rowView(forMessage: message.id) {
                let menu = MessageMenu.make(thread: thread, message: message, me: session.user?.id, chat: chat)
                let timer = Timer(timeInterval: 4, repeats: false) { _ in menu.cancelTracking() }
                RunLoop.main.add(timer, forMode: .common)
                menu.popUp(positioning: nil, at: NSPoint(x: rect.midX, y: rect.minY + 20), in: view)
            }
        }
    #endif

    /// Every image of the loaded thread, oldest first, so the lightbox moves through them all.
    private func openLightbox(_ image: MessageImage) {
        let items = thread.messages.flatMap { message in
            (message.images ?? []).map { LightboxItem(image: $0, sender: (message.user ?? thread.user(message.userId))?.displayName ?? "Someone", date: message.createdAt) }
        }

        guard let index = items.firstIndex(where: { $0.id == image.id }) else { return }

        Lightbox.present(items, index: index, over: NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })
    }

    private var title: String {
        if let partner = thread.partner { return partner.displayName }
        if let name = thread.orgName, !name.isEmpty { return name }

        return thread.members.map(\.user).filter { $0.id != session.user?.id }.prefix(3).map(\.displayName).joined(separator: ", ")
    }

    private var subtitle: String {
        if !thread.typing.isEmpty {
            if thread.isOrg {
                return thread.typing.count == 1 ? "@\(thread.typing[0]) is typing" : "\(thread.typing.count) people are typing"
            }

            return "typing"
        }

        if thread.isOrg {
            return thread.members.count == 1 ? "1 member" : "\(thread.members.count) members"
        }

        return thread.partner.map { "@" + $0.handle } ?? ""
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                NotificationCenter.default.post(name: .showInfo, object: nil)
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if thread.isOrg {
                            OrgAvatar(members: thread.members.map(\.user).filter { $0.id != session.user?.id }, size: 30)
                        } else {
                            Avatar(user: thread.partner, size: 30)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(DS.Fonts.rowTitle)
                            .foregroundStyle(DS.Colors.ink)
                            .lineLimit(1)
                            .help(title)

                        HStack(spacing: 3) {
                            if !thread.typing.isEmpty {
                                TypingDots(color: DS.Colors.primary, size: 3.5)
                                    .transition(.opacity)
                            }

                            Text(subtitle)
                                .font(DS.Fonts.caption)
                                .foregroundStyle(thread.typing.isEmpty ? DS.Colors.inkMuted : DS.Colors.primary)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                        .animation(.easeOut(duration: 0.15), value: thread.typing.isEmpty)
                    }
                    .frame(minWidth: 160, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help("Show info")
            .accessibilityLabel("\(title), \(subtitle). Show info")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                NotificationCenter.default.post(name: .showInfo, object: nil)
            } label: {
                Label("Info", systemImage: "info.circle")
            }
            .help("Show Info (⌘I)")

            Menu {
                Button(thread.pinnedAt == nil ? "Pin" : "Unpin", systemImage: "pin") {
                    Task { await inbox.setPinned(thread.pinnedAt == nil, thread.reference); await thread.poll() }
                }

                Menu("Mute", systemImage: "bell.slash") {
                    ForEach(MuteDuration.allCases.filter { $0 != .off }, id: \.self) { duration in
                        Button(duration.title) { Task { await inbox.mute(duration, thread.reference); await thread.poll() } }
                    }
                }

                if thread.mutedUntilAt.map({ $0 > .now }) == true {
                    Button("Unmute", systemImage: "bell") { Task { await inbox.mute(.off, thread.reference); await thread.poll() } }
                }

                Button(thread.isArchived ? "Pop Back to Open" : "Stash", systemImage: "archivebox") {
                    Task { await inbox.setStashed(!thread.isArchived, thread.reference) }
                }

                if let partner = thread.partner {
                    Divider()

                    Button("View Profile", systemImage: "person.crop.circle") {
                        NotificationCenter.default.post(name: .openProfile, object: partner.handle)
                    }

                    Button("Block @\(partner.handle)…", systemImage: "hand.raised", role: .destructive) {
                        confirmBlock(partner)
                    }
                } else if thread.role != nil {
                    Divider()

                    Button("Leave Org…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmLeave()
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More")
        }
    }

    // MARK: - Confirmations

    private func confirmBlock(_ partner: User) {
        let alert = NSAlert()
        alert.messageText = "Block @\(partner.handle)?"
        alert.informativeText = "They won't be able to push to you or see your commits. You can unblock them from their profile."
        alert.addButton(withTitle: "Block").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task { await inbox.block(partner) }
        }
    }

    private func confirmLeave() {
        guard let me = session.user?.asUser else { return }

        let alert = NSAlert()
        alert.messageText = "Leave this org?"
        alert.informativeText = "You'll stop getting its messages. Someone in it has to add you back for you to return."
        alert.addButton(withTitle: "Leave").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task { await thread.remove(me) }
        }
    }
}

extension Notification.Name {
    static let scrollToBottom = Notification.Name("devnull.scrollToBottom")
}

struct MessageLayout: Hashable {
    let isOutgoing: Bool
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let showsSender: Bool
}

/// The round button that brings the thread back to its newest message, with how many arrived while scrolled up.
struct ScrollDownButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Colors.inkMuted)
                .frame(width: 36, height: 36)
                .background(DS.Colors.popover, in: Circle())
                .overlay(Circle().strokeBorder(DS.Colors.hairline))
                .shadow(color: DS.Elevation.floating.color, radius: DS.Elevation.floating.radius, y: DS.Elevation.floating.y)
                .overlay(alignment: .top) {
                    if count > 0 {
                        CountBadge(count: count)
                            .offset(y: -9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Back to present")
        .accessibilityLabel(count > 0 ? "Scroll to the newest message, \(count) new" : "Scroll to the newest message")
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: count)
    }
}

/// A thread's shape while its messages load: a few bubbles on both sides, along the bottom where the newest land.
struct ChatSkeleton: View {
    private static let bubbles: [(outgoing: Bool, width: CGFloat, height: CGFloat)] = [
        (false, 220, 34), (false, 300, 52), (true, 180, 34), (true, 260, 34), (false, 240, 34),
    ]

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            ForEach(Self.bubbles.indices, id: \.self) { index in
                let bubble = Self.bubbles[index]

                RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                    .fill(bubble.outgoing ? DS.Colors.bubbleOutgoing.opacity(0.25) : DS.Colors.bubbleIncoming)
                    .frame(width: bubble.width, height: bubble.height)
                    .frame(maxWidth: .infinity, alignment: bubble.outgoing ? .trailing : .leading)
            }
        }
        .padding(.horizontal, DS.Metrics.chatGutter)
        .padding(.bottom, 12)
        .allowsHitTesting(false)
        .skeleton()
    }
}

/// The day a run of messages was sent, which floats at the top of the list while scrolling through that day.
struct DaySeparator: View {
    let date: Date

    var body: some View {
        ServicePill(text: Formatting.daySeparator(date))
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The top of a thread: who it is with, so an empty one isn't just blank.
struct ThreadIntro: View {
    @Environment(Session.self) private var session
    let thread: ThreadModel

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            if let partner = thread.partner {
                Avatar(user: partner, size: 64)
                    .padding(.bottom, DS.Spacing.xs)
                Text(partner.displayName)
                    .font(DS.Fonts.section)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Text("@" + partner.handle)
                    .font(DS.Fonts.monoHandle)
                    .foregroundStyle(DS.Colors.inkMuted)

                if let bio = partner.bio, !bio.isEmpty {
                    Text(bio)
                        .font(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 360)
                }
            } else {
                OrgAvatar(members: thread.members.map(\.user).filter { $0.id != session.user?.id }, size: 64)
                    .padding(.bottom, DS.Spacing.xs)
                Text(thread.orgName.flatMap { $0.isEmpty ? nil : $0 } ?? "Org")
                    .font(DS.Fonts.section)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Text(thread.members.count == 1 ? "1 member" : "\(thread.members.count) members")
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct TypingBubble: View {
    var body: some View {
        TypingDots(color: DS.Colors.inkFaint, size: 7)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .padding(.leading, BubbleShape.tailWidth)
            .background(Palette.incoming, in: BubbleShape(isOutgoing: false, hasTail: true))
            .accessibilityLabel("Typing")
    }
}

/// Three dots bouncing in turn, for "typing" in the thread, its title and the inbox.
struct TypingDots: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: size * 0.6) {
                ForEach(0 ..< 3) { index in
                    let wave = max(0, sin(time * 6 - Double(index) * 0.9))

                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .opacity(0.4 + 0.6 * wave)
                        .offset(y: -size * 0.35 * wave)
                }
            }
        }
        .frame(height: size * 1.5)
    }
}

/// What the composer is replaced with when the user can't push: a request to merge or drop, or why they can't write.
struct AccessBanner: View {
    @Environment(Inbox.self) private var inbox
    let thread: ThreadModel
    let notice: String

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Text(notice)
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if thread.access == .request {
                HStack(spacing: DS.Spacing.m) {
                    Button("Drop") { Task { await inbox.drop(thread.reference) } }
                        .buttonStyle(.dsOutline)
                        .help("Decline the request and hide this remote")
                    Button("Merge") { Task { await inbox.merge(thread.reference) } }
                        .buttonStyle(.dsPrimary)
                        .keyboardShortcut(.defaultAction)
                        .help("Accept the request and move this remote to Open")
                }
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity)
        .background(DS.Colors.surface)
        .overlay(alignment: .top) { DS.Colors.hairline.frame(height: 1) }
    }
}

enum AttachmentLoader {
    /// Reads images from a drop or a paste, as attachments the API takes (PNG, JPEG, GIF or WebP).
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([Attachment]) -> Void) {
        Task {
            var attachments: [Attachment] = []

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let fileURL = URL(dataRepresentation: url, relativeTo: nil),
                   let attachment = attachment(fileAt: fileURL) {
                    attachments.append(attachment)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          let data = await withCheckedContinuation({ continuation in
                              _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in continuation.resume(returning: data) }
                          }),
                          let attachment = attachment(data: data, filename: "image") {
                    attachments.append(attachment)
                }
            }

            await completion(attachments)
        }
    }

    static func attachment(fileAt url: URL) -> Attachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        return attachment(data: data, filename: url.lastPathComponent)
    }

    /// Keeps GIFs, PNGs, JPEGs and WebPs as they are, and turns anything else (HEIC, TIFF from a paste) into a PNG.
    static func attachment(data: Data, filename: String) -> Attachment? {
        let signatures: [(prefix: [UInt8], mime: String, ext: String)] = [
            ([0x89, 0x50, 0x4E, 0x47], "image/png", "png"),
            ([0xFF, 0xD8, 0xFF], "image/jpeg", "jpg"),
            ([0x47, 0x49, 0x46], "image/gif", "gif"),
        ]

        if let match = signatures.first(where: { data.starts(with: $0.prefix) }) {
            return Attachment(data: data, mimeType: match.mime, filename: "image.\(match.ext)")
        }

        if data.count > 12, data[8 ..< 12] == Data("WEBP".utf8) {
            return Attachment(data: data, mimeType: "image/webp", filename: "image.webp")
        }

        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return Attachment(data: png, mimeType: "image/png", filename: "image.png")
    }
}
