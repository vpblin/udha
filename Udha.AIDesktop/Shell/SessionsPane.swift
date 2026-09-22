import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Sessions detail pane: which machine one supervised session is running
/// on, what it is doing, what it wants from you, and a box to answer in.
struct SessionsPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    @State private var draft = ""
    /// Files dropped onto the pane, waiting to go out with the next message.
    @State private var attachments: [SessionAttachment] = []
    /// True while a drag is hovering the pane, so the border can say "let go".
    @State private var dropTargeted = false
    /// The Mac's input devices, for the mic picker in the header.
    @State private var mics = AudioInputDevices()
    @State private var pendingHandoff: SessionsBoard.PendingHandoff?
    /// Which half of the pane is showing when the embedded terminal is on.
    /// Defaults to the terminal: switching the feature on is a statement that
    /// you want to watch the session, not read a fact list about it.
    @State private var tab: PaneTab = .terminal
    /// The session whose title is being edited inline, and the draft text.
    /// Nil when not renaming. Double-click the title or pick Rename to start.
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool
    /// Redrawn when a terminal client detaches or dies, so the chrome around
    /// it can say so. The terminal itself is an NSView and repaints itself.
    @State private var terminalStatus: EmbeddedTerminalController.Status = .attached

    enum PaneTab: Hashable { case terminal, details }

    private var embeddedOn: Bool { core.config.config.embeddedTerminal }

    private let inset: CGFloat = UdhaTheme.contentInset

    private var snapshot: SessionSnapshot? {
        guard let id = shell.selectedSessionID else { return nil }
        return core.stateStore.snapshot(id: id)
    }

    var body: some View {
        Group {
            if let snap = snapshot {
                detail(snap)
            } else {
                UdhaEmptyState(
                    title: "Nothing supervised yet",
                    text: "Start a session and Udha watches it — the state, the tool it's on, and the moment it needs you.",
                    action: ("New session", "plus", { shell.newSessionOpen = true })
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A session that goes away takes its terminal with it — otherwise a
        // removed session leaves a client attached to a tmux that no longer
        // exists, and the controller leaks for the life of the app.
        .onChange(of: core.stateStore.orderedIDs) { _, ids in
            core.embeddedTerminals.prune(keeping: Set(ids))
        }
        // The board's "Rename" item selects the session and trips this flag;
        // start the inline editor once the detail pane is showing it.
        .onChange(of: shell.renameSelectedSession) { _, want in
            guard want, let snap = snapshot else { return }
            shell.renameSelectedSession = false
            beginRename(snap)
        }
        .sheet(item: $pendingHandoff) { plan in
            SessionHandoffSheet(core: core, shell: shell, plan: plan) { pendingHandoff = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaDriverTab)) { note in
            guard let which = note.object as? String else { return }
            tab = which == "details" ? .details : .terminal
        }
    }

    // MARK: - Detail

    /// Header and machine card are fixed; only the body between them and the
    /// send box scrolls, so the thing you're about to type into never walks off
    /// the bottom of a long session.
    private func detail(_ snap: SessionSnapshot) -> some View {
        let stale = core.config.config.staleAfterSeconds
        let style = UdhaSessionStyle(snapshot: snap, staleAfter: stale)
        let machine = MachineDirectory.summary(core: core, host: snap.hostName)
        let showTerminal = embeddedOn && tab == .terminal

        return VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
            header(snap, style: style)
            // The row under the buttons: the notify link at the left, and at
            // the right — under Open in Terminal — which Claude login the
            // session is on, how full it is, and the menu that moves it.
            let login = loginMembers(snap)
            if snap.supportsAttentionEvents || login != nil {
                HStack(alignment: .center, spacing: 12) {
                    if snap.supportsAttentionEvents {
                        Button {
                            core.sessionManager.changeAttention(id: snap.id, action: "watch", enabled: !snap.attentionState.notifyWhenDone)
                        } label: {
                            Label(snap.attentionState.notifyWhenDone ? "Will notify when done" : "Notify when done",
                                  systemImage: snap.attentionState.notifyWhenDone ? "bell.fill" : "bell")
                        }.buttonStyle(.link)
                    }
                    Spacer(minLength: 0)
                    if let login { loginStrip(snap, current: login.current, members: login.members) }
                }
            }
            runningOn(snap, machine: machine)
            AttentionInbox(core: core, shell: shell, sessionID: snap.id)
            if snap.sizePinned {
                pinnedSizeCard(snap)
            }

            if showTerminal {
                terminalBody(snap)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                        if let ask = waitingText(snap, stale: stale) {
                            waitingCard(snap, text: ask)
                        }
                        factsCard(snap, machine: machine)
                    }
                    .padding(.bottom, 8)
                }
                .udhaScroll()
            }

            // One input, never two. With the terminal showing, Claude's own
            // prompt is the input — it is the one that has the slash-command
            // menu, the approval keys and the history — so Udha's box would
            // only be a second place to type that behaves differently.
            if !showTerminal {
                sendBox(snap)
            }
        }
        .padding(.horizontal, inset)
        .padding(.top, 18)
        .padding(.bottom, showTerminal ? 18 : 12)
        // Drop anywhere on the pane, not just on the box: with the terminal
        // tab open the box is a 36pt target at the very bottom of the window.
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers, snap)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: UdhaTheme.cardRadius, style: .continuous)
                    .strokeBorder(UdhaTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Embedded terminal

    /// The live terminal in a card. One controller per session, kept alive by
    /// `AppCore` so switching cards does not re-attach.
    private func terminalBody(_ snap: SessionSnapshot) -> some View {
        let controller = core.embeddedTerminals.controller(for: snap)
        return VStack(spacing: 0) {
            if case .ended(let why) = terminalStatus {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UdhaTheme.warnInk)
                    Text(why)
                        .font(UdhaTheme.text(12, .medium))
                        .foregroundStyle(UdhaTheme.label)
                    Spacer(minLength: 8)
                    Button("Reattach") { controller.reattach() }
                        .udhaButton(.primary, height: 24, hPadding: 11)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UdhaTheme.warnTint)
                HRule(color: UdhaTheme.hairline)
            }
            EmbeddedTerminalSurface(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(6)
        }
        .udhaCard()
        .udhaRounded(UdhaTheme.cardRadius)
        .id(snap.id)
        .onAppear {
            terminalStatus = controller.status
            controller.onStatusChange = { terminalStatus = $0 }
        }
    }

    // MARK: - Header

    private func header(_ snap: SessionSnapshot, style: UdhaSessionStyle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                if let agent = snap.agentName {
                    HStack(spacing: 5) {
                        Text("✦").font(UdhaTheme.text(10, .regular))
                        Text(agent).font(UdhaTheme.text(11, .semibold))
                    }
                    .foregroundStyle(UdhaTheme.accentInk)
                }
                HStack(spacing: 9) {
                    PingDot(color: style.mark, size: 10, active: style.pulses)
                    if renamingID == snap.id {
                        TextField("", text: $renameDraft)
                            .textFieldStyle(.plain)
                            .font(UdhaTheme.text(22, .bold))
                            .foregroundStyle(UdhaTheme.label)
                            .focused($renameFocused)
                            .onSubmit { commitRename(snap) }
                            .onExitCommand { renamingID = nil }
                            .frame(maxWidth: 380)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UdhaTheme.card))
                            .udhaOutline(radius: 7, color: UdhaTheme.accent, width: 1.5)
                    } else {
                        Text(snap.label)
                            .font(UdhaTheme.text(22, .bold))
                            .tracking(-0.3)
                            .foregroundStyle(UdhaTheme.label)
                            .lineLimit(1)
                            // Double-click to rename, the same gesture that
                            // renames a meeting's title.
                            .onTapGesture(count: 2) { beginRename(snap) }
                            .help("Double-click to rename")
                    }
                }
                HStack(spacing: 8) {
                    Mono(UdhaFormat.tildePath(snap.directory), size: 11.5)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let right = snap.model ?? snap.tool.flatMap({ $0 == .claude ? nil : $0.label }) {
                        UdhaPill(right, fg: UdhaTheme.accentInk, bg: UdhaTheme.accentTint, height: 18)
                    }
                    if let account = snap.account {
                        UdhaPill(account, fg: UdhaTheme.secondary, bg: UdhaTheme.fill, height: 18)
                            .help("The Claude login this session runs under. It moves to another one in the pool when this one hits its usage limit.")
                    }
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                micPicker

                if embeddedOn {
                    UdhaSegmented(options: [(PaneTab.terminal, "Terminal"), (PaneTab.details, "Details")],
                                  selection: $tab)
                }

                Menu {
                    if core.agents.agents.isEmpty {
                        Text("No agents yet")
                    } else {
                        ForEach(core.agents.agents) { agent in
                            Button(agent.name) {
                                _ = core.sessionManager.runAgent(agent, sourceSessionID: snap.id)
                                shell.say("\(agent.name) running in a fresh session")
                            }
                        }
                    }
                } label: {
                    UdhaLabel(title: "Run agent", icon: "plus")
                        .foregroundStyle(UdhaTheme.label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous).fill(UdhaTheme.fill))
                .font(UdhaTheme.text(12, .medium))

                Button {
                    core.sessionManager.showSession(id: snap.id)
                    shell.say("Focused \(snap.label) in Terminal")
                } label: {
                    UdhaLabel(title: "Open in Terminal", icon: "terminal")
                }
                .udhaButton(.primary, height: 26)

                Menu {
                    if snap.supportsAttentionEvents {
                        Button(snap.attentionState.notifyWhenDone ? "Cancel completion notification" : "Notify me when done") {
                            core.sessionManager.changeAttention(id: snap.id, action: "watch", enabled: !snap.attentionState.notifyWhenDone)
                        }
                        Toggle("Notify for reviews", isOn: Binding(get: { snap.attentionState.notifyReviews },
                            set: { core.sessionManager.changeAttention(id: snap.id, action: "reviews", enabled: $0) }))
                        Toggle("Notify for completions", isOn: Binding(get: { snap.attentionState.notifyCompletions },
                            set: { core.sessionManager.changeAttention(id: snap.id, action: "completions", enabled: $0) }))
                        Divider()
                    }
                    Button("Rename") { beginRename(snap) }
                    Button("Duplicate") {
                        if let id = core.sessionManager.duplicate(sessionID: snap.id) {
                            shell.select(session: id)
                        }
                    }
                    if snap.account != nil, snap.hostName == nil || !core.remoteHostClient.hostAccountsUnsupported {
                        Button("Switch Claude login") { core.sessionManager.rotateAccount(id: snap.id) }
                            .help("Move this conversation to the login in its pool with the most headroom, right now")
                    }
                    Button(snap.priority == .high ? "Set normal priority" : "Set high priority") {
                        core.sessionManager.setPriority(
                            id: snap.id, level: snap.priority == .high ? .normal : .high
                        )
                    }
                    Divider()
                    Button("Release window size") { core.sessionManager.releaseWindowSize(id: snap.id) }
                        .help("Hand the tmux window back to the terminal attached to it after a phone sized it")
                    Divider()
                    Button("Terminate process") { core.sessionManager.terminateSession(id: snap.id) }
                    Button("Remove session", role: .destructive) {
                        core.sessionManager.removeSession(id: snap.id)
                        shell.selectedSessionID = core.stateStore.visible.first?.id
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UdhaTheme.label)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous).fill(UdhaTheme.fill))
            }
        }
    }

    // MARK: - Login strip

    /// The session's login and its tree's pool, read from the machine that
    /// owns the pool: this Mac's manager for a local session, the host's
    /// `accounts` reply for a remote one. A box whose agent predates the
    /// reply still gets a name-only strip from the row's `account`.
    private func loginMembers(_ snap: SessionSnapshot) -> (current: String?, members: [ClaudeLoginOverview])? {
        guard snap.tool == .claude else { return nil }
        if snap.hostName == nil {
            guard let info = core.sessionManager.loginOverview(for: snap.id), !info.members.isEmpty else { return nil }
            return info
        }
        if let pool = core.remoteHostClient.hostPool(for: snap.directory), !pool.members.isEmpty {
            return (pool.members.first { $0.name == snap.account }?.dir, pool.members)
        }
        if let login = core.remoteHostClient.hostDefaultLogin, snap.account == nil || snap.account == login.name {
            return (login.dir, [login])
        }
        guard let account = snap.account else { return nil }
        return (account, [ClaudeLoginOverview(dir: account, name: account)])
    }

    /// Person glyph, the login's name, its two windows as meters, and Switch.
    private func loginStrip(_ snap: SessionSnapshot, current: String?, members: [ClaudeLoginOverview]) -> some View {
        let me = members.first { $0.dir == current } ?? members.first { $0.name == snap.account } ?? members.first
        let canSwitch = members.count > 1
            && (snap.hostName == nil || !core.remoteHostClient.hostAccountsUnsupported)
        return HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UdhaTheme.secondary)
            Text(me?.displayName ?? snap.account ?? "—")
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
            if let me, me.isLimited() {
                UdhaPill(me.headroom(), fg: UdhaTheme.badInk, bg: UdhaTheme.badTint, size: 10.5, height: 18)
            } else if let me, me.needsSignIn {
                UdhaPill("sign in again", fg: UdhaTheme.warnInk, bg: UdhaTheme.warnTint, size: 10.5, height: 18)
            } else if let u = me?.usage {
                usageMeter("5h", u.fiveHourPercent, resets: u.fiveHourResetsAt)
                usageMeter("7d", u.sevenDayPercent, resets: u.sevenDayResetsAt)
                if u.scopedPercent != nil {
                    usageMeter(u.scopedName, u.scopedPercent, resets: u.scopedResetsAt)
                }
            } else {
                Text("no reading yet")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            if canSwitch {
                Menu {
                    Button("Emptiest login") {
                        core.sessionManager.rotateAccount(id: snap.id)
                        shell.say("Moving \(snap.label) to the login with the most headroom")
                    }
                    Divider()
                    ForEach(members) { m in
                        Button {
                            core.sessionManager.rotateAccount(id: snap.id, to: m.dir)
                            shell.say("Moving \(snap.label) to \(m.name)")
                        } label: {
                            if m.dir == me?.dir {
                                Label("\(m.displayName) · \(m.headroom())", systemImage: "checkmark")
                            } else {
                                Text("\(m.displayName) · \(m.headroom())")
                            }
                        }
                        .disabled(m.dir == me?.dir)
                    }
                } label: {
                    UdhaLabel(title: "Switch", icon: "arrow.left.arrow.right", iconSize: 11)
                        .foregroundStyle(UdhaTheme.label)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous).fill(UdhaTheme.fill))
                .font(UdhaTheme.text(11.5, .medium))
                .help("Move this conversation to another Claude login in its pool, keeping the transcript")
            }
        }
        .help("The Claude login this session runs under and how much of its five-hour and weekly windows are used. It moves on its own when this one hits its limit.")
    }

    /// "5h ▰▰▱▱ 26%" — one window's fill, coloured by how close it is.
    private func usageMeter(_ label: String, _ percent: Int?, resets: Date?) -> some View {
        let p = percent ?? 0
        let tint: Color = p >= 90 ? UdhaTheme.bad : (p >= 60 ? UdhaTheme.warn : UdhaTheme.accent)
        return HStack(spacing: 5) {
            Text(label)
                .font(UdhaTheme.mono(10))
                .foregroundStyle(UdhaTheme.tertiary)
            UdhaBar(fraction: Double(p) / 100, color: tint, height: 5)
                .frame(width: 44)
            Text(percent.map { "\($0)%" } ?? "—")
                .font(UdhaTheme.text(11, .medium))
                .monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
        }
        .help(resets.map { "Resets \(ClaudeAccountPool.clock.string(from: $0))" } ?? "\(label) window")
    }

    // MARK: - Running on

    /// Which machine this session is on, and the one action that changes it.
    /// The hand-off button is only drawn when there is somewhere to send it —
    /// a button that explains why it can't run is worse than no button in a
    /// strip this small, and the context menu still says the same thing.
    private func runningOn(_ snap: SessionSnapshot, machine: MachineSummary) -> some View {
        HStack(spacing: 10) {
            Text("Running on")
                .font(UdhaTheme.text(11, .semibold))
                .foregroundStyle(UdhaTheme.secondary)
            StateMark(color: machine.online ? UdhaTheme.good : UdhaTheme.bad, size: 8, filled: true, pulses: false)
            Text(machine.name)
                .font(UdhaTheme.text(13, .bold))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
            if machine.platform != "—", !machine.platform.isEmpty {
                Text(machine.platform)
                    .font(UdhaTheme.text(11.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if machine.latency != "—" {
                Text(machine.latency)
                    .font(UdhaTheme.text(11.5, .regular))
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.secondary)
            }
            if let host = handoffTarget(snap) {
                Button("Hand off to \(host)") {
                    pendingHandoff = SessionsBoard.PendingHandoff(sessions: [snap], host: host)
                }
                .udhaButton(.ghost, height: 24, hPadding: 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .udhaCard(radius: 10)
    }

    // MARK: - Pinned size

    /// The phone sized this window to its own screen and did not hand it back
    /// — the terminal here is letterboxed at phone width until something does.
    /// Amber, not red: nothing is wrong with the session, only its shape.
    private func pinnedSizeCard(_ snap: SessionSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UdhaTheme.warnInk)
            Text("Sized for the phone")
                .font(UdhaTheme.text(12.5, .semibold))
                .foregroundStyle(UdhaTheme.warnInk)
            Text("The window is pinned to the phone's grid; this terminal shows it letterboxed.")
                .font(UdhaTheme.text(11.5, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Release") { core.sessionManager.releaseWindowSize(id: snap.id) }
                .udhaButton(.ghost, height: 24, hPadding: 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UdhaTheme.warnTint))
    }

    /// OS and round trip, dropping whichever has not been read yet.
    private func machineMeta(_ m: MachineSummary) -> String {
        var parts: [String] = []
        if m.platform != "—", !m.platform.isEmpty { parts.append(m.platform) }
        if m.latency != "—" { parts.append(m.latency) }
        return parts.joined(separator: " · ")
    }

    /// Only local sessions can move, and only to a box that is answering.
    private func handoffTarget(_ snap: SessionSnapshot) -> String? {
        guard snap.hostName == nil else { return nil }
        return core.remoteHostClient.onlineHosts.sorted().first
    }

    // MARK: - Waiting card

    /// The prompt on screen when there is one, otherwise the question the turn
    /// ended on. Both mean the same thing to you — it's your move — so both get
    /// the same card.
    private func waitingText(_ snap: SessionSnapshot, stale: Double) -> String? {
        guard !snap.supportsAttentionEvents, snap.attention(staleAfter: stale) == .needsYou else { return nil }
        if let text = snap.blockedText, !text.isEmpty { return text }
        if let q = snap.lastQuestion, !q.isEmpty { return q }
        if let err = snap.lastErrorMessage, !err.isEmpty { return err }
        return nil
    }

    private func waitingCard(_ snap: SessionSnapshot, text: String) -> some View {
        let destructive = snap.pendingPrompt?.isDestructive ?? false
        let yesNo = snap.pendingPrompt?.style == .yesNo
        let blocked = snap.blockedKind != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Pulsing(period: 1.4) {
                    Circle().fill(UdhaTheme.bad).frame(width: 8, height: 8)
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Waiting on you · \(UdhaFormat.duration(since: snap.phaseEnteredAt, now: ctx.date))")
                        .font(UdhaTheme.text(11, .semibold))
                        .foregroundStyle(UdhaTheme.badInk)
                }
                Spacer(minLength: 8)
                if let kind = snap.blockedKind {
                    UdhaPill(kind, fg: UdhaTheme.badInk, bg: UdhaTheme.badTint, size: 10.5, height: 18, mono: true)
                }
            }

            Text(text)
                .font(blocked ? UdhaTheme.mono(12.5) : UdhaTheme.text(15, .medium))
                .lineSpacing(blocked ? 4 : 3)
                .foregroundStyle(UdhaTheme.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

            if destructive {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text("This one reads as destructive. Check what it is about to do before approving.")
                        .font(UdhaTheme.text(12, .medium))
                }
                .foregroundStyle(UdhaTheme.badInk)
                .padding(.top, 12)
            }

            HStack(spacing: 8) {
                if blocked {
                    Button {
                        core.sessionManager.approvePrompt(id: snap.id)
                        shell.say("Approved · \(snap.label)")
                    } label: {
                        Text(yesNo ? "Yes, go ahead" : "Approve")
                    }
                    .udhaButton(.primary, height: 28, hPadding: 12)

                    Button(yesNo ? "Not now" : "Reject") {
                        core.sessionManager.rejectPrompt(id: snap.id)
                        shell.say("Rejected — told Claude to stop")
                    }
                    .udhaButton(.ghost, height: 28, hPadding: 12)
                }

                Button {
                    core.sessionManager.showSession(id: snap.id)
                    shell.say("Focused \(snap.label) in Terminal")
                } label: { Text("Open in Terminal") }
                .udhaButton(.bare, height: 28, hPadding: 8)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .udhaCard(fill: UdhaTheme.badTint)
    }

    // MARK: - Facts

    /// The Session fact list as a card: repo, tmux window, machine, last
    /// activity, context/spend, tool·subagents. The tmux name is the one the
    /// host spawned under, so it is the string you can actually paste into
    /// `tmux attach -t` on either machine — including after a rename.
    private func factsCard(_ snap: SessionSnapshot, machine: MachineSummary) -> some View {
        let tmux = snap.tmuxTarget
        var rows: [(String, String, Bool)] = [
            ("Assistant", snap.tool?.label ?? "shell command", false),
            ("Model", snap.model ?? "—", false),
            ("Repo", UdhaFormat.tildePath(snap.directory), true),
            ("tmux window", "\(tmux):0", true),
            ("Machine", [machine.name, machineMeta(machine)].filter { !$0.isEmpty }.joined(separator: " · "), false),
            ("Last activity", "\(UdhaFormat.duration(since: snap.phaseEnteredAt)) ago", false),
            ("Context / spend", SessionsBoard.meta(snap), true),
            ("Tool · subagents",
             "\(snap.phase == .usingTool ? (snap.phaseDetail ?? "—") : "—") · \(snap.subagentCount == 0 ? "—" : "\(snap.subagentCount)")",
             true),
        ]
        if let account = snap.account { rows.insert(("Login", account, true), at: 2) }
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Session")
                    .font(UdhaTheme.text(13, .semibold))
                    .foregroundStyle(UdhaTheme.label)
                Spacer()
                Text("watch it live in Terminal")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(UdhaTheme.fill)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(row.0)
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .frame(width: 130, alignment: .leading)
                    if row.2 {
                        Mono(row.1, size: 11.5, color: UdhaTheme.label)
                            .textSelection(.enabled)
                    } else {
                        Text(row.1)
                            .font(UdhaTheme.text(12.5, .regular))
                            .foregroundStyle(UdhaTheme.label)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
            }
        }
        .udhaCard()
        .udhaRounded(UdhaTheme.cardRadius)
    }

    // MARK: - Microphone

    /// Which mic the Mac is listening to, one click from the session you are
    /// talking to. It sets the *system* default input, so dictation into the
    /// terminal, the voice agent and a meeting recording all follow it.
    private var micPicker: some View {
        Menu {
            ForEach(mics.devices) { device in
                Button {
                    if mics.select(device) { shell.say("Listening on \(device.name)") }
                } label: {
                    Text(device.id == mics.currentID ? "✓ \(device.name)" : device.name)
                }
            }
            Divider()
            Button("Sound settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            UdhaLabel(title: mics.currentName, icon: "mic")
                .foregroundStyle(UdhaTheme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous).fill(UdhaTheme.fill))
        .font(UdhaTheme.text(12, .regular))
        .help("Microphone the Mac is listening to")
    }

    // MARK: - Rename

    /// Begin editing a session's title inline. Focus is grabbed on the next
    /// runloop tick, after the TextField has actually been placed.
    private func beginRename(_ snap: SessionSnapshot) {
        renameDraft = snap.label
        renamingID = snap.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ snap: SessionSnapshot) {
        let text = renameDraft.trimmingCharacters(in: .whitespaces)
        renamingID = nil
        renameFocused = false
        guard !text.isEmpty, text != snap.label else { return }
        core.sessionManager.rename(sessionID: snap.id, to: text)
        shell.say("Renamed to \(text)")
    }

    // MARK: - Send box

    /// The box for typing to the session, and the strip of images dropped
    /// onto the pane waiting to go with it.
    private func sendBox(_ snap: SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty { attachmentStrip }
            HStack(spacing: 10) {
                UdhaField(placeholder: "Send text — or drop a file anywhere here",
                          text: $draft, height: 32) {
                    send(snap)
                }
                Button("Send") { send(snap) }
                    .udhaButton(.primary, height: 32, hPadding: 16)
                    .disabled(!canSend)
            }
        }
    }

    /// Nothing to say and nothing to show, or an image still on its way to the
    /// box — either way there is nothing to send yet.
    private var canSend: Bool {
        guard attachments.allSatisfy(\.isReady) else { return false }
        return !draft.trimmingCharacters(in: .whitespaces).isEmpty || !attachments.isEmpty
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { item in
                    HStack(spacing: 8) {
                        if let preview = item.preview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 26, height: 26)
                                .clipped()
                                .udhaRounded(4)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(UdhaTheme.text(11, .medium))
                                .foregroundStyle(UdhaTheme.label)
                                .lineLimit(1)
                            if let failure = item.failure {
                                Text(failure)
                                    .font(UdhaTheme.text(10, .regular))
                                    .foregroundStyle(UdhaTheme.badInk)
                            } else if let host = item.host {
                                Text(item.remotePath == nil ? "copying to \(host)…" : "on \(host)")
                                    .font(UdhaTheme.text(10, .regular))
                                    .foregroundStyle(UdhaTheme.tertiary)
                            }
                        }
                        .frame(maxWidth: 160, alignment: .leading)
                        Button {
                            attachments.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .udhaButton(.bare, height: 18, hPadding: 4)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .udhaCard(radius: 8)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 4)
        }
        .frame(height: 48)
    }

    private func send(_ snap: SessionSnapshot) {
        guard canSend else { return }
        let text = SessionAttachments.compose(text: draft.trimmingCharacters(in: .whitespaces),
                                              attachments: attachments)
        guard !text.isEmpty else { return }
        core.sessionManager.sendInput(id: snap.id, text: text)
        draft = ""
        attachments = []
        shell.say("Sent to \(snap.label)")
    }

    // MARK: - Dropped images

    /// Claude Code can't be handed bytes through tmux, so a dropped image is
    /// staged as a file and its path goes out with the next message — exactly
    /// what you would do by hand, minus the trip through Finder. A session on
    /// the box gets its own copy over SSH first, so the path resolves there.
    private func handleDrop(_ providers: [NSItemProvider], _ snap: SessionSnapshot) -> Bool {
        guard SessionAttachments.canHandle(providers) else { return false }
        let host = snap.hostName
        // With the terminal showing you are typing *there*, not in the send
        // box — so the path is typed into the live prompt at the cursor and
        // goes out with whatever you write around it. Nothing is submitted.
        let toPrompt = embeddedOn && tab == .terminal
        Task {
            let staged = await SessionAttachments.stage(providers, host: host)
            guard !staged.isEmpty else {
                shell.say("Nothing to attach there — drop files, not folders")
                return
            }
            if toPrompt {
                await typeIntoPrompt(staged, snap: snap, host: host)
                return
            }
            attachments.append(contentsOf: staged)
            shell.say(staged.count == 1 ? "Attached \(staged[0].name)" : "Attached \(staged.count) files")
            guard let host else { return }
            for item in staged {
                do {
                    let remote = try await SessionAttachments.upload(item.localURL, to: host)
                    update(item.id) { $0.remotePath = remote }
                } catch {
                    update(item.id) { $0.failure = "couldn't copy to \(host)" }
                    shell.say("Copy to \(host) failed: \(error.localizedDescription)")
                }
            }
        }
        return true
    }

    /// Type staged paths into the session's own prompt, cursor where it is,
    /// with no Enter — the drop adds the image to the sentence you are already
    /// writing instead of firing a message of its own.
    private func typeIntoPrompt(_ staged: [SessionAttachment],
                                snap: SessionSnapshot,
                                host: String?) async {
        for item in staged {
            var path = item.localURL.path
            if let host {
                shell.say("Copying \(item.name) to \(host)…")
                do {
                    path = try await SessionAttachments.upload(item.localURL, to: host)
                } catch {
                    shell.say("Copy to \(host) failed: \(error.localizedDescription)")
                    continue
                }
            }
            core.sessionManager.sendRaw(id: snap.id, text: path + " ")
        }
        shell.say(staged.count == 1
                  ? "Typed \(staged[0].name) into the prompt"
                  : "Typed \(staged.count) image paths into the prompt")
    }

    private func update(_ id: UUID, _ change: (inout SessionAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&attachments[index])
    }
}
