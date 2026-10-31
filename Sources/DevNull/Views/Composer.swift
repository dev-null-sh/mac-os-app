import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// What the composer suggests for the word being typed: people for "@", emoji for ":".
enum Completion: Equatable {
    case mention(query: String, range: NSRange)
    case emoji(query: String, range: NSRange)
    /// `#12` in a commit, for the repository's GitHub issue suggestions.
    case issue(query: String, range: NSRange)

    var range: NSRange {
        switch self {
        case let .mention(_, range), let .emoji(_, range), let .issue(_, range): range
        }
    }
}

struct Suggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let user: User?
    let emoji: String?
    let insertion: String
}

/// Lets SwiftUI reach the composer's text view: inserting emoji where the cursor is, completing a word, focusing.
@MainActor
final class ComposerHandle {
    weak var textView: NSTextView?

    func insert(_ text: String) {
        guard let textView else { return }

        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func replace(_ range: NSRange, with text: String) {
        guard let textView, NSMaxRange(range) <= (textView.string as NSString).length else { return }

        textView.insertText(text, replacementRange: range)
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

struct Composer: View {
    @Environment(Session.self) private var session
    @Bindable var thread: ThreadModel

    @State private var recorder = VoiceRecorder()
    @State private var recordState = RecordState.idle
    @State private var dragOffset = CGSize.zero
    @State private var pressStartedAt = Date.distantPast
    @State private var height: CGFloat = 20
    @State private var completion: Completion?
    @State private var suggestionIndex = 0
    @State private var showsEmoji = false
    @State private var handle = ComposerHandle()
    @State private var pasteNotice: String?
    #if DEBUG
        /// The preview shows the recording UI without a microphone.
        @State private var previewRecording = false
    #endif

    private let maxLength = 2000

    enum RecordState {
        case idle
        case holding
        case locked
    }

    var body: some View {
        VStack(spacing: 0) {
            DS.Colors.hairline.frame(height: 1)

            if !links.isEmpty, !isRecording {
                linkCardBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let reply = thread.replyingTo {
                replyBar(reply)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 4) {
                if isRecording {
                    recordingStatus
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    composeField
                        .transition(.opacity)
                }

                trailingButton
            }
            .padding(.leading, 6)
            // Room for the recording circle, which grows past the microphone, to stay inside the window.
            .padding(.trailing, DS.Spacing.l)
            .padding(.vertical, 7)
        }
        .background(Palette.composer)
        // Suggestions and notices float over the thread instead of pushing it up, so nothing above moves.
        .overlay(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                if let notice = pasteNotice {
                    Label(notice, systemImage: "exclamationmark.circle.fill")
                        .font(DS.Fonts.chatCaption.weight(.medium))
                        .foregroundStyle(DS.Colors.destructive)
                        .padding(.horizontal, DS.Spacing.m + 2)
                        .padding(.vertical, DS.Spacing.s)
                        .background(DS.Colors.popover, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))
                        .elevation(DS.Elevation.floating)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !suggestions.isEmpty {
                    SuggestionList(suggestions: suggestions, selected: suggestionIndex) { accept($0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, DS.Spacing.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: 0, alignment: .bottom)
            .offset(y: -DS.Spacing.m)
        }
        .disabled(!thread.isLoaded)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: thread.replyingTo?.id)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: suggestions.map(\.id))
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: links.isEmpty)
        .animation(.easeOut(duration: 0.15), value: isRecording)
        .animation(DS.Motion.standard, value: pasteNotice)
        .onChange(of: thread.replyingTo?.id) { if thread.replyingTo != nil { handle.focus() } }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .previewComposerAction)) { note in previewAction(note.object as? String ?? "") }
        #endif
        .onChange(of: recorder.elapsed) {
            if recorder.elapsed >= VoiceRecorder.maxDuration - 0.1 {
                finishRecording(send: true)
            }
        }
    }

    #if DEBUG
        private func previewAction(_ action: String) {
            switch action {
            case "emoji", "emoji:off": showsEmoji = action == "emoji"
            case "paste": rejectPaste(2412)
            case "record:holding", "record:locked":
                previewRecording = true
                recordState = action == "record:locked" ? .locked : .holding
            default:
                previewRecording = false
                recordState = .idle
            }
        }
    #endif

    // MARK: - Text

    private var composeField: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Button(action: pickImages) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(IconButtonStyle(size: Self.iconSize))
            .help("Attach images (up to 3)")
            .accessibilityLabel("Attach images")

            ZStack(alignment: .topLeading) {
                if thread.draft.isEmpty {
                    Text(placeholder)
                        .font(DS.Fonts.composer)
                        .foregroundStyle(DS.Colors.inkFaint)
                        .lineLimit(1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                ComposerTextView(
                    text: $thread.draft,
                    height: $height,
                    handle: handle,
                    onSubmit: submit,
                    onPasteImages: { thread.attachments.append(contentsOf: $0.prefix(3 - thread.attachments.count)) },
                    onEscape: escape,
                    onCompletion: { completion = $0; suggestionIndex = 0 },
                    onCompletionKey: handleCompletionKey,
                    maxLength: maxLength,
                    onPasteRejected: rejectPaste
                )
                .frame(height: fieldHeight)
                .onChange(of: thread.draft) { thread.userTyped() }
            }
            .padding(.vertical, 7)
            .animation(.easeOut(duration: 0.1), value: fieldHeight)

            Button { showsEmoji.toggle() } label: {
                Image(systemName: "face.smiling")
            }
            .buttonStyle(IconButtonStyle(size: Self.iconSize, tint: showsEmoji ? DS.Colors.primary : DS.Colors.inkMuted))
            // What's left near the limit sits over the emoji button, as Telegram counts, so the text never reflows.
            .overlay(alignment: .top) {
                if thread.draft.count > maxLength - 200 {
                    Text("\(maxLength - thread.draft.count)")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(thread.draft.count > maxLength ? DS.Colors.destructive : DS.Colors.inkMuted)
                        .fixedSize()
                        .offset(y: -14)
                        .accessibilityLabel("\(maxLength - thread.draft.count) characters left")
                        .transition(.opacity)
                }
            }
            .help("Emoji")
            .accessibilityLabel("Emoji")
            .popover(isPresented: $showsEmoji, arrowEdge: .top) {
                EmojiPicker(mode: .insert) { emoji in handle.insert(emoji) }
            }

            Button { thread.sendPing() } label: {
                Image(systemName: "bell.and.waves.left.and.right")
            }
            .buttonStyle(IconButtonStyle(size: Self.iconSize))
            .help(pingLabel)
            .accessibilityLabel(pingLabel)

            if session.user?.remotes != nil {
                CallButton(thread: thread)
            }
        }
    }

    private var pingLabel: String {
        thread.partner.map { "Ping @" + $0.handle } ?? "Ping everyone in the org"
    }

    private var isRecording: Bool {
        #if DEBUG
            if previewRecording { return true }
        #endif
        return recorder.isRecording
    }

    private var levels: [Float] {
        #if DEBUG
            if previewRecording { return (0 ..< 60).map { Float(0.25 + 0.6 * abs(sin(Double($0) / 2.7))) } }
        #endif
        return recorder.levels
    }

    /// Icon buttons beside the field, as tall as a one-line field so they line up with its text.
    private static let iconSize: CGFloat = 34

    /// The field grows to 8 lines, then scrolls.
    private var fieldHeight: CGFloat {
        min(max(height, 20), Self.maxFieldHeight)
    }

    private static let maxFieldHeight = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 15)) * 8)

    private var canSend: Bool {
        !thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thread.draft.count <= maxLength
    }

    private var placeholder: String {
        if let partner = thread.partner {
            return "Push to @\(partner.handle)"
        }

        return "Push to the org"
    }

    private func submit() {
        guard canSend else {
            if thread.draft.count > maxLength { NSSound.beep() }
            return
        }

        thread.sendDraft()
    }

    private func escape() {
        if completion != nil {
            completion = nil
        } else if thread.replyingTo != nil {
            thread.replyingTo = nil
        }
    }

    // MARK: - Completion

    private var suggestions: [Suggestion] {
        switch completion {
        case let .mention(query, _)?:
            let query = query.lowercased()
            let people = (thread.members.map(\.user) + [thread.partner].compactMap { $0 }).filter { $0.id != session.user?.id }

            return people
                .filter { query.isEmpty || $0.handle.lowercased().hasPrefix(query) || $0.displayName.lowercased().split(separator: " ").contains { $0.hasPrefix(query) } }
                .prefix(6)
                .map { Suggestion(id: $0.id, title: $0.displayName, detail: "@" + $0.handle, user: $0, emoji: nil, insertion: "@\($0.handle) ") }
        case let .emoji(query, _)?:
            let query = query.lowercased()
            let prefixed = Reactions.all.filter { $0.name.hasPrefix(query) }
            let contained = Reactions.all.filter { !$0.name.hasPrefix(query) && $0.name.contains(query) }

            return (prefixed + contained)
                .prefix(6)
                .map { Suggestion(id: $0.name, title: $0.emoji, detail: ":\($0.name):", user: nil, emoji: $0.emoji, insertion: $0.emoji) }
        case .issue?, nil:
            return []
        }
    }

    private func accept(_ suggestion: Suggestion) {
        guard let completion else { return }

        handle.replace(completion.range, with: suggestion.insertion)
        self.completion = nil

        if let emoji = suggestion.emoji {
            Reactions.recordUse(emoji)
        }
    }

    /// Arrow keys move through the suggestions, Tab and Return take one, while there are any.
    private func handleCompletionKey(_ key: CompletionKey) -> Bool {
        let list = suggestions

        guard !list.isEmpty else { return false }

        switch key {
        case .up: suggestionIndex = (suggestionIndex - 1 + list.count) % list.count
        case .down: suggestionIndex = (suggestionIndex + 1) % list.count
        case .accept: accept(list[min(suggestionIndex, list.count - 1)])
        }

        return true
    }

    private func rejectPaste(_ length: Int) {
        withAnimation { pasteNotice = "Paste rejected: the message would be \(length.formatted())/\(maxLength.formatted()) characters." }

        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { pasteNotice = nil }
        }
    }

    // MARK: - Link card

    /// The web links in the draft, any of which can get the card.
    private var links: [String] {
        guard thread.draft.contains("http"), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }

        let draft = thread.draft

        return detector.matches(in: draft, range: NSRange(draft.startIndex..., in: draft)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme ?? "") else { return nil }
            return Range(match.range, in: draft).map { String(draft[$0]) }
        }
    }

    /// Which link gets a card, like Telegram's link preview bar: the first one unless another is picked, or none.
    private var linkCardBar: some View {
        let links = links
        let chosen = thread.linkCard.flatMap { card in card.isEmpty || links.contains(card) ? card : nil } ?? links[0]

        return HStack(spacing: 10) {
            Image(systemName: chosen.isEmpty ? "link.badge.plus" : "link")
                .font(.system(size: 15))
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 34)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(DS.Colors.primary)
                .frame(width: 2.5, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(chosen.isEmpty ? "No link card" : "Link card")
                    .font(DS.Fonts.chatCaptionStrong)
                    .foregroundStyle(DS.Colors.primary)
                Text(chosen.isEmpty ? "Pick a link to show a card for" : URL(string: chosen).map { ($0.host() ?? "") + $0.path() } ?? chosen)
                    .font(DS.Fonts.chatCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(chosen.isEmpty ? "Pick a link to show a card for" : chosen)

            if links.count > 1 || chosen.isEmpty {
                Menu {
                    ForEach(links, id: \.self) { link in
                        Button { thread.linkCard = link } label: {
                            if link == chosen { Label(link, systemImage: "checkmark") } else { Text(link) }
                        }
                    }

                    Divider()

                    Button("No Link Card") { thread.linkCard = "" }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose which link gets the card")
                .accessibilityLabel("Choose link card")
            }

            Spacer()

            if !chosen.isEmpty {
                Button { thread.linkCard = "" } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("Push without a link card")
                .accessibilityLabel("Remove link card")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.top, 8)
    }

    // MARK: - Reply

    private func replyBar(_ reply: Message) -> some View {
        let author = thread.user(reply.userId)

        return HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 15))
                .foregroundStyle(DS.Colors.primary)
                .frame(width: 34)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(DS.Colors.primary)
                .frame(width: 2.5, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Reply to \(author?.id == session.user?.id ? "yourself" : author?.displayName ?? "message")")
                    .font(DS.Fonts.chatCaptionStrong)
                    .foregroundStyle(DS.Colors.primary)
                    .lineLimit(1)
                Text(MessageText.preview(reply, members: [], me: session.user?.id))
                    .font(DS.Fonts.chatCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .lineLimit(1)
            }
            .help(MessageText.preview(reply, members: [], me: session.user?.id))

            Spacer()

            Button { thread.replyingTo = nil } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Cancel reply (Esc)")
            .accessibilityLabel("Cancel reply")
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.top, 8)
    }

    // MARK: - Images

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff]
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }

        let picked = panel.urls.compactMap(AttachmentLoader.attachment(fileAt:))
        thread.attachments.append(contentsOf: picked.prefix(3 - thread.attachments.count))
    }

    // MARK: - Voice

    /// Send when there's text, otherwise the microphone, which morphs into the send button as text is typed.
    @ViewBuilder
    private var trailingButton: some View {
        ZStack {
            if canSend, !isRecording {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, DS.Colors.primaryFill)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .help("Push (Return)")
                .accessibilityLabel("Push")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if recordState == .locked {
                Button { finishRecording(send: true) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, DS.Colors.primaryFill)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .help("Push voice note (Return)")
                .accessibilityLabel("Push voice note")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                micButton
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: 34, height: 34)
        .padding(.bottom, 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: canSend)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: recordState)
    }

    /// Hold to record and release to push; slide left to cancel or up to lock and keep recording hands-free. A tap
    /// starts a hands-free recording straight away.
    private var micButton: some View {
        let holding = recordState == .holding
        let level = CGFloat(levels.last ?? 0)

        return Image(systemName: "mic.fill")
            .font(.system(size: 17))
            .foregroundStyle(holding ? DS.Colors.onPrimary : DS.Colors.inkMuted)
            .frame(width: 34, height: 34)
            .background {
                if holding {
                    Circle()
                        .fill(DS.Colors.primaryFill)
                        .frame(width: 40 + level * 8, height: 40 + level * 8)
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .overlay(alignment: .top) {
                if holding {
                    LockHint(progress: min(1, max(0, -dragOffset.height / 70)))
                        .offset(y: -78)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .offset(x: holding ? min(0, dragOffset.width) : 0, y: holding ? min(0, max(-70, dragOffset.height)) : 0)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged(holdChanged).onEnded { _ in holdEnded() })
            .help("Hold to record a voice note, or click to record hands-free")
            .accessibilityLabel("Record a voice note")
            .accessibilityAction { startHandsFree() }
    }

    private func holdChanged(_ value: DragGesture.Value) {
        if recordState == .idle, !recorder.isRecording {
            recordState = .holding
            pressStartedAt = Date()
            dragOffset = .zero

            Task {
                let started = await recorder.start()

                // Released or cancelled before the microphone was ready: nothing to record.
                if !started || recordState == .idle {
                    if started { recorder.cancel() }
                    recordState = .idle
                }
            }

            return
        }

        guard recordState == .holding else { return }

        dragOffset = value.translation

        if value.translation.width < -110 {
            recorder.cancel()
            recordState = .idle
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        } else if value.translation.height < -70 {
            recordState = .locked
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    private func holdEnded() {
        dragOffset = .zero

        guard recordState == .holding else { return }

        if Date().timeIntervalSince(pressStartedAt) < 0.35 {
            recordState = .locked
        } else {
            finishRecording(send: true)
        }
    }

    private func startHandsFree() {
        Task {
            if await recorder.start() { recordState = .locked }
        }
    }

    private func finishRecording(send: Bool) {
        recordState = .idle

        guard recorder.isRecording else { return }

        if send, let recording = recorder.stop() {
            thread.sendVoice(recording)
        } else {
            recorder.cancel()
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 10) {
            if recordState == .locked {
                Button { finishRecording(send: false) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle(size: Self.iconSize, tint: DS.Colors.destructive))
                .help("Discard")
                .accessibilityLabel("Discard voice note")
            }

            Circle()
                .fill(DS.Colors.destructive)
                .frame(width: 9, height: 9)
                .opacity(Int(recorder.elapsed * 2) % 2 == 0 ? 1 : 0.3)
                .padding(.leading, recordState == .locked ? 0 : 12)

            Text(Formatting.preciseDuration(recorder.elapsed))
                .font(DS.Fonts.monoCaption.weight(.medium))
                .foregroundStyle(DS.Colors.ink)
                .frame(width: 52, alignment: .leading)

            if recordState == .locked {
                Waveform(levels: Array(levels.suffix(60)).map(Double.init), progress: 1, tint: DS.Colors.primary, idle: .clear)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()

                Label("Slide to cancel", systemImage: "chevron.left")
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .offset(x: min(0, dragOffset.width * 0.6))
                    .opacity(1 + Double(min(0, dragOffset.width)) / 110)

                Spacer()
            }
        }
        .frame(height: 34)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording, \(Int(recorder.elapsed)) seconds")
    }
}

/// The lock above the microphone while holding it: dragging up to it keeps the recording going hands-free.
private struct LockHint: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: progress >= 1 ? "lock.fill" : "lock.open")
                .font(.system(size: 14, weight: .semibold))
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .opacity(1 - progress)
        }
        .foregroundStyle(progress >= 1 ? DS.Colors.primary : DS.Colors.inkMuted)
        .frame(width: 34, height: 56)
        .background(DS.Colors.popover, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Colors.hairline))
        .elevation(DS.Elevation.floating)
    }
}

