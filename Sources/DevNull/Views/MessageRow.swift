import AppKit
import SwiftUI

/// What the rows of an open thread share: the message to flash after jumping to it, and how to open images and the
/// emoji picker anchored on a row.
@MainActor
@Observable
final class ChatState {
    var highlighted: Int?

    @ObservationIgnored let list = MessageListController()
    @ObservationIgnored var openImage: (MessageImage) -> Void = { _ in }

    @ObservationIgnored weak var thread: ThreadModel?

    #if DEBUG
        /// The preview's stand-ins for hovering a message and opening its reaction picker, which scripts can't do.
        var previewHover: Int?
        var previewPicker: Int?
    #endif

    /// Scrolls to a message and flashes it, as tapping a reply does, loading older pages first when it's further back.
    func jump(to id: Int) {
        Task {
            guard let thread, await thread.loadUntil(id) else { return }

            // Let the list take in the older pages before scrolling to the message.
            try? await Task.sleep(for: .milliseconds(30))
            flash(id)
        }
    }

    private func flash(_ id: Int) {
        guard list.scroll(toMessage: id) else { return }

        highlighted = id

        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.4)) { if self.highlighted == id { self.highlighted = nil } }
        }
    }
}

/// The view a row of the message list shows.
struct ChatRowView: View {
    let row: ChatRow
    let thread: ThreadModel

    var body: some View {
        switch row.kind {
        case .intro:
            ThreadIntro(thread: thread)
        case .loadingOlder:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        case let .day(date):
            DaySeparator(date: date)
        case .unread:
            UnreadSeparator()
        case let .message(message, layout, status):
            MessageRow(thread: thread, message: message, layout: layout, status: status)
        case let .receipt(receipt):
            PullReceiptView(receipt: receipt)
        case let .typing(handles):
            TypingRow(thread: thread, handles: handles)
        case .end:
            // Breathing room between the last message and the composer.
            Color.clear.frame(height: 10)
        }
    }
}

struct MessageRow: View {
    @Environment(Session.self) private var session
    @Environment(ChatState.self) private var chat
    let thread: ThreadModel
    let message: Message
    let layout: MessageLayout
    let status: PendingMessage.Status?

    @State private var hovering = false
    @State private var hoverEnd: Task<Void, Never>?
    @State private var showsPicker = false

