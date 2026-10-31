import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The commit composer, staged at the top of a log, in its own window (⌘N, Quote…), or as the reply composer under a
/// commit: the field, images, a poll, the rendered preview, a schedule, the countdown and Commit.
struct CommitComposer: View {
    enum Presentation: Equatable {
        case staged
        case window
        /// The bordered reply box: no poll or schedule, and Reply instead of Commit.
        case reply(parentId: String, handle: String)
    }

    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let presentation: Presentation
    @Binding var draft: DraftStore.CommitDraft
    /// The draft came back after navigating away, which shows `stash@{0}`.
    var isRestored = false
    var handle = ComposerHandle()
    var autofocus = false
    var onCommitted: () -> Void = {}

    @State private var height: CGFloat = 20
    @State private var completion: Completion?
    @State private var suggestionIndex = 0
    @State private var people: [User] = []
    @State private var organizations: [Organization] = []
    @State private var issue: IssueSuggestion?
    @State private var showsPreview = false
    @State private var showsEmoji = false
    @State private var showsRecipients = false
    /// The participants unticked under "Replying to"; everyone else the thread addresses gets the reply.
    @State private var excludedRecipients: Set<String> = []
    @State private var preview: Commit?
    @State private var showsSchedule = false
    @State private var scheduleDate = Date.now.addingTimeInterval(3600)
    @State private var isSubmitting = false
    @State private var error: String?
    @State private var isDropTargeted = false

    private static let maxLength = 4000
    private static let maxImages = 3
    private static let pollDurations: [(minutes: Int, title: String)] = [(60, "1 hour"), (1440, "1 day"), (4320, "3 days"), (10080, "7 days")]

    private var remaining: Int { Self.maxLength - draft.body.count }
    private var quoted: Commit? { draft.quotedCommitId.flatMap { workspace.existingBox($0)?.commit } }
    private var lineHeight: CGFloat { 19 }
    private var parentId: String? { if case let .reply(id, _) = presentation { id } else { nil } }
    private var placeholder: String { if case let .reply(_, handle) = presentation { "Reply to @\(handle)…" } else { "What did you ship?" } }
    private var fieldHeight: CGFloat { min(max(height, lineHeight), lineHeight * 12) }

    private var pollIsValid: Bool {
        guard let options = draft.pollOptions else { return true }

        let filled = options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        return filled.count >= 2 && Set(filled.map { $0.lowercased() }).count == filled.count && filled.allSatisfy { $0.count <= 50 }
    }

    private var canSubmit: Bool {
        !draft.isEmpty && remaining >= 0 && pollIsValid && !isSubmitting && (!draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.images.isEmpty)
    }

