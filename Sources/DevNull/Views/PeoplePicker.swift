import SwiftUI

/// Finds people for a new remote, a new org, or to add to an org, as the web's pickers do: anyone who can't be picked
/// stays listed, greyed out, with the reason.
struct PeoplePicker: View {
    enum Mode: Equatable {
        case remote
        case newOrg
        case addToOrg(id: String)
        /// Sending a commit's link to one person, as the web's "Send commit in Remotes".
        case share

        var isMultiple: Bool { self != .remote && self != .share }

        var title: String {
            switch self {
            case .remote: "New Remote"
            case .newOrg: "New Org"
            case .addToOrg: "Add People"
            case .share: "Send Commit in Remotes"
            }
        }
    }

    @Environment(Inbox.self) private var inbox
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let done: (_ users: [User], _ name: String, _ shareHistory: Bool) -> Void

    @State private var search = ""
    @State private var candidates: [Candidate] = []
    @State private var selected: [User] = []
    @State private var name = ""
    @State private var shareHistory = true
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                Text(mode.title)
                    .font(DS.Fonts.section)
                    .foregroundStyle(DS.Colors.ink)

                if mode == .newOrg {
                    TextField("Org name (optional)", text: $name)
                        .font(DS.Fonts.body)
                        .fieldChrome()
                        .onChange(of: name) { name = String(name.prefix(60)) }
                }

                SearchField(prompt: "Search by name or @handle", text: $search)

                if mode.isMultiple {
                    selectedChips
                }
            }
            .padding([.horizontal, .top], DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.m)

            DS.Colors.hairline.frame(height: 1)

            List {
                if let error {
                    EmptyState(fatal: "fatal: could not search people", message: error)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                } else if candidates.isEmpty, !isLoading {
                    EmptyState(
                        fatal: search.isEmpty ? "$ who" : "fatal: no one matches “\(search)”",
                        message: search.isEmpty ? "Search for someone to push to." : "Try a name or an @handle."
                    )
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                }

                ForEach(candidates) { candidate in
                    CandidateRow(candidate: candidate, isSelected: selected.contains { $0.id == candidate.user.id })
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(candidate) }
                        .opacity(candidate.reason == nil ? 1 : 0.5)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { toggle(candidate) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 280)
            .overlay {
                if isLoading, candidates.isEmpty { ProgressView().controlSize(.small) }
            }

            DS.Colors.hairline.frame(height: 1)

            HStack(spacing: DS.Spacing.m) {
                if case .addToOrg = mode {
                    Toggle("Share history with them", isOn: $shareHistory)
                        .toggleStyle(.checkbox)
                        .font(DS.Fonts.body)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.dsGhost)
                    .keyboardShortcut(.cancelAction)

                if mode.isMultiple {
                    Button(mode == .newOrg ? "Create" : "Add") {
                        done(selected, name.trimmingCharacters(in: .whitespaces), shareHistory)
                        dismiss()
                    }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                }
            }
            .padding(DS.Spacing.l)
        }
        .background(DS.Colors.popover)
        .frame(width: 420, height: 520)
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// The people picked so far. The strip keeps its height while empty, so picking the first person doesn't push the
    /// list down.
    private var selectedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.s) {
                ForEach(selected) { user in
                    HStack(spacing: DS.Spacing.xs) {
                        Avatar(user: user, size: 18)
                        Text("@" + user.handle)
                            .font(DS.Fonts.monoHandle)
                            .foregroundStyle(DS.Colors.primary)
                        Button { selected.removeAll { $0.id == user.id } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(DS.Colors.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove @\(user.handle)")
                    }
                    .padding(.leading, 3)
                    .padding(.trailing, DS.Spacing.s)
                    .frame(height: 24)
                    .background(DS.Colors.primarySoft, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                }

                if selected.isEmpty {
                    Text(mode == .newOrg ? "Pick at least one person." : "Pick the people to add.")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.inkFaint)
                }
            }
        }
        .frame(height: 24)
    }

    private func load() async {
        struct Response: Decodable { let candidates: [Candidate] }

        isLoading = true
        defer { isLoading = false }

        let query: [String: String?] = switch mode {
        case .remote: ["q": search]
        case .share: ["q": search, "for": "share"]
        case .newOrg: ["q": search, "for": "org"]
        case let .addToOrg(id): ["q": search, "org": id]
        }

        do {
            let response: Response = try await inbox.api.get("remotes/candidates", query: query)
            candidates = response.candidates
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ candidate: Candidate) {
        if let reason = candidate.reason {
            presentAlert("@\(candidate.user.handle) \(reason).")
            return
        }

        guard mode.isMultiple else {
            done([candidate.user], "", false)
            dismiss()
            return
        }

        if let index = selected.firstIndex(where: { $0.id == candidate.user.id }) {
            selected.remove(at: index)
        } else {
            selected.append(candidate.user)
        }
    }
}

struct CandidateRow: View {
    let candidate: Candidate
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(user: candidate.user, size: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.user.displayName)
                    .font(DS.Fonts.bodyMedium)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(1)
                Text(candidate.reason ?? "@" + candidate.user.handle)
                    .font(candidate.reason == nil ? DS.Fonts.monoHandle : DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .lineLimit(1)
            }
            .help(candidate.reason.map { "@\(candidate.user.handle) \($0)" } ?? "@" + candidate.user.handle)

            Spacer(minLength: DS.Spacing.m)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(isSelected ? DS.Colors.primary : DS.Colors.rail)
                .opacity(candidate.reason == nil ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, DS.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
