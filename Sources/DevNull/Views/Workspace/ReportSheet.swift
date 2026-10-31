import AppKit
import SwiftUI

/// Report commit, as on the web: a reason, optional details and up to three images that only the reporter and
/// moderators see.
struct ReportSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    let commit: Commit

    @State private var reason = "spam"
    @State private var details = ""
    @State private var images: [Attachment] = []
    @State private var isSending = false
    @State private var error: String?

    private static let reasons: [(String, String)] = [("spam", "Spam or misleading links"), ("harassment", "Harassment or hate"), ("unsafe", "Harmful or private information"), ("other", "Something else")]
    private static let maxImages = 3

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Report \(commit.hash)")
                    .font(DS.Fonts.section)
                    .foregroundStyle(DS.Colors.ink)
                Text("Your report is private. Attachments are visible only to you and moderators. Reporting does not hide this commit.")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !commit.text.isEmpty {
                Text(commit.text)
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.ink)
                    .lineLimit(3)
                    .padding(.vertical, DS.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { DS.Colors.hairline.frame(height: 1) }
                    .overlay(alignment: .bottom) { DS.Colors.hairline.frame(height: 1) }
            }

            Picker("Reason", selection: $reason) {
                ForEach(Self.reasons, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.radioGroup)

            TextField("Details (optional)", text: $details, axis: .vertical)
                .lineLimit(2 ... 5)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .fieldChrome()
                .onChange(of: details) { details = String(details.prefix(500)) }

            ForEach($images) { $attachment in
                HStack(spacing: DS.Spacing.m) {
                    Group {
                        if let image = attachment.image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            DS.Colors.wash
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

                    TextField("Describe the image for screen readers", text: $attachment.description)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.body)
                        .fieldChrome()

                    Button { images.removeAll { $0.id == attachment.id } } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Remove Image")
                    .accessibilityLabel("Remove image")
                }
            }

            if let error {
                Text(error)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.destructive)
            }

            HStack {
                Button("Add Image…", action: pickImages)
                    .buttonStyle(.dsOutline)
                    .disabled(images.count >= Self.maxImages || isSending)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.dsOutline)
                    .keyboardShortcut(.cancelAction)
                Button(isSending ? "Reporting…" : "Report", action: send)
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSending)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 440)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let attachment = AttachmentLoader.attachment(fileAt: url) else { return }
                    DispatchQueue.main.async { if images.count < Self.maxImages { images.append(attachment) } }
                }
            }
            return true
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .webP]

        guard panel.runModal() == .OK else { return }

        images.append(contentsOf: panel.urls.compactMap(AttachmentLoader.attachment(fileAt:)).prefix(Self.maxImages - images.count))
    }

    private func send() {
        isSending = true
        error = nil

        Task {
            defer { isSending = false }

            do {
                try await workspace.report(commit.id, reason: reason, details: details.trimmingCharacters(in: .whitespacesAndNewlines), images: images)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
