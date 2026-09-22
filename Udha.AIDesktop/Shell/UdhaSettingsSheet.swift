import SwiftUI
import AppKit
import AVFoundation
import LocalAuthentication

/// Section identity for the Settings modal. Kept separate from the rows so the
/// palette can name the section count without building every control.
enum UdhaSettingsCatalog {
    struct SectionRef: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let sections: [SectionRef] = [
        .init(id: "overview", name: "Overview"),
        .init(id: "appearance", name: "Appearance"),
        .init(id: "sessions", name: "Sessions"),
        .init(id: "logins",   name: "Claude logins"),
        .init(id: "overlay",  name: "Edge overlay"),
        .init(id: "meetings", name: "Meetings"),
        .init(id: "slack",    name: "Slack"),
        .init(id: "lock",     name: "Focus & lock"),
        .init(id: "keys",     name: "Keys & devices"),
        .init(id: "mobile",   name: "iPhone"),
        .init(id: "advanced", name: "Advanced"),
    ]

    static func name(for id: String) -> String {
        sections.first { $0.id == id }?.name ?? "Settings"
    }
}

/// One line in the settings list. `head` and `note` are structural; `row` is a
/// label/help pair on the left and whatever control the setting needs on the right.
struct UdhaSettingRow: Identifiable {
    enum Kind { case head, note, row }

    let id: String
    var kind: Kind = .row
    var title: String = ""
    var help: String? = nil
    /// Section this row came from — rendered as a red eyebrow when the list is
    /// showing search results from across every section.
    var origin: String = ""
    var control: AnyView? = nil

    var searchText: String { "\(title) \(help ?? "")".lowercased() }

    static func head(_ title: String) -> UdhaSettingRow {
        .init(id: "head-" + title, kind: .head, title: title)
    }
    static func note(_ text: String) -> UdhaSettingRow {
        .init(id: "note-" + String(text.prefix(24)), kind: .note, title: text)
    }
}