    var body: some View {
        switch presentation {
        case .staged:
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: DS.Metrics.railWidth)
                composer
                    .padding(.vertical, 12)
                    .padding(.leading, DS.Spacing.xs)
                    .padding(.trailing, DS.Metrics.commitGutter)
            }
            .background(alignment: .leading) {
                GraphRail(above: .clear, lane: LaneColor.of(workspace.session.user?.asUser), nodeFilled: !draft.body.isEmpty, dashedTail: true)
                    .animation(DS.Motion.respecting(reduceMotion, DS.Motion.quick), value: draft.body.isEmpty)
            }
            .overlay(alignment: .bottom) { RowHairline() }
        case .window:
            composer
                .padding(DS.Spacing.xl)
        case .reply:
            composer
                .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.rail))
        }
    }

    // MARK: Layout

    /// The parent's author and the people its thread addresses, when there's anyone besides the author to choose.
    private var participants: [User] {
        guard let parentId else { return [] }

        let participants = workspace.thread(parentId).participants

        return participants.count > 1 ? participants : []
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if !participants.isEmpty {
                recipients
            }

            ZStack(alignment: .topLeading) {
                if showsPreview {
                    previewBox
                        .frame(minHeight: fieldHeight, alignment: .topLeading)
                } else {
                    ComposerTextView(
                        text: $draft.body,
                        height: $height,
                        handle: handle,
                        onSubmit: submit,
                        onPasteImages: add,
                        onEscape: escape,
                        onCompletion: { completion = $0; suggestionIndex = 0 },
                        onCompletionKey: completionKey,
                        maxLength: Self.maxLength,
                        onPasteRejected: { _ in error = "fatal: the paste would go over \(Self.maxLength) characters" },
                        submitsOnCommandReturn: true,
                        focusesOnAppear: presentation == .window || autofocus,
                        accessibilityLabel: placeholder,
                        completesIssues: true
                    )
                    .frame(height: fieldHeight)

                    if draft.body.isEmpty {
                        Text(placeholder)
                            .font(DS.Fonts.composer)
                            .foregroundStyle(DS.Colors.inkFaint)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: DS.Metrics.readingMeasure, alignment: .leading)

            if !suggestions.isEmpty {
                suggestionList
            }

            if !draft.images.isEmpty {
                images
            }

            if draft.pollOptions != nil {
                pollEditor
            }

            if let quoted {
                QuoteEmbed(commit: quoted)
                    .allowsHitTesting(false)
                    .frame(maxWidth: DS.Metrics.readingMeasure)
            }

            if let error {
                Text(error)
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            toolRow
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(DS.Colors.primary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            AttachmentLoader.load(providers) { add($0) }
            return true
        }
        .task(id: completion) { await loadSuggestions() }
        .task(id: showsPreview ? draft.body : nil) { await loadPreview() }
        .onChange(of: draft.body) { error = nil }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .previewWorkspaceAction)) { note in
                if note.object as? String == "submit", presentation == .staged { submit() }
            }
        #endif
    }

    private var recipients: some View {
        let selected = participants.filter { !excludedRecipients.contains($0.id) }
        let names = selected.enumerated().map { index, user in
            (index == 0 ? "" : index == selected.count - 1 ? " and " : ", ") + "@" + user.handle
        }.joined()

        return Button { showsRecipients = true } label: {
            (Text("Replying to ").foregroundStyle(DS.Colors.inkMuted) + Text(names).foregroundStyle(DS.Colors.primary))
                .font(DS.Fonts.caption)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Choose who to include")
        .popover(isPresented: $showsRecipients, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                Text("Replying to")
                    .font(DS.Fonts.section)
                Text("Choose who to include. The commit author stays selected. Anyone you mention in your reply will also be notified.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(participants.enumerated()), id: \.element.id) { index, user in
                    Toggle(isOn: Binding(
                        get: { !excludedRecipients.contains(user.id) },
                        set: { included in if included { excludedRecipients.remove(user.id) } else { excludedRecipients.insert(user.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(user.handle)")
                                .font(DS.Fonts.bodyMedium)
                            if index == 0 {
                                Text("Commit author")
                                    .font(DS.Fonts.caption)
                                    .foregroundStyle(DS.Colors.inkMuted)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(index == 0)
                    .accessibilityLabel("Include @\(user.handle)")
                }

                HStack {
                    Spacer()
                    Button("Done") { showsRecipients = false }
                        .buttonStyle(.dsPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.Spacing.l)
            .frame(width: 320)
        }
    }

    private var toolRow: some View {
        HStack(spacing: DS.Spacing.xs) {
            if isRestored, !draft.isEmpty {
                Text("stash@{0}")
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
                Button("drop") { draft = DraftStore.CommitDraft(quotedCommitId: draft.quotedCommitId) }
                    .buttonStyle(LinkButtonStyle())
                    .font(DS.Fonts.caption)
                    .help("Drop the stashed draft")
                    .padding(.trailing, DS.Spacing.s)
            }

            tool("photo", help: "Add Image", label: "Add image", disabled: draft.images.count >= Self.maxImages || draft.pollOptions != nil, action: pickImages)
            tool("face.smiling", help: "Emoji", label: "Emoji", disabled: showsPreview, isOn: showsEmoji) { showsEmoji.toggle() }
                .popover(isPresented: $showsEmoji, arrowEdge: .bottom) {
                    EmojiPicker(mode: .insert) { emoji in handle.insert(emoji) }
                }
            if parentId == nil {
                tool("list.bullet", help: draft.pollOptions == nil ? "Add Poll" : "Remove Poll", label: draft.pollOptions == nil ? "Add poll" : "Remove poll", disabled: !draft.images.isEmpty || draft.quotedCommitId != nil, isOn: draft.pollOptions != nil) {
                    draft.pollOptions = draft.pollOptions == nil ? ["", ""] : nil
                }
            }

            tool("eye", help: showsPreview ? "Edit" : "Preview", label: showsPreview ? "Edit" : "Preview", disabled: draft.body.isEmpty, isOn: showsPreview) {
                showsPreview.toggle()
            }
            if parentId == nil {
                tool("calendar", help: "Schedule", label: "Schedule", disabled: draft.quotedCommitId != nil, isOn: draft.scheduledAt != nil) {
                    scheduleDate = draft.scheduledAt ?? Date.now.addingTimeInterval(3600)
                    showsSchedule = true
                }
                .popover(isPresented: $showsSchedule, arrowEdge: .bottom) { schedulePopover }
            }

            Spacer(minLength: DS.Spacing.m)

            Text(verbatim: "\(remaining)")
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(remaining <= 0 ? DS.Colors.destructive : DS.Colors.inkFaint)
                .frame(minWidth: 32, alignment: .trailing)
                .accessibilityLabel("\(remaining) characters left")

            if let scheduledAt = draft.scheduledAt {
                Text(Formatting.scheduleTime(scheduledAt))
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
            }

            Button(action: submit) {
                HStack(spacing: DS.Spacing.s) {
                    Text(parentId != nil ? "Reply" : draft.scheduledAt == nil ? "Commit" : "Schedule")
                    Text("⌘↩")
                        .font(DS.Fonts.monoMeta)
                        .opacity(0.7)
                }
                .frame(minWidth: parentId == nil ? 96 : 72)
            }
            .buttonStyle(.dsPrimary)
            .disabled(!canSubmit)
            .help(draft.scheduledAt == nil ? "Commit (⌘↩)" : "Schedule (⌘↩)")
        }
        .frame(maxWidth: DS.Metrics.readingMeasure)
    }

    private func tool(_ symbol: String, help: String, label: String, disabled: Bool = false, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(IconButtonStyle(tint: isOn ? DS.Colors.primary : DS.Colors.inkMuted))
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Preview

    private var previewBox: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if let preview {
                CommitBodyView(commit: preview, size: 15, foldable: false)
            } else {
                Text(draft.body)
                    .font(DS.Fonts.composer)
                    .foregroundStyle(DS.Colors.inkMuted)
            }

            if draft.images.isEmpty, draft.pollOptions == nil, let url = firstURL {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(url)
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Unfurls into a link card")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkFaint)
                }
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.rail, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .padding(.leading, 5)
    }

    private var firstURL: String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        return detector?.firstMatch(in: draft.body, range: NSRange(draft.body.startIndex..., in: draft.body))?.url?.absoluteString
    }

    private func loadPreview() async {
        guard showsPreview, !draft.body.isEmpty else { return }

        struct Rendered: Decodable {
            let body: String
            let bodySegments: [BodySegment]?
        }

        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        if let rendered: DataEnvelope<Rendered> = try? await workspace.api.send("POST", "commits/preview", json: ["body": draft.body]) {
            preview = Commit(id: "preview", body: rendered.data.body, bodySegments: rendered.data.bodySegments)
        }
    }

    // MARK: Images

    private var images: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach($draft.images) { $attachment in
                HStack(alignment: .center, spacing: DS.Spacing.m) {
                    Group {
                        if let image = attachment.image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            DS.Colors.wash
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

                    TextField("Describe the image for screen readers", text: $attachment.description)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.body)
                        .fieldChrome()

                    Button {
                        draft.images.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Remove Image")
                    .accessibilityLabel("Remove image")
                }
            }
        }
        .frame(maxWidth: DS.Metrics.readingMeasure)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .webP]

        guard panel.runModal() == .OK else { return }

        add(panel.urls.compactMap(AttachmentLoader.attachment(fileAt:)))
    }

    private func add(_ attachments: [Attachment]) {
        guard draft.pollOptions == nil else { return }

        draft.images.append(contentsOf: attachments.prefix(Self.maxImages - draft.images.count))
    }

    // MARK: Poll

    private var pollEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            ForEach(Array((draft.pollOptions ?? []).indices), id: \.self) { index in
                HStack(spacing: DS.Spacing.s) {
                    TextField("Option \(index + 1)", text: Binding(
                        get: { draft.pollOptions?[safe: index] ?? "" },
                        set: { value in if draft.pollOptions?.indices.contains(index) == true { draft.pollOptions?[index] = String(value.prefix(50)) } }
                    ))
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .fieldChrome()

                    if (draft.pollOptions?.count ?? 0) > 2 {
                        Button {
                            draft.pollOptions?.remove(at: index)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(IconButtonStyle())
                        .help("Remove Option")
                        .accessibilityLabel("Remove option \(index + 1)")
                    }
                }
            }

            HStack {
                if (draft.pollOptions?.count ?? 0) < 4 {
                    Button("Add Option") { draft.pollOptions?.append("") }
                        .buttonStyle(LinkButtonStyle())
                }

                Spacer()

                Picker("Ends in", selection: $draft.pollDuration) {
                    ForEach(Self.pollDurations, id: \.minutes) { Text($0.title).tag($0.minutes) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .padding(DS.Spacing.m)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))
        .frame(maxWidth: DS.Metrics.readingMeasure)
    }

    // MARK: Schedule

    private var schedulePopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("Schedule")
                .font(DS.Fonts.section)
            DatePicker("Commit at", selection: $scheduleDate, in: Date.now.addingTimeInterval(300) ... Date.now.addingTimeInterval(30 * 86400), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            Text("Goes out \(Formatting.scheduleTime(scheduleDate)), within 30 days.")
                .font(DS.Fonts.monoCaption)
                .foregroundStyle(DS.Colors.inkMuted)
            HStack {
                if draft.scheduledAt != nil {
                    Button("Clear") {
                        draft.scheduledAt = nil
                        showsSchedule = false
                    }
                    .buttonStyle(.dsGhost)
                }
                Spacer()
                Button("Set Time") {
                    draft.scheduledAt = scheduleDate
                    showsSchedule = false
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 300)
    }

    // MARK: Suggestions

    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let user: User?
        var organization: Organization? = nil
        let insertion: String
    }

    private var suggestions: [Item] {
        switch completion {
        case .mention?:
            people.prefix(6).map { Item(id: $0.id, title: $0.displayName, detail: "@" + $0.handle, user: $0, insertion: "@\($0.handle) ") }
                + organizations.map { Item(id: "organization-\($0.handle)", title: $0.name, detail: "@" + $0.handle, user: nil, organization: $0, insertion: "@\($0.handle) ") }
        case .issue?:
            issue.map { [Item(id: "issue-\($0.number)", title: $0.title, detail: "#\($0.number)", user: nil, insertion: $0.url + " ")] } ?? []
        case .emoji(let query, _)?:
            Reactions.all.filter { $0.name.hasPrefix(query.lowercased()) }.prefix(6).map { Item(id: $0.name, title: $0.emoji, detail: ":\($0.name):", user: nil, insertion: $0.emoji) }
        case nil:
            []
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                Button {
                    accept(item)
                } label: {
                    HStack(spacing: DS.Spacing.m) {
                        if let user = item.user {
                            Avatar(user: user, size: 20)
                        } else if let organization = item.organization {
                            OrganizationAvatar(organization: organization, size: 20)
                        } else if case .issue? = completion {
                            Image(systemName: "smallcircle.filled.circle")
                                .foregroundStyle(DS.Colors.success)
                        }
                        Text(item.title)
                            .font(DS.Fonts.body)
                            .foregroundStyle(DS.Colors.ink)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(DS.Colors.inkMuted)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Spacing.m)
                    .frame(height: 30)
                    .background(index == suggestionIndex ? DS.Colors.selectionSoft : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.xs)
        .frame(maxWidth: 360)
        .background(DS.Colors.popover, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Colors.hairline))
        .elevation(DS.Elevation.popover)
    }

    private func loadSuggestions() async {
        switch completion {
        case let .mention(query, _)?:
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            var parameters: [String: String?] = ["q": query]
            parameters["quote"] = draft.quotedCommitId
            parameters["reply"] = parentId

            struct Found: Decodable {
                let data: [User]
                let organizations: [Organization]
            }

            if let found: Found = try? await workspace.api.get("search/mentions", query: parameters), !Task.isCancelled {
                people = found.data
                organizations = found.organizations
            }
        case let .issue(query, _)?:
            struct Found: Decodable { let issue: IssueSuggestion? }

            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            issue = nil
            if let found: Found = try? await workspace.api.get("search/issues", query: ["q": query]), !Task.isCancelled {
                issue = found.issue
            }
        default:
            people = []
            organizations = []
            issue = nil
        }
    }

    private func completionKey(_ key: CompletionKey) -> Bool {
        let items = suggestions

        guard !items.isEmpty else { return false }

        switch key {
        case .up: suggestionIndex = (suggestionIndex - 1 + items.count) % items.count
        case .down: suggestionIndex = (suggestionIndex + 1) % items.count
        case .accept: accept(items[min(suggestionIndex, items.count - 1)])
        }

        return true
    }

    private func accept(_ item: Item) {
        guard let range = completion?.range else { return }

        handle.replace(range, with: item.insertion)
        completion = nil
    }

    // MARK: Committing

    private func escape() {
        if completion != nil {
            completion = nil
        } else {
            handle.textView?.window?.makeFirstResponder(nil)
        }
    }

    private func submit() {
        guard canSubmit else { return }

        isSubmitting = true
        error = nil

        Task {
            defer { isSubmitting = false }

            let submitted = draft
            var json: [String: Any] = [:]
            let body = submitted.body.trimmingCharacters(in: .whitespacesAndNewlines)

            if !body.isEmpty { json["body"] = body }
            if let quoted = submitted.quotedCommitId { json["quoted_commit_id"] = quoted }
            if let parentId {
                json["parent_id"] = parentId
                if !participants.isEmpty {
                    json["reply_recipients"] = participants.dropFirst().map(\.id).filter { !excludedRecipients.contains($0) }
                }
            }
            if let options = submitted.pollOptions {
                json["poll"] = ["options": options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, "duration": submitted.pollDuration]
            }
            if let scheduledAt = submitted.scheduledAt { json["scheduled_at"] = Formatting.apiDate(scheduledAt) }
            if !submitted.images.isEmpty { json["image_descriptions"] = submitted.images.map(\.description) }

            let path = submitted.scheduledAt == nil ? "commits" : "scheduled-commits"
            let files = submitted.images.map { Upload(data: $0.data, filename: $0.filename, mimeType: $0.mimeType) }

            do {
                if let scheduledAt = submitted.scheduledAt {
                    let _: DataEnvelope<ScheduledCommit> = files.isEmpty
                        ? try await workspace.api.send("POST", path, json: json)
                        : try await workspace.api.sendMultipart("POST", path, json: json, field: "images", files: files)
                    workspace.toasts.show("scheduled for \(Formatting.scheduleTime(scheduledAt))")
                    await workspace.scheduled.reload()
                } else {
                    let response: DataEnvelope<Commit> = files.isEmpty
                        ? try await workspace.api.send("POST", path, json: json)
                        : try await workspace.api.sendMultipart("POST", path, json: json, field: "images", files: files)
                    let commit = workspace.box(response.data).commit

                    if let parentId {
                        workspace.thread(parentId).appendReply(commit.id)
                    } else {
                        for kind in [LogKind.following, .latest] { workspace.log(kind).insertOwn(commit.id) }
                    }

                    let summary = commit.text.split(separator: "\n").first.map(String.init) ?? ""
                    workspace.toasts.show("[\(parentId == nil ? "log" : "reply") \(commit.hash)] \(summary.count > 48 ? summary.prefix(47) + "…" : summary)")
                }

                draft = DraftStore.CommitDraft()
                showsPreview = false
                preview = nil
                onCommitted()
            } catch {
                self.error = "fatal: \(error.localizedDescription)"
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The composer in its own window: ⌘N, or Quote… with the quoted commit under the field. Quoting keeps its own draft,
/// so it never eats the staged one.
struct CommitComposerWindow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var drafts = workspace.drafts
        let isQuoting = drafts.quote.quotedCommitId != nil

        ScrollView {
            CommitComposer(presentation: .window, draft: isQuoting ? $drafts.quote : $drafts.commit, isRestored: !(isQuoting ? drafts.quote : drafts.commit).isEmpty) {
                dismissWindow(id: "composer")
            }
        }
        .background(DS.Colors.surface)
        .navigationTitle(isQuoting ? "Quote" : "New Commit")
        .onDisappear {
            // A quote with nothing written is let go with the window; anything typed stays as a draft.
            if drafts.quote.body.isEmpty, drafts.quote.images.isEmpty { drafts.quote = DraftStore.CommitDraft() }
        }
    }
}
