import SwiftUI
import AppKit

/// The whole main window: a 52pt translucent title bar, the nav sidebar, the
/// list column, the content pane, and a 28pt status bar — with the command
/// palette and Settings layered on top.
struct UdhaRootView: View {
    @Environment(AppCore.self) private var core
    @State private var shell = UdhaShellModel()
    /// Bumped when the accent changes so every colour is re-read.
    @State private var themeRevision = UdhaTheme.revision
    /// The design's `windowin`: the content settles into place on launch.
    @State private var settled = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    UdhaSidebar(core: core, shell: shell)
                    content
                        .background(contentGround)
                }
                .frame(maxHeight: .infinity)

                HRule()
                UdhaStatusBar(core: core, shell: shell)
            }
            .background(UdhaTheme.canvas)
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 10)
            .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.6), value: settled)
            .onAppear { settled = true }

            // Keyboard-only affordances. Hidden buttons rather than a global
            // NSEvent monitor so the shortcuts follow the responder chain and
            // stay inert while another window is key.
            Group {
                Button("") { shell.togglePalette() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("") { shell.newSessionOpen = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("") { recordShortcut() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("") { joinShortcut() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("") { openSelectedInTerminal() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("") { toggleSessionList() }
                    .keyboardShortcut("\\", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)

            if shell.paletteOpen {
                UdhaCommandPalette(core: core, shell: shell)
                    .transition(.opacity)
            }

            if shell.settingsOpen {
                UdhaSettingsSheet(core: core, shell: shell)
                    .transition(.opacity)
            }
        }
        .id(themeRevision)
        // The window's own unified toolbar is the title bar: the section's
        // name and hint sit beside the traffic lights, the meeting control and
        // the new-session button on the right. Native, so the lights are
        // centred, the bar drags the window, and dark mode is AppKit's.
        .modifier(UdhaToolbar(core: core, shell: shell))
        .modifier(UdhaUIDriver(core: core, shell: shell))
        .animation(UdhaTheme.quick, value: shell.paletteOpen)
        .animation(UdhaTheme.quick, value: shell.settingsOpen)
        .frame(minWidth: 1180, minHeight: 660)
        .tint(UdhaTheme.accent)
        .sheet(isPresented: $shell.newSessionOpen) {
            UdhaNewSessionSheet(core: core, seed: shell.newSessionSeed, clearSeed: { shell.newSessionSeed = nil },
                                isPresented: $shell.newSessionOpen) { id in
                shell.select(session: id)
            }
        }
        // Anchored here rather than on VideosPane: ⌘J can fire while the
        // sidebar has focus, and the sheet has to be presentable then too.
        .sheet(isPresented: $shell.joinSheetOpen) {
            JoinVideosSheet(core: core, shell: shell)
        }
        .sheet(isPresented: $shell.firstRunOpen) {
            FirstRunView(config: core.config, keychain: core.keychain) {
                shell.firstRunOpen = false
            }
            .interactiveDismissDisabled()
        }
        .onAppear { onAppear() }
        .onChange(of: shell.selectedSessionID) { _, new in
            core.stateStore.focusedSessionID = new
        }
        // The appearance and accent are settings; applying them re-keys the
        // tree so every adaptive colour is re-read with the new accent.
        .onChange(of: core.config.config.appearance) { _, appearance in
            UdhaTheme.apply(config: core.config.config)
            themeRevision = UdhaTheme.revision
            _ = appearance
        }
        // Sessions are restored asynchronously, so the list is usually empty
        // when the window first appears — and a selected session can be removed
        // out from under us. Re-anchor whenever the roster changes so the detail
        // pane never sits on "nothing supervised" with sessions in the sidebar.
        .onChange(of: core.stateStore.visible.map(\.id)) { _, ids in
            let stale = shell.selectedSessionID.map { !ids.contains($0) } ?? true
            if stale { shell.selectedSessionID = ids.first }
            if shell.selectedMeetingID == nil {
                shell.selectedMeetingID = core.meetings.store.meetings.first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaRequestNewSession)) { _ in
            shell.newSessionOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaRequestSettings)) { _ in
            shell.openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaRequestMeetings)) { _ in
            // "Meetings…" while one is being recorded means *that* meeting.
            if core.meetings.live != nil { shell.openLive() } else { shell.go(.meetings) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaOpenSection)) { note in
            guard let section = note.object as? UdhaSection else { return }
            shell.go(section)
        }
        .onReceive(NotificationCenter.default.publisher(for: .udhaFocusSession)) { note in
            guard let id = note.object as? UUID else { return }
            shell.select(session: id)
        }
    }

    /// The canvas under the content pane, with the ambient glow drifting
    /// through it when that is on.
    @ViewBuilder
    private var contentGround: some View {
        ZStack {
            UdhaTheme.canvas
            if core.config.config.appearance.ambientGlow {
                AmbientGlow()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch shell.section {
        case .sessions: SessionsPane(core: core, shell: shell)
        case .meetings: MeetingsPane(core: core, shell: shell)
        case .agents:   AgentsPane(core: core, shell: shell)
        case .inbox:    InboxPane(core: core, shell: shell)
        case .videos:   VideosPane(core: core, shell: shell)
        case .machines: MachinesPane(core: core, shell: shell)
        }
    }

    private func onAppear() {
        if shell.selectedSessionID == nil {
            shell.selectedSessionID = core.stateStore.visible.first?.id
        }
        if shell.selectedAgentSlug == nil {
            shell.selectedAgentSlug = core.agents.agents.first?.slug
        }
        if shell.selectedMeetingID == nil {
            shell.selectedMeetingID = core.meetings.store.meetings.first?.id
        }
        if shell.selectedThreadID == nil {
            shell.selectedThreadID = core.slack.inbox.threads.first?.id
        }
        // A meeting already running when the window opens (auto-record fired
        // while it was closed) should land you on the live view, not on an old
        // meeting's notes.
        if core.meetings.live != nil { shell.openLive() }
        if !core.config.config.hasCompletedFirstRun { shell.firstRunOpen = true }
    }

    /// Collapse the sidebar to its nav rail. Reached from the title bar, ⌘\\
    /// and ⌘K, because the moment you need it is usually the moment the window
    /// is already in front of an audience.
    private func toggleSessionList() {
        let now = !core.config.config.hideSessionList
        core.config.mutate { $0.hideSessionList = now }
        shell.say(now ? "List hidden · ⌘\\ to bring it back" : "List shown")
    }

    private func recordShortcut() {
        if core.meetings.live != nil {
            Task { await core.meetings.stop() }
            shell.showingLive = false
            shell.say("Meeting ended · writing it up")
        } else {
            Task { await core.meetings.start(mode: .standard) }
            shell.openLive()
            shell.say("Recording · mic + system audio")
        }
    }

    /// ⌘J opens the join sheet for whatever is ticked in Videos. Says why when
    /// it can't, rather than doing nothing: a shortcut that is silently inert
    /// reads as a broken shortcut.
    private func joinShortcut() {
        guard shell.section == .videos else { return }
        let picked = core.recordings.store.recordings
            .filter { shell.joinSelection.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        guard picked.count >= 2 else {
            shell.say(picked.isEmpty
                      ? "Tick two videos to join them"
                      : "Tick one more video to join")
            return
        }
        shell.openJoinSheet(
            order: picked.map(\.id),
            name: RecordingCenter.defaultJoinTitle(for: picked)
        )
    }

    private func openSelectedInTerminal() {
        guard shell.section == .sessions, let id = shell.selectedSessionID else { return }
        core.sessionManager.showSession(id: id)
    }
}

// MARK: - Title bar (the window toolbar)

/// The section's name and hint as the window title, the list toggle at the
/// leading edge, and on the right the meeting control and the new-session
/// button.
struct UdhaToolbar: ViewModifier {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    private var hidden: Bool { core.config.config.hideSessionList }

    func body(content: Content) -> some View {
        content
            .navigationTitle(shell.section.title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        let now = !hidden
                        core.config.mutate { $0.hideSessionList = now }
                        shell.say(now ? "List hidden · ⌘\\ to bring it back" : "List shown")
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help(hidden ? "Show list (⌘\\)" : "Hide list (⌘\\)")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    meetingButton
                    Button { shell.newSessionOpen = true } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    }
                    .udhaButton(.primary, height: 26, square: true)
                    .help("New session (⌘N)")
                }
            }
    }

    /// What the section is doing, in a few words, under its name.
    private var subtitle: String {
        switch shell.section {
        case .sessions:
            let stale = core.config.config.staleAfterSeconds
            let all = core.stateStore.visible
            let waiting = all.filter { $0.attention(staleAfter: stale) == .needsYou }.count
            if all.isEmpty { return core.stateStore.all.isEmpty ? "Nothing supervised yet" : "Everything hidden" }
            return waiting > 0 ? "\(waiting) waiting on you" : "\(all.count) supervised"
        case .machines: return "This Mac and every box running udha-agent"
        case .meetings: return core.meetings.live != nil ? "Recording now" : "\(core.meetings.store.meetings.count) recorded"
        case .agents:   return "\(core.agents.agents.count) reusable prompts"
        case .inbox:    return core.slack.inbox.unreadCount > 0 ? "\(core.slack.inbox.unreadCount) unread" : "\(core.slack.inbox.threads.count) threads"
        case .videos:   return "\(core.recordings.store.recordings.count) recordings"
        }
    }

    /// "Stop meeting" as a red pill with a pulsing dot, a waveform and the
    /// elapsed clock while recording; a quiet "Record meeting" otherwise. Says
    /// "meeting" in both states so it never reads as belonging to whatever
    /// the window happens to be showing.
    @ViewBuilder
    private var meetingButton: some View {
        if let live = core.meetings.live {
            Button {
                Task { await core.meetings.stop() }
                shell.showingLive = false
                shell.say("Meeting ended · writing it up")
            } label: {
                HStack(spacing: 6) {
                    Pulsing(active: live.recorder.state != .paused) {
                        Circle().fill(UdhaTheme.bad).frame(width: 8, height: 8)
                    }
                    Text("Stop meeting")
                    WaveBars(color: UdhaTheme.bad, active: live.recorder.state != .paused)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(UdhaFormat.clock(live.recorder.activeDuration))
                            .font(UdhaTheme.mono(11))
                            .opacity(0.75)
                    }
                }
            }
            .udhaButton(.danger, height: 26, hPadding: 11)
            .help("Stop recording and write the meeting up (⌘⇧R)")
        } else {
            Button {
                Task { await core.meetings.start(mode: .standard) }
                shell.openLive()
                shell.say("Recording · mic + system audio")
            } label: {
                UdhaLabel(title: "Record meeting", icon: "record.circle")
            }
            .udhaButton(.ghost, height: 26, hPadding: 10)
            .help("Record mic + system audio (⌘⇧R)")
        }
    }
}

// MARK: - Status bar

/// 28pt: a live dot, the last thing Udha did (in the accent), then counts,
/// the overlay's whereabouts, a hint, and a clock.
struct UdhaStatusBar: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    private var counts: (waiting: Int, working: Int, quiet: Int) {
        let stale = core.config.config.staleAfterSeconds
        var w = 0, k = 0, q = 0
        for snap in core.stateStore.visible {
            switch snap.attention(staleAfter: stale) {
            case .needsYou: w += 1
            case .working:  k += 1
            case .quiet:    q += 1
            }
        }
        return (w, k, q)
    }

    private var overlayNote: String {
        guard core.config.config.overlay.enabled else { return "Overlay hidden" }
        guard let id = core.config.config.overlay.displayID else { return "Overlay follows the active display" }
        let name = NSScreen.screens.first { $0.udhaDisplayID == id }?.localizedName
        return name.map { "Overlay pinned to \($0)" } ?? "Overlay pinned to a display that's unplugged"
    }

    var body: some View {
        let c = counts
        HStack(spacing: 18) {
            Pulsing(period: 2.2) {
                Circle().fill(UdhaTheme.good).frame(width: 6, height: 6)
            }
            Text(shell.status)
                .font(UdhaTheme.text(11, .medium))
                .foregroundStyle(shell.statusIsAction ? UdhaTheme.accent : UdhaTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(c.waiting) waiting · \(c.working) working · \(c.quiet) quiet")
                .font(UdhaTheme.text(11, .regular))
                .monospacedDigit()
            Text(overlayNote)
                .font(UdhaTheme.text(11, .regular))
                .lineLimit(1)
            Text(shell.section == .sessions
                 ? "Drag a card onto a machine to hand it off"
                 : "⌘K for anything")
                .font(UdhaTheme.text(11, .regular))
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Mono(UdhaFormat.wallClock(ctx.date), size: 11, color: UdhaTheme.tertiary)
            }
        }
        .foregroundStyle(UdhaTheme.secondary)
        .padding(.horizontal, 14)
        .frame(height: UdhaTheme.statusBarHeight)
        .udhaChrome(.headerView, tint: UdhaTheme.chrome)
    }
}

extension Notification.Name {
    /// Posted by the menu bar to jump the main window to the Meetings section.
    static let udhaRequestMeetings = Notification.Name("udhaRequestMeetings")
    /// Posted with a session UUID to select it in the main window.
    static let udhaFocusSession = Notification.Name("udhaFocusSession")
    /// Posted with an `UdhaSection` to switch the main window to it.
    static let udhaOpenSection = Notification.Name("udhaOpenSection")
}