/// The Settings modal: a fixed 1000×640 panel with a section rail on the left
/// and one searchable list on the right.
///
/// Search is deliberately global — typing "mic" surfaces the microphone rows
/// from Meetings and Keys together, each stamped with the section it
/// came from. Ten tabs is too many to remember which one holds what.
struct UdhaSettingsSheet: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    @State private var elevenLabsKey = ""
    @State private var anthropicKey = ""
    @State private var inputDevices: [AudioDevice] = []
    @State private var outputDevices: [AudioDevice] = []
    @State private var screenRevision = 0
    @State private var slackToken = ""
    @State private var message = ""
    /// Walking the meetings directory is O(files); do it once when the sheet
    /// opens rather than on every body evaluation.
    @State private var meetingsSize = "—"
    @State private var shown = false

    private var config: ConfigStore { core.config }

    var body: some View {
        ZStack {
            UdhaTheme.scrim.ignoresSafeArea()
                .onTapGesture { shell.settingsOpen = false }

            VStack(spacing: 0) {
                header
                HRule()
                HStack(spacing: 0) {
                    rail
                    VRule()
                    list
                }
            }
            .frame(width: 1000, height: 640)
            .background(
                ZStack {
                    VisualEffectBackground(material: .popover, blending: .withinWindow)
                    UdhaTheme.canvas.opacity(0.92)
                }
            )
            .udhaRounded(14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(UdhaTheme.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.36), radius: 40, y: 22)
            .scaleEffect(shown ? 1 : 0.97)
            .opacity(shown ? 1 : 0)
            .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.26), value: shown)
        }
        .onExitCommand { shell.settingsOpen = false }
        .onAppear {
            loadSecrets()
            refreshDevices()
            meetingsSize = Self.folderSize(of: core.meetings.store.meetingsDirectory)
            shown = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in screenRevision &+= 1 }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 14) {
            Text("Settings")
                .font(UdhaTheme.text(15, .bold))
                .tracking(-0.15)
                .foregroundStyle(UdhaTheme.label)

            UdhaSearchField(placeholder: "Search every setting…", text: $shell.settingsQuery)
                .frame(maxWidth: 420)

            Text(searchHint)
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.tertiary)

            Spacer()

            if !message.isEmpty {
                Text(message)
                    .font(UdhaTheme.text(11.5, .medium))
                    .foregroundStyle(UdhaTheme.accentInk)
            }

            Button("Done") { shell.settingsOpen = false }
                .udhaButton(.primary, height: 28, hPadding: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchHint: String {
        guard !query.isEmpty else { return "Searching finds settings in every section" }
        return "\(rows.filter { $0.kind == .row }.count) of \(allRowCount) settings"
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(UdhaSettingsCatalog.sections) { section in
                    let active = section.id == shell.settingsSection && query.isEmpty
                    Button {
                        shell.settingsSection = section.id
                        shell.settingsQuery = ""
                    } label: {
                        Text(section.name)
                            .font(UdhaTheme.text(13, .medium))
                            .foregroundStyle(active ? UdhaTheme.onAccent : UdhaTheme.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(active ? UdhaTheme.accent : .clear))
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .hoverBackground(base: .clear, hover: active ? .clear : UdhaTheme.fill, radius: 7)
                }
            }
            .padding(10)
        }
        .frame(width: 212)
        .background(UdhaTheme.sidebar)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(query.isEmpty ? UdhaSettingsCatalog.name(for: shell.settingsSection) : "Search results")
                    .font(UdhaTheme.text(20, .bold))
                    .tracking(-0.3)
                    .foregroundStyle(UdhaTheme.label)
                    .padding(.bottom, 10)

                let visible = rows
                if visible.isEmpty {
                    Text("No setting matches that. Try “overlay”, “mic”, “key”, “lock”.")
                        .font(UdhaTheme.text(14, .regular))
                        .foregroundStyle(UdhaTheme.muted)
                        .padding(.vertical, 20)
                } else {
                    ForEach(visible) { row in
                        rowView(row)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: UdhaSettingRow) -> some View {
        switch row.kind {
        case .head:
            Text(row.title)
                .font(UdhaTheme.text(13, .semibold))
                .foregroundStyle(UdhaTheme.label)
                .padding(.top, 22)
                .padding(.bottom, 4)

        case .note:
            Text(row.title)
                .font(UdhaTheme.text(12, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .udhaWell()
                .padding(.top, 12)

        case .row:
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        if !row.origin.isEmpty {
                            Text(row.origin)
                                .font(UdhaTheme.text(10.5, .semibold))
                                .foregroundStyle(UdhaTheme.accentInk)
                        }
                        Text(row.title)
                            .font(UdhaTheme.text(13, .medium))
                            .foregroundStyle(UdhaTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 268, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        row.control
                        if let help = row.help {
                            Text(help)
                                .font(UdhaTheme.text(11.5, .regular))
                                .foregroundStyle(UdhaTheme.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 520, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 11)
                HRule(color: UdhaTheme.hairline)
            }
        }
    }

    // MARK: - Row assembly

    private var query: String {
        shell.settingsQuery.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var allRowCount: Int {
        UdhaSettingsCatalog.sections
            .map { sectionRows($0.id).filter { $0.kind == .row }.count }
            .reduce(0, +)
    }

    private var rows: [UdhaSettingRow] {
        guard !query.isEmpty else { return sectionRows(shell.settingsSection) }
        return UdhaSettingsCatalog.sections.flatMap { section in
            sectionRows(section.id)
                .filter { $0.kind == .row && $0.searchText.contains(query) }
                .map { var r = $0; r.origin = section.name; return r }
        }
    }

    private func sectionRows(_ id: String) -> [UdhaSettingRow] {
        switch id {
        case "overview": return overviewRows
        case "appearance": return appearanceRows
        case "sessions": return sessionsRows
        case "logins":   return loginsRows
        case "overlay":  return overlayRows
        case "meetings": return meetingsRows
        case "slack":    return slackRows
        case "lock":     return lockRows
        case "keys":     return keysRows
        case "mobile":   return mobileRows
        case "advanced": return advancedRows
        default:         return []
        }
    }

    // MARK: - Controls

    private func toggle(_ binding: Binding<Bool>) -> AnyView {
        AnyView(
            HStack(spacing: 8) {
                UdhaSwitch(isOn: binding)
                Text(binding.wrappedValue ? "On" : "Off")
                    .font(UdhaTheme.text(11.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
            }
        )
    }

    private func kv(_ text: String) -> AnyView {
        AnyView(Mono(text, size: 12, color: UdhaTheme.ink))
    }

    private func action(_ label: String, danger: Bool = false, _ run: @escaping () -> Void) -> AnyView {
        AnyView(
            Button(label, action: run)
                .udhaButton(danger ? .danger : .ghost, height: 26, hPadding: 11)
        )
    }

    private func statusControl(
        _ status: TriStatus,
        actions: [(String, () -> Void)] = []
    ) -> AnyView {
        AnyView(
            HStack(spacing: 9) {
                UdhaStateChip(text: status.word,
                              dot: status == .granted ? UdhaTheme.good : (status == .missing ? UdhaTheme.bad : UdhaTheme.warn),
                              ink: status == .granted ? UdhaTheme.goodInk : (status == .missing ? UdhaTheme.badInk : UdhaTheme.warnInk),
                              tint: status == .granted ? UdhaTheme.goodTint : (status == .missing ? UdhaTheme.badTint : UdhaTheme.warnTint))
                ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                    Button(a.0, action: a.1)
                        .udhaButton(.ghost, height: 26, hPadding: 10)
                }
            }
        )
    }

    enum TriStatus {
        case granted, missing, unknown
        var word: String {
            switch self {
            case .granted: return "Granted"
            case .missing: return "Not granted"
            case .unknown: return "Not yet asked"
            }
        }
    }

    private func tri(_ s: TerminalAccess.Status) -> TriStatus {
        switch s {
        case .ok: return .granted
        case .denied: return .missing
        default: return .unknown
        }
    }

    private func tri(_ s: AccessibilityAccess.Status) -> TriStatus {
        switch s {
        case .ok: return .granted
        case .denied: return .missing
        default: return .unknown
        }
    }

    private func tri(_ s: MeetingCalendar.Status) -> TriStatus {
        switch s {
        case .ok: return .granted
        case .denied: return .missing
        default: return .unknown
        }
    }

    private func tri(_ s: SystemAudioAccess.Status) -> TriStatus {
        switch s {
        case .ok: return .granted
        case .denied: return .missing
        default: return .unknown
        }
    }

    // MARK: - Appearance

    private var appearanceRows: [UdhaSettingRow] {
        [
            .head("Look"),
            .init(
                id: "a-mode", title: "Appearance",
                help: "Match the Mac follows System Settings; the other two pin the window.",
                control: AnyView(UdhaSegmented(
                    options: UdhaAppearanceMode.allCases.map { (value: $0, label: $0.label) },
                    selection: config.binding(\.appearance.mode)
                ))
            ),
            .init(
                id: "a-accent", title: "Accent",
                help: "Selection, the primary button, and the working state all take this colour.",
                control: AnyView(AccentPicker(selection: config.binding(\.appearance.accent)))
            ),
            .head("Motion"),
            .init(
                id: "a-glow", title: "Ambient glow",
                help: "A slow drift of colour under the content. Cheap to draw; off for a projector.",
                control: toggle(config.binding(\.appearance.ambientGlow))
            ),
            .init(
                id: "a-motion", title: "Lift cards on hover",
                help: "Rows slide and cards lift as the pointer crosses them.",
                control: toggle(config.binding(\.appearance.motion))
            ),
        ]
    }

    // MARK: - Overview

    private var overviewRows: [UdhaSettingRow] {
        let all = core.stateStore.all
        let stale = config.config.staleAfterSeconds
        let waiting = all.filter { $0.attention(staleAfter: stale) == .needsYou }.count
        let meetings = core.meetings.store.meetings
        let budget = config.config.notifications.maxDailyTTSCharacters

        return [
            .head("Permissions"),
            .init(
                id: "perm-terminal", title: "Terminal control",
                help: "Lets a click on a session bring its Terminal window forward.",
                control: statusControl(tri(core.terminalAccess.status), actions: [
                    ("Repair", { core.terminalAccess.repairNow() }),
                    ("Open System Settings", { core.terminalAccess.openAutomationSettings() }),
                ])
            ),
            .init(
                id: "perm-ax", title: "Accessibility",
                help: core.accessibility.needsRelaunchAfterGrant
                    ? "Granted — but the event tap only picks it up after a relaunch."
                    : "Needed for the input lock and the global hotkeys.",
                control: statusControl(tri(core.accessibility.status), actions: [
                    ("Repair", { core.accessibility.repairNow() }),
                    ("Open System Settings", { core.accessibility.openAccessibilitySettings() }),
                ])
            ),
            .init(
                id: "perm-mic", title: "Microphone",
                help: "Meetings and push-to-talk.",
                control: statusControl(micStatus)
            ),
            .init(
                id: "perm-sysaudio", title: "System audio recording",
                help: "Asked for at your first meeting, never at launch — probing would trigger the prompt.",
                control: statusControl(tri(core.systemAudioAccess.status), actions: [
                    ("Request now", { Task { _ = await core.systemAudioAccess.requestAccess() } }),
                    ("Open System Settings", { core.systemAudioAccess.openSystemAudioSettings() }),
                ])
            ),

            .head("Today"),
            .init(id: "ov-sessions", title: "Sessions supervised",
                  control: kv("\(all.count) · \(waiting) waiting on you")),
            .init(id: "ov-meetings", title: "Meetings stored",
                  control: kv("\(meetings.count) · \(meetingsSize)")),
            .init(id: "ov-tour", title: "First-run tour",
                  help: "The guided setup, again.",
                  control: action("Replay") { shell.settingsOpen = false; shell.firstRunOpen = true }),
        ]
    }

    private var micStatus: TriStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .missing
        default: return .unknown
        }
    }

    private static func folderSize(of url: URL) -> String {
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return "—" }
        var total = 0
        for case let f as URL in en {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    // MARK: - Claude logins

    /// One editor per machine: this Mac's pools from its own config, a
    /// connected box's from its `accounts` reply. A box whose agent predates
    /// the reply gets a note instead of an empty list.
    private var loginsRows: [UdhaSettingRow] {
        var rows: [UdhaSettingRow] = [
            .note("A tree is a folder whose sessions run as their own Claude login; a pool is that tree's logins. A session starts on the login with the most headroom and moves to another the moment its usage limit is hit. Each login is a dir Claude Code keeps its sign-in in — ~/.claude-<name> — and must be a seat of your own, never a shared one. Pools are per machine: a box's sessions switch among the box's logins."),
        ]
        // The connected box first: that is where the work runs, and its
        // pool is the one with several logins to look after.
        let client = core.remoteHostClient
        if let host = client.activeHostName, client.state == .connected {
            rows.append(.head(host))
            if client.hostAccountsUnsupported {
                rows.append(.note("\(host)'s udha-agent predates login pools. Rebuild it with udha-agent/install.sh to edit its logins here."))
            } else {
                rows.append(.init(id: "l-\(host)", title: "Logins", control: AnyView(ClaudeLoginsEditor(core: core, host: host))))
            }
        }
        rows.append(.head("This Mac"))
        rows.append(.init(id: "l-local", title: "Logins", control: AnyView(ClaudeLoginsEditor(core: core, host: nil))))
        return rows
    }

    // MARK: - Sessions

    private var sessionsRows: [UdhaSettingRow] {
        [
            .init(
                id: "s-sidecar", title: "Detailed status for new Claude sessions",
                help: "Launches Claude with Udha's hooks, so sessions report the exact tool, the end of a turn, and real context left. Existing sessions keep the on-screen reader.",
                control: toggle(config.binding(\.statusSidecarEnabled))
            ),
            .init(
                id: "s-stale", title: "Call a waiting session stale after",
                control: AnyView(UdhaSelect(
                    options: [(300.0, "5 min"), (900.0, "15 min"), (1800.0, "30 min"),
                              (3600.0, "1 hour"), (10800.0, "3 hours")],
                    selection: config.binding(\.staleAfterSeconds)
                ))
            ),
            .init(
                id: "s-hidelist", title: "Hide the session list",
                help: "Collapses the sidebar to its nav rail — for demos, where session names are client names, and for a small screen, where the list is 452pt the pane wants back. ⌘\\ toggles it, and so does the title bar.",
                control: toggle(config.binding(\.hideSessionList))
            ),
            .init(
                id: "s-embedded", title: "Show the terminal inside Udha",
                help: "Draws a live terminal for the selected session in the window, attached to the same tmux session. Off, the pane shows only the fact list. \"Open in Terminal\" keeps working either way — both can be attached at once.",
                control: toggle(Binding(
                    get: { config.config.embeddedTerminal },
                    set: { new in
                        config.mutate { $0.embeddedTerminal = new }
                        // Switching it off detaches every cached client now,
                        // rather than leaving invisible tmux clients attached
                        // and holding the window size down.
                        if !new { core.embeddedTerminals.closeAll() }
                    }
                ))
            ),
            .init(
                id: "s-reclaim", title: "Reclaim Terminal windows on launch",
                help: "Finds the windows already attached instead of opening duplicates.",
                control: toggle(Binding(
                    get: { config.config.reclaimTerminalWindows },
                    set: { new in
                        config.mutate { $0.reclaimTerminalWindows = new }
                        TmuxSession.reclaimTerminalWindows = new
                    }
                ))
            ),
            .init(
                id: "s-awake", title: "Keep the Mac awake while sessions run",
                control: toggle(Binding(
                    get: { config.config.awake.keepSystemAwake },
                    set: { new in
                        config.mutate { $0.awake.keepSystemAwake = new }
                        core.awake.apply(config.config.awake)
                    }
                ))
            ),

            .head("Defaults for a new session"),
            .init(
                id: "s-assistant", title: "Assistant",
                help: "Which coding agent a new session starts, on this Mac or a box.",
                control: AnyView(UdhaSegmented(
                    options: SessionTool.allCases.map { (Optional($0), $0.label) } + [(nil, "Command")],
                    selection: Binding(
                        get: { config.config.newSession.tool },
                        set: { new in
                            config.mutate {
                                // Nothing to name for an assistant; picking
                                // "Command" hands the field back, blank.
                                $0.newSession.command = new?.command ?? ""
                            }
                        }
                    )
                ))
            ),
            .init(
                id: "s-cmd", title: "Command",
                control: AnyView(UdhaField(
                    placeholder: "npm run dev",
                    text: config.binding(\.newSession.command),
                    height: 28, mono: true
                ).frame(width: 260))
            ),
            .init(
                id: "s-dir", title: "Working directory",
                help: "Blank means the last folder you used.",
                control: AnyView(HStack(spacing: 8) {
                    UdhaField(
                        placeholder: "~/projects",
                        text: config.binding(\.newSession.directory),
                        height: 28, mono: true
                    ).frame(width: 260)
                    Button("Choose…") { chooseDefaultDirectory() }
                        .udhaButton(.ghost, height: 28, hPadding: 10)
                })
            ),
            .init(
                id: "s-perm", title: "Permissions",
                help: "“Bypass all” runs every command and edit with no prompts.",
                control: AnyView(Group {
                    // Each assistant has its own four rungs, so the row follows
                    // whichever one the default starts.
                    if config.config.newSession.tool == .qwen {
                        UdhaSelect(
                            options: QwenApprovalMode.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { config.config.newSession.qwenApproval },
                                set: { new in config.mutate { $0.newSession.qwenApproval = new } }
                            ),
                            minWidth: 260
                        )
                    } else if config.config.newSession.tool == .codex {
                        UdhaSelect(
                            options: CodexApprovalMode.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { config.config.newSession.codexApproval },
                                set: { new in config.mutate { $0.newSession.codexApproval = new } }
                            ),
                            minWidth: 260
                        )
                    } else {
                        UdhaSelect(
                            options: ClaudePermissionMode.allCases.map { ($0, $0.label) },
                            selection: Binding(
                                get: { config.config.newSession.permission },
                                set: { new in config.mutate { $0.newSession.permission = new } }
                            ),
                            minWidth: 260
                        )
                    }
                })
            ),
        ]
    }

    private func chooseDefaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            config.mutate { $0.newSession.directory = url.path }
        }
    }

    // MARK: - Edge overlay

    private struct AttachedScreen: Identifiable {
        let id: UInt32
        let name: String
    }

    private var attachedScreens: [AttachedScreen] {
        _ = screenRevision
        return NSScreen.screens
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { s in s.udhaDisplayID.map { AttachedScreen(id: $0, name: s.localizedName) } }
    }

    private func overlayChanged() {
        NotificationCenter.default.post(name: .udhaOverlayConfigChanged, object: nil)
    }

    private var overlayRows: [UdhaSettingRow] {
        var displayOptions: [(UInt32?, String)] = [(nil, "Active display")]
        displayOptions += attachedScreens.map { (Optional($0.id), $0.name) }

        return [
            .init(
                id: "o-enabled", title: "Edge overlay enabled",
                control: toggle(Binding(
                    get: { config.config.overlay.enabled },
                    set: { new in config.mutate { $0.overlay.enabled = new }; overlayChanged() }
                ))
            ),
            .init(
                id: "o-edge", title: "Screen edge",
                control: AnyView(UdhaSegmented(
                    options: [(OverlayEdge.right, "Right"), (OverlayEdge.left, "Left")],
                    selection: Binding(
                        get: { config.config.overlay.edge },
                        set: { new in config.mutate { $0.overlay.edge = new }; overlayChanged() }
                    )
                ))
            ),
            .init(
                id: "o-display", title: "Display",
                help: "A pinned display that isn't attached falls back to the active one.",
                control: AnyView(UdhaSelect(
                    options: displayOptions,
                    selection: Binding(
                        get: { config.config.overlay.displayID },
                        set: { new in config.mutate { $0.overlay.displayID = new }; overlayChanged() }
                    )
                ))
            ),
            .init(
                id: "o-labels", title: "Labels",
                control: AnyView(UdhaSegmented(
                    options: [(OverlayLabelMode.onHover, "On hover"),
                              (OverlayLabelMode.always, "Always"),
                              (OverlayLabelMode.never, "Never")],
                    selection: Binding(
                        get: { config.config.overlay.labelMode },
                        set: { new in config.mutate { $0.overlay.labelMode = new }; overlayChanged() }
                    )
                ))
            ),
            .init(
                id: "o-width", title: "Trigger width",
                control: AnyView(HStack(spacing: 14) {
                    UdhaSlider(
                        value: Binding(
                            get: { config.config.overlay.triggerWidth },
                            set: { new in config.mutate { $0.overlay.triggerWidth = new.rounded() } }
                        ),
                        range: 4...40,
                        onCommit: overlayChanged
                    )
                    Mono("\(Int(config.config.overlay.triggerWidth))pt", size: 11, color: UdhaTheme.muted)
                })
            ),
            .init(
                id: "o-hide", title: "Hide main window on launch",
                control: toggle(config.binding(\.overlay.hideMainWindowOnLaunch))
            ),
            .note("The overlay rests as a thin strip on top of every screen and blooms when you reach the edge. Clicking a session brings its Terminal forward."),
        ]
    }

    private var hourOptions: [(String, String)] {
        (0...23).map { h in
            let raw = String(format: "%02d:00", h)
            let label = h == 0 ? "12am" : (h < 12 ? "\(h)am" : (h == 12 ? "12pm" : "\(h - 12)pm"))
            return (raw, label)
        }
    }

    // MARK: - Meetings

    private var meetingsRows: [UdhaSettingRow] {
        [
            .init(
                id: "m-auto", title: "Auto-start when another app takes the mic",
                help: "Zoom, Meet, FaceTime — recording begins on its own.",
                control: toggle(config.binding(\.meetings.autoRecordMeetings))
            ),
            .init(
                id: "m-autostop", title: "Auto-stop when the call ends",
                help: "Only for meetings recorded while another app held the mic — an in-person recording is never stopped for you.",
                control: toggle(config.binding(\.meetings.autoStopMeetings))
            ),
            .init(
                id: "m-sys", title: "Record system audio (“Them”)",
                help: "Udha's own voice is excluded, so narration never lands in the transcript.",
                control: toggle(config.binding(\.meetings.diarizeSystemAudio))
            ),
            .init(
                id: "m-keep", title: "Keep audio recordings",
                help: "Per-meeting .m4a archives alongside the transcript.",
                control: toggle(config.binding(\.meetings.keepAudioRecordings))
            ),
            .init(
                id: "m-quiet", title: "Auto-stop after this much silence",
                control: AnyView(UdhaSelect(
                    options: [(30, "30 sec"), (45, "45 sec"), (90, "90 sec"), (180, "3 min")],
                    selection: config.binding(\.meetings.autoStopAfterQuietSec)
                ))
            ),

            .head("Calendar"),
            .init(
                id: "m-cal-on", title: "Name meetings from Apple Calendar",
                help: "Every account Calendar.app syncs, read locally. The event overlapping the recording gives the title, its calendar names the org, and the invite list goes into the notes.",
                control: toggle(config.binding(\.meetings.useCalendarTitles))
            ),
            .init(
                id: "m-cal-perm", title: "Calendar access",
                help: core.meetingCalendar.status == .notDetermined
                    ? "Asked for at your first recording."
                    : "Full access to events — read only, nothing is ever written.",
                control: statusControl(tri(core.meetingCalendar.status), actions: [
                    ("Request now", { Task {
                        if await core.meetingCalendar.requestAccess() { await core.meetings.backfillCalendar() }
                    } }),
                    ("Open System Settings", { core.meetingCalendar.openCalendarSettings() }),
                ])
            ),
            .init(
                id: "m-cal-match", title: "Match past recordings",
                help: "Attach events to recordings that have none; placeholder titles are replaced, names you typed are kept.",
                control: action("Match now") { Task { await core.meetings.backfillCalendar() } }
            ),

            .head("Notes"),
            .init(
                id: "m-live-on", title: "Live notes while recording",
                help: "Action items — and, in process-mapping mode, the swimlane — refreshed on a loop.",
                control: toggle(config.binding(\.meetings.liveUpdatesEnabled))
            ),
            .init(
                id: "m-notes-provider", title: "Notes are written by",
                help: "The local model runs on your own hardware (Settings › Keys has no part in it): free, private, slower. Claude needs API credit.",
                control: AnyView(UdhaSelect(
                    options: [(NotesProvider.claude, "Claude API"), (NotesProvider.local, "Local model (\(config.config.localModel.model) on the box)")],
                    selection: config.binding(\.meetings.notesProvider)
                ))
            ),
            .init(
                id: "m-notes-fallback", title: "Use the local model when Claude can't be billed",
                help: "No key, or the API account out of credit: the write-up still happens, locally.",
                control: toggle(config.binding(\.meetings.fallbackToLocal))
            ),
            .init(
                id: "m-live-model", title: "Live notes model",
                control: AnyView(UdhaSelect(
                    options: [("claude-haiku-4-5", "claude-haiku-4-5"), ("claude-sonnet-5", "claude-sonnet-5")],
                    selection: config.binding(\.meetings.liveModel)
                ))
            ),
            .init(
                id: "m-final-model", title: "Final write-up model",
                control: AnyView(UdhaSelect(
                    options: [("claude-sonnet-5", "claude-sonnet-5"), ("claude-opus-5", "claude-opus-5"),
                              ("claude-haiku-4-5", "claude-haiku-4-5")],
                    selection: config.binding(\.meetings.finalModel)
                ))
            ),
            .init(
                id: "m-cadence", title: "Live loop runs",
                control: AnyView(UdhaSelect(
                    options: [(30, "every 30s"), (60, "every 60s"), (120, "every 2 min"), (300, "every 5 min")],
                    selection: config.binding(\.meetings.liveUpdateIntervalSec)
                ))
            ),
            .init(
                id: "m-key", title: "Anthropic API key",
                help: core.meetings.hasAnthropicKey
                    ? "Stored in the Keychain. Recording and transcription work without it."
                    : "Not set — recording and transcription still work; notes don't.",
                control: AnyView(HStack(spacing: 8) {
                    SecureField("sk-ant-…", text: $anthropicKey)
                        .textFieldStyle(.plain)
                        .font(UdhaTheme.mono(12))
                        .padding(.horizontal, 9)
                        .frame(width: 240, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UdhaTheme.card))
                        .udhaOutline(radius: 8)
                    Button("Save") { save(anthropicKey, as: .anthropicAPIKey, label: "Anthropic key") }
                        .udhaButton(.ghost, height: 28, hPadding: 10)
                })
            ),
            .note("Recording, chunking and transcription never depend on Claude. A missing key or an API outage costs you the notes, not the call — and not even those with the local fallback on."),
        ]
    }

    // MARK: - Slack

    private var slackRows: [UdhaSettingRow] {
        var rows: [UdhaSettingRow] = [
            .init(
                id: "sl-workspaces", title: "Workspaces",
                control: kv(config.config.slack.workspaces.isEmpty
                    ? "none connected"
                    : config.config.slack.workspaces.map(\.teamDomain).joined(separator: " · "))
            ),
            .init(
                id: "sl-add", title: "Add a workspace",
                help: "Paste a user token (xoxp-…) with history, users:read and chat:write.",
                control: AnyView(HStack(spacing: 8) {
                    SecureField("xoxp-…", text: $slackToken)
                        .textFieldStyle(.plain)
                        .font(UdhaTheme.mono(12))
                        .padding(.horizontal, 9)
                        .frame(width: 240, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UdhaTheme.card))
                        .udhaOutline(radius: 8)
                    Button("Connect") { connectSlack() }
                        .udhaButton(.ghost, height: 28, hPadding: 10)
                })
            ),
        ]

        for ws in config.config.slack.workspaces {
            let missing = core.slack.missingScopes[ws.teamID] ?? []
            rows.append(.init(
                id: "sl-ws-\(ws.teamID)", title: ws.teamName,
                help: missing.isEmpty
                    ? "Signed in as \(ws.userName)."
                    : "Missing scopes: \(missing.sorted().joined(separator: ", "))",
                control: AnyView(HStack(spacing: 8) {
                    UdhaCheckbox(isOn: Binding(
                        get: { ws.enabled },
                        set: { core.slack.setEnabled(teamID: ws.teamID, enabled: $0) }
                    ))
                    Mono(ws.enabled ? "POLLING" : "PAUSED", size: 10.5, color: UdhaTheme.muted, tracking: 0.6)
                    Button("Remove") { core.slack.removeWorkspace(teamID: ws.teamID) }
                        .udhaButton(.ghost, height: 26, hPadding: 10)
                })
            ))
        }

        rows += [
            .head("Announcements"),
            .init(id: "sl-dm", title: "Announce new DMs",
                  control: toggle(slackToggle(\.announceDMs))),
            .init(id: "sl-mention", title: "Announce mentions",
                  control: toggle(slackToggle(\.announceMentions))),
            .init(id: "sl-all", title: "Announce every channel message",
                  help: "Noisy. Off means only messages that name you.",
                  control: toggle(slackToggle(\.announceAllChannelMessages))),
            .init(
                id: "sl-poll", title: "Check every",
                control: AnyView(UdhaSelect(
                    options: [(10, "10s"), (20, "20s"), (60, "60s"), (300, "5 min")],
                    selection: Binding(
                        get: { config.config.slack.pollIntervalSec },
                        set: { new in
                            config.mutate { $0.slack.pollIntervalSec = new }
                            core.slack.refreshPollers()
                        }
                    )
                ))
            ),
        ]
        return rows
    }

    private func slackToggle(_ path: WritableKeyPath<SlackConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { config.config.slack[keyPath: path] },
            set: { new in
                config.mutate { $0.slack[keyPath: path] = new }
                core.slack.refreshPollers()
            }
        )
    }

    private func connectSlack() {
        let token = slackToken
        guard !token.isEmpty else { return }
        Task {
            do {
                let ws = try await core.slack.addWorkspace(userToken: token)
                slackToken = ""
                flash("Connected \(ws.teamName)")
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    // MARK: - Focus & lock

    private var lockRows: [UdhaSettingRow] {
        let lock = config.config.inputLock
        let biometry = Self.biometryAvailable

        return [
            .init(
                id: "l-enabled", title: "Input lock enabled",
                help: "A deterrent, not kiosk mode — macOS keeps ⌃⌘Q and the power button, and quitting Udha releases it.",
                control: toggle(Binding(
                    get: { config.config.inputLock.enabled },
                    set: { new in
                        config.mutate { $0.inputLock.enabled = new }
                        core.inputLock.apply(config.config.inputLock)
                    }
                ))
            ),
            .init(id: "l-hotkey", title: "Lock the room",
                  control: kv(lock.lockHotkey.displayString)),
            .init(
                id: "l-autolock", title: "Auto-lock when idle",
                control: toggle(Binding(
                    get: { config.config.inputLock.autoLockMinutes > 0 },
                    set: { new in
                        config.mutate { $0.inputLock.autoLockMinutes = new ? 10 : 0 }
                        core.inputLock.apply(config.config.inputLock)
                    }
                ))
            ),
            .init(
                id: "l-idle", title: "Idle before locking",
                control: AnyView(UdhaSelect(
                    options: [(2, "2 min"), (5, "5 min"), (10, "10 min"), (30, "30 min")],
                    selection: Binding(
                        get: { max(1, config.config.inputLock.autoLockMinutes) },
                        set: { new in
                            config.mutate { $0.inputLock.autoLockMinutes = new }
                            core.inputLock.apply(config.config.inputLock)
                        }
                    )
                ))
            ),
            .init(
                id: "l-curtain", title: "Frosted privacy curtain",
                control: toggle(lockToggle(\.hideScreen))
            ),
            .init(
                id: "l-chip", title: "Show the lock badge",
                control: toggle(lockToggle(\.showChip))
            ),
            .init(
                id: "l-password", title: "Unlock with Touch ID",
                help: biometry
                    ? "Falls back to your account password."
                    : "No biometry on this Mac — password fallback must stay on or the lock is unrecoverable.",
                control: toggle(lockToggle(\.allowPasswordFallback))
            ),
            .init(
                id: "l-test", title: "Test the lock",
                help: "Releases on its own after 5 seconds. Works even with the lock switched off.",
                control: action("Test for 5s") { core.inputLock.testLock(seconds: 5) }
            ),
            .note("The lock swallows every keystroke and click. The screen stays on so you can keep watching sessions run."),
        ]
    }

    private static var biometryAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    private func lockToggle(_ path: WritableKeyPath<InputLockConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { config.config.inputLock[keyPath: path] },
            set: { new in
                config.mutate { $0.inputLock[keyPath: path] = new }
                core.inputLock.apply(config.config.inputLock)
            }
        )
    }

    // MARK: - Keys & devices

    private var keysRows: [UdhaSettingRow] {
        [
            .init(
                id: "k-el", title: "ElevenLabs API key",
                control: AnyView(HStack(spacing: 8) {
                    SecureField(core.keychain.has(.elevenLabsAPIKey) ? "•••• stored" : "sk_…",
                                text: $elevenLabsKey)
                        .textFieldStyle(.plain)
                        .font(UdhaTheme.mono(12))
                        .padding(.horizontal, 9)
                        .frame(width: 240, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UdhaTheme.card))
                        .udhaOutline(radius: 8)
                    Button("Replace") { save(elevenLabsKey, as: .elevenLabsAPIKey, label: "ElevenLabs key") }
                        .udhaButton(.ghost, height: 28, hPadding: 10)
                })
            ),
            .init(
                id: "k-anthropic", title: "Anthropic API key",
                control: AnyView(HStack(spacing: 8) {
                    SecureField(core.keychain.has(.anthropicAPIKey) ? "•••• stored" : "sk-ant-…",
                                text: $anthropicKey)
                        .textFieldStyle(.plain)
                        .font(UdhaTheme.mono(12))
                        .padding(.horizontal, 9)
                        .frame(width: 240, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UdhaTheme.card))
                        .udhaOutline(radius: 8)
                    Button("Replace") { save(anthropicKey, as: .anthropicAPIKey, label: "Anthropic key") }
                        .udhaButton(.ghost, height: 28, hPadding: 10)
                })
            ),
            .note("Keys live in the macOS Keychain, never in the config file."),

            .head("Audio"),
            .init(
                id: "k-meeting-in", title: "Meeting microphone",
                help: "Blank follows the system default input.",
                control: AnyView(UdhaSelect(
                    options: [("", "System default")] + inputDevices.map { ($0.uid, $0.name) },
                    selection: config.binding(\.meetings.inputDeviceUID),
                    minWidth: 260
                ))
            ),
        ]
    }

    // MARK: - iPhone

    private var mobileRows: [UdhaSettingRow] {
        let bridge = config.config.mobileBridge
        return [
            .init(
                id: "mb-enabled", title: "Mobile bridge",
                help: "Lets a paired iPhone drive this machine. Off means the relay never opens.",
                control: toggle(Binding(
                    get: { config.config.mobileBridge.enabled },
                    set: { new in
                        config.mutate { $0.mobileBridge.enabled = new }
                        if new { core.mobileBridge.start() } else { core.mobileBridge.stop() }
                    }
                ))
            ),
            .init(id: "mb-status", title: "Relay", control: kv(bridgeStatusText)),
            .init(
                id: "mb-name", title: "Display name (shown on iPhone)",
                control: AnyView(UdhaField(
                    placeholder: Host.current().localizedName ?? "Udha",
                    text: config.binding(\.mobileBridge.instanceName),
                    height: 28
                ).frame(width: 260))
            ),
            .init(
                id: "mb-auth", title: "Account",
                help: bridgeAccountHelp,
                control: AnyView(HStack(spacing: 8) {
                    if core.mobileBridgeAuth0.hasCachedTokens {
                        Button("Sign out") { core.mobileBridgeAuth0.signOut(); core.mobileBridge.stop() }
                            .udhaButton(.ghost, height: 26, hPadding: 10)
                    } else if core.mobileBridgeAuth0.isSigningIn {
                        // A sign-in in flight is not a reason to take the
                        // controls away. The failure that actually happens is
                        // the browser never surfacing the page, and waiting is
                        // the one response to that which cannot work.
                        Button("Open browser again") { core.mobileBridgeAuth0.reopenBrowser() }
                            .udhaButton(.ghost, height: 26, hPadding: 10)
                        Button("Copy link") { copyAuthorizeURL() }
                            .udhaButton(.bare, height: 26, hPadding: 8)
                        Button("Cancel") { core.mobileBridgeAuth0.cancelSignIn() }
                            .udhaButton(.bare, height: 26, hPadding: 8)
                    } else {
                        Button("Sign in") { signIn() }
                            .udhaButton(.ghost, height: 26, hPadding: 10)
                    }
                })
            ),
            .init(
                id: "mb-relay-url", title: "Relay URL",
                help: "Your own relay server. Empty means the bridge never opens a socket.",
                control: bridgeField("wss://relay.example.com", \.mobileBridge.relayURL)
            ),
            .init(
                id: "mb-auth0-domain", title: "Auth0 domain",
                help: "The tenant that issues tokens for that relay.",
                control: bridgeField("your-tenant.us.auth0.com", \.mobileBridge.auth0Domain)
            ),
            .init(
                id: "mb-auth0-client", title: "Auth0 client ID",
                help: "A Native application (PKCE, no secret) with http://localhost:8789/callback allowed.",
                control: bridgeField("client id", \.mobileBridge.auth0ClientID)
            ),
            .init(
                id: "mb-auth0-audience", title: "Auth0 audience",
                help: "The relay API's identifier. Enable Allow Offline Access on it so a refresh token is issued.",
                control: bridgeField("https://relay.example.com", \.mobileBridge.auth0Audience)
            ),
            .note(bridge.isConfigured
                  ? "Relay and Auth0 settings are read at launch — relaunch Udha after changing them."
                  : "Nothing is configured yet: fill in the four fields above, relaunch, then sign in."),
        ]
    }

    private func bridgeField(_ placeholder: String, _ keyPath: WritableKeyPath<AppConfig, String>) -> AnyView {
        AnyView(UdhaField(placeholder: placeholder, text: config.binding(keyPath), height: 28, mono: true)
            .frame(width: 300))
    }

    private var bridgeStatusText: String {
        switch core.mobileBridge.status {
        case .off:            return "off"
        case .startingRelay:  return "connecting…"
        case .awaitingMobile: return "connected · waiting for the phone"
        case .mobileActive:   return "iPhone is the active endpoint"
        case .error(let s):   return "error: \(s)"
        }
    }

    private var bridgeAccountHelp: String {
        if core.mobileBridgeAuth0.isSigningIn {
            return "Waiting for the browser to come back. If no page opened, re-open it or copy the link into a browser yourself."
        }
        return core.mobileBridgeAuth0.cachedUserID.map { "Signed in as \($0)." } ?? "Not signed in."
    }

    private func copyAuthorizeURL() {
        guard let url = core.mobileBridgeAuth0.pendingAuthorizeURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        flash("Sign-in link copied")
    }

    private func signIn() {
        Task {
            do {
                _ = try await core.mobileBridgeAuth0.signIn()
                if config.config.mobileBridge.enabled { core.mobileBridge.start() }
                // Now that tokens exist, discover other machines for the host switch.
                core.ensureRemoteDiscovery()
                flash("Signed in")
            } catch Auth0Error.superseded {
                // A newer attempt took over — it owns the outcome, and flashing
                // a failure here would bury its result.
            } catch Auth0Error.cancelled {
                // The user asked for it; the button coming back is the feedback.
            } catch {
                flash("Sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Advanced

    private var advancedRows: [UdhaSettingRow] {
        [
            .init(
                id: "a-share-api", title: "Video share backend",
                help: "Where published videos are uploaded. Empty = publishing is off.",
                control: bridgeField("https://api.example.com/prod", \.recordings.shareAPIBaseURL)
            ),
            .init(
                id: "a-share-link", title: "Share link base",
                help: "The origin a published video's link is shown as. Empty = no link is built.",
                control: bridgeField("https://example.com", \.recordings.shareLinkBaseURL)
            ),
            .init(
                id: "a-debug", title: "Tool debug panel",
                help: "Invoke any of the agent tools by hand and read the context feed the agent sees.",
                control: action("Open") { shell.settingsOpen = false; shell.debugPanelOpen = true }
            ),
            .init(
                id: "a-log", title: "Log file",
                help: "~/Library/Logs/Udha.AI/udha.log",
                control: action("Reveal") {
                    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Logs/Udha.AI/udha.log")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            ),
            .init(
                id: "a-config", title: "Config file",
                help: "Tolerant JSON — unknown keys are kept, not dropped.",
                control: action("Reveal") {
                    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Udha.AI/config.json")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            ),
            .init(
                id: "a-verbose", title: "Verbose logging",
                help: "Writes DEBUG lines to the log file too. Chatty — the pane reader alone emits several a second.",
                control: toggle(Binding(
                    get: { config.config.verboseLogging },
                    set: { new in
                        config.mutate { $0.verboseLogging = new }
                        Log.verbose = new
                    }
                ))
            ),
            .init(
                id: "a-reset", title: "Reset every setting",
                help: "Sessions and meetings are untouched; only config.json goes back to defaults.",
                control: action("Reset", danger: true) { resetSettings() }
            ),
        ]
    }

    private func resetSettings() {
        let sessions = config.config.sessions
        let recents = config.config.recentDirectories
        config.mutate { cfg in
            var fresh = AppConfig()
            fresh.sessions = sessions
            fresh.recentDirectories = recents
            fresh.hasCompletedFirstRun = true
            cfg = fresh
        }
        core.awake.apply(config.config.awake)
        core.inputLock.apply(config.config.inputLock)
        NotificationCenter.default.post(name: .udhaOverlayConfigChanged, object: nil)
        flash("Settings reset")
    }

    // MARK: - Helpers

    private func loadSecrets() {}

    private func save(_ value: String, as key: KeychainKey, label: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { flash("\(label) is empty"); return }
        do {
            try core.keychain.set(trimmed, for: key)
            flash("\(label) saved")
            if key == .elevenLabsAPIKey { elevenLabsKey = "" }
            if key == .anthropicAPIKey { anthropicKey = "" }
        } catch {
            flash("Could not save \(label)")
        }
    }

    private func refreshDevices() {
        inputDevices = AudioDeviceLister.inputDevices()
        outputDevices = AudioDeviceLister.outputDevices()
    }

    private func flash(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if message == text { message = "" }
        }
    }
}

// MARK: - Config binding sugar

extension ConfigStore {
    /// `config.binding(\.overlay.enabled)` — a `Binding` that routes writes
    /// through `mutate`, so every settings control persists to disk the same way.
    func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { new in self.mutate { $0[keyPath: keyPath] = new } }
        )
    }
}


/// Four swatches; the chosen one wears a ring.
struct AccentPicker: View {
    @Binding var selection: UdhaAccent

    var body: some View {
        HStack(spacing: 10) {
            ForEach(UdhaAccent.allCases, id: \.self) { accent in
                Button { selection = accent } label: {
                    VStack(spacing: 5) {
                        Circle()
                            .fill(accent.accent)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(UdhaTheme.label.opacity(selection == accent ? 0.9 : 0), lineWidth: 2).padding(-3))
                        Text(accent.label)
                            .font(UdhaTheme.text(11, selection == accent ? .semibold : .regular))
                            .foregroundStyle(selection == accent ? UdhaTheme.label : UdhaTheme.secondary)
                    }
                    .frame(width: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}