    /// A hairline around incoming bubbles in light mode, where white bubbles would otherwise melt into the wash.
    static let incomingBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .clear : NSColor(hex: 0xE1E4E8)
    })

    /// The gap between a bubble and its hover actions, and the room the row keeps beside bubbles for them.
    private static let actionsGap: CGFloat = 6
    private static let actionsRoom: CGFloat = 64

    private var sender: User? { message.user ?? thread.user(message.userId) }

    private var isHovered: Bool {
        #if DEBUG
            if chat.previewHover == message.id { return true }
        #endif
        return hovering
    }
    private var outgoing: Bool { layout.isOutgoing }

    var body: some View {
        if message.isEvent {
            ServicePill(text: MessageText.eventText(message, me: session.user?.id, partner: thread.partner))
                .multilineTextAlignment(.center)
                .padding(.vertical, 6)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
        } else {
            bubbleRow
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: DS.Metrics.chatAvatarGap) {
            if outgoing {
                Spacer(minLength: Self.actionsRoom)
                if case let .failed(reason) = status {
                    failedButton(reason)
                }
            } else if layout.showsSender {
                Group {
                    if layout.isLastInGroup {
                        Button { openProfile(sender) } label: { Avatar(user: sender, size: DS.Metrics.chatAvatar) }
                            .buttonStyle(.plain)
                            .help("@" + (sender?.handle ?? ""))
                    } else {
                        Color.clear.frame(width: DS.Metrics.chatAvatar, height: 1)
                    }
                }
            }

            Group {
                if isJumbo {
                    jumbo
                } else {
                    bubble
                }
            }
            // The actions hug the bubble's outer edge as an overlay, so hovering never changes the row's size.
            .overlay(alignment: outgoing ? .bottomLeading : .bottomTrailing) {
                // A zero-width slot on the edge: the actions hang outside it, away from the bubble.
                hoverActions
                    .fixedSize()
                    .frame(width: 0, alignment: outgoing ? .trailing : .leading)
                    .offset(x: outgoing ? -Self.actionsGap : Self.actionsGap)
            }
            .frame(maxWidth: DS.Metrics.bubbleMaxWidth, alignment: outgoing ? .trailing : .leading)

            if !outgoing {
                Spacer(minLength: Self.actionsRoom)
            }
        }
        .padding(.horizontal, DS.Metrics.chatGutter)
        .padding(.top, layout.isFirstInGroup ? 7 : 1.5)
        .padding(.bottom, layout.isLastInGroup ? 1.5 : 0)
        .background(chat.highlighted == message.id ? DS.Colors.primarySoft : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            hoverEnd?.cancel()

            if inside {
                hovering = true
            } else {
                // A short grace, so the actions don't blink away while the pointer crosses to them.
                hoverEnd = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !Task.isCancelled { hovering = false }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        #if DEBUG
            .onChange(of: chat.previewPicker) { showsPicker = chat.previewPicker == message.id }
        #endif
    }

    // MARK: - Bubble

    private var foreground: Color { outgoing ? DS.Colors.onPrimary : DS.Colors.ink }

    /// Time and receipt inside a bubble: quieter than its text, as Telegram's meta reads.
    private var metaColor: Color { outgoing ? DS.Colors.onPrimary.opacity(0.72) : DS.Colors.inkMuted }

    private var onlyImages: Bool {
        (message.body ?? "").isEmpty && !(message.images ?? []).isEmpty && message.replyTo == nil && message.replyToId == nil && message.voice == nil && message.linkPreview == nil
    }

    private var reactions: [Reaction] { message.reactions ?? [] }

    private var bubble: some View {
        let blocks = MessageText.blocks(message, mentioned: Set(mentionedHandles), outgoing: outgoing)
        let endsWithText = reactions.isEmpty && message.linkPreview == nil && {
            switch blocks.last {
            case .text?, .quote?: true
            default: false
            }
        }()
        // A voice note's duration sits on the left of its last line, leaving room for the time on the right.
        let voiceOnly = reactions.isEmpty && message.voice != nil && blocks.isEmpty
        let inlineTime = endsWithText || voiceOnly
        let tail = layout.isLastInGroup && !onlyImages
        let shape = BubbleShape(isOutgoing: outgoing, isFirst: layout.isFirstInGroup, hasTail: tail, reservesTail: !onlyImages)
        let showsName = layout.showsSender && layout.isFirstInGroup && !outgoing
        // Media runs edge to edge, like Telegram's: flush with the bubble's top when nothing sits above it.
        let mediaOnTop = !showsName && message.replyTo == nil && message.replyToId == nil

        return BubbleStack(spacing: 4, trailsLast: !inlineTime) {
            if showsName {
                Button { openProfile(sender) } label: {
                    Text(sender?.displayName ?? "Someone")
                        .font(DS.Fonts.senderName)
                        .foregroundStyle(LaneColor.of(sender))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("@" + (sender?.handle ?? ""))
                .padding(.horizontal, onlyImages ? 10 : 0)
                .padding(.top, onlyImages ? 6 : 0)
            }

            if let reply = message.replyTo {
                ReplyGhostView(ghost: reply, author: thread.user(reply.userId), outgoing: outgoing)
                    .onTapGesture { chat.jump(to: reply.id) }
            } else if message.replyToId != nil {
                Text("Replying to a message you can't see")
                    .font(DS.Fonts.chatCaption)
                    .foregroundStyle(metaColor)
            }

            if let images = message.images, !images.isEmpty {
                ImageGrid(images: images, open: { chat.openImage($0) })
                    .overlay(alignment: .bottomTrailing) {
                        if onlyImages, reactions.isEmpty {
                            timeLabel(.white)
                                .padding(.horizontal, DS.Spacing.s)
                                .padding(.vertical, DS.Spacing.xxs)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                                .padding(DS.Spacing.m)
                        }
                    }
                    .clipShape(onlyImages ? AnyShape(shape) : AnyShape(Rectangle()))
                    .padding(.horizontal, onlyImages ? 0 : -DS.Metrics.bubblePadding.leading)
                    .padding(.top, !onlyImages && mediaOnTop ? -DS.Metrics.bubblePadding.top : 0)
                    .layoutValue(key: BubbleMedia.self, value: true)
            }

            if let voice = message.voice {
                VoiceNoteView(voice: voice, outgoing: outgoing, upcoming: { thread.voiceNotes(after: message.id) })
            }

            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case let .text(text):
                    Text(index == blocks.count - 1 && endsWithText ? text + timePlaceholder : text)
                        .font(DS.Fonts.chatBody)
                        .foregroundStyle(foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .quote(text):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(foreground.opacity(0.5))
                            .frame(width: 3)
                        Text(index == blocks.count - 1 && endsWithText ? text + timePlaceholder : text)
                            .font(DS.Fonts.chatBody)
                            .foregroundStyle(foreground.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case let .code(language, code):
                    CodeBlockView(language: language, code: code, outgoing: outgoing)
                }
            }

            if let preview = message.linkPreview {
                LinkCard(preview: preview, outgoing: outgoing)
            }

            if !reactions.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    ReactionChips(thread: thread, message: message, reactions: reactions, outgoing: outgoing)
                    Spacer(minLength: 0)
                    timeLabel(metaColor)
                }
                .padding(.top, 2)
                // Under a lone image there's no bubble padding to sit in.
                .padding(onlyImages ? EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8) : EdgeInsets())
            } else if !inlineTime, !onlyImages {
                timeLabel(metaColor)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if inlineTime {
                timeLabel(metaColor).offset(y: voiceOnly ? -2 : 1)
            }
        }
        .padding(.horizontal, onlyImages ? 0 : DS.Metrics.bubblePadding.leading)
        .padding(outgoing ? .trailing : .leading, onlyImages ? 0 : BubbleShape.tailWidth)
        .padding(.top, onlyImages ? 0 : DS.Metrics.bubblePadding.top)
        .padding(.bottom, onlyImages ? 0 : DS.Metrics.bubblePadding.bottom)
        .background(outgoing ? Palette.outgoing : Palette.incoming, in: shape)
        .clipShape(shape)
        .overlay { if !outgoing { shape.stroke(Self.incomingBorder, lineWidth: 1) } }
        // Image-only bubbles have no tail; they keep its room outside so they line up with the rest of their group.
        .padding(outgoing ? .trailing : .leading, onlyImages ? BubbleShape.tailWidth : 0)
        .opacity(status.map { if case .failed = $0 { return 0.6 }; return 1 } ?? 1)
        .onTapGesture(count: 2) { if status == nil, thread.canPush { thread.toggleReaction(Reactions.doubleTap, on: message) } }
        .popover(isPresented: $showsPicker, arrowEdge: .top) {
            EmojiPicker(mode: .reaction(selected: Set(reactions.filter { $0.userId == session.user?.id }.map(\.emoji)))) { emoji in
                showsPicker = false
                thread.toggleReaction(emoji, on: message)
            }
        }
    }

    // MARK: - Jumbo emoji

    /// One to three emoji on their own show big and without a bubble, as Telegram does.
    private var isJumbo: Bool {
        guard let body = message.body?.trimmingCharacters(in: .whitespaces), !body.isEmpty, body.count <= 3,
              message.images?.isEmpty ?? true, message.voice == nil, message.replyToId == nil, message.linkPreview == nil
        else { return false }

        return MessageText.isOnlyEmoji(MessageText.emojify(body))
    }

    private var jumbo: some View {
        let body = MessageText.emojify(message.body ?? "")

        return VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
            if layout.showsSender, layout.isFirstInGroup, !outgoing {
                Text(sender?.displayName ?? "Someone")
                    .font(DS.Fonts.senderName)
                    .foregroundStyle(LaneColor.of(sender))
                    .lineLimit(1)
            }

            Text(body)
                .font(.system(size: body.count == 1 ? 52 : 40))
                .onTapGesture(count: 2) { if status == nil, thread.canPush { thread.toggleReaction(Reactions.doubleTap, on: message) } }

            HStack(spacing: 6) {
                if !reactions.isEmpty {
                    ReactionChips(thread: thread, message: message, reactions: reactions, outgoing: false, onChat: true)
                }

                // On the chat background, like the day pills, since there's no bubble to sit in.
                timeLabel(DS.Colors.inkMuted)
                    .padding(.horizontal, DS.Spacing.s + 1)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(Palette.servicePill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            }
        }
        .padding(outgoing ? .trailing : .leading, BubbleShape.tailWidth)
        .popover(isPresented: $showsPicker, arrowEdge: .top) {
            EmojiPicker(mode: .reaction(selected: Set(reactions.filter { $0.userId == session.user?.id }.map(\.emoji)))) { emoji in
                showsPicker = false
                thread.toggleReaction(emoji, on: message)
            }
        }
    }

    // MARK: - Time

    private var time: String {
        message.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private func timeLabel(_ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(time)
                .font(DS.Fonts.monoMeta)

            if outgoing {
                ReceiptMark(state: receiptState)
            }
        }
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }

    /// Invisible text as wide as the time, ending the last line, so the time sits on that line when it fits and on a
    /// line of its own when it doesn't, like Telegram and WhatsApp lay bubbles out.
    private var timePlaceholder: AttributedString {
        var placeholder = AttributedString("\u{2002}\u{2002}" + time + (outgoing ? "\u{2002}\u{2003}" : ""))
        placeholder.font = DS.Fonts.monoMeta
        placeholder.foregroundColor = .clear
        return placeholder
    }

    private var receiptState: ReceiptMark.State {
        switch status {
        case .sending?: .sending
        case .failed?: .failed
        case nil: isPulled ? .pulled : .pushed
        }
    }

    /// Pulled by the partner, or in an org by anyone else, as Telegram's double check means "read" in a group.
    private var isPulled: Bool {
        thread.isOrg ? !thread.readers(of: message).isEmpty : thread.partnerReadThroughId >= message.id
    }

    /// The people the message mentions, as the API found them, or the thread's people named in it while pending.
    private var mentionedHandles: [String] {
        if let mentions = message.mentions {
            return mentions.map { $0.handle.lowercased() }
        }

        let known = ([thread.partner, session.user?.asUser].compactMap { $0 } + thread.members.map(\.user)).map { $0.handle.lowercased() }
        let body = message.body ?? ""

        return known.filter { body.localizedCaseInsensitiveContains("@" + $0) }
    }

    private var accessibilityText: String {
        let who = outgoing ? "You" : sender?.displayName ?? "Someone"
        let text = MessageText.preview(message, members: [], me: session.user?.id)
        let state = switch receiptState {
        case .sending: ", sending"
        case .failed: ", not sent"
        case .pulled: ", pulled"
        case .pushed: outgoing ? ", pushed" : ""
        }

        return "\(who): \(text), \(time)\(state)"
    }

    // MARK: - Actions

    @ViewBuilder
    private var hoverActions: some View {
        if thread.canPush, status == nil {
            HStack(spacing: 0) {
                Button { showsPicker = true } label: { Image(systemName: "face.smiling") }
                    .help("React")
                    .accessibilityLabel("React")

                Button { thread.replyingTo = message } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .help("Reply")
                    .accessibilityLabel("Reply")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .padding(2)
            .background(Palette.servicePill, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))
            .opacity(isHovered || showsPicker ? 1 : 0)
            .allowsHitTesting(isHovered || showsPicker)
            .animation(DS.Motion.quick, value: isHovered || showsPicker)
        }
    }

    private func failedButton(_ reason: String) -> some View {
        Menu {
            Button("Try Again") { if let pending = thread.pending.first(where: { $0.clientId == message.clientId }) { thread.retry(pending) } }
            Button("Delete", role: .destructive) { if let pending = thread.pending.first(where: { $0.clientId == message.clientId }) { thread.discard(pending) } }
        } label: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(reason)
        .accessibilityLabel("Not sent. Try again or delete.")
        .padding(.bottom, 4)
    }

    private func openProfile(_ user: User?) {
        guard let user else { return }
        NSWorkspace.shared.open(APIClient.baseURL.appending(path: "@" + user.handle))
    }
}

