import SwiftUI
import AppKit

/// One row in the ⌘K palette.
struct UdhaCommand: Identifiable {
    let id: String
    /// Section header the row groups under.
    let group: String
    let label: String
    /// The grey line after the label — what it will actually do, in context.
    let hint: String
    /// Key hint rendered on the right, e.g. "⌘N". Empty when there isn't one.
    var keys: String = ""
    /// SF Symbol.
    let icon: String
    /// True when the command can't run right now (nothing selected, no
    /// workspace connected). Still listed — the hint says why — but dimmed and
    /// inert, because silently hiding half the palette makes it untrustworthy.
    var enabled: Bool = true
    let run: () -> Void

    /// Everything the fuzzy filter matches against.
    var haystack: String { "\(label) \(hint) \(group)".lowercased() }
}

/// Builds the palette's command list against the live app state.
///
/// Rebuilt on every keystroke, which is what lets each row's hint name the
/// thing it will act on ("asana-reporter · edit asana_sync.py") instead of
/// describing the command in the abstract.
@MainActor
struct UdhaCommandRegistry {
    let core: AppCore
    let shell: UdhaShellModel
    let openWindow: (String) -> Void

    func commands() -> [UdhaCommand] {
        sessionCommands() + agentCommands() + meetingCommands()
            + videoCommands() + machineCommands()
            + slackCommands() + focusCommands()
            + overlayCommands() + settingsCommands()
    }

    // MARK: - Machines

    private func machineCommands() -> [UdhaCommand] {
        let hosts = core.knownHostNames
        let online = core.remoteHostClient.onlineHosts
        let connected = core.currentHostName

        var commands: [UdhaCommand] = [
            UdhaCommand(
                id: "machines-open",
                group: "Machines",
                label: "Show machines",
                hint: hosts.isEmpty
                    ? "this Mac only — no other machine has paired yet"
                    : "this Mac · " + hosts.map { online.contains($0) ? $0 : "\($0) (offline)" }.joined(separator: " · "),
                icon: "server.rack"
            ) {
                shell.go(.machines)
            },
        ]

        // One row per machine, each naming what it will actually do to that
        // machine — connect, or drop it — rather than a generic "switch host".
        for host in hosts {
            let isConnected = connected == host
            let isOnline = online.contains(host)
            commands.append(UdhaCommand(
                id: "machine-\(host)",
                group: "Machines",
                label: isConnected ? "Disconnect from \(host)" : "Connect to \(host)",
                hint: isConnected ? "stops showing its sessions here"
                    : (isOnline ? "shows its sessions next to this Mac's" : "offline — nothing on the relay"),
                icon: "server.rack",
                enabled: isConnected || isOnline
            ) {
                core.selectHost(isConnected ? nil : host)
                shell.select(machine: host)
                shell.say(isConnected ? "Disconnected from \(host)" : "Connecting to \(host)…")
            })
            commands.append(UdhaCommand(
                id: "machine-ssh-\(host)",
                group: "Machines",
                label: "Open a terminal on \(host)",
                hint: isOnline ? "ssh \(host) in a new Terminal window" : "offline — ssh would hang",
                icon: "terminal",
                enabled: isOnline
            ) {
                MachineActions.openTerminal(host: host)
                shell.say("Opened an SSH terminal on \(host)")
            })
        }
        return commands
    }

    // MARK: - Videos

