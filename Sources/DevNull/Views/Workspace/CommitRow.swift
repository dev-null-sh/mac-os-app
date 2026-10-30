import AppKit
import SwiftUI

// MARK: - Shared state

/// The author whose nodes stay lit while the pointer rests on one of their nodes, avatars, names or handles; every
/// other author's rail fades to 30%.
@MainActor
@Observable
final class RailHighlight {
    var authorId: String?

    func opacity(for authorId: String?) -> Double {
        guard let highlighted = self.authorId else { return 1 }

        return highlighted == authorId ? 1 : 0.3
    }
}

private struct WorkspaceActionsEnvironmentKey: EnvironmentKey {
    static let defaultValue: WorkspaceActions? = nil
}

extension EnvironmentValues {
    /// The window's workspace actions, for rows that open commit windows or profiles.
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsEnvironmentKey.self] }
        set { self[WorkspaceActionsEnvironmentKey.self] = newValue }
    }
}

// MARK: - Rail

/// One row's slice of the graph: the segment above the node in the previous author's lane, the node, and the segment
/// below in this author's lane. Rows without a node (markers, skeletons) only continue the line.
struct GraphRail: View {
    var above: Color
    var aboveOpacity: Double = 1
    var lane: Color
    var opacity: Double = 1
    var hasNode = true
    var nodeFilled = false
    var hasTail = true
    var dashedTail = false
    var nodeScale: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let x = DS.Metrics.railWidth / 2
            let nodeTop = DS.Metrics.nodeTop
            let node = DS.Metrics.node

            func line(from: CGFloat, to: CGFloat, color: Color, alpha: Double, dashed: Bool = false) {
                guard to > from else { return }

                var path = Path()
                path.move(to: CGPoint(x: x, y: from))
                path.addLine(to: CGPoint(x: x, y: to))
                context.stroke(path, with: .color(color.opacity(alpha)), style: StrokeStyle(lineWidth: DS.Metrics.railLine, dash: dashed ? [3, 3] : []))
            }

            guard hasNode else {
                line(from: 0, to: size.height, color: above, alpha: aboveOpacity)
                return
            }

            line(from: 0, to: nodeTop, color: above, alpha: aboveOpacity)

            if hasTail {
                line(from: nodeTop + node, to: size.height, color: dashedTail ? DS.Colors.rail : lane, alpha: dashedTail ? 1 : opacity, dashed: dashedTail)
            }

            let scaled = node * nodeScale
            let rect = CGRect(x: x - scaled / 2, y: nodeTop + node / 2 - scaled / 2, width: scaled, height: scaled).insetBy(dx: 1, dy: 1)
            context.fill(Path(ellipseIn: rect), with: .color(nodeFilled ? lane.opacity(opacity) : DS.Colors.shell))
            context.stroke(Path(ellipseIn: rect), with: .color(lane.opacity(opacity)), lineWidth: DS.Metrics.railLine)
        }
        .frame(width: DS.Metrics.railWidth)
        .accessibilityHidden(true)
    }
}

/// The 1pt hairline under a row, starting after the rail so the rail is never crossed.
struct RowHairline: View {
    var body: some View {
        DS.Colors.hairline
            .frame(height: 1)
            .padding(.leading, DS.Metrics.railWidth)
    }
}

// MARK: - Commit row

