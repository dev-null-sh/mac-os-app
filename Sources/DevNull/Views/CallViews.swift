import SwiftUI

/// The phone beside Ping in a remote's composer. It asks first, in the call console above the composer, since the
/// offer carries this Mac's addresses.
struct CallButton: View {
    @Environment(CallCenter.self) private var calls
    let thread: ThreadModel

    var body: some View {
        Button { calls.confirming = thread.reference } label: {
            Image(systemName: "phone")
        }
        .buttonStyle(IconButtonStyle(size: 30))
        .disabled(calls.isBusy)
        .help(calls.isBusy ? "Already on a call" : label)
        .accessibilityLabel(label)
    }

    private var label: String {
        thread.partner.map { "Call @" + $0.handle } ?? "Call \(thread.orgName ?? "the org")"
    }
}

/// The call of this remote, above its composer: asking, ringing, connected with the controls, or how it ended.
struct CallConsole: View {
    @Environment(CallCenter.self) private var calls
    let thread: ThreadModel

    var body: some View {
        Group {
            if let partner = thread.partner {
                DirectCallCard(partner: partner, isInThread: true)
            } else if case let .org(id, name) = thread.reference {
                OrgCallCard(org: OrgInfo(id: id, name: thread.orgName ?? name), isInThread: true)
            }
        }
        .padding(.horizontal, DS.Spacing.m + 2)
        .padding(.bottom, DS.Spacing.s)
        .animation(DS.Motion.standard, value: calls.direct)
        .animation(DS.Motion.standard, value: calls.org)
    }
}

/// The call going on, floating over every page but the remote it's in, so it can be answered or hung up from anywhere.
struct CallBar: View {
    @Environment(CallCenter.self) private var calls
    @Environment(Navigation.self) private var navigation

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            if let partner = calls.direct.partner, !isShowing(.direct(partner)) {
                DirectCallCard(partner: partner, isInThread: false)
            }

            if let org = calls.org.org ?? calls.ringingOrgCall?.org, !isShowing(.org(id: org.id, name: org.name)) {
                OrgCallCard(org: org, isInThread: false)
            }
        }
        .frame(maxWidth: 448)
        .padding(.top, DS.Spacing.m)
        .padding(.horizontal, DS.Spacing.l)
        .animation(DS.Motion.standard, value: calls.direct)
        .animation(DS.Motion.standard, value: calls.org)
        .animation(DS.Motion.standard, value: calls.ringingOrgCall)
    }

    private func isShowing(_ reference: ThreadReference) -> Bool {
        navigation.path.isEmpty && navigation.item == .remote(reference)
    }
}

// MARK: - 1:1

private struct DirectCallCard: View {
    @Environment(CallCenter.self) private var calls
    @Environment(Navigation.self) private var navigation: Navigation?
    let partner: User
    let isInThread: Bool

    private var handle: String { "@" + partner.handle }