    private func videoCommands() -> [UdhaCommand] {
        let recording = core.recordings.isRecording
        let paused = core.recordings.live?.engine.state == .paused
        let latest = core.recordings.store.recordings.first

        return [
            UdhaCommand(
                id: "record-screen",
                group: "Videos",
                label: recording ? "Stop recording" : "Record screen",
                hint: recording ? "stop and render both masters" : "screen + camera + mic, captions burned in",
                icon: recording ? "stop.fill" : "record.circle"
            ) {
                if recording {
                    Task { await core.recordings.stop() }
                    shell.go(.videos)
                    shell.say("Rendering both masters…")
                } else {
                    shell.go(.videos)
                    shell.recordTargetOpen = true
                    shell.say("Pick a screen or window to record")
                }
            },

            UdhaCommand(
                id: "record-pause",
                group: "Videos",
                label: paused ? "Resume recording" : "Pause recording",
                hint: recording ? "pauses are excised from the final video" : "no recording in progress",
                icon: paused ? "play.fill" : "pause.fill",
                enabled: recording
            ) {
                if paused {
                    core.recordings.resume()
                    shell.say("Recording resumed")
                } else {
                    core.recordings.pause()
                    shell.say("Recording paused")
                }
            },

            UdhaCommand(
                id: "videos-open",
                group: "Videos",
                label: "Show videos",
                hint: latest.map { "latest: \($0.title)" } ?? "nothing recorded yet",
                icon: "film"
            ) {
                shell.go(.videos)
            },

            UdhaCommand(
                id: "video-rerender",
                group: "Videos",
                label: "Re-render latest video",
                hint: latest.map { "redo both masters for \($0.title)" } ?? "nothing recorded yet",
                icon: "arrow.clockwise",
                enabled: latest != nil && !recording
            ) {
                guard let latest else { return }
                shell.go(.videos)
                shell.selectedRecordingID = latest.id
                Task { await core.recordings.retryProcessing(latest) }
                shell.say("Re-rendering \(latest.title)")
            },

            UdhaCommand(
                id: "video-join",
                group: "Videos",
                label: "Join selected videos",
                hint: joinHint,
                keys: "⌘J",
                icon: "arrow.trianglehead.merge",
                enabled: joinPicks.count >= 2
            ) {
                let picks = joinPicks
                guard picks.count >= 2 else { return }
                shell.go(.videos)
                shell.openJoinSheet(
                    order: picks.map(\.id),
                    name: RecordingCenter.defaultJoinTitle(for: picks)
                )
            },

            UdhaCommand(
                id: "video-reveal",
                group: "Videos",
                label: "Reveal latest video in Finder",
                hint: latest.map { $0.title } ?? "nothing recorded yet",
                icon: "folder",
                enabled: latest != nil
            ) {
                guard let latest else { return }
                NSWorkspace.shared.activateFileViewerSelecting([core.recordings.store.folderURL(for: latest)])
            },
        ]
    }

