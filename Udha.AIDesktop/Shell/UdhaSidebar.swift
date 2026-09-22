import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The left of the window: a 194pt nav sidebar over vibrancy — six sections
/// with icons and badges, the palette button, Lock and Settings — and beside
/// it the 320pt list column for whichever section is active: the sessions
/// board, or a list of meetings / agents / threads / videos / machines.
struct UdhaSidebar: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    /// Filters the meetings list. Same shape as the sessions board's search —
    /// always shown, matches everything a row shows plus the people on the call.
    @State private var meetingQuery = ""
    @State private var listQuery = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let hidden = core.config.config.hideSessionList
        return HStack(spacing: 0) {
            navRail
            VRule()
            if !hidden {
                listColumn
                VRule()
            }
        }
        // The rail stays: sections still have to be reachable, and its badges
        // are counts rather than names, so nothing on it identifies a client.
        .frame(width: hidden ? UdhaTheme.navWidth + 0.5 : UdhaTheme.sidebarWidth + 1)
        .animation(UdhaTheme.quick, value: hidden)
    }

    // MARK: - Nav rail

    /// Six sections, each with an icon and what it is doing. The active one is
    /// the accent; the rest slide right a touch on hover.
    private var navRail: some View {
        VStack(spacing: 2) {
            navRow(.sessions, badge: sessionsBadge)
            navRow(.machines, badge: machinesBadge)
            navRow(.meetings, badge: core.meetings.live != nil ? "REC" : nil)
            navRow(.agents, badge: core.agents.agents.isEmpty ? nil : "\(core.agents.agents.count)")
            navRow(.inbox, badge: core.slack.inbox.unreadCount > 0 ? "\(core.slack.inbox.unreadCount)" : nil)
            navRow(.videos, badge: videosBadge)

            Spacer(minLength: 0)

            paletteButton
                .padding(.bottom, 4)

            footerRow("Lock the room", icon: "lock") {
                guard core.config.config.inputLock.enabled else {
                    shell.openSettings(section: "lock")
                    shell.say("Turn the input lock on first")
                    return
                }
                core.inputLock.lock(source: .hotkey)
                shell.say("Room locked — Touch ID to unlock")
            }
            footerRow("Settings", icon: "gearshape", keys: "⌘,") {
                shell.openSettings()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: UdhaTheme.navWidth)
        .udhaChrome(.sidebar, tint: UdhaTheme.sidebar)
    }

    /// Waiting-on-you count when there is one — the nav should say the thing
    /// you'd open the section for — otherwise the plain roster size.
    private var sessionsBadge: String {
        let stale = core.config.config.staleAfterSeconds
        let waiting = core.stateStore.visible.filter { $0.attention(staleAfter: stale) == .needsYou }.count
        return waiting > 0 ? "\(waiting)" : "\(core.stateStore.visible.count)"
    }

    /// "REC" while capturing, then the render progress, then a plain count —
    /// the nav should say what the section is doing without being opened.
    private var videosBadge: String? {
        if core.recordings.isRecording { return "REC" }
        if !core.recordings.processingIDs.isEmpty { return "…" }
        let count = core.recordings.store.recordings.count
        return count > 0 ? "\(count)" : nil
    }

    /// Machines online out of machines known — "2/3" the moment one is off, so
    /// the nav itself is where you notice a box has dropped.
    private var machinesBadge: String? {
        let known = core.knownHostNames
        guard !known.isEmpty else { return "1" }
        let online = 1 + known.filter { core.remoteHostClient.onlineHosts.contains($0) }.count
        let total = 1 + known.count
        return online == total ? "\(total)" : "\(online)/\(total)"
    }

    private func navRow(_ section: UdhaSection, badge: String?) -> some View {
        let active = shell.section == section
        let hidden = core.config.config.hideSessionList
        let isRec = badge == "REC"
        // Clicking the section you are already on puts its list away, and
        // clicking again brings it back — the control that names the list is
        // the one that hides it, and it costs no new chrome.
        return NavRowButton(active: active) {
            if active {
                core.config.mutate { $0.hideSessionList = !hidden }
            } else {
                // Switching sections always shows the list: arriving somewhere
                // new with an empty column reads as a broken section.
                if hidden { core.config.mutate { $0.hideSessionList = false } }
                shell.go(section)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(active ? UdhaTheme.onAccent : UdhaTheme.accent)
                Text(section.title)
                    .font(UdhaTheme.text(13, .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isRec {
                    Pulsing(period: 1.4) {
                        Circle().fill(UdhaTheme.bad).frame(width: 6, height: 6)
                    }
                }
                if let badge {
                    Text(badge)
                        .font(UdhaTheme.text(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(active ? UdhaTheme.onAccent : UdhaTheme.secondary)
                }
            }
            .foregroundStyle(active ? UdhaTheme.onAccent : UdhaTheme.label)
        }
    }

    /// The accent-tinted "What can Udha do?" with a sheen passing over it.
    private var paletteButton: some View {
        Button { shell.openPalette() } label: {
            HStack(spacing: 8) {
                Text("⌘").font(UdhaTheme.text(12, .semibold))
                Text("What can Udha do?")
                    .font(UdhaTheme.text(12.5, .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .foregroundStyle(UdhaTheme.accentInk)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UdhaTheme.accentTint))
            .overlay(Sheen().udhaRounded(7))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverSlide(dx: 0, dy: -1)
        .help("Command palette (⌘K)")
    }

    private func footerRow(_ title: String, icon: String, keys: String? = nil,
                           _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                Text(title).font(UdhaTheme.text(12.5, .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let keys { Mono(keys, size: 11, color: UdhaTheme.tertiary) }
            }
            .foregroundStyle(UdhaTheme.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverBackground(base: .clear, hover: UdhaTheme.fill, radius: 7)
    }

    // MARK: - List column

    /// Sessions get the board — machines as groups, cards you can drag between
    /// them. Every other section is a header, a search field, its actions, and
    /// a list of rounded rows.
    @ViewBuilder
    private var listColumn: some View {
        if shell.section == .sessions {
            SessionsBoard(core: core, shell: shell)
        } else {
            VStack(spacing: 0) {
                listHeader
                HRule()

                VStack(spacing: 8) {
                    UdhaSearchField(placeholder: searchPlaceholder, text: queryBinding, focus: $searchFocused)
                    listActions
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        switch shell.section {
                        case .meetings: meetingsList
                        case .agents:   agentsList
                        case .inbox:    inboxList
                        case .videos:   videosList
                        case .machines: machinesList
                        case .sessions: EmptyView()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: .infinity)

                if shell.section == .videos, !shell.joinSelection.isEmpty {
                    joinBar
                }
            }
            .frame(width: UdhaTheme.boardWidth)
            .udhaChrome(.sidebar, tint: UdhaTheme.list)
            // Each section keeps its own filter; the field clears on switch so
            // a filter typed for meetings never hides every agent.
            .onChange(of: shell.section) { _, _ in listQuery = "" }
        }
    }

    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(shell.section.title)
                .font(UdhaTheme.text(15, .bold))
                .tracking(-0.15)
                .foregroundStyle(UdhaTheme.label)
            Text(sectionHint)
                .font(UdhaTheme.text(11.5, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var sectionHint: String {
        switch shell.section {
        case .sessions: return ""
        case .meetings:
            if core.meetings.live != nil { return "Recording now" }
            return "\(core.meetings.store.meetings.count) recorded"
        case .agents:   return "\(core.agents.agents.count) reusable prompts"
        case .inbox:    return core.slack.inbox.unreadCount > 0
            ? "\(core.slack.inbox.unreadCount) unread"
            : "\(core.slack.inbox.threads.count) threads"
        case .videos:   return "\(core.recordings.store.recordings.count) recordings"
        case .machines: return "This Mac and every box running udha-agent"
        }
    }

    private var searchPlaceholder: String {
        switch shell.section {
        case .sessions: return "Filter sessions…"
        case .machines: return "Filter machines…"
        case .meetings: return "Filter meetings…"
        case .agents:   return "Filter agents…"
        case .inbox:    return "Filter threads…"
        case .videos:   return "Filter recordings…"
        }
    }

    /// Meetings keep their own richer filter (people, org, action items); the
    /// rest share one plain substring filter.
    private var queryBinding: Binding<String> {
        shell.section == .meetings ? $meetingQuery : $listQuery
    }

    private var q: String { listQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func matches(_ fields: [String?]) -> Bool {
        guard !q.isEmpty else { return true }
        return fields.contains { $0?.lowercased().contains(q) == true }
    }

    /// The one or two actions a section offers above its list.
    @ViewBuilder
    private var listActions: some View {
        switch shell.section {
        case .meetings:
            VStack(spacing: 6) {
                listActionButton("Record meeting", icon: "record.circle", kind: .primary,
                                 disabled: core.meetings.live != nil) {
                    Task { await core.meetings.start(mode: .standard) }
                    shell.openLive()
                    shell.liveTab = .transcript
                    shell.say("Recording · mic + system audio")
                }
                listActionButton("Record + map process", icon: "arrow.triangle.branch", kind: .ghost,
                                 disabled: core.meetings.live != nil) {
                    Task { await core.meetings.start(mode: .processMapping) }
                    shell.openLive()
                    shell.liveTab = .diagram
                    shell.say("Recording + mapping process")
                }
            }
        case .agents:
            listActionButton("New agent", icon: "plus", kind: .ghost) {
                let agent = core.agents.create(name: "New agent")
                shell.selectedAgentSlug = agent.slug
                shell.agentEditorSlug = agent.slug
            }
        case .videos:
            listActionButton("Record screen", icon: "record.circle", kind: .primary,
                             disabled: core.recordings.isRecording) {
                shell.recordTargetOpen = true
            }
        case .inbox, .machines, .sessions:
            EmptyView()
        }
    }

    private func listActionButton(_ title: String, icon: String, kind: UdhaButtonKind,
                                  disabled: Bool = false, _ run: @escaping () -> Void) -> some View {
        UdhaListAction(title: title, icon: icon, kind: kind, disabled: disabled, action: run)
    }

    // MARK: - Machines list

    /// Online first, then anything the account has paired with that is not
    /// answering. A machine that has dropped is the whole reason to open this
    /// section, so it keeps its row rather than vanishing from the list.
    @ViewBuilder
    private var machinesList: some View {
        let all = MachineDirectory.summaries(core: core)
            .filter { matches([$0.name, $0.platform, $0.stateLabel, $0.host]) }
        let online = all.filter(\.online)
        let offline = all.filter { !$0.online }

        ForEach([("Online", online), ("Offline", offline)], id: \.0) { title, group in
            if !group.isEmpty {
                if !offline.isEmpty {
                    HStack(spacing: 8) {
                        Eyebrow(title, color: title == "Offline" ? UdhaTheme.badInk : UdhaTheme.secondary)
                        Mono("\(group.count)", size: 10.5)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                }
                ForEach(group) { machine in machineRow(machine) }
            }
        }

        Text("Pairing is per instance ID — every machine here is one the iPad app can reach too.")
            .font(UdhaTheme.text(11, .regular))
            .foregroundStyle(UdhaTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 12)
    }

    private func machineRow(_ machine: MachineSummary) -> some View {
        let selected = shell.selectedMachine == machine.host && shell.machinePicked
        return SidebarRow(
            selected: selected,
            accent: !machine.online,
            mark: AnyView(StateMark(color: machine.online ? UdhaTheme.good : UdhaTheme.bad,
                                    size: 8, filled: machine.connected || machine.host == nil,
                                    pulses: false)),
            onTap: { shell.select(machine: machine.host) }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(machine.name)
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Mono(machine.latency, size: 10.5, color: UdhaTheme.tertiary)
                }
                Text(machine.stateLabel)
                    .font(UdhaTheme.text(11, .medium))
                    .foregroundStyle(machine.online ? UdhaTheme.secondary : UdhaTheme.bad)
                    .lineLimit(1)
                Text("\(machine.platform) · \(machine.sessionsSummary)")
                    .font(UdhaTheme.text(10.5, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.name), \(machine.stateLabel)")
        .contextMenu {
            if let host = machine.host {
                if machine.connected {
                    Button("Disconnect") { core.selectHost(nil) }
                } else {
                    Button("Connect") { core.selectHost(host) }
                }
                Button("Open SSH terminal") { MachineActions.openTerminal(host: host) }
                Divider()
                Button("Copy ssh command") { MachineActions.copy("ssh \(host)") }
            } else {
                Button("Open Terminal") { MachineActions.openTerminal(host: nil) }
            }
            Button("Refresh now") { core.machines.refresh() }
        }
    }

    // MARK: - Videos list

    @ViewBuilder
    private var videosList: some View {
        if let live = core.recordings.live {
            liveRecordingRow(live)
        }

        let rows = core.recordings.store.recordings.filter { matches([$0.title]) }
        ForEach(rows) { recording in
            recordingRow(recording)
        }
        if rows.isEmpty, !q.isEmpty { noMatch }
    }

    private var noMatch: some View {
        Text("Nothing matches “\(listQuery)”")
            .font(UdhaTheme.text(11.5, .regular))
            .foregroundStyle(UdhaTheme.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveRecordingRow(_ live: LiveRecording) -> some View {
        let paused = live.engine.state == .paused
        return SidebarRow(
            selected: shell.selectedRecordingID == live.recording.id,
            accent: true,
            mark: AnyView(StateMark(color: UdhaTheme.bad, size: 8, filled: true, pulses: !paused)),
            onTap: { shell.selectedRecordingID = live.recording.id }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    UdhaTag(paused ? "Paused" : "Rec", fg: UdhaTheme.badInk, bg: UdhaTheme.badTint)
                    Text(live.recording.title)
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // Same reason as the Videos pane: the duration is computed
                    // from `Date()`, so only a timeline advances it.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Mono(UdhaFormat.clock(live.engine.activeDuration), size: 10.5, color: UdhaTheme.badInk)
                    }
                }
                Text(liveCaptureSummary(live))
                    .font(UdhaTheme.text(11, .medium))
                    .foregroundStyle(UdhaTheme.badInk)
                    .lineLimit(1)
            }
        }
    }

    /// Says what is actually being captured right now, so a degraded stream is
    /// visible while there is still time to do something about it.
    private func liveCaptureSummary(_ live: LiveRecording) -> String {
        var parts = live.recording.isCameraOnly ? [] : ["Screen"]
        if !live.engine.cameraUnavailable { parts.append("camera") }
        if !live.engine.micUnavailable { parts.append("mic") }
        if !live.engine.systemAudioUnavailable { parts.append("system audio") }
        return parts.joined(separator: " + ")
    }

    private func recordingRow(_ recording: Recording) -> some View {
        let selected = shell.selectedRecordingID == recording.id
        let processing = core.recordings.processingIDs.contains(recording.id)
        // The tick replaces the state mark rather than crowding in beside it:
        // a row only offers one when it is finished, and a finished row's
        // status line already says what state it is in.
        let joinable = canJoin(recording)
        return SidebarRow(
            selected: selected,
            accent: recording.stage == .failed,
            mark: joinable ? nil : AnyView(StateMark(
                color: recordingMarkColor(recording, processing: processing),
                size: 8,
                filled: recording.stage == .ready,
                pulses: processing
            )),
            onTap: { shell.selectedRecordingID = recording.id }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if recording.isJoined {
                        UdhaTag("Joined", fg: UdhaTheme.accentInk, bg: UdhaTheme.accentTint)
                    }
                    Text(recording.title)
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Mono(UdhaFormat.clock(recording.durationSeconds), size: 10.5, color: UdhaTheme.tertiary)
                }
                Text(recordingStatusLine(recording, processing: processing))
                    .font(UdhaTheme.text(11, .medium))
                    .foregroundStyle(recording.stage == .failed ? UdhaTheme.badInk
                                     : (recording.stage == .ready ? UdhaTheme.secondary : UdhaTheme.warnInk))
                    .lineLimit(1)
                Text(UdhaFormat.shortWhen(recording.createdAt))
                    .font(UdhaTheme.text(10.5, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            .padding(.leading, joinable ? 22 : 0)
        }
        // An overlay, not the row's `mark` slot: the mark is inside the row's
        // own Button label, and a control nested in another button's label does
        // not reliably get the click. An overlay is a sibling above it in z,
        // which does.
        .overlay(alignment: .topLeading) {
            if joinable {
                UdhaCheckbox(
                    isOn: Binding(
                        get: { shell.joinSelection.contains(recording.id) },
                        set: { _ in shell.toggleJoin(recording.id) }
                    ),
                    size: 15
                )
                .padding(.leading, 9)
                .padding(.top, 10)
            }
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([core.recordings.store.folderURL(for: recording)])
            }
            if recording.stage != .capturing {
                Button(recording.isJoined ? "Re-join" : "Re-render") {
                    Task { await core.recordings.retryProcessing(recording) }
                    shell.say(recording.isJoined ? "Re-joining \(recording.title)" : "Re-rendering \(recording.title)")
                }
            }
            if recording.isJoined {
                Button("Undo join") {
                    core.recordings.undoJoin(recording)
                    if shell.selectedRecordingID == recording.id { shell.selectedRecordingID = nil }
                    shell.say("Join undone · the originals were never touched")
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                core.recordings.delete(recording)
                if shell.selectedRecordingID == recording.id { shell.selectedRecordingID = nil }
                shell.joinSelection.remove(recording.id)
                shell.say("Deleted \(recording.title)")
            }
        }
    }

    /// You can only concatenate a master that exists, and not one that is being
    /// written right now.
    private func canJoin(_ recording: Recording) -> Bool {
        recording.stage == .ready
            && !recording.renderedOrientations.isEmpty
            && !core.recordings.processingIDs.contains(recording.id)
    }

    /// The ticked videos in the order they will play — oldest first, because a
    /// join reads as a sequence while the list reads newest first.
    private var joinCandidates: [Recording] {
        core.recordings.store.recordings
            .filter { shell.joinSelection.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// What ticking videos puts at the foot of the list: what is selected, a
    /// way out, and the one action.
    private var joinBar: some View {
        let picked = joinCandidates
        let ready = picked.count >= 2
        return HStack(spacing: 10) {
            Text("\(picked.count) selected")
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.label)
            Spacer(minLength: 4)
            Button("Clear") { shell.clearJoinSelection() }
                .udhaButton(.bare, height: 26, hPadding: 8)
            Button { openJoinSheet() } label: {
                HStack(spacing: 6) {
                    Text("Join")
                    Mono("⌘J", size: 10.5, color: UdhaTheme.onAccentDim)
                }
            }
            .udhaButton(.primary, height: 26, hPadding: 11)
            .disabled(!ready)
            .help(ready ? "Join these into one video" : "Tick a second video to join")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(UdhaTheme.accentTint)
        .overlay(alignment: .top) { HRule() }
    }

    private func openJoinSheet() {
        let picked = joinCandidates
        guard picked.count >= 2 else { return }
        shell.openJoinSheet(
            order: picked.map(\.id),
            name: RecordingCenter.defaultJoinTitle(for: picked)
        )
    }

    private func recordingMarkColor(_ recording: Recording, processing: Bool) -> Color {
        if processing { return UdhaTheme.accent }
        switch recording.stage {
        case .ready:      return UdhaTheme.good
        case .failed:     return UdhaTheme.bad
        case .capturing:  return UdhaTheme.bad
        default:          return UdhaTheme.warn
        }
    }

    private func recordingStatusLine(_ recording: Recording, processing: Bool) -> String {
        let verb = recording.isJoined ? "Joining" : "Rendering"
        if processing {
            if let fraction = core.recordings.renderProgress[recording.id] {
                return "\(verb) · \(Int(fraction * 100))%"
            }
            return recording.isJoined ? "Joining…" : "Processing…"
        }
        switch recording.stage {
        case .capturing:       return "Interrupted mid-recording"
        case .needsProcessing: return "Needs processing"
        case .transcribing:    return "Transcribing…"
        case .composing:       return "\(verb)…"
        case .failed:          return recording.failureReason ?? "Failed"
        case .ready:
            let masters = recording.renderedOrientations.count
            let base = masters == 2
                ? "Wide + vertical"
                : (recording.renderedOrientations.first?.rawValue.capitalized ?? "Ready")
            if recording.isJoined { return "\(base) · joined from \(recording.joinedFromIDs.count)" }
            if core.recordings.store.isJoinSource(recording) { return "\(base) · joined" }
            return base
        }
    }

    // MARK: - Meetings

    /// The recorded meetings with the filter applied — the live one is never
    /// filtered, it sits above the list regardless.
    private var filteredMeetings: [Meeting] {
        let q = meetingQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return core.meetings.store.meetings }
        return core.meetings.store.meetings.filter { meetingMatches($0, query: q) }
    }

    /// Matches title, summary, the people and org on the calendar event, and
    /// the action-item text — everything a row shows plus what the call was
    /// about, so "invoice" or a colleague's name both find the right call.
    private func meetingMatches(_ m: Meeting, query q: String) -> Bool {
        if m.title.lowercased().contains(q) { return true }
        if m.summary.lowercased().contains(q) { return true }
        if m.actionItems.contains(where: { $0.text.lowercased().contains(q)
            || ($0.owner?.lowercased().contains(q) ?? false) }) { return true }
        if let cal = m.calendarEvent {
            let calFields: [String?] = [cal.title, cal.org, cal.organizer, cal.location, cal.account]
            if calFields.contains(where: { $0?.lowercased().contains(q) == true }) { return true }
            if cal.attendees.contains(where: { $0.lowercased().contains(q) }) { return true }
        }
        return false
    }

    @ViewBuilder
    private var meetingsList: some View {
        if let live = core.meetings.live {
            liveRow(live)
        }

        let rows = filteredMeetings
        ForEach(rows) { meeting in
            meetingRow(meeting)
        }
        if rows.isEmpty, !meetingQuery.isEmpty {
            Text("No meeting matches “\(meetingQuery)”")
                .font(UdhaTheme.text(11.5, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func liveRow(_ live: LiveMeeting) -> some View {
        let paused = live.recorder.state == .paused
        return Button { shell.openLive() } label: {
            HStack(alignment: .top, spacing: 9) {
                StateMark(color: paused ? UdhaTheme.warn : UdhaTheme.bad, size: 8, filled: true, pulses: !paused)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        UdhaTag(paused ? "Paused" : "Rec", fg: UdhaTheme.badInk, bg: UdhaTheme.badTint)
                        Text(live.meeting.title)
                            .font(UdhaTheme.text(12.5, .semibold))
                            .foregroundStyle(UdhaTheme.label)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Mono(UdhaFormat.clock(live.recorder.activeDuration), size: 10.5, color: UdhaTheme.badInk)
                        }
                    }
                    Text((paused ? "Paused · " : "Recording · ")
                         + (live.recorder.systemAudioUnavailable ? "Me only" : "Me + Them")
                         + (live.meeting.calendarEvent.map { " · \($0.org)" } ?? ""))
                        .font(UdhaTheme.text(11, .medium))
                        .foregroundStyle(UdhaTheme.badInk)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous).fill(UdhaTheme.badTint))
            .overlay(RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous)
                        .strokeBorder(shell.showingLive ? UdhaTheme.bad : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func meetingRow(_ meeting: Meeting) -> some View {
        let selected = !shell.showingLive && shell.selectedMeetingID == meeting.id
        let tag: (String, Color, Color)? = {
            if meeting.endedAt != nil && !meeting.finalized {
                return ("Needs summary", UdhaTheme.warnInk, UdhaTheme.warnTint)
            }
            if core.meetings.isFinalizing(meeting) { return ("Writing…", UdhaTheme.accentInk, UdhaTheme.accentTint) }
            if core.meetings.store.hasProcessModel(meeting) { return ("Mapped", UdhaTheme.accentInk, UdhaTheme.accentTint) }
            return nil
        }()
        var state: [String] = []
        if let d = meeting.durationSeconds { state.append(UdhaFormat.elapsed(d)) }
        if let cal = meeting.calendarEvent { state.append(cal.org) }
        return SidebarRow(
            selected: selected,
            onTap: {
                shell.showingLive = false
                shell.selectedMeetingID = meeting.id
                shell.meetingTab = .notes
            }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let tag { UdhaTag(tag.0, fg: tag.1, bg: tag.2) }
                    Text(meeting.title)
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Mono(UdhaFormat.shortWhen(meeting.createdAt), size: 10.5, color: UdhaTheme.tertiary)
                }
                if !state.isEmpty {
                    Text(state.joined(separator: " · "))
                        .font(UdhaTheme.text(11, .medium))
                        .foregroundStyle(UdhaTheme.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meeting.title)
        .contextMenu {
            Button("Export notes…") { MeetingExporter.exportNotes(meeting: meeting, store: core.meetings.store) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([core.meetings.store.folderURL(for: meeting)])
            }
            Divider()
            Button("Delete", role: .destructive) { core.meetings.store.delete(meeting) }
        }
    }

    // MARK: - Agents list

    @ViewBuilder
    private var agentsList: some View {
        let rows = core.agents.agents.filter { matches([$0.name, $0.description]) }
        ForEach(rows) { agent in
            SidebarRow(
                selected: shell.selectedAgentSlug == agent.slug,
                onTap: { shell.selectedAgentSlug = agent.slug }
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if agent.isBuiltIn {
                            UdhaTag("Built in")
                        }
                        Text(agent.name)
                            .font(UdhaTheme.text(12.5, .semibold))
                            .foregroundStyle(UdhaTheme.label)
                            .lineLimit(1)
                    }
                    Text(agent.description.isEmpty ? "No description" : agent.description)
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(agent.name)
            .contextMenu {
                Button("Edit prompt") { shell.agentEditorSlug = agent.slug }
                Button("Delete", role: .destructive) { core.agents.delete(agent) }
            }
        }
        if rows.isEmpty, !q.isEmpty { noMatch }
    }

    // MARK: - Inbox list

    @ViewBuilder
    private var inboxList: some View {
        if core.config.config.slack.workspaces.isEmpty {
            emptyInbox
        } else if core.slack.inbox.threads.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing yet")
                    .font(UdhaTheme.text(13, .semibold))
                    .foregroundStyle(UdhaTheme.label)
                Text("DMs and mentions land here as they arrive. Udha only sees messages sent while it's running.")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
            }
            .padding(9)
        } else {
            let rows = core.slack.inbox.threads.filter { matches([$0.label, $0.preview, $0.where_]) }
            ForEach(rows) { thread in
                threadRow(thread)
            }
            if rows.isEmpty, !q.isEmpty { noMatch }
        }
    }

    private var emptyInbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No Slack workspace")
                .font(UdhaTheme.text(13, .semibold))
                .foregroundStyle(UdhaTheme.label)
            Text("Connect one and DMs and mentions show up here, answerable without leaving the app.")
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.secondary)
            Button("Connect a workspace") { shell.openSettings(section: "slack") }
                .udhaButton(.ghost, height: 28, hPadding: 10)
        }
        .padding(9)
    }

    private func threadRow(_ thread: SlackThread) -> some View {
        SidebarRow(
            selected: shell.selectedThreadID == thread.id,
            mark: AnyView(
                Circle()
                    .fill(thread.unread ? UdhaTheme.accent : Color.clear)
                    .frame(width: 8, height: 8)
                    .background(Circle().fill(thread.unread ? UdhaTheme.accentTint : .clear).padding(-3))
            ),
            onTap: {
                shell.selectedThreadID = thread.id
                core.slack.inbox.markRead(thread.id)
            }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(thread.label)
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Mono(UdhaFormat.shortWhen(thread.lastActivity), size: 10.5, color: UdhaTheme.tertiary)
                }
                Text(thread.preview)
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .lineLimit(1)
                Text(thread.where_)
                    .font(UdhaTheme.text(10.5, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(thread.label)\(thread.unread ? ", unread" : "")")
    }
}

// MARK: - Nav row button

/// A nav row: accent fill when active, slides 4pt right on hover, presses in
/// a touch. Its own type so the hover state has a view to live in.
private struct NavRowButton<Label: View>: View {
    let active: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 9)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? UdhaTheme.accent : (hovering ? UdhaTheme.fill : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(NavPressStyle())
        .offset(x: hovering && UdhaTheme.motion ? 4 : 0)
        .onHover { hovering = $0 }
        .animation(UdhaTheme.lift, value: hovering)
        .animation(UdhaTheme.quick, value: active)
    }
}

private struct NavPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(UdhaTheme.quick, value: configuration.isPressed)
    }
}

/// A bright diagonal band that sweeps across every few seconds.
private struct Sheen: View {
    @State private var x: CGFloat = -1.4

    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, UdhaTheme.accent.opacity(0.26), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 34)
                .rotationEffect(.degrees(10))
                .offset(x: x * geo.size.width)
                .animation(.easeInOut(duration: 4.5).repeatForever(autoreverses: false), value: x)
                .onAppear { x = 1.2 }
        }
        .allowsHitTesting(false)
    }
}

extension UdhaSection {
    /// The SF Symbol the nav draws for the section.
    var symbol: String {
        switch self {
        case .sessions: return "terminal"
        case .machines: return "server.rack"
        case .meetings: return "video"
        case .agents:   return "cpu"
        case .inbox:    return "tray"
        case .videos:   return "film"
        }
    }
}