/// The people or emoji matching the word being typed, in a card floating above the composer, like Telegram's.
private struct SuggestionList: View {
    let suggestions: [Suggestion]
    let selected: Int
    let pick: (Suggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { pick(suggestion) } label: {
                    HStack(spacing: DS.Spacing.m + 2) {
                        if let user = suggestion.user {
                            Avatar(user: user, size: 24)
                        } else if let emoji = suggestion.emoji {
                            Text(emoji)
                                .font(.system(size: 19))
                                .frame(width: 24)
                        }

                        if suggestion.user != nil {
                            Text(suggestion.title)
                                .font(DS.Fonts.bodyMedium)
                                .foregroundStyle(DS.Colors.ink)
                                .lineLimit(1)
                        }

                        Text(suggestion.detail)
                            .font(DS.Fonts.monoHandle)
                            .foregroundStyle(DS.Colors.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Spacing.m)
                    .frame(height: 32)
                    .background(index == selected ? DS.Colors.primarySoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(suggestion.user != nil ? "\(suggestion.title) · \(suggestion.detail)" : suggestion.detail)
                .accessibilityLabel(suggestion.user != nil ? "\(suggestion.title), \(suggestion.detail)" : suggestion.detail)
                .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
        }
        .padding(DS.Spacing.xs)
        .frame(width: 300)
        .background(DS.Colors.popover, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))
        .elevation(DS.Elevation.popover)
    }
}

enum CompletionKey {
    case up
    case down
    case accept
}

/// The composer's text view: Return pushes, Shift-Return or Option-Return adds a line, it grows with its text, takes
/// pasted images as attachments, and reports the "@" or ":" word being typed for suggestions, like Telegram's.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let handle: ComposerHandle
    let onSubmit: () -> Void
    let onPasteImages: ([Attachment]) -> Void
    let onEscape: () -> Void
    let onCompletion: (Completion?) -> Void
    let onCompletionKey: (CompletionKey) -> Bool
    let maxLength: Int
    let onPasteRejected: (Int) -> Void
    /// Commits take Return as a new line and ⌘↩ to send; remotes push on Return.
    var submitsOnCommandReturn = false
    var focusesOnAppear = true
    var accessibilityLabel = "Message"
    /// Whether `#123` words are reported, which only commits link to issues.
    var completesIssues = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityLabel(accessibilityLabel)
        handle.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        DispatchQueue.main.async {
            if focusesOnAppear { textView.window?.makeFirstResponder(textView) }
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            context.coordinator.recalculateHeight(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? NSTextView else { return }

        handle.textView = textView

        if textView.string != text {
            textView.string = text
            // Text set from outside (a restored draft, a sent message clearing it) puts the cursor at its end.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

            context.coordinator.recalculateHeight(textView)
            context.coordinator.reportCompletion(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var lastCompletion: Completion?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            parent.text = textView.string
            recalculateHeight(textView)
            reportCompletion(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportCompletion(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }

            layout.ensureLayout(for: container)
            let height = max(ceil(layout.usedRect(for: container).height), ceil(textView.font.map { layout.defaultLineHeight(for: $0) } ?? 17))

            // Deferred: the text is also cleared while SwiftUI updates the view, when a change here would be dropped.
            if abs(parent.height - height) > 0.5 {
                let binding = parent.$height
                DispatchQueue.main.async { binding.wrappedValue = height }
            }
        }

        /// The word before the cursor, when it starts with "@" or ":" at the start of the text or after a space.
        func reportCompletion(_ textView: NSTextView) {
            let string = textView.string as NSString
            let cursor = textView.selectedRange()
            var completion: Completion?

            if cursor.length == 0, cursor.location <= string.length {
                var start = cursor.location

                while start > 0 {
                    let character = string.character(at: start - 1)
                    if let scalar = UnicodeScalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
                    start -= 1
                }

                let word = string.substring(with: NSRange(location: start, length: cursor.location - start))
                let range = NSRange(location: start, length: cursor.location - start)

                if word.hasPrefix("@"), word.count <= 40, word.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                    completion = .mention(query: String(word.dropFirst()), range: range)
                } else if word.hasPrefix(":"), word.count >= 3, !word.dropFirst().contains(":"), word.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }) {
                    completion = .emoji(query: String(word.dropFirst()), range: range)
                } else if parent.completesIssues, word.hasPrefix("#"), (2 ... 11).contains(word.count), word.dropFirst().first != "0", word.count != 7, word.dropFirst().allSatisfy(\.isASCIIDigitCharacter) {
                    // "#1234" is an issue of the repository, as on the web; six digits read as a color instead.
                    completion = .issue(query: String(word.dropFirst()), range: range)
                }
            }

            if completion != lastCompletion {
                lastCompletion = completion

                // Selection changes also arrive while SwiftUI updates the view, when state changes would be dropped.
                let report = parent.onCompletion
                DispatchQueue.main.async { report(completion) }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCompletionKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCompletionKey(.down)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onCompletionKey(.accept)
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []

                if parent.submitsOnCommandReturn {
                    if flags.contains(.command) {
                        parent.onSubmit()
                    } else if !parent.onCompletionKey(.accept) {
                        textView.insertNewlineIgnoringFieldEditor(nil)
                    }
                } else if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else if !parent.onCompletionKey(.accept) {
                    parent.onSubmit()
                }

                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }

    final class SubmittingTextView: NSTextView {
        weak var coordinator: Coordinator?

        /// ⌘↩ reaches the menu bar before the text view, so a commit composer takes it here while it has the focus.
        /// Bare key equivalents are delivered to the composer so global shortcuts cannot swallow typed text.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let parent = coordinator?.parent, parent.submitsOnCommandReturn, window?.firstResponder === self,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               (event.keyCode == 36 || event.keyCode == 76) {
                parent.onSubmit()
                return true
            }

            let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .function]
            guard event.modifierFlags.intersection(commandModifiers).isEmpty,
                  let characters = event.characters,
                  !characters.isEmpty else {
                return super.performKeyEquivalent(with: event)
            }

            keyDown(with: event)
            return true
        }

        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general

            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL], !urls.isEmpty {
                coordinator?.parent.onPasteImages(urls.compactMap(AttachmentLoader.attachment(fileAt:)))
                return
            }

            if pasteboard.string(forType: .string) == nil,
               let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
               let attachment = AttachmentLoader.attachment(data: data, filename: "pasted") {
                coordinator?.parent.onPasteImages([attachment])
                return
            }

            // Like the web, a paste that would take the message over the limit is refused rather than cut.
            if let pasted = pasteboard.string(forType: .string), let parent = coordinator?.parent {
                let length = string.count - (string as NSString).substring(with: selectedRange()).count + pasted.count

                if length > parent.maxLength {
                    NSSound.beep()
                    parent.onPasteRejected(length)
                    return
                }
            }

            pasteAsPlainText(sender)
        }
    }
}