/// Stacks a bubble's parts as narrow as its widest part, like chat apps size bubbles to their text, with the last part,
/// the time, on the trailing edge.
struct BubbleStack: Layout {
    var spacing: CGFloat
    /// Whether the last part is the time on a row of its own, which sits on the trailing edge.
    var trailsLast = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(proposal: proposal, subviews: subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }

        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let x = trailsLast && index == subviews.count - 1 ? bounds.maxX - size.width : bounds.minX

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            y += size.height + spacing
        }
    }

    /// The widest part at its ideal width, no wider than offered: text that fits on one line keeps the bubble narrow,
    /// and parts that stretch, like the reactions row, don't widen it. Media decides alone when there is some, so a
    /// caption wraps under its image instead of widening the bubble past it.
    private func width(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        let available = proposal.width ?? .infinity
        let media = subviews.filter { $0[BubbleMedia.self] }
        let ideal = (media.isEmpty ? Array(subviews) : media).map { min($0.sizeThatFits(.unspecified).width, available) }

        return min(ideal.max() ?? 0, available)
    }
}

/// Marks a bubble's images, whose width the bubble takes.
struct BubbleMedia: LayoutValueKey {
    static let defaultValue = false
}

struct ReceiptMark: View {
    enum State {
        case sending
        case failed
        case pushed
        case pulled
    }

