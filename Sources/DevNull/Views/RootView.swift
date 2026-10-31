import SwiftUI

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .waitingForBrowser:
                SignInView()
            case .signedIn:
                SignedIn { WorkspaceView() }
            }
        }
        // Commit Blue is the app's one accent, whatever the system accent is: selection, links, toggles, focus.
        .tint(DS.Colors.primaryFill)
        .onAppear {
            #if DEBUG
                PreviewAppearance.apply()
            #endif
        }
    }
}

/// A window's content once someone is signed in, with the inbox and the workspace it reads from. A window opened while
/// signed out shows the sign-in screen.
struct SignedIn<Content: View>: View {
    @Environment(Session.self) private var session
    @ViewBuilder var content: () -> Content

    var body: some View {
        if session.phase == .signedIn, let inbox = session.inbox, let workspace = session.workspace, let calls = session.calls {
            content()
                .environment(inbox)
                .environment(workspace)
                .environment(calls)
                .tint(DS.Colors.primaryFill)
        } else if session.phase == .loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SignInView()
        }
    }
}

struct SignInView: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: DS.Spacing.xxl) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            VStack(spacing: DS.Spacing.s) {
                Wordmark()
                Text("Push and pull remotes with everyone on /dev/null.")
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.inkMuted)
            }

            // Both states share one slot, so approving in the browser doesn't move anything above it.
            ZStack(alignment: .top) {
                waiting
                    .opacity(session.phase == .waitingForBrowser ? 1 : 0)
                    .accessibilityHidden(session.phase != .waitingForBrowser)
                signIn
                    .opacity(session.phase == .waitingForBrowser ? 0 : 1)
                    .accessibilityHidden(session.phase == .waitingForBrowser)
            }
            .animation(DS.Motion.quick, value: session.phase)

            Text(session.error ?? " ")
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.destructive)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340, minHeight: 34, alignment: .top)
                .opacity(session.error == nil ? 0 : 1)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.shell)
    }

    private var signIn: some View {
        VStack(spacing: DS.Spacing.l) {
            Button {
                session.signIn()
            } label: {
                Text("Sign In with GitHub")
                    .frame(minWidth: 220)
            }
            .buttonStyle(DSButtonStyle(kind: .primary, large: true))
            .keyboardShortcut(.defaultAction)

            Text("Your browser opens /dev/null to approve this Mac as a device.\nNo password or token is stored: the Mac keeps its own key in your Keychain.")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.inkFaint)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
    }

    private var waiting: some View {
        VStack(spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.m) {
                ProgressView().controlSize(.small)
                Text("Approve this Mac in your browser…")
                    .font(DS.Fonts.body)
                    .foregroundStyle(DS.Colors.inkMuted)
            }
            .frame(height: DS.Metrics.controlHeightLarge)

            HStack(spacing: DS.Spacing.m) {
                Button("Open Browser Again") { session.signIn() }
                    .buttonStyle(.dsOutline)
                Button("Cancel") { session.cancelSignIn() }
                    .buttonStyle(.dsGhost)
            }
        }
    }
}

/// "/dev/null" as the web sets it: lowercase, bold, tight tracking, the second slash drawn as an outline in the first
/// lane. SwiftUI can't stroke text, so the glyphs are laid out by Core Text and drawn as paths.
struct Wordmark: View {
    var size: CGFloat = 30

    var body: some View {
        let glyphs = WordmarkGlyphs(size: size)

        Canvas { context, _ in
            context.fill(glyphs.solid, with: .color(DS.Colors.ink))
            context.stroke(glyphs.slash, with: .color(DS.Colors.lane(0)), lineWidth: max(1, size * 0.035))
        }
        .frame(width: glyphs.bounds.width, height: glyphs.bounds.height)
        .accessibilityElement()
        .accessibilityLabel("/dev/null")
    }
}

private struct WordmarkGlyphs {
    let solid: Path
    let slash: Path
    let bounds: CGSize

    init(size: CGFloat) {
        let text = NSAttributedString(string: "/dev/null", attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .kern: -0.025 * size,
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        // Core Text draws upward from the baseline; the canvas draws downward from the top.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: ascent)
        let solid = CGMutablePath()
        let slash = CGMutablePath()

        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            let range = CFRange(location: 0, length: count)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            CTRunGetStringIndices(run, range, &indices)

            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName as String] as! CTFont

            for index in 0 ..< count {
                guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }

                // The second slash, "/dev[/]null", is the outlined one.
                (indices[index] == 4 ? slash : solid).addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y).concatenating(flip))
            }
        }

        self.solid = Path(solid)
        self.slash = Path(slash)
        bounds = CGSize(width: ceil(width), height: ceil(ascent + descent))
    }
}