/// A commit in a log, a profile, Starred or search results: rail, avatar, header, body, embeds and the action row.
struct CommitRow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(RailHighlight.self) private var highlight: RailHighlight?
    @Environment(\.workspaceActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let box: CommitBox
    /// The lane and author of the row above, whose segment runs into this node.
    var above: (lane: Color, authorId: String?) = (DS.Colors.rail, nil)
    var showsHash = true
    var showsReplyContext = true
    var hasTail = true

    @State private var isHovered = false
    @State private var nodeScale: CGFloat = 1
    @State private var showsPreview = false

    private var commit: Commit { box.commit }
    private var lane: Color { LaneColor.of(commit.author) }
    private var isFocused: Bool { navigation.focusedRow == box.id }
    private var isSelected: Bool { navigation.selectedCommit == box.id }
    private var isOwn: Bool { commit.author?.id == workspace.session.user?.id }

    var body: some View {
        if commit.isTombstone {
            TombstoneRow(box: box, above: above, hasTail: hasTail)
        } else {
            HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: DS.Metrics.railWidth)

                if box.isDeleting {
                    Text("rm \(commit.hash)")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.destructive)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    content
                }
            }
            .background(alignment: .leading) {
                GraphRail(
                    above: above.lane,
                    aboveOpacity: highlight?.opacity(for: above.authorId) ?? 1,
                    lane: lane,
                    opacity: highlight?.opacity(for: commit.author?.id) ?? 1,
                    hasTail: hasTail,
                    nodeScale: nodeScale
                )
                .onHover { hovering in highlight?.authorId = hovering ? commit.author?.id : nil }
            }
            .overlay(alignment: .bottom) { RowHairline() }
            .animation(DS.Motion.respecting(reduceMotion, DS.Motion.quick), value: isHovered)
            .animation(DS.Motion.respecting(reduceMotion, DS.Motion.standard), value: highlight?.authorId)
            .contextMenu { CommitMenuItems(box: box) }
            .onAppear(perform: pop)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isFocused ? .isSelected : [])
            .id(box.id)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if showsReplyContext, let parentHandle = commit.parent?.value.author?.handle {
                Text("↳ replying to @\(parentHandle)")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .padding(.leading, DS.Metrics.bodyIndent)
            }

            header

            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                if !commit.text.isEmpty {
                    CommitBodyView(commit: commit)
                }

                TranslationView(box: box)
                CommitEmbeds(commit: commit)
                CommitActionRow(box: box)
            }
            .padding(.leading, DS.Metrics.bodyIndent)
        }
        .padding(.vertical, 10)
        .padding(.leading, DS.Spacing.xs)
        .padding(.trailing, DS.Metrics.commitGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isFocused {
                DS.Colors.primary.frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering { workspace.prefetchThread(box.id) } else { workspace.cancelThreadPrefetch() }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { navigation.openThread(box.id) })
        .simultaneousGesture(TapGesture().onEnded { navigation.focusedRow = box.id })
    }

    private var rowBackground: Color {
        if isSelected { return DS.Colors.selectionSoft }
        if isFocused || isHovered { return DS.Colors.wash }

        return .clear
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Spacing.m) {
            Button {
                openProfile()
            } label: {
                Avatar(user: commit.author, size: DS.Metrics.commitAvatar)
            }
            .buttonStyle(.plain)
            .onHover { hovering in highlight?.authorId = hovering ? commit.author?.id : nil }
            .userPreview(commit.author, isPresented: $showsPreview)
            .onReceive(NotificationCenter.default.publisher(for: .showUserPreview)) { note in
                if note.object as? String == box.id { showsPreview = true }
            }

            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                Button(action: openProfile) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Text(commit.author?.displayName ?? "")
                            .font(DS.Fonts.commitAuthor)
                            .foregroundStyle(DS.Colors.ink)
                            .lineLimit(1)
                        Text("@\(commit.author?.handle ?? "")")
                            .font(DS.Fonts.monoHandle)
                            .foregroundStyle(DS.Colors.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in highlight?.authorId = hovering ? commit.author?.id : nil }
                .layoutPriority(-1)

                Text("·")
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkFaint)

                Button {
                    navigation.push(.commit(box.id))
                } label: {
                    Text(Formatting.relative(commit.createdAt))
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                }
                .buttonStyle(.plain)
                .help(commit.createdAt.map { Formatting.stamp($0) } ?? "")
                .fixedSize()

                if isOwn, let status = commit.status, status != .approved {
                    StatusLabel(text: status == .pending ? "pending" : "not approved", tint: status == .pending ? DS.Colors.inkMuted : DS.Colors.destructive)
                }

                if commit.isPinned == true {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.Colors.inkFaint)
                        .accessibilityLabel("Pinned")
                }
            }

            Spacer(minLength: DS.Spacing.m)

            if showsHash {
                Button {
                    navigation.push(.commit(box.id))
                } label: {
                    Text(commit.hash)
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkFaint)
                }
                .buttonStyle(.plain)
                .help("Open Commit Page")
                .fixedSize()
            }
        }
        // Ends where the body and action row end, so the hash doesn't drift to the far edge on wide windows.
        .frame(maxWidth: DS.Metrics.bodyIndent + DS.Metrics.readingMeasure)
    }

    private func openProfile() {
        guard let handle = commit.author?.handle else { return }

        actions?.openProfile(handle)
    }

    /// The node pops when the user's own commit lands at the top.
    private func pop() {
        guard isOwn, let created = commit.createdAt, Date.now.timeIntervalSince(created) < 5, !reduceMotion else { return }

        nodeScale = 0.4
        withAnimation(DS.Motion.standard) { nodeScale = 1 }
    }

    private var accessibilityLabel: String {
        var parts = ["\(commit.author?.displayName ?? "Someone"), @\(commit.author?.handle ?? "")", Formatting.relative(commit.createdAt), commit.text]

        if commit.stars > 0 { parts.append("\(commit.stars) stars") }
        if commit.replies > 0 { parts.append("\(commit.replies) replies") }

        return parts.joined(separator: ", ")
    }
}