    let state: State

    var body: some View {
        // Every state draws in the same 15-point slot, so the time doesn't move when the clock becomes a check.
        ZStack(alignment: .leading) {
            switch state {
            case .sending:
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
            case .pushed:
                Image(systemName: "checkmark")
            case .pulled:
                Image(systemName: "checkmark")
                Image(systemName: "checkmark").offset(x: 4)
            }
        }
        .font(.system(size: 9, weight: .bold))
        .frame(width: 15, alignment: .leading)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.15), value: state)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .sending: "Sending"
        case .failed: "Not sent"
        case .pushed: "Pushed"
        case .pulled: "Pulled"
        }
    }
}

/// A chat bubble. The corners facing the next and previous messages of a group are tighter, and the last message of a
/// group has a tail that sweeps out of its bottom corner, as in Telegram. The tail is drawn inside the shape's own rect,
/// in room the bubble keeps on that side, so clipping never cuts it off. Body and tail are one continuous outline, so
/// the light-mode hairline never strokes a seam between them and no part overlaps another.
struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 7

    let isOutgoing: Bool
    var isFirst = true
    let hasTail: Bool
    var reservesTail = true

    func path(in rect: CGRect) -> Path {
        let radius = DS.Radius.bubble
        let inner: CGFloat = 5
        let top = isFirst ? radius : inner
        let inset = reservesTail ? Self.tailWidth : 0
        let body = CGRect(x: rect.minX + (isOutgoing ? 0 : inset), y: rect.minY, width: rect.width - inset, height: rect.height)
        let clamp = { (value: CGFloat) in min(value, body.width / 2, body.height / 2) }
        // The tail grows out of a square corner, so the two read as one shape.
        let senderBottom = clamp(hasTail ? 0 : inner)
        let topLeading = clamp(isOutgoing ? radius : top)
        let topTrailing = clamp(isOutgoing ? top : radius)
        let bottomTrailing = isOutgoing ? senderBottom : clamp(radius)
        let bottomLeading = isOutgoing ? clamp(radius) : senderBottom
        let tailTop = min(17, body.height)

        var path = Path()
        path.move(to: CGPoint(x: body.minX + topLeading, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - topTrailing, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + topTrailing), radius: topTrailing)

        if hasTail, isOutgoing {
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - tailTop))
            path.addCurve(to: CGPoint(x: body.maxX + Self.tailWidth, y: body.maxY), control1: CGPoint(x: body.maxX, y: body.maxY - 6), control2: CGPoint(x: body.maxX + 3, y: body.maxY - 1.5))
        } else {
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - bottomTrailing))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - bottomTrailing, y: body.maxY), radius: bottomTrailing)
        }

        if hasTail, !isOutgoing {
            path.addLine(to: CGPoint(x: body.minX - Self.tailWidth, y: body.maxY))
            path.addCurve(to: CGPoint(x: body.minX, y: body.maxY - tailTop), control1: CGPoint(x: body.minX - 3, y: body.maxY - 1.5), control2: CGPoint(x: body.minX, y: body.maxY - 6))
        } else {
            path.addLine(to: CGPoint(x: body.minX + bottomLeading, y: body.maxY))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - bottomLeading), radius: bottomLeading)
        }

        path.addLine(to: CGPoint(x: body.minX, y: body.minY + topLeading))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + topLeading, y: body.minY), radius: topLeading)
        path.closeSubpath()

        return path
    }
}