/// The sheet images go through before they're pushed, like Telegram's: a preview of each, a description for screen
/// readers, and a caption that becomes the message.
struct AttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var thread: ThreadModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                Text(thread.attachments.count == 1 ? "Push an Image" : "Push \(thread.attachments.count) Images")
                    .font(DS.Fonts.section)
                    .foregroundStyle(DS.Colors.ink)

                HStack(alignment: .top, spacing: DS.Spacing.m + 2) {
                    ForEach($thread.attachments) { $attachment in
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            ZStack(alignment: .topTrailing) {
                                if let image = attachment.image {
                                    Image(nsImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: thread.attachments.count == 1 ? .fit : .fill)
                                        .frame(width: previewSize.width, height: previewSize.height)
                                        .background(DS.Colors.wash)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                                }

                                Button {
                                    withAnimation(DS.Motion.standard) { thread.attachments.removeAll { $0.id == attachment.id } }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(DS.Spacing.s)
                                .help("Remove")
                                .accessibilityLabel("Remove image")
                            }

                            TextField("Description (alt text)", text: $attachment.description)
                                .font(DS.Fonts.caption)
                                .lineLimit(1)
                                .fieldChrome()
                                .frame(width: previewSize.width)
                                .help("Read aloud by screen readers in place of the image")
                        }
                    }
                }

                TextField("Add a caption…", text: $thread.draft, axis: .vertical)
                    .font(DS.Fonts.chatBody)
                    .lineLimit(1 ... 5)
                    .fieldChrome()
                    .onSubmit(send)
            }
            .padding(DS.Spacing.xl)

            DS.Colors.hairline.frame(height: 1)

            HStack(spacing: DS.Spacing.m) {
                if thread.attachments.count < 3 {
                    Button(action: add) {
                        Label("Add…", systemImage: "plus")
                    }
                    .buttonStyle(.dsGhost)
                }

                Spacer()

                Button("Cancel") {
                    thread.attachments = []
                    dismiss()
                }
                .buttonStyle(.dsOutline)
                .keyboardShortcut(.cancelAction)

                Button("Push", action: send)
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(thread.draft.count > 2000)
            }
            .padding(DS.Spacing.l)
        }
        .frame(width: thread.attachments.count == 1 ? 440 : 540)
        .background(DS.Colors.popover)
    }

    /// One image fills the sheet's content width; several share it as three square tiles.
    private var previewSize: CGSize {
        let tile = ((540 - DS.Spacing.xl * 2) - (DS.Spacing.m + 2) * 2) / 3

        return thread.attachments.count == 1 ? CGSize(width: 440 - DS.Spacing.xl * 2, height: 300) : CGSize(width: tile, height: tile)
    }

    private func send() {
        thread.sendDraft()
        dismiss()
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff]
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }

        thread.attachments.append(contentsOf: panel.urls.compactMap(AttachmentLoader.attachment(fileAt:)).prefix(3 - thread.attachments.count))
    }
}