    var body: some View {
        switch calls.direct {
        case let .ringing(user, _) where user.id == partner.id:
            CallCard(tone: .primary) {
                Avatar(user: partner, size: 22)
                (Text(handle).fontWeight(.semibold) + Text(" is calling")).lineLimit(1)
                Spacer(minLength: DS.Spacing.s)
                Button("Decline") { calls.declineCall() }.buttonStyle(.dsOutline)
                Button("Accept") { calls.acceptCall() }.buttonStyle(.dsPrimary)
            }
        case let .calling(user, since) where user.id == partner.id:
            CallCard {
                Dot(color: DS.Colors.primary, pulses: true)
                HStack(spacing: DS.Spacing.xs) {
                    Text("Ringing \(handle)…").fontWeight(.semibold)
                    Elapsed(since: since).foregroundStyle(DS.Colors.inkMuted)
                }
                .lineLimit(1)
                Spacer(minLength: DS.Spacing.s)
                Button("Cancel") { calls.hangUp() }.buttonStyle(.dsOutline)
            }
        case let .connecting(user) where user.id == partner.id:
            CallCard {
                ProgressView().controlSize(.small)
                Text("Connecting…").fontWeight(.semibold)
                Spacer(minLength: DS.Spacing.s)
                Button("Cancel") { calls.hangUp() }.buttonStyle(.dsOutline)
            }
        case let .connected(user, startedAt) where user.id == partner.id:
            CallCard {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    if calls.hasVideo {
                        CallVideoView(engine: calls.engine).frame(height: calls.videoHeight)
                    }

                    HStack(spacing: DS.Spacing.m) {
                        Dot(color: DS.Colors.success)
                        Elapsed(since: startedAt).fontWeight(.medium)

                        if !calls.code.isEmpty {
                            Text("fp \(calls.code)")
                                .font(DS.Fonts.monoCaption)
                                .foregroundStyle(DS.Colors.inkMuted)
                                .help("Read this out to \(handle). If you both see the same code, nobody is listening in between.")
                        }

                        Spacer(minLength: DS.Spacing.s)

                        if !isInThread, let navigation {
                            Button("Open remote") { navigation.select(.remote(.direct(partner))) }.buttonStyle(.dsGhost)
                        }

                        CallControls(leaveLabel: "Hang up") { calls.hangUp() }
                    }

                    CallNotice()
                }
            }
        case let .ended(user, reason) where user.id == partner.id:
            CallCard {
                Text(reason).foregroundStyle(DS.Colors.inkMuted).lineLimit(2)
                Spacer(minLength: DS.Spacing.s)
                DismissButton { calls.dismissDirect() }
            }
        default:
            if isInThread, calls.confirming == .direct(partner), !calls.isBusy {
                CallCard {
                    (Text("Call ") + Text(handle).fontWeight(.semibold) + Text("?")).lineLimit(1)
                    Spacer(minLength: DS.Spacing.s)
                    Button("Cancel") { calls.confirming = nil }.buttonStyle(.dsOutline)
                    Button("Call") { calls.startCall(partner) }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

// MARK: - Orgs

private struct OrgCallCard: View {
    @Environment(CallCenter.self) private var calls
    @Environment(Navigation.self) private var navigation: Navigation?
    let org: OrgInfo
    let isInThread: Bool

    private var name: String { org.name ?? "the org" }
    private var reference: ThreadReference { .org(id: org.id, name: org.name) }
    private var ongoing: OngoingOrgCall? { calls.ongoing.first { $0.org.id == org.id } }

    var body: some View {
        switch calls.org {
        case let .joining(current) where current.id == org.id:
            CallCard {
                ProgressView().controlSize(.small)
                Text("Joining the call…").fontWeight(.semibold)
                Spacer(minLength: DS.Spacing.s)
                Button("Cancel") { calls.leaveOrgCall() }.buttonStyle(.dsOutline)
            }
        case let .joined(current, joinedAt) where current.id == org.id:
            joined(since: joinedAt)
        case let .ended(current, reason) where current.id == org.id:
            CallCard {
                Text(reason).foregroundStyle(DS.Colors.inkMuted).lineLimit(2)
                Spacer(minLength: DS.Spacing.s)
                DismissButton { calls.dismissOrg() }
            }
        default:
            if let ringing = calls.ringingOrgCall, ringing.org.id == org.id {
                CallCard(tone: .primary) {
                    (Text("Call in ") + Text(name).fontWeight(.semibold) + Text(" · " + handles(ringing.members))).lineLimit(1)
                    Spacer(minLength: DS.Spacing.s)
                    Button("Decline") { calls.declineOrgCall() }.buttonStyle(.dsOutline)
                    Button("Join") { calls.joinOrgCall(org) }.buttonStyle(.dsPrimary)
                }
            } else if isInThread, calls.confirming == reference, !calls.isBusy {
                CallCard {
                    (Text(ongoing == nil ? "Call everyone in " : "Join the call in ") + Text(name).fontWeight(.semibold) + Text("?")).lineLimit(1)
                    Spacer(minLength: DS.Spacing.s)
                    Button("Cancel") { calls.confirming = nil }.buttonStyle(.dsOutline)
                    Button(ongoing == nil ? "Call" : "Join") { calls.joinOrgCall(org) }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                }
            } else if isInThread, let ongoing, !calls.isBusy {
                CallCard {
                    Dot(color: DS.Colors.success, pulses: true)
                    Text("Call going on · " + handles(ongoing.members)).lineLimit(1)
                    Spacer(minLength: DS.Spacing.s)
                    Button("Join") { calls.joinOrgCall(org) }.buttonStyle(.dsPrimary)
                }
            }
        }
    }

    private func joined(since: Date) -> some View {
        CallCard {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                if calls.hasVideo {
                    CallVideoView(engine: calls.engine).frame(height: calls.videoHeight)
                }

                HStack(spacing: DS.Spacing.m) {
                    Dot(color: calls.peers.isEmpty ? DS.Colors.primary : DS.Colors.success, pulses: calls.peers.isEmpty)

                    Group {
                        if calls.peers.isEmpty {
                            Text(calls.orgIsRinging ? "Ringing \(name)…" : "Waiting for someone to join…").fontWeight(.semibold)
                        } else {
                            HStack(spacing: DS.Spacing.xs) {
                                if !isInThread { Text(name).fontWeight(.semibold) }
                                Elapsed(since: since).fontWeight(.medium)
                            }
                        }
                    }
                    .lineLimit(1)

                    Spacer(minLength: DS.Spacing.s)

                    if !isInThread, let navigation {
                        Button("Open remote") { navigation.select(.remote(reference)) }.buttonStyle(.dsGhost)
                    }

                    CallControls(leaveLabel: "Leave") { calls.leaveOrgCall() }
                }

                if !calls.peers.isEmpty {
                    WrappingHStack(spacing: DS.Spacing.xs) {
                        Text("In the call")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.inkMuted)

                        ForEach(calls.peers) { peer in
                            HStack(spacing: DS.Spacing.xs) {
                                Dot(color: peer.isConnected ? DS.Colors.success : DS.Colors.primary, pulses: !peer.isConnected)
                                Text("@" + peer.user.handle).font(DS.Fonts.monoCaption)
                            }
                            .padding(.horizontal, DS.Spacing.s)
                            .padding(.vertical, DS.Spacing.xxs)
                            .background(DS.Colors.wash, in: Capsule())
                            .help(peer.isConnected
                                ? "fp \(peer.code). Read it out to @\(peer.user.handle): if you both see the same code, nobody is listening in between."
                                : "Connecting to @\(peer.user.handle)…")
                        }
                    }
                }

                CallNotice()
            }
        }
    }

    private func handles(_ members: [CallMember]) -> String {
        let names = members.prefix(2).map { "@" + $0.user.handle }.joined(separator: ", ")
        return members.count > 2 ? "\(names) +\(members.count - 2)" : names
    }
}

// MARK: - Pieces

/// Mute, camera, the screen sharing to come, and hanging up or leaving.
private struct CallControls: View {
    @Environment(CallCenter.self) private var calls
    let leaveLabel: String
    let leave: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            control(calls.isMicMuted ? "mic.slash.fill" : "mic.fill", calls.isMicMuted ? "Unmute microphone" : "Mute microphone", isOn: calls.isMicMuted) {
                calls.toggleMicrophone()
            }

            control(calls.isCameraOn ? "video.fill" : "video.slash", calls.isCameraOn ? "Turn camera off" : "Turn camera on", isOn: calls.isCameraOn) {
                calls.toggleCamera()
            }

            control("rectangle.on.rectangle", "Screen sharing is coming soon", isOn: false) {}
                .disabled(true)

            Button(action: leave) {
                Label(leaveLabel, systemImage: "phone.down.fill")
            }
            .buttonStyle(.dsDestructive)
            .help(leaveLabel)
        }
    }

