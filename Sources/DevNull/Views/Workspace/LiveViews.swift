import SwiftUI

/// The web's LIVE marker beside someone streaming, which opens their stream in the browser.
struct LiveBadge: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let stream: LiveStream

    @State private var isPulsing = false

    var body: some View {
        Button {
            if let url = URL(string: stream.url) { openURL(url) }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .opacity(isPulsing ? 0.4 : 1)
                Text("LIVE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(nsColor: NSColor(hex: 0xDC2626)), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Watch live on \(stream.platformName)")
        .accessibilityLabel("Live on \(stream.platformName). Watch.")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever()) { isPulsing = true }
        }
    }
}

extension User {
    /// The stream they're on, while it lasts.
    var liveStream: LiveStream? { live.flatMap { $0.isOn ? $0 : nil } }
}

/// Go live, as on the web: a YouTube or Twitch link, and for how many hours the marker stays on the avatar.
struct GoLiveSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var hours = 2.0
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Go Live")
                    .font(DS.Fonts.section)
                    .foregroundStyle(DS.Colors.ink)
                Text("Share your YouTube or Twitch stream and your avatar gets a live marker that sends people to it, for as long as you choose.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Stream link")
                    .font(DS.Fonts.bodyMedium)
                TextField("https://www.youtube.com/live/… or https://twitch.tv/…", text: $url)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .fieldChrome()
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack {
                    Text("For")
                        .font(DS.Fonts.bodyMedium)
                    Spacer()
                    Text(Int(hours) == 1 ? "1 hour" : "\(Int(hours)) hours")
                        .font(DS.Fonts.monoCaption)
                        .foregroundStyle(DS.Colors.inkMuted)
                }
                Slider(value: $hours, in: 1 ... 12, step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("1h").font(DS.Fonts.monoCaption)
                } maximumValueLabel: {
                    Text("12h").font(DS.Fonts.monoCaption)
                }
            }

            if let error {
                Text(error)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.destructive)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.dsOutline)
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Going Live…" : "Go Live", action: save)
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 440)
    }

    private func save() {
        isSaving = true
        error = nil

        Task {
            defer { isSaving = false }

            do {
                try await workspace.setLive(url: url.trimmingCharacters(in: .whitespaces), hours: Int(hours))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The people the user follows who are live right now, as the web's "Live now", each opening their stream.
struct LiveNowSection: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL

    var body: some View {
        let people = workspace.liveFollowing.filter { $0.liveStream != nil }

        if !people.isEmpty {
            Section {
                ForEach(people) { user in
                    Button {
                        if let url = user.liveStream.flatMap({ URL(string: $0.url) }) { openURL(url) }
                    } label: {
                        HStack(spacing: DS.Spacing.s) {
                            Avatar(user: user, size: 18)
                            Text(user.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.Colors.inkFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Watch @\(user.handle) live on \(user.liveStream?.platformName ?? "")")
                    .accessibilityLabel("Watch \(user.displayName) live")
                }
            } header: {
                SidebarSectionHeader(title: "Live now")
            }
        }
    }
}