/// The emoji panel, like Telegram's: recently used first, then every category, searchable by name, with a tab per
/// category at the bottom. Inserting into the composer keeps it open; picking a reaction closes it.
struct EmojiPicker: View {
    enum Mode: Equatable {
        case insert
        case reaction(selected: Set<String>)
    }

    let mode: Mode
    let pick: (String) -> Void

    @State private var search = ""
    @State private var hovered: String?
    @State private var recent = Reactions.recent
    @State private var currentSection: String?
    @FocusState private var searchFocused: Bool

    private static let recentTitle = "Recently Used"
    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 0), count: 9)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(searchFocused ? DS.Colors.primary : DS.Colors.inkFaint)
                TextField("Search emoji", text: $search)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .focused($searchFocused)
                    .focusEffectDisabled()
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Colors.inkFaint) }
                    .buttonStyle(.plain)
                    .opacity(search.isEmpty ? 0 : 1)
                    .disabled(search.isEmpty)
                    .accessibilityLabel("Clear search")
            }
            .padding(.horizontal, DS.Spacing.m + 2)
            .frame(height: DS.Metrics.controlHeight)
            .background(DS.Colors.wash, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(searchFocused ? DS.Colors.primary : .clear))
            .padding(DS.Spacing.m + 2)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if search.isEmpty {
                            if !recent.isEmpty {
                                section(Self.recentTitle, recent)
                            }

                            ForEach(EmojiCatalog.categories, id: \.name) { category in
                                section(category.name, category.emoji)
                            }
                        } else {
                            let results = Reactions.search(search)

                            if results.isEmpty {
                                Text("No emoji match “\(search)”")
                                    .font(DS.Fonts.body)
                                    .foregroundStyle(DS.Colors.inkMuted)
                                    .lineLimit(1)
                                    .padding(.vertical, DS.Spacing.xxl)
                                    .gridCellColumns(9)
                                    .frame(maxWidth: .infinity)
                            } else {
                                section("Results", results)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.bottom, DS.Spacing.m)
                }
                .frame(height: 300)

                if search.isEmpty {
                    DS.Colors.hairline.frame(height: 1)

                    HStack(spacing: 0) {
                        ForEach(tabs, id: \.self) { name in
                            let isCurrent = name == (currentSection ?? tabs.first)

                            Button {
                                currentSection = name
                                withAnimation(DS.Motion.slide) { proxy.scrollTo(name, anchor: .top) }
                            } label: {
                                Image(systemName: Self.symbol(for: name))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(isCurrent ? DS.Colors.primary : DS.Colors.inkMuted)
                                    .frame(width: 30, height: 26)
                                    .background(isCurrent ? DS.Colors.primarySoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(name)
                            .accessibilityLabel(name)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, DS.Spacing.xs)
                }
            }
        }
        .frame(width: 344)
        .background(DS.Colors.popover)
        .onAppear { searchFocused = mode != .insert }
    }

    private var tabs: [String] {
        (recent.isEmpty ? [] : [Self.recentTitle]) + EmojiCatalog.categories.map(\.name)
    }

    /// One line-art symbol per category, so the tabs read as navigation instead of more emoji to pick.
    private static func symbol(for category: String) -> String {
        switch category {
        case recentTitle: "clock"
        case "Smileys & People": "face.smiling"
        case "Animals & Nature": "leaf"
        case "Food & Drink": "fork.knife"
        case "Activity": "basketball"
        case "Travel & Places": "car"
        case "Objects": "lightbulb"
        case "Symbols": "number"
        case "Flags": "flag"
        default: "circle"
        }
    }

    private func section(_ title: String, _ emoji: [String]) -> some View {
        Section {
            ForEach(emoji, id: \.self) { item in
                Button {
                    Reactions.recordUse(item)
                    pick(item)
                } label: {
                    Text(item)
                        .font(.system(size: 24))
                        .frame(width: 36, height: 36)
                        .background(cellBackground(item), in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                        .scaleEffect(hovered == item ? 1.12 : 1)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: hovered == item)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { hovered = item } else if hovered == item { hovered = nil } }
                .accessibilityLabel(item)
            }
        } header: {
            Text(title)
                .font(DS.Fonts.label)
                .foregroundStyle(DS.Colors.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DS.Spacing.s)
                .padding(.horizontal, DS.Spacing.xs)
                // Pinned headers sit on the panel's own color, so they read as part of it.
                .background(DS.Colors.popover)
                .id(title)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func cellBackground(_ emoji: String) -> Color {
        if case let .reaction(selected) = mode, selected.contains(emoji) {
            return DS.Colors.primarySoft
        }

        return hovered == emoji ? DS.Colors.wash : .clear
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