struct ReplyGhostView: View {
    let ghost: ReplyGhost
    let author: User?
    let outgoing: Bool

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(outgoing ? Color.white : LaneColor.of(author))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(author?.displayName ?? "Message")
                    .font(DS.Fonts.chatCaptionStrong)
                    .foregroundStyle(outgoing ? Color.white : LaneColor.of(author))
                    .lineLimit(1)
                Text(text)
                    .font(DS.Fonts.chatCaption)
                    .foregroundStyle(outgoing ? Color.white.opacity(0.85) : DS.Colors.inkMuted)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)

            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .background((outgoing ? Color.white : LaneColor.of(author)).opacity(outgoing ? 0.14 : 0.1), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .help("Jump to the message")
    }

    private var text: String {
        let body = MessageText.emojify(ghost.body ?? "").replacingOccurrences(of: "\n", with: " ")

        if body.isEmpty, (ghost.imagesCount ?? 0) > 0 { return "📷 Photo" }
        if ghost.hasVoice == true { return "🎤 Voice note" }

        return body
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    let outgoing: Bool

    @State private var copied = false

    var body: some View {
        let ink = outgoing ? DS.Colors.onPrimary : DS.Colors.ink

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(ink.opacity(0.6))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true

                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 22, tint: ink.opacity(0.7)))
                .help(copied ? "Copied" : "Copy code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 3)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(DS.Fonts.code)
                    .foregroundStyle(ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
        }
        // Inside a blue bubble the block darkens it; inside a light one it's a step off the bubble, like the web's pre.
        .background(outgoing ? AnyShapeStyle(Color.black.opacity(0.16)) : AnyShapeStyle(DS.Colors.shell), in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay {
            if !outgoing {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline)
            }
        }
    }
}