    private func control(_ symbol: String, _ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(IconButtonStyle(size: 30, tint: isOn ? DS.Colors.primary : DS.Colors.inkMuted))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct CallNotice: View {
    @Environment(CallCenter.self) private var calls

    var body: some View {
        if let notice = calls.notice {
            Label(notice, systemImage: "exclamationmark.circle.fill")
                .font(DS.Fonts.chatCaption.weight(.medium))
                .foregroundStyle(DS.Colors.destructive)
        }
    }
}

private struct CallCard<Content: View>: View {
    enum Tone {
        case plain
        case primary
    }

    var tone = Tone.plain
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            content()
        }
        .font(DS.Fonts.body)
        .foregroundStyle(DS.Colors.ink)
        .padding(DS.Spacing.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .primary ? DS.Colors.primarySoft : DS.Colors.popover, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(tone == .primary ? DS.Colors.primary : DS.Colors.hairline))
        .elevation(DS.Elevation.floating)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Call")
    }
}

private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .buttonStyle(IconButtonStyle(size: 28))
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

private struct Dot: View {
    let color: Color
    var pulses = false
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(pulses && isDim ? 0.35 : 1)
            .onAppear {
                guard pulses else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { isDim = true }
            }
            .accessibilityHidden(true)
    }
}

/// mm:ss since the call started, ticking every second.
private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(DS.Fonts.monoCaption)
        }
    }
}