/// The translated body under the original, with where it came from and the way back.
struct TranslationView: View {
    @Environment(Workspace.self) private var workspace
    let box: CommitBox

    var body: some View {
        if let translation = box.translation {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if translation.available == false || translation.body == nil {
                    Text("fatal: no translation available")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                } else {
                    Text(translation.body ?? "")
                        .font(DS.Fonts.commitBody)
                        .lineSpacing(DS.Fonts.commitLineSpacing)
                        .foregroundStyle(DS.Colors.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: DS.Metrics.readingMeasure, alignment: .leading)
                }

                HStack(spacing: DS.Spacing.s) {
                    Text("translated from \(translation.sourceName ?? translation.sourceLanguage ?? "another language")")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkFaint)
                    Button("Show original") { workspace.translate(box.id) }
                        .buttonStyle(LinkButtonStyle())
                        .font(DS.Fonts.caption)
                }
            }
            .padding(.leading, DS.Spacing.m)
            .overlay(alignment: .leading) { DS.Colors.rail.frame(width: 2) }
        }
    }
}

// MARK: - Action row

/// Star, reply, the replies summary, copy link and more. The full row, in the replies pane and on the commit page,
/// adds quote, pastéis and translate.
struct CommitActionRow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.workspaceActions) private var actions
    @Environment(\.openWindow) private var openWindow

    let box: CommitBox
    var full = false

    @State private var copied = false

    private var commit: Commit { box.commit }
    private var isOwn: Bool { commit.author?.id == workspace.session.user?.id }

    var body: some View {
        HStack(spacing: DS.Spacing.l) {
            Button {
                workspace.toggleStar(box.id)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: commit.isStarred ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(commit.isStarred ? DS.Colors.primary : DS.Colors.inkMuted)
                    if commit.stars > 0 {
                        Text(verbatim: "\(commit.stars)")
                            .font(DS.Fonts.monoCaption)
                            .foregroundStyle(commit.isStarred ? DS.Colors.primary : DS.Colors.inkMuted)
                    }
                }
                .frame(minWidth: 28, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isOwn)
            .help(isOwn ? "You can't star your own commit" : commit.isStarred ? "Unstar (s)" : "Star (s)")
            .accessibilityLabel(commit.isStarred ? "Unstar, \(commit.stars) stars" : "Star, \(commit.stars) stars")

            iconButton("bubble.left", help: "Reply (r)", label: "Reply") {
                navigation.openThread(box.id, focusComposer: true)
            }

            if full {
                iconButton("quote.bubble", help: "Quote (q)", label: "Quote") {
                    CommitCommand.perform(.quote, on: box.id, workspace: workspace, navigation: navigation, actions: actions, openWindow: openWindow)
                }

                if workspace.session.user?.pasteisMode == true, !isOwn {
                    Button {
                        workspace.givePastel(box.id)
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            // The web's pastel de nata, with a plain glyph until it loads.
                            RemoteImage(url: APIClient.baseURL.appending(path: "pastel-de-nata.svg"), contentMode: .fit) {
                                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(DS.Colors.warning)
                            }
                            .frame(width: 14, height: 14)
                            if let count = commit.pasteisCount, count > 0 {
                                Text(verbatim: "\(count)").font(DS.Fonts.monoCaption).foregroundStyle(DS.Colors.inkMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Give a Pastel")
                    .accessibilityLabel("Give a pastel, \(commit.pasteisCount ?? 0) given")
                }

                iconButton("character.bubble", help: "Translate", label: box.translation == nil ? "Translate" : "Show original") {
                    workspace.translate(box.id)
                }
            }

            if commit.replies > 0, !full {
                Button {
                    navigation.toggleThread(box.id)
                } label: {
                    HStack(spacing: DS.Spacing.s) {
                        RepliersStack(users: commit.repliers)
                        Text("\(commit.replies) \(commit.replies == 1 ? "reply" : "replies")")
                            .font(DS.Fonts.bodyMedium)
                            .foregroundStyle(DS.Colors.primary)
                        if let last = commit.lastReplyAt {
                            Text("last \(Formatting.relative(last))")
                                .font(DS.Fonts.monoMeta)
                                .foregroundStyle(DS.Colors.inkFaint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Replies (o)")
                .accessibilityLabel("\(commit.replies) replies")
            }

            Spacer(minLength: 0)

            iconButton(copied ? "checkmark" : "link", help: "Copy Link (y)", label: "Copy link") {
                workspace.copyLink(box.id)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }

            Menu {
                CommitMenuItems(box: box)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.inkMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions")
        }
        .frame(maxWidth: DS.Metrics.readingMeasure)
    }

    private func iconButton(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.inkMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Up to three repliers' avatars, overlapped −4 and knocked out by the row behind them.
struct RepliersStack: View {
    let users: [User]
    var size: CGFloat = 18

    var body: some View {
        if !users.isEmpty {
            HStack(spacing: -4) {
                ForEach(Array(users.prefix(3).enumerated()), id: \.element.id) { index, user in
                    Avatar(user: user, size: size)
                        .padding(1.5)
                        .background(DS.Colors.surface, in: Circle())
                        .zIndex(Double(3 - index))
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// The commit's context menu, also behind the row's `…`.
struct CommitMenuItems: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.workspaceActions) private var actions
    @Environment(\.openWindow) private var openWindow

    let box: CommitBox

    private var commit: Commit { box.commit }
    private var isOwn: Bool { commit.author?.id == workspace.session.user?.id }

    var body: some View {
        button("Reply", .reply)
        button("Quote…", .quote)
        if !isOwn {
            button(commit.isStarred ? "Unstar" : "Star", .star)
        }
        if workspace.session.user?.pasteisMode == true, !isOwn {
            button("Give a Pastel", .pastel)
        }

        Divider()

        button("Copy Link", .copyLink)
        button("Open Commit Page", .openPage)
        button("Open in New Window", .openWindow)
        if !commit.text.isEmpty {
            button(box.translation == nil ? "Translate" : "Show Original", .translate)
        }

        Divider()

        if isOwn {
            if commit.parentId == nil {
                button(commit.isPinned == true ? "Unpin from Profile" : "Pin to Profile", .pin)
            }
            Button("Delete…", role: .destructive) { perform(.delete) }
        } else {
            button("Report…", .report)

            Divider()

            if let handle = commit.author?.handle {
                button("Mute @\(handle)", .mute)
                button("Block @\(handle)…", .block)
            }
        }
    }

    private func button(_ title: String, _ command: CommitCommand) -> some View {
        Button(title) { perform(command) }
    }

    private func perform(_ command: CommitCommand) {
        CommitCommand.perform(command, on: box.id, workspace: workspace, navigation: navigation, actions: actions, openWindow: openWindow)
    }
}

// MARK: - Tombstone, markers, skeleton, root

/// A deleted commit that still has replies: the rail stays, with a dashed disc where the avatar was.
struct TombstoneRow: View {
    @Environment(Navigation.self) private var navigation
    let box: CommitBox
    var above: (lane: Color, authorId: String?) = (DS.Colors.rail, nil)
    var hasTail = true

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.m) {
            Circle()
                .strokeBorder(DS.Colors.rail, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: DS.Metrics.commitAvatar, height: DS.Metrics.commitAvatar)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("[deleted]")
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
                Text("This commit was deleted.")
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.inkMuted)
            }

            Spacer(minLength: 0)

            if box.commit.replies > 0 {
                Button("\(box.commit.replies) \(box.commit.replies == 1 ? "reply" : "replies")") { navigation.toggleThread(box.id) }
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, DS.Metrics.railWidth + DS.Spacing.xs)
        .padding(.trailing, DS.Metrics.commitGutter)
        .background(alignment: .leading) {
            GraphRail(above: above.lane, lane: DS.Colors.rail, hasTail: hasTail)
        }
        .overlay(alignment: .bottom) { RowHairline() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Deleted commit")
    }
}

/// A day marker or the HEAD marker: the rail continues without a node beside a mono label.
struct MarkerRow: View {
    enum Kind {
        case day(Date)
        case head
    }

    let kind: Kind
    var lane: Color = DS.Colors.rail

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            switch kind {
            case let .day(date):
                Text(Formatting.dayMarker(date))
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
            case .head:
                Text("HEAD@{last visit}")
                    .font(DS.Fonts.monoCaption)
                    .foregroundStyle(DS.Colors.inkMuted)
                Line()
                    .stroke(DS.Colors.rail, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(height: 1)
            }
        }
        .padding(.vertical, DS.Spacing.s)
        .padding(.leading, DS.Metrics.railWidth + DS.Spacing.xs)
        .padding(.trailing, DS.Metrics.commitGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) { GraphRail(above: lane, lane: lane, hasNode: false) }
        .accessibilityElement(children: .combine)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// A commit row's shape while the next page loads: the rail keeps running beside an avatar disc and three bars.
struct SkeletonCommitRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Circle()
                .fill(DS.Colors.wash)
                .frame(width: DS.Metrics.commitAvatar, height: DS.Metrics.commitAvatar)

            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    SkeletonBar(width: proxy.size.width * 0.4, height: 10)
                        .padding(.top, 13)
                    SkeletonBar(width: proxy.size.width * 0.9, height: 10)
                    SkeletonBar(width: proxy.size.width * 0.6, height: 10)
                }
            }
            .frame(height: 76)
        }
        .padding(.vertical, 10)
        .padding(.leading, DS.Metrics.railWidth + DS.Spacing.xs)
        .padding(.trailing, DS.Metrics.commitGutter)
        .background(alignment: .leading) {
            GraphRail(above: DS.Colors.rail, lane: DS.Colors.rail)
        }
        .skeleton()
    }
}

/// The end of history: a hollow node with no tail.
struct RootNodeRow: View {
    var above: Color

    var body: some View {
        HStack {
            Text("That's the root commit. There's nothing before it.")
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.bottom, DS.Spacing.xxl)
        .padding(.leading, DS.Metrics.railWidth + DS.Spacing.xs)
        .background(alignment: .topLeading) {
            GraphRail(above: above, lane: DS.Colors.rail, hasTail: false)
                .frame(height: 44)
        }
    }
}