struct LinkCard: View {
    let preview: LinkPreview
    let outgoing: Bool

    var body: some View {
        let accent = outgoing ? DS.Colors.onPrimary : DS.Colors.primary
        let ink = outgoing ? DS.Colors.onPrimary : DS.Colors.ink

        Button {
            if let url = URL(string: preview.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    if let site = preview.siteName ?? URL(string: preview.url)?.host() {
                        Text(site)
                            .font(DS.Fonts.chatCaptionStrong)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                    if let title = preview.title {
                        Text(title)
                            .font(DS.Fonts.bodyMedium.weight(.semibold))
                            .foregroundStyle(ink)
                            .lineLimit(2)
                    }
                    if let description = preview.description {
                        Text(description)
                            .font(DS.Fonts.chatCaption)
                            .foregroundStyle(ink.opacity(0.8))
                            .lineLimit(3)
                    }
                    if let image = preview.imageUrl.flatMap(URL.init(string:)) {
                        RemoteImage(url: image) { (outgoing ? Color.white.opacity(0.12) : DS.Colors.wash) }
                            .frame(maxWidth: 320)
                            .frame(height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                            .padding(.top, 4)
                    }
                }
                .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preview.url)
    }
}

/// One to three images in a mosaic, each registering where it is on screen so the lightbox can zoom out of it and
/// back into it.
struct ImageGrid: View {
    let images: [MessageImage]
    let open: (MessageImage) -> Void

    var body: some View {
        if images.count == 1, let image = images.first {
            tile(image)
                .frame(width: Self.size(image).width, height: Self.size(image).height)
        } else {
            // Two images share the width evenly; three put the first beside the other two stacked.
            HStack(spacing: 2) {
                tile(images[0]).frame(width: images.count == 2 ? 160 : 180, height: 220)
                VStack(spacing: 2) {
                    ForEach(images.dropFirst()) { image in
                        tile(image).frame(width: images.count == 2 ? 160 : 140, height: images.count == 2 ? 220 : 109)
                    }
                }
            }
        }
    }

    private func tile(_ image: MessageImage) -> some View {
        RemoteImage(url: URL(string: image.url)) {
            Rectangle().fill(DS.Colors.rail.opacity(0.6))
        }
        .background(ImageAnchor(id: image.id))
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { open(image) }
        .accessibilityLabel(image.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Image")
        .accessibilityAddTraits(.isButton)
        .help(image.description ?? "")
    }

    /// Fits the image in 320×360 keeping its shape, as messaging apps do.
    static func size(_ image: MessageImage) -> CGSize {
        let width = CGFloat(image.width ?? 320)
        let height = CGFloat(image.height ?? 240)
        let scale = min(320 / width, 360 / height, 1.5)

        return CGSize(width: max(120, (width * scale).rounded()), height: max(90, (height * scale).rounded()))
    }
}

struct VoiceNoteView: View {
    let voice: MessageVoice
    let outgoing: Bool
    let upcoming: () -> [MessageVoice]

    private var player: VoicePlayer { .shared }
    private static let waveformWidth: CGFloat = 170

    var body: some View {
        let active = player.currentId == voice.id
        let playing = active && player.isPlaying
        let tint: Color = outgoing ? .white : DS.Colors.primaryFill
        let url = URL(string: voice.url)

        HStack(spacing: 10) {
            Button {
                if let url { player.toggle(voice, url: url, upcoming: upcoming()) }
            } label: {
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(outgoing ? Palette.outgoing : .white)
                        .offset(x: playing ? 0 : 1)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(url == nil || voice.url.isEmpty)
            .help(playing ? "Pause" : "Play")
            .accessibilityLabel(playing ? "Pause voice note" : "Play voice note")

            VStack(alignment: .leading, spacing: 3) {
                Waveform(levels: voice.waveform.map { Double($0) / 100 }, progress: active ? player.progress : 0, tint: tint, idle: (outgoing ? Color.white : DS.Colors.ink).opacity(0.3))
                    .frame(width: Self.waveformWidth, height: 24)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard let url, !voice.url.isEmpty else { return }
                        player.seek(voice, url: url, to: value.location.x / Self.waveformWidth, upcoming: upcoming())
                    })
                    .accessibilityLabel("Waveform")
                    .accessibilityValue("\(Int((active ? player.progress : 0) * 100)) percent")

                HStack(spacing: 6) {
                    Text(Formatting.duration(active ? player.elapsed : Double(voice.durationMs) / 1000))
                        .font(DS.Fonts.monoMeta)
                        .foregroundStyle(outgoing ? Color.white.opacity(0.8) : DS.Colors.inkMuted)

                    if active {
                        VolumeButton(outgoing: outgoing)
                            .transition(.opacity)

                        Button(rateLabel) { player.cycleRate() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((outgoing ? Color.white : DS.Colors.ink).opacity(0.15), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                            .foregroundStyle(outgoing ? Color.white : DS.Colors.ink)
                            .help("Playback speed")
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.15), value: active)
    }

    private var rateLabel: String {
        switch player.rate {
        case 1.5: "1.5×"
        case 2: "2×"
        default: "1×"
        }
    }
}

/// The speaker next to a playing voice note, with a slider for how loud voice notes play on this Mac.
private struct VolumeButton: View {
    let outgoing: Bool

    @State private var showsSlider = false

    var body: some View {
        @Bindable var player = VoicePlayer.shared

        Button { showsSlider.toggle() } label: {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : player.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10))
                .frame(width: 16, height: 14)
                .foregroundStyle(outgoing ? Color.white.opacity(0.8) : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Volume")
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(player.volume * 100)) percent")
        .popover(isPresented: $showsSlider, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0 ... 1)
                    .frame(width: 140)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

struct Waveform: View {
    let levels: [Double]
    let progress: Double
    let tint: Color
    let idle: Color

    var body: some View {
        Canvas { context, size in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let width = max(1.5, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

            for (index, level) in levels.enumerated() {
                let height = max(3, size.height * level)
                let rect = CGRect(x: CGFloat(index) * (width + spacing), y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(Double(index) / Double(count) < progress ? tint : idle))
            }
        }
    }
}

struct ReactionChips: View {
    @Environment(Session.self) private var session
    let thread: ThreadModel
    let message: Message
    let reactions: [Reaction]
    let outgoing: Bool
    /// On the chat background (under a jumbo emoji) rather than inside a bubble.
    var onChat = false

    var body: some View {
        let grouped = reactions.reduce(into: [(emoji: String, users: [String])]()) { result, reaction in
            if let index = result.firstIndex(where: { $0.emoji == reaction.emoji }) {
                result[index].users.append(reaction.userId)
            } else {
                result.append((reaction.emoji, [reaction.userId]))
            }
        }

        WrappingHStack(spacing: 4) {
            ForEach(grouped, id: \.emoji) { group in
                let mine = group.users.contains(session.user?.id ?? "")

                Button {
                    thread.toggleReaction(group.emoji, on: message)
                } label: {
                    HStack(spacing: 4) {
                        Text(group.emoji)
                            .font(.system(size: 14))

                        // In orgs, a few reactions show who reacted; more show how many, as Telegram does.
                        if thread.isOrg, group.users.count <= 3 {
                            HStack(spacing: -5) {
                                ForEach(group.users, id: \.self) { id in
                                    Avatar(user: thread.user(id), size: 17)
                                }
                            }
                        } else if group.users.count > 1 || thread.isOrg {
                            Text("\(group.users.count)")
                                .font(DS.Fonts.monoCaption.weight(.semibold))
                                .contentTransition(.numericText())
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: DS.Metrics.reactionHeight)
                    .foregroundStyle(chipForeground(mine))
                    .background(chipBackground(mine), in: RoundedRectangle(cornerRadius: DS.Radius.md))
                    .overlay {
                        if mine, !outgoing {
                            RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Colors.primary, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!thread.canPush)
                .help(group.users.compactMap { thread.user($0).map { "@" + $0.handle } }.joined(separator: ", "))
                .accessibilityLabel("\(group.emoji), \(group.users.count) \(group.users.count == 1 ? "reaction" : "reactions")\(mine ? ", including yours" : "")")
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: reactions)
    }

    private func chipForeground(_ mine: Bool) -> Color {
        if outgoing { return mine ? Palette.outgoing : .white }
        return mine ? DS.Colors.primary : DS.Colors.ink
    }

    private func chipBackground(_ mine: Bool) -> Color {
        if outgoing { return mine ? .white : .white.opacity(0.18) }
        return mine ? DS.Colors.primarySoft : onChat ? DS.Colors.servicePill : DS.Colors.bubbleInset
    }
}

/// Lays chips out in rows, wrapping to the next row when the next chip doesn't fit.
struct WrappingHStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))

        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0

        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX

            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }

            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }

            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }

        return rows
    }
}

/// "Pulled 14:32" under the user's last message in a DM, or the avatars of who pulled the latest message in an org.
struct PullReceiptView: View {
    let receipt: PullReceipt

    var body: some View {
        HStack(spacing: 5) {
            if receipt.isOutgoing { Spacer() }

            if receipt.total == 1, receipt.readers.count == 1, let pulledAt = receipt.pulledAt {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("Pulled \(Formatting.pulledTime(pulledAt))")
            } else {
                Text("Pulled by")

                if receipt.readers.count == receipt.total, receipt.total > 3 {
                    Text("everyone").fontWeight(.semibold)
                } else {
                    HStack(spacing: -4) {
                        ForEach(receipt.readers.prefix(5)) { user in
                            Avatar(user: user, size: 16)
                                .overlay(Circle().stroke(Palette.chatBackground, lineWidth: 1.5))
                        }
                    }

                    if receipt.readers.count > 5 {
                        Text("+\(receipt.readers.count - 5)").monospacedDigit()
                    }
                }
            }

            if !receipt.isOutgoing { Spacer() }
        }
        .font(DS.Fonts.caption)
        .foregroundStyle(DS.Colors.inkMuted)
        // Lined up with the bubbles' body edges: past the avatar and the tail's room.
        .padding(.leading, receipt.isOutgoing ? 0 : DS.Metrics.chatGutter + DS.Metrics.chatAvatar + DS.Metrics.chatAvatarGap + BubbleShape.tailWidth)
        .padding(.trailing, receipt.isOutgoing ? DS.Metrics.chatGutter + BubbleShape.tailWidth : 0)
        .padding(.top, 3)
        .padding(.bottom, 2)
        .help(receipt.readers.map { "@" + $0.handle }.joined(separator: ", "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(receipt.pulledAt.map { "Pulled \(Formatting.pulledTime($0))" } ?? "Pulled by \(receipt.readers.map(\.displayName).joined(separator: ", "))")
    }
}

/// The bar above the first message that was unread when the thread opened.
struct UnreadSeparator: View {
    var body: some View {
        Text("Unread Messages")
            .font(DS.Fonts.label)
            .foregroundStyle(DS.Colors.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(DS.Colors.primarySoft)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Who is typing, as a bubble with bouncing dots under the last message, with their avatar in an org.
struct TypingRow: View {
    let thread: ThreadModel
    let handles: [String]

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Metrics.chatAvatarGap) {
            if thread.isOrg {
                Avatar(user: thread.members.first { $0.user.handle == handles.first }?.user, size: DS.Metrics.chatAvatar)
            }

            TypingBubble()

            Spacer()
        }
        .padding(.horizontal, DS.Metrics.chatGutter)
        .padding(.top, 7)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(handles.count == 1 ? "@\(handles[0]) is typing" : "\(handles.count) people are typing")
    }
}
