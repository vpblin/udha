import SwiftUI
import AppKit

/// A way to drive the window from outside while nobody can click it — a
/// locked screen, a headless self-test, a screenshot run from another
/// machine. Off unless the app is launched with `-UDHAUIDriver 1`.
///
/// Commands arrive as distributed notifications named `<bundle id>.ui`
/// with `userInfo["cmd"]`, one per line of the list below:
///
///     section:<sessions|machines|meetings|agents|inbox|videos>
///     list:toggle               show / hide the list column
///     palette:toggle            ⌘K
///     palette:type:<text>       type into the palette
///     settings:open / settings:close / settings:section:<id>
///     select:next / select:prev   next / previous session on the board
///     select:machine:<host|mac>
///     tab:terminal / tab:details
///     command:<⌘K command id>     e.g. command:release-size
///     appearance:<system|light|dark>
///     accent:<blue|purple|green|graphite>
///     glow:on / glow:off
///     newsession:open / newsession:close
///     overlay:bloom / overlay:collapse
///     meeting:split:<folder>@<seconds>   cut a finished recording in two
///
/// From a shell:
///
///     python3 -c 'from Foundation import NSDistributedNotificationCenter as C; \
///       C.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_( \
///       "<bundle id>.ui", None, {"cmd": "section:machines"}, True)'
///
/// (`<bundle id>` is the app's own `CFBundleIdentifier` — `ai.udha.desktop`
/// unless a `Local.xcconfig` overrides `UDHA_BUNDLE_ID`.)
struct UdhaUIDriver: ViewModifier {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "UDHAUIDriver") }
    /// Derived from the bundle id so a fork (or a `Local.xcconfig` that
    /// overrides `UDHA_BUNDLE_ID`) gets its own channel and two builds on one
    /// Mac can't drive each other.
    static let name = Notification.Name((Bundle.main.bundleIdentifier ?? "ai.udha.desktop") + ".ui")

    func body(content: Content) -> some View {
        if Self.enabled {
            content.onReceive(DistributedNotificationCenter.default().publisher(for: Self.name)) { note in
                guard let cmd = note.userInfo?["cmd"] as? String else { return }
                Log.app.info("UIDriver: \(cmd)")
                run(cmd)
            }
        } else {
            content
        }
    }

    private func run(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "section":
            if parts.count > 1, let s = UdhaSection(rawValue: parts[1]) { shell.go(s) }
        case "week":
            // week:<n> — the Time section's week n weeks back (0 = this week).
            let back = Int(parts.count > 1 ? parts[1] : "0") ?? 0
            let current = TimeTracker.weekStart(containing: Date())
            shell.selectedWeek = Calendar.current.date(byAdding: .day, value: -7 * back, to: current)!
            shell.go(.time)
        case "list":
            core.config.mutate { $0.hideSessionList.toggle() }
        case "palette":
            if parts.count > 1, parts[1] == "type" {
                shell.paletteOpen = true
                shell.paletteQuery = parts.count > 2 ? parts[2] : ""
                shell.paletteCursor = 0
            } else {
                shell.togglePalette()
            }
        case "settings":
            guard parts.count > 1 else { return }
            switch parts[1] {
            case "open":    shell.openSettings()
            case "close":   shell.settingsOpen = false
            case "section": if parts.count > 2 { shell.openSettings(section: parts[2]) }
            default: break
            }
        case "select":
            guard parts.count > 1 else { return }
            let ids = core.stateStore.visible.map(\.id)
            switch parts[1] {
            case "next", "prev":
                guard !ids.isEmpty else { return }
                let current = shell.selectedSessionID.flatMap { ids.firstIndex(of: $0) } ?? -1
                let next = parts[1] == "next" ? (current + 1) % ids.count : (current - 1 + ids.count) % ids.count
                shell.select(session: ids[next])
            case "machine":
                let host = parts.count > 2 ? parts[2] : "mac"
                shell.select(machine: host == "mac" ? nil : host)
            default: break
            }
        case "command":
            // Run a ⌘K command by id ("command:release-size") without the
            // palette, for checks that need the action and not the picker.
            guard parts.count > 1 else { return }
            let registry = UdhaCommandRegistry(core: core, shell: shell, openWindow: { _ in })
            if let c = registry.commands().first(where: { $0.id == parts[1] }) {
                if c.enabled { c.run() } else { shell.say(c.hint) }
            }
        case "tab":
            if parts.count > 1 { NotificationCenter.default.post(name: .udhaDriverTab, object: parts[1]) }
        case "appearance":
            if parts.count > 1, let mode = UdhaAppearanceMode(rawValue: parts[1]) {
                core.config.mutate { $0.appearance.mode = mode }
            }
        case "accent":
            if parts.count > 1, let accent = UdhaAccent(rawValue: parts[1]) {
                core.config.mutate { $0.appearance.accent = accent }
            }
        case "glow":
            core.config.mutate { $0.appearance.ambientGlow = parts.count > 1 && parts[1] == "on" }
        case "newsession":
            shell.newSessionOpen = parts.count > 1 && parts[1] == "open"
        // Folders + hidden, for the locked-screen screenshot runs:
        //   folder:new            new folder on the selected session's machine
        //   folder:toggle         collapse/expand the selected session's folder
        //   session:hide          hide the selected session
        //   sessions:unhide       unhide everything, on every machine
        case "folder":
            guard parts.count > 1 else { return }
            let sel = shell.selectedSessionID.flatMap { core.stateStore.snapshot(id: $0) }
            switch parts[1] {
            case "new":
                shell.go(.sessions)
                shell.newFolderRequest = UdhaShellModel.NewFolderRequest(host: sel?.hostName)
            case "toggle":
                guard let key = sel?.folderID?.uuidString else { return }
                core.config.mutate { cfg in
                    if let i = cfg.collapsedFolderIDs.firstIndex(of: key) { cfg.collapsedFolderIDs.remove(at: i) }
                    else { cfg.collapsedFolderIDs.append(key) }
                }
            default: break
            }
        case "session":
            guard parts.count > 1, parts[1] == "hide", let id = shell.selectedSessionID else { return }
            core.sessionManager.setHidden(sessionID: id, hidden: true)
        case "sessions":
            guard parts.count > 1, parts[1] == "unhide" else { return }
            core.sessionManager.unhideAll()
            for host in core.remoteHosts.connectedHosts { core.sessionManager.unhideAll(host: host) }
        case "meeting":
            // The tidy-up verbs, scripted:
            //   meeting:split:<folder>@<seconds>[@raw]   (raw = don't write either half up yet)
            //   meeting:join:<folder>,<folder>[,…]       (folds into the earliest, then writes it up)
            //   meeting:rename:<folder>=<title>
            //   meeting:finalize:<folder>
            //   meeting:delete:<folder>
            guard parts.count > 2 else { return }
            let store = core.meetings.store
            func meeting(_ folder: String) -> Meeting? { store.meetings.first { $0.folderName == folder } }
            switch parts[1] {
            case "split":
                let arg = parts[2].split(separator: "@").map(String.init)
                guard arg.count >= 2, let offset = TimeInterval(arg[1]), let m = meeting(arg[0])
                else { Log.app.error("UIDriver: no meeting for \(parts[2])"); return }
                let raw = arg.count > 2 && arg[2] == "raw"
                Task {
                    let second = await core.meetings.split(m, at: offset, finalize: !raw)
                    Log.app.info("UIDriver: split \(arg[0]) → \(second?.folderName ?? "FAILED")")
                }
            case "join":
                let found = parts[2].split(separator: ",").compactMap { meeting(String($0)) }
                guard found.count >= 2 else { Log.app.error("UIDriver: join needs 2+ meetings: \(parts[2])"); return }
                Task {
                    let joined = await core.meetings.join(found)
                    Log.app.info("UIDriver: joined → \(joined?.folderName ?? "FAILED")")
                }
            case "rename":
                let arg = parts[2].split(separator: "=", maxSplits: 1).map(String.init)
                guard arg.count == 2, var m = meeting(arg[0]) else { return }
                m.title = arg[1]
                store.save(m)
                Log.app.info("UIDriver: renamed \(arg[0]) → \(arg[1])")
            case "finalize":
                guard let m = meeting(parts[2]) else { return }
                Task { await core.meetings.finalize(m) }
            case "delete":
                // Removes the folder for good — back it up first.
                guard let m = meeting(parts[2]), core.meetings.live?.meeting.id != m.id else { return }
                store.delete(m)
                Log.app.info("UIDriver: deleted \(parts[2])")
            default: break
            }
        case "calendar":
            // calendar:busy:<days> — writes the next N days' busy events to
            // /tmp/udha/calendar-busy.tsv, for "when am I free?" from a script
            // (only the app holds the Calendar grant).
            let days = Double(parts.count > 2 ? parts[2] : "7") ?? 7
            let from = Calendar.current.startOfDay(for: Date())
            let lines = core.meetingCalendar.busyLines(from: from, to: from.addingTimeInterval(days * 86_400))
            try? FileManager.default.createDirectory(atPath: "/tmp/udha", withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(toFile: "/tmp/udha/calendar-busy.tsv", atomically: true, encoding: .utf8)
            Log.app.info("UIDriver: wrote \(lines.count) busy events")
        case "overlay":
            NotificationCenter.default.post(name: .udhaOverlayDriverBloom,
                                            object: parts.count > 1 && parts[1] == "bloom")
        default:
            Log.app.error("UIDriver: unknown command \(cmd)")
        }
    }
}

extension Notification.Name {
    /// `object` is "terminal" or "details" — the Sessions pane switches tabs.
    static let udhaDriverTab = Notification.Name("udhaDriverTab")
}