    /// The videos ticked in the sidebar, oldest first — the order a join plays
    /// them in.
    private var joinPicks: [Recording] {
        core.recordings.store.recordings
            .filter { shell.joinSelection.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Names the videos it will actually join, so the row is specific rather
    /// than a description of the command in the abstract.
    private var joinHint: String {
        let picks = joinPicks
        switch picks.count {
        case 0:  return "tick two videos in the sidebar first"
        case 1:  return "only \(picks[0].title) is ticked — tick one more"
        case 2:  return "\(picks[0].title) → \(picks[1].title)"
        default: return "\(picks[0].title) and \(picks.count - 1) more, in order"
        }
    }

    // MARK: - Sessions

    private var staleAfter: Double { core.config.config.staleAfterSeconds }

    /// The machine "New folder" targets: the selected session's, else this Mac.
    private var folderHost: String? { selected?.hostName }
    private var foldersSupported: Bool { folderHost == nil || !core.remoteHostClient.hostFoldersUnsupported }
    private var hasHidden: Bool {
        let c = core.stateStore.hiddenCounts
        return c.folders > 0 || c.sessions > 0
    }
    private var hiddenHint: String {
        let c = core.stateStore.hiddenCounts
        guard hasHidden else { return "nothing is hidden" }
        let parts = [
            c.folders > 0 ? "\(c.folders) \(c.folders == 1 ? "folder" : "folders")" : nil,
            c.sessions > 0 ? "\(c.sessions) \(c.sessions == 1 ? "session" : "sessions")" : nil,
        ].compactMap { $0 }
        return "bring back " + parts.joined(separator: " and ")
    }

    private var blockedSession: SessionSnapshot? {
        core.stateStore.visible.first { $0.phase == .awaitingApproval }
    }

    private var questionSession: SessionSnapshot? {
        core.stateStore.visible.first {
            $0.phase == .awaitingReply && $0.attention(staleAfter: staleAfter) == .needsYou
        }
    }

    private var selected: SessionSnapshot? {
        guard let id = shell.selectedSessionID else { return nil }
        return core.stateStore.snapshot(id: id)
    }

    private func sessionCommands() -> [UdhaCommand] {
        let blocked = blockedSession
        let question = questionSession
        let sel = selected

        return [
            UdhaCommand(
                id: "approve",
                group: "Sessions",
                label: "Approve what Claude is asking",
                hint: blocked.map { "\($0.label) · \(($0.pendingPrompt?.text ?? "").firstLineTrimmed)" }
                    ?? "nothing is waiting on approval",
                keys: "⏎",
                icon: "checkmark",
                enabled: blocked != nil
            ) {
                guard let blocked else { return }
                shell.select(session: blocked.id)
                core.sessionManager.approvePrompt(id: blocked.id)
                shell.say("Approved · \(blocked.label)")
            },

            UdhaCommand(
                id: "answer",
                group: "Sessions",
                label: "Answer the open question",
                hint: question.map { "\($0.label) · \(($0.lastQuestion ?? "waiting on you").firstLineTrimmed)" }
                    ?? "no session is waiting on a reply",
                icon: "bubble.left",
                enabled: question != nil
            ) {
                guard let question else { return }
                shell.select(session: question.id)
                shell.say("Answer \(question.label) — type below")
            },

            UdhaCommand(
                id: "new-session",
                group: "Sessions",
                label: "New session",
                hint: "pick a folder and a command",
                keys: "⌘N",
                icon: "plus"
            ) {
                shell.newSessionOpen = true
            },

            // Folders live on the board; the palette hands it the request so
            // the new row opens for naming there.
            UdhaCommand(
                id: "new-folder",
                group: "Sessions",
                label: "New folder",
                hint: folderHost == nil ? "on this Mac — group sessions in the list"
                    : (foldersSupported ? "on \(folderHost!)" : "\(folderHost!)'s agent needs a rebuild first"),
                icon: "folder.badge.plus",
                enabled: foldersSupported
            ) {
                shell.go(.sessions)
                shell.newFolderRequest = UdhaShellModel.NewFolderRequest(host: folderHost)
            },

            UdhaCommand(
                id: "unhide-all",
                group: "Sessions",
                label: "Unhide all",
                hint: hiddenHint,
                icon: "eye",
                enabled: hasHidden
            ) {
                core.sessionManager.unhideAll()
                for host in core.remoteHostClient.onlineHosts where !core.remoteHostClient.hostFoldersUnsupported {
                    core.sessionManager.unhideAll(host: host)
                }
                shell.say("Unhid everything")
            },

            UdhaCommand(
                id: "terminal",
                group: "Sessions",
                label: "Open in Terminal",
                hint: sel.map { "bring \($0.label)'s tmux window forward" } ?? "select a session first",
                keys: "⌘⏎",
                icon: "terminal",
                enabled: sel != nil
            ) {
                guard let sel else { return }
                core.sessionManager.showSession(id: sel.id)
                shell.say("Focused \(sel.label) in Terminal")
            },

            UdhaCommand(
                id: "send-text",
                group: "Sessions",
                label: "Send text to a session",
                hint: "type into the pane without leaving Udha",
                icon: "keyboard",
                enabled: sel != nil
            ) {
                shell.go(.sessions)
                shell.say("Type in the box under Recent output")
            },

            UdhaCommand(
                id: "duplicate",
                group: "Sessions",
                label: "Duplicate session",
                hint: sel.map { "same folder as \($0.label), fresh Claude" } ?? "select a session first",
                icon: "doc.on.doc",
                enabled: sel != nil
            ) {
                guard let sel, let new = core.sessionManager.duplicate(sessionID: sel.id) else { return }
                shell.select(session: new)
                shell.say("Duplicated \(sel.label)")
            },

            UdhaCommand(
                id: "switch-login",
                group: "Sessions",
                label: "Switch Claude login",
                hint: sel.flatMap { s in s.account.map { "\(s.label) is on \($0) · move it to the emptiest login" } }
                    ?? (sel.map { "\($0.label)'s folder has one login" } ?? "select a session first"),
                icon: "person.2.badge.key",
                enabled: sel?.account != nil
            ) {
                guard let sel else { return }
                core.sessionManager.rotateAccount(id: sel.id)
                shell.say("Moving \(sel.label) to another login")
            },

            UdhaCommand(
                id: "kill",
                group: "Sessions",
                label: "Kill session",
                hint: sel.map { "ends the tmux session \($0.label)" } ?? "select a session first",
                icon: "stop.fill",
                enabled: sel != nil
            ) {
                guard let sel else { return }
                core.sessionManager.terminateSession(id: sel.id)
                shell.say("Terminated \(sel.label)")
            },

            UdhaCommand(
                id: "release-size",
                group: "Sessions",
                label: "Release window size",
                hint: sel.map { $0.sizePinned ? "\($0.label) is pinned to the phone's grid" : "\($0.label) · hand the tmux window back to its terminal" }
                    ?? "select a session first",
                icon: "arrow.up.left.and.arrow.down.right",
                enabled: sel != nil
            ) {
                guard let sel else { return }
                core.sessionManager.releaseWindowSize(id: sel.id)
                shell.say("Released the window size of \(sel.label)")
            },

            UdhaCommand(
                id: "priority",
                group: "Sessions",
                label: "Set priority",
                hint: "high sessions speak even when focused",
                icon: "flag",
                enabled: sel != nil
            ) {
                guard let sel else { return }
                let next: SessionPriority = sel.priority == .high ? .normal : .high
                core.sessionManager.setPriority(id: sel.id, level: next)
                shell.say("\(sel.label) priority → \(next.rawValue)")
            },

        ]
    }

    // MARK: - Agents

    private func agentCommands() -> [UdhaCommand] {
        let names = core.agents.agents.prefix(3).map(\.name).joined(separator: ", ")
        return [
            UdhaCommand(
                id: "run-agent",
                group: "Agents",
                label: "Run an agent…",
                hint: names.isEmpty ? "no agents yet — create one" : names,
                keys: "⌘R",
                icon: "sparkles",
                enabled: !core.agents.agents.isEmpty
            ) {
                shell.go(.agents)
                if shell.selectedAgentSlug == nil { shell.selectedAgentSlug = core.agents.agents.first?.slug }
                shell.say("Pick a folder and run")
            },
            UdhaCommand(
                id: "new-agent",
                group: "Agents",
                label: "New agent",
                hint: "a reusable .md prompt",
                icon: "doc.badge.plus"
            ) {
                shell.go(.agents)
                shell.newAgentPending = true
            },
            UdhaCommand(
                id: "reveal-agents",
                group: "Agents",
                label: "Edit agent prompts",
                hint: "Application Support/Udha.AI/Agents",
                icon: "pencil"
            ) {
                NSWorkspace.shared.activateFileViewerSelecting([core.agents.agentsDirectory])
                shell.say("Revealed the agents folder")
            },
        ]
    }

    // MARK: - Meetings

    private func meetingCommands() -> [UdhaCommand] {
        let recording = core.meetings.live != nil
        let latest = core.meetings.store.meetings.first
        let autoOn = core.config.config.meetings.autoRecordMeetings

        return [
            UdhaCommand(
                id: "record",
                group: "Meetings",
                label: recording ? "Stop recording" : "Record meeting",
                hint: recording ? "stop and write it up" : "mic + system audio, live transcript",
                keys: "⌘⇧R",
                icon: recording ? "stop.fill" : "record.circle"
            ) {
                if recording {
                    Task { await core.meetings.stop() }
                    shell.showingLive = false
                    shell.say("Meeting ended · writing it up")
                } else {
                    Task { await core.meetings.start(mode: .standard) }
                    shell.openLive()
                    shell.liveTab = .transcript
                    shell.say("Recording · mic + system audio")
                }
            },

            UdhaCommand(
                id: "record-map",
                group: "Meetings",
                label: "Record + map process",
                hint: "live swimlane SOP diagram",
                icon: "arrow.triangle.branch",
                enabled: !recording
            ) {
                Task { await core.meetings.start(mode: .processMapping) }
                shell.openLive()
                shell.liveTab = .diagram
                shell.say("Recording + mapping process")
            },

            UdhaCommand(
                id: "regen-notes",
                group: "Meetings",
                label: "Regenerate notes",
                hint: latest.map { "re-run the final pass on \($0.title)" } ?? "no meetings recorded yet",
                icon: "arrow.clockwise",
                enabled: latest != nil && core.meetings.hasNotesModel
            ) {
                guard let target = shell.selectedMeetingID.flatMap({ id in
                    core.meetings.store.meetings.first { $0.id == id }
                }) ?? latest else { return }
                Task { await core.meetings.finalize(target) }
                shell.say("Regenerating notes for \(target.title)")
            },

            UdhaCommand(
                id: "export-notes",
                group: "Meetings",
                label: "Export notes as Markdown",
                hint: "notes, action items, fenced mermaid",
                icon: "arrow.down.doc",
                enabled: latest != nil
            ) {
                guard let target = shell.selectedMeetingID.flatMap({ id in
                    core.meetings.store.meetings.first { $0.id == id }
                }) ?? latest else { return }
                MeetingExporter.exportNotes(meeting: target, store: core.meetings.store)
                shell.say("Exported \(target.title)")
            },

            UdhaCommand(
                id: "export-diagram",
                group: "Meetings",
                label: "Export diagram as PNG",
                hint: "the swimlane, at print size",
                icon: "square.and.arrow.down",
                enabled: latest.map { core.meetings.store.hasProcessModel($0) } ?? false
            ) {
                guard let target = shell.selectedMeetingID.flatMap({ id in
                    core.meetings.store.meetings.first { $0.id == id }
                }) ?? latest,
                      let model = core.meetings.store.loadProcessModel(for: target) else { return }
                MeetingExporter.exportDiagramPNG(model: model, title: target.title)
                shell.say("Exported the diagram")
            },

            UdhaCommand(
                id: "auto-record",
                group: "Meetings",
                label: "Auto-record when an app takes the mic",
                hint: autoOn ? "on — Zoom, Meet, FaceTime" : "off",
                icon: autoOn ? "switch.2" : "switch.2",
                enabled: true
            ) {
                core.config.mutate { $0.meetings.autoRecordMeetings.toggle() }
                shell.say("Auto-record \(core.config.config.meetings.autoRecordMeetings ? "on" : "off")")
            },
        ]
    }

    // MARK: - Slack

    private func slackCommands() -> [UdhaCommand] {
        let hasWorkspaces = !core.config.config.slack.workspaces.isEmpty
        let unread = core.slack.inbox.unreadCount
        return [
            UdhaCommand(
                id: "check-slack",
                group: "Slack",
                label: "Check Slack",
                hint: hasWorkspaces
                    ? (unread == 0 ? "nothing unread" : "\(unread) unread thread\(unread == 1 ? "" : "s")")
                    : "connect a workspace first",
                icon: "tray",
                enabled: hasWorkspaces
            ) {
                shell.go(.inbox)
                shell.say(unread == 0 ? "Inbox is clear" : "\(unread) unread")
            },
            UdhaCommand(
                id: "send-slack",
                group: "Slack",
                label: "Send a Slack message",
                hint: "dictate it, Udha sends it",
                icon: "paperplane",
                enabled: hasWorkspaces
            ) {
                shell.go(.inbox)
                shell.say("Pick a thread and reply")
            },
        ]
    }

    // MARK: - Focus

    private func focusCommands() -> [UdhaCommand] {
        let lock = core.config.config.inputLock
        let awake = core.config.config.awake
        return [
            UdhaCommand(
                id: "lock",
                group: "Focus",
                label: "Lock the room",
                hint: lock.enabled
                    ? "swallows keyboard and mouse, screen stays on"
                    : "turn the lock on in Settings first",
                keys: "⌃⌥⌘L",
                icon: "lock",
                enabled: lock.enabled
            ) {
                core.inputLock.lock(source: .hotkey)
                shell.say("Room locked — Touch ID to unlock")
            },
            UdhaCommand(
                id: "auto-lock",
                group: "Focus",
                label: "Auto-lock when idle",
                hint: lock.autoLockMinutes > 0 ? "after \(lock.autoLockMinutes) minutes" : "off",
                icon: "timer"
            ) {
                shell.openSettings(section: "lock")
            },
            UdhaCommand(
                id: "awake",
                group: "Focus",
                label: "Keep the Mac awake",
                hint: awake.keepSystemAwake ? "on while sessions are running" : "off",
                icon: "sun.max"
            ) {
                core.config.mutate { $0.awake.keepSystemAwake.toggle() }
                core.awake.apply(core.config.config.awake)
                shell.say("Keep awake \(core.config.config.awake.keepSystemAwake ? "on" : "off")")
            },
        ]
    }

    // MARK: - Overlay

    private func overlayCommands() -> [UdhaCommand] {
        let overlay = core.config.config.overlay
        return [
            UdhaCommand(
                id: "hide-list",
                group: "View",
                label: core.config.config.hideSessionList ? "Show the session list" : "Hide the session list",
                hint: core.config.config.hideSessionList
                    ? "bring the sidebar list back"
                    : "for demos and small screens — client names off screen",
                keys: "⌘\\",
                icon: core.config.config.hideSessionList ? "sidebar.left" : "sidebar.leading"
            ) {
                let now = !core.config.config.hideSessionList
                core.config.mutate { $0.hideSessionList = now }
                shell.say(now ? "Session list hidden" : "Session list shown")
            },

            UdhaCommand(
                id: "pin-overlay",
                group: "Overlay",
                label: "Pin overlay to this display",
                hint: overlay.displayID == nil ? "currently follows the active display" : "currently pinned",
                icon: "display"
            ) {
                let id = NSScreen.main?.udhaDisplayID
                core.config.mutate { $0.overlay.displayID = id }
                NotificationCenter.default.post(name: .udhaOverlayConfigChanged, object: nil)
                shell.say("Overlay pinned to this display")
            },
            UdhaCommand(
                id: "hide-overlay",
                group: "Overlay",
                label: overlay.enabled ? "Hide the edge overlay" : "Show the edge overlay",
                hint: overlay.enabled ? "until you turn it back on" : "bring the strip back",
                icon: overlay.enabled ? "eye.slash" : "eye"
            ) {
                core.config.mutate { $0.overlay.enabled.toggle() }
                NotificationCenter.default.post(name: .udhaOverlayConfigChanged, object: nil)
                shell.say("Overlay \(core.config.config.overlay.enabled ? "shown" : "hidden")")
            },
        ]
    }

    // MARK: - Settings

    private func settingsCommands() -> [UdhaCommand] {
        [
            UdhaCommand(
                id: "settings",
                group: "Settings",
                label: "Settings",
                hint: "\(UdhaSettingsCatalog.sections.count) sections — meetings, Slack, keys",
                keys: "⌘,",
                icon: "gearshape"
            ) {
                shell.openSettings(section: "overview")
            },
            UdhaCommand(
                id: "permissions",
                group: "Settings",
                label: "Check permissions",
                hint: "Terminal, Accessibility, audio",
                icon: "checkmark.shield"
            ) {
                shell.openSettings(section: "overview")
            },
            UdhaCommand(
                id: "tour",
                group: "Settings",
                label: "Replay the first-run tour",
                hint: "the guided setup",
                icon: "location.north.circle"
            ) {
                shell.firstRunOpen = true
                shell.paletteOpen = false
            },
            UdhaCommand(
                id: "debug",
                group: "Settings",
                label: "Tool debug panel",
                hint: "invoke any agent tool by hand; read the context feed",
                icon: "wrench.and.screwdriver"
            ) {
                shell.debugPanelOpen = true
                shell.paletteOpen = false
            },
        ]
    }
}

private extension String {
    /// First non-empty line, trimmed and clipped — palette hints are one line.
    var firstLineTrimmed: String {
        let line = components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 64 ? String(line.prefix(63)) + "…" : line
    }
}
