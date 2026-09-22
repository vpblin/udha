import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine)
import Combine
#endif
#if canImport(os)
import os
#endif

@MainActor
final class SessionManager: ObservableObject {
    let stateStore: SessionStateStore
    let config: ConfigStore
    let activity: ActivityLog

    private var sessions: [UUID: TmuxSession] = [:]
    private var buffers: [UUID: RingBuffer] = [:]
    private var quietTimers: [UUID: DispatchSourceTimer] = [:]
    private var pendingClassification: [UUID: (state: SessionState, seenAt: Date)] = [:]
    private var lastOutputAt: [UUID: Date] = [:]
    private var attentionTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    // MARK: Claude logins
    /// What is known about every login in a `ClaudeAccount` pool — usage
    /// readings and which ones are waiting out a limit.
    let accountPool = ClaudeAccountPool()
    /// The config dir each live Claude session is running under.
    private var sessionAccount: [UUID: String] = [:]
    /// Sessions mid-rotation: respawned, waiting for the prompt to come back.
    private var rotating: Set<UUID> = []
    /// The last limit notice acted on per session, so the same notice sitting
    /// in the pane for minutes is one event, not one every poll.
    private var lastLimitNotice: [UUID: (text: String, at: Date)] = [:]
    private var lastRotationAt: [UUID: Date] = [:]
    private var usageProbeTimer: Timer?
    private var lastUsageProbeAt: Date = .distantPast

    /// Per-session bookkeeping for the pane reader. `capture-pane` polls every
    /// 2s, so the turn-end edge is observed here rather than inferred from a
    /// spinner line that may already have scrolled away.
    private struct PaneTracker {
        /// Consecutive captures with no "esc to interrupt".
        var quietCaptures = 0
        /// Whether this session has ever been seen mid-turn. Distinguishes
        /// "finished, go review it" from "never started".
        var sawStreaming = false
        /// Set once Claude's chrome has been recognised in the pane; from then
        /// on the unusable `pipe-pane` stream is ignored for this session.
        var sawClaudeChrome = false
        /// Once a hook event arrives we trust the sidecar over the pane — it
        /// names the exact tool instead of guessing from rendered text.
        var sidecarActive = false
        var subagents = 0
    }
    private var paneTrackers: [UUID: PaneTracker] = [:]

    /// Raw `capture-pane` output, per session, as it arrives. Used by the
    /// mobile bridge for terminal frames.
    var onPaneCapture: ((UUID, String) -> Void)?
    /// Fired after the desktop releases a window the mobile bridge had pinned,
    /// so the bridge can drop its own bookkeeping — otherwise a phone asking
    /// for the same grid again would be de-duplicated into no resize at all.
    var onWindowSizeReleased: ((UUID) -> Void)?

    /// When set, this desktop is driving another machine's sessions over the
    /// relay: actions forward to the host and local classification is paused, so
    /// the same overlay/cards render the remote sessions. Set by `AppCore` when
    /// the user picks a host in the sidebar.
#if !UDHA_AGENT
    var remoteHost: RemoteHostClient?
#endif
    /// Retained for the (unused) exclusive mode; local and remote sessions now
    /// coexist in the store and actions route per session via `isRemote`.
    var suspended = false

    /// True when the session lives on the connected remote host.
    private func isRemote(_ id: UUID) -> Bool { stateStore.snapshot(id: id)?.hostName != nil }

    init(stateStore: SessionStateStore, config: ConfigStore, activity: ActivityLog) {
        self.stateStore = stateStore
        self.config = config
        self.activity = activity
        stateStore.loadAttention(from: AttentionAgent.directory.appendingPathComponent("inbox.json"))
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAttentionCommands() }
        }
        // Idle logins report nothing on their own; ask claude.ai on a slow
        // cadence so the pool ranks them on a reading rather than a guess.
        usageProbeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeLoginUsageIfDue() }
        }
        // The first pass as soon as the config has loaded — `AppCore` loads it
        // right after building this — not at the first tick: it is what names
        // every login in the pane before any reading exists.
        DispatchQueue.main.async { [weak self] in self?.probeLoginUsageIfDue() }

        // After a long sleep the per-session GCD poll timer and tail follower go
        // stale, so parked sessions stop being re-classified and their state
        // silently freezes. Rebuild each session's output plumbing on wake.
#if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWake() }
        }
#endif
    }

    private func handleSystemWake() {
        let live = Array(sessions.values)
        Log.pty.info("system woke — re-establishing output for \(live.count) sessions")
        // tmux/Apple-events work per session is synchronous; keep it off the main
        // thread so wake doesn't jank the UI. The classify callbacks hop back to
        // the main actor themselves.
        DispatchQueue.global(qos: .userInitiated).async {
            for session in live { session.handleSystemWake() }
        }
    }

    func restoreSessions() {
        pruneDeadConfigEntries()
        // Folders first, so `visible` is right from the very first insert: a
        // session filed in a hidden folder must never flash into the list.
        // A membership pointing at a folder that no longer exists is dropped
        // here rather than read around forever.
        let known = Set(config.config.sessionFolders.map(\.id))
        if config.config.sessions.contains(where: { $0.folderID.map { !known.contains($0) } ?? false }) {
            config.mutate { cfg in
                for i in cfg.sessions.indices where cfg.sessions[i].folderID.map({ !known.contains($0) }) ?? false {
                    cfg.sessions[i].folderID = nil
                }
            }
        }
        syncFolders()
        let live = TmuxSession.liveSessionNames() ?? []
        for cfg in config.config.sessions where cfg.enabled {
            // Only reattach to sessions whose tmux process is still alive.
            // After a computer restart the tmux server is gone, so spawning
            // would open a Terminal window per saved session — too noisy.
            let probe = TmuxSession(
                id: cfg.id,
                label: cfg.label,
                directory: cfg.directory,
                command: cfg.command,
                args: cfg.args
            )
            // A session renamed before this build kept its old tmux name; the
            // prune above already knows it by its uuid, so bring the name into
            // line before the probe or it is skipped as "not running".
            probe.repairName(live: live)
            guard probe.isAlive() else {
                Log.pty.info("skipping restore of \(cfg.label) — tmux session not running")
                continue
            }
            _ = try? spawn(sessionConfig: cfg)
        }
    }

    /// Drop persisted entries whose tmux session no longer exists.
    ///
    /// Only `removeSession(id:)` ever deleted from the config, so every session
    /// that ended any other way — reboot, tmux server restart, crash, quitting
    /// the app — left its entry behind forever. Those ghosts are invisible in
    /// the UI (the sidebar renders live snapshots) but they still occupy the
    /// namespace `uniqueLabel` checks, so each new session on a familiar folder
    /// collided with a dead one and got another numeric suffix bolted on.
    ///
    /// Liveness is matched on the uuid fragment rather than the full tmux name,
    /// because `rename` changes the label while leaving the tmux name alone.
    private func pruneDeadConfigEntries() {
        guard let liveNames = TmuxSession.liveSessionNames() else {
            Log.pty.info("skipping config prune — tmux is unreachable, can't tell dead from alive")
            return
        }
        let doomed = config.config.sessions.filter { cfg in
            guard cfg.enabled else { return false }   // parked on purpose; not garbage
            let suffix = "-" + TmuxSession.shortID(for: cfg.id)
            return !liveNames.contains { $0.hasSuffix(suffix) }
        }
        guard !doomed.isEmpty else { return }
        let doomedIDs = Set(doomed.map(\.id))
        config.mutate { $0.sessions.removeAll { doomedIDs.contains($0.id) } }
        Log.pty.info("pruned \(doomed.count) dead session entries; \(self.config.config.sessions.count) remain")
    }

    @discardableResult
    func changeAttention(id: UUID, action: String, eventID: String? = nil, enabled: Bool = false) -> Bool {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) {
            remoteHost.changeAttention(id: id, action: action, eventID: eventID, enabled: enabled)
            return true
        }
#endif
        return stateStore.changeAttention(id: id, action: action, eventID: eventID, enabled: enabled)
    }

    private func pollAttentionCommands() {
        for snap in stateStore.all where snap.hostName == nil {
            let box = AttentionAgent.mailbox(snap.id)
            guard let files = try? FileManager.default.contentsOfDirectory(at: box, includingPropertiesForKeys: nil) else { continue }
            for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(50) {
                guard let data = try? Data(contentsOf: file), data.count <= 16384,
                      let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let commandID = command["commandID"] as? String,
                      UUID(uuidString: commandID) != nil,
                      file.deletingPathExtension().lastPathComponent == commandID else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                let result = stateStore.processAttentionCommand(id: snap.id, command: command)
                if let response = try? JSONSerialization.data(withJSONObject: result) {
                    try? response.write(to: file.deletingPathExtension().appendingPathExtension("reply"), options: .atomic)
                }
                try? FileManager.default.removeItem(at: file)
            }
            // Replies whose agent went away do not accumulate forever.
            for file in files where file.pathExtension == "reply" {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) > 300 {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }


    func shutdownAll() {
        for s in sessions.values { s.detach() }
    }

    func buffer(for id: UUID) -> RingBuffer? {
        buffers[id]
    }

    func session(for id: UUID) -> TmuxSession? {
        sessions[id]
    }

    func spawn(sessionConfig: SessionConfig) throws -> UUID {
        let id = sessionConfig.id
        let buffer = RingBuffer(maxLines: 2000)

        // Install the hook + statusLine scripts and hand Claude the settings
        // file. Failure here is not fatal: the session still runs, it just falls
        // back to reading the pane.
        var sidecarPath: String? = nil
        if config.config.statusSidecarEnabled, sessionConfig.tool == .claude {
            do {
                try ClaudeStatusSidecar.install()
                // NB: the stale feed is cleared inside `TmuxSession.start()`,
                // which is the only place that knows whether we're launching a
                // new session or reattaching to one whose feed is still live.
                sidecarPath = ClaudeStatusSidecar.settingsPath.path
            } catch {
                Log.pty.error("sidecar install failed, falling back to pane reading: \(error.localizedDescription)")
            }
        }

        // Directory-scoped Claude login: `CLAUDE_CONFIG_DIR` relocates the whole
        // user-level config, credentials included, so the session runs as that
        // account. Injected at launch and never persisted into `SessionConfig`,
        // so re-pointing an account applies on the next spawn instead of being
        // frozen into the session. An explicit per-session `env` entry wins.
        var env = sessionConfig.env
        var launchArgs = sessionConfig.args
        var accountName: String? = nil
        if sessionConfig.tool == .claude, env["CLAUDE_CONFIG_DIR"] == nil,
           let account = ClaudeAccount.account(for: sessionConfig.directory,
                                               accounts: config.config.claudeAccounts) {
            // A tree with several logins: pick the one with the most headroom
            // for a fresh session, and stay on whichever the live process is
            // already on when this is a reattach.
            let chosen = chooseLogin(for: sessionConfig, account: account)
            env["CLAUDE_CONFIG_DIR"] = chosen
            sessionAccount[id] = chosen
            if account.pool.count > 1 {
                accountName = ClaudeAccountPool.shortName(chosen)
                launchArgs = ClaudeAccountPool.resolvingResume(launchArgs, directory: sessionConfig.directory,
                                                               primaryDir: account.pool[0], chosenDir: chosen)
                if sessionConfig.account.map(ClaudeAccountPool.normalized) != chosen {
                    config.mutate { cfg in
                        if let i = cfg.sessions.firstIndex(where: { $0.id == id }) { cfg.sessions[i].account = chosen }
                    }
                }
            }
            Log.pty.info("session \(sessionConfig.label) launching with CLAUDE_CONFIG_DIR=\(chosen)")
        }

        let session = TmuxSession(
            id: id,
            label: sessionConfig.label,
            directory: sessionConfig.directory,
            command: sessionConfig.command,
            args: launchArgs + ((try? AttentionAgent.arguments(for: sessionConfig.tool, sessionID: id)) ?? []),
            env: env,
            sidecarSettingsPath: sidecarPath
        )

        var snapshot = SessionSnapshot(
            id: id,
            label: sessionConfig.label,
            directory: sessionConfig.directory,
            state: .starting,
            stateEnteredAt: Date(),
            currentActivity: nil,
            pendingPrompt: nil,
            lastErrorMessage: nil,
            lastSpoken: nil,
            priority: sessionConfig.priority,
            exitCode: nil,
            agentName: sessionConfig.agentName,
            parentSessionID: sessionConfig.parentSessionID,
            branch: sessionConfig.branch,
            tool: sessionConfig.tool,
            tmuxName: session.tmuxName,
            folderID: sessionConfig.folderID,
            hidden: sessionConfig.hidden ?? false
        )
        snapshot.account = accountName
        stateStore.insert(snapshot)
        if session.isAlive(), let inputTime = ClaudeStatusSidecar.latestInputTime(for: id) {
            stateStore.beginAttentionTurn(id: id, at: inputTime)
        }

        let destructiveKeywords = config.config.notifications.destructiveKeywords

        session.onData = { [weak self] data in
            guard let self else { return }
            buffer.append(data)
            Task { @MainActor in
                self.lastOutputAt[id] = Date()
                self.handleOutput(id: id, buffer: buffer, destructiveKeywords: destructiveKeywords)
            }
        }

        session.onSnapshot = { [weak self] content in
            // Fan out the raw capture before classification so the mobile
            // bridge can forward frames without a second capture-pane poll.
            self?.onPaneCapture?(id, content)
            guard let self else { return }
            Task { @MainActor in
                self.handleSnapshot(id: id, content: content, destructiveKeywords: destructiveKeywords)
            }
        }

        session.onSizePinnedChange = { [weak self] pinned in
            Task { @MainActor in
                self?.stateStore.update(id: id) { $0.sizePinned = pinned }
            }
        }

        session.onSidecarLine = { [weak self] line in
            guard let self else { return }
            Task { @MainActor in
                self.handleSidecarLine(id: id, line: line)
            }
        }

        session.onExit = { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                self.stateStore.update(id: id) { snap in
                    snap.state = code == 0 ? .exited : .crashed
                    snap.exitCode = code
                    snap.stateEnteredAt = Date()
                }
                Log.pty.info("Session \(sessionConfig.label) exited code=\(code)")
            }
        }

        do {
            try session.start()
            sessions[id] = session
            buffers[id] = buffer
            stateStore.update(id: id) { $0.applyClassifiedState(.idle) }

            // Seed buffer with recent scrollback so restart doesn't lose history
            let scrollback = session.captureScrollback(maxLines: 200)
            if !scrollback.isEmpty {
                buffer.append(string: scrollback + "\n")
                Log.pty.info("seeded \(sessionConfig.label) with \(scrollback.count)B scrollback")
                // Classify the seeded content immediately. A session that was
                // already parked at a prompt BEFORE we attached produces no new
                // line events, so without this pass it sits unclassified until
                // fresh output happens to arrive.
                handleOutput(id: id, buffer: buffer, destructiveKeywords: destructiveKeywords)
            }

            startQuietTransitionTimer(for: id)
        } catch {
            stateStore.update(id: id) { $0.state = .crashed; $0.lastErrorMessage = "\(error)" }
            Log.pty.error("Failed to start session \(sessionConfig.label): \(error.localizedDescription)")
            throw error
        }

        return id
    }

    func terminateSession(id: UUID) {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) { remoteHost.interrupt(id: id); return }
#endif
        sessions[id]?.kill()
    }

    /// Hand a phone-shaped window back to whatever is attached to it. The
    /// phone normally does this itself on detach; this is the way out when it
    /// didn't — a dropped relay, an app swiped away mid-look — and the Mac's
    /// terminal is left letterboxed at 72 columns.
    func releaseWindowSize(id: UUID) {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) { remoteHost.releaseWindowSize(id: id); return }
#endif
        guard let session = sessions[id] else { return }
        session.releaseWindowSize()
        stateStore.update(id: id) { $0.sizePinned = false }
        onWindowSizeReleased?(id)
        Log.pty.info("released window size of \(session.tmuxName)")
    }

    func removeSession(id: UUID) {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) { remoteHost.close(id: id); stateStore.remove(id: id); return }
#endif
        if let session = sessions[id] {
            // Kill tmux AND close the Terminal window that was attached to it.
            // The AppleScript round-trips and settle sleep are blocking — keep
            // them off the main actor; the UI-facing cleanup below is instant.
            Task.detached(priority: .userInitiated) {
                session.killAndCloseTerminal()
            }
        }
        sessions.removeValue(forKey: id)
        buffers.removeValue(forKey: id)
        lastOutputAt.removeValue(forKey: id)
        pendingClassification.removeValue(forKey: id)
        sessionAccount.removeValue(forKey: id)
        lastLimitNotice.removeValue(forKey: id)
        lastRotationAt.removeValue(forKey: id)
        rotating.remove(id)
        stateStore.remove(id: id)
        config.mutate { $0.sessions.removeAll(where: { $0.id == id }) }
    }

    /// Returns true only if a live tmux session was found AND tmux accepted
    /// the keystrokes. Callers (especially voice tools) need this signal to
    /// avoid telling the user "done" when nothing was sent.
    @discardableResult
    func sendInput(id: UUID, text: String) -> Bool {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) { remoteHost.sendInput(id: id, text: text); return true }
#endif
        guard let session = sessions[id] else {
            Log.pty.error("sendInput: no live tmux session for id \(id.uuidString)")
            return false
        }
        let ok = session.sendInput(text: text)
        if ok {
            stateStore.beginAttentionTurn(id: id)
            activity.record(.sendInput(sessionID: id, text: text))
        }
        return ok
    }

    @discardableResult
    func sendRaw(id: UUID, text: String) -> Bool {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) { remoteHost.sendRawText(id: id, text: text); return true }
#endif
        guard let session = sessions[id] else {
            Log.pty.error("sendRaw: no live tmux session for id \(id.uuidString)")
            return false
        }
        return session.sendRaw(text: text)
    }

    @discardableResult
    func sendKey(id: UUID, key: String) -> Bool {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) { remoteHost.sendKey(id: id, key: key); return true }
#endif
        guard let session = sessions[id] else {
            Log.pty.error("sendKey: no live tmux session for id \(id.uuidString)")
            return false
        }
        return session.sendKey(key)
    }

    /// Raise a session's terminal if one is already open; never create one.
    /// Used when the selection changes in the main window, where popping a new
    /// SSH terminal for every row click would be far too aggressive.
#if !UDHA_AGENT
    func focusTerminalIfOpen(id: UUID) {
        if isRemote(id) {
            if let winID = remoteTerminalWindowID[id] {
                Task.detached(priority: .userInitiated) { _ = Self.raiseTerminalWindow(winID) }
            }
            stateStore.focusedSessionID = id
            return
        }
        showSession(id: id)
    }
#endif

    func showSession(id: UUID) {
        // A remote session lives in the host's tmux — open a local Terminal that
        // SSHes in and attaches to it, so "Open in Terminal" gives the same live
        // interactive session it does locally, just running on the box.
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) {
            if let snap = stateStore.snapshot(id: id), let host = snap.hostName ?? remoteHost.activeHostName {
                openRemoteTerminal(id: id, host: host, tmuxName: snap.tmuxTarget, label: Self.terminalTitle(host: host, directory: snap.directory,
                                                                    accountDir: ClaudeAccount.configDir(for: snap.directory,
                                                                                                        accounts: config.config.claudeAccounts)))
            }
            stateStore.focusedSessionID = id
            return
        }
#endif
        Log.pty.info("showSession: \(self.sessions[id]?.label ?? id.uuidString)")
        sessions[id]?.bringToFront()
        stateStore.focusedSessionID = id
    }

#if canImport(AppKit)
    /// Terminal windows Udha opened for remote sessions, by session id — so a
    /// second "Open in Terminal" raises the same window instead of duplicating.
    private var remoteTerminalWindowID: [UUID: String] = [:]

#if !UDHA_AGENT
    /// Last time we opened a terminal per remote session — a click that lands
    /// twice (overlay tap + selection change) must never open two windows.
    private var remoteTerminalOpenedAt: [UUID: Date] = [:]

    /// The line a Mac terminal runs to attach to a box's tmux session, and the
    /// part of it `ps` shows that identifies such a window. One place for
    /// both, or a window this build opens is one the next lookup can't find.
    /// The inner command is double-quoted so ssh hands it over whole, and the
    /// target single-quoted inside that for the remote shell; the AppleScript
    /// strings it lands in escape the double quotes themselves.
    nonisolated static func remoteAttachCommand(host: String, tmuxName: String) -> String {
        "ssh -t \(host) \"\(remoteAttachNeedle(tmuxName: tmuxName))\""
    }

    nonisolated static func remoteAttachNeedle(tmuxName: String) -> String {
        "tmux attach -t '\(tmuxName)'"
    }

    /// Open (or re-focus) Terminal.app attached to a remote session over SSH.
    ///
    /// Every AppleScript / `ps` round-trip runs off the main actor: walking all
    /// Terminal windows can take a while, and a blocked main thread is a
    /// beachball. Only the bookkeeping touches `self`, on the main actor.
    private func openRemoteTerminal(id: UUID, host: String, tmuxName: String, label: String) {
        if let last = remoteTerminalOpenedAt[id], Date().timeIntervalSince(last) < 2 {
            Log.pty.info("remote terminal: debounced duplicate open for \(tmuxName)")
            return
        }
        remoteTerminalOpenedAt[id] = Date()
        let known = remoteTerminalWindowID[id]
        Task.detached(priority: .userInitiated) { [weak self] in
            // 1. The window we opened earlier this run, if it's still around.
            if let known, Self.raiseTerminalWindow(known) { return }
            // 2. A window from a previous run (or opened by hand) still attached.
            if let existing = Self.findExistingRemoteWindowID(tmuxName: tmuxName) {
                await MainActor.run { self?.remoteTerminalWindowID[id] = existing }
                if Self.raiseTerminalWindow(existing) { return }
            }
            // 3. Nothing attached: open a new window.
            // The target is quoted for the *box's* shell: it may be a pattern
            // (`*-8c7c11ee`, see `tmuxTarget`), and zsh there would otherwise
            // try to glob it against the home directory and refuse.
            let cmd = Self.remoteAttachCommand(host: host, tmuxName: tmuxName)
            // …and once more for the AppleScript string literal it rides in.
            let script = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let open: String
            if Self.usesITerm {
                // iTerm2 bridges the box's clipboard to the Mac (OSC 52); Terminal
                // can't, so a session copy never reaches the Mac clipboard there.
                let title = label.replacingOccurrences(of: "\"", with: "")
                open = """
                tell application "iTerm"
                  activate
                  set w to (create window with default profile command "\(script)")
                  tell current session of w to set name to "\(title)"
                  return id of w
                end tell
                """
            } else {
                open = """
                tell application "Terminal"
                  activate
                  do script "\(script)"
                  return id of front window as string
                end tell
                """
            }
            let out = Self.runOsa(open)
            await MainActor.run {
                if let out, !out.isEmpty { self?.remoteTerminalWindowID[id] = out }
                else { self?.remoteTerminalWindowID[id] = nil }
            }
            Log.pty.info("remote terminal: opened \(cmd) → \(Self.usesITerm ? "iTerm" : "Terminal") window \(out ?? "nil")")
        }
    }

    /// Raise a Terminal window by id. Returns false if it no longer exists.
    nonisolated private static func raiseTerminalWindow(_ winID: String) -> Bool {
        let focus: String
        if usesITerm {
            focus = """
            tell application "iTerm"
              activate
              repeat with w in windows
                if ((id of w) as string) is "\(winID)" then
                  select w
                  return "ok"
                end if
              end repeat
              return "gone"
            end tell
            """
        } else {
            focus = """
            tell application "Terminal"
              try
                set w to (first window whose id is \(winID))
                activate
                set index of w to 1
                return "ok"
              end try
              return "gone"
            end tell
            """
        }
        let result = runOsa(focus)
        Log.pty.info("remote terminal: raise window \(winID) → \(result ?? "nil")")
        return result == "ok"
    }

    /// Find a Terminal window that is *already* running our SSH attach for this
    /// tmux session, by matching the local tty of the `ssh … tmux attach -t
    /// <name>` process to a Terminal tab. Unlike the in-memory map this survives
    /// an app relaunch — exactly when duplicates used to pile up. Mirrors how
    /// local sessions reclaim their windows (`attachedTTYs`).
    nonisolated private static func findExistingRemoteWindowID(tmuxName: String) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "tty=,command="]
        let out = Pipe(); ps.standardOutput = out; ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        // Drain BEFORE waiting: the full command list exceeds the pipe buffer,
        // and waiting first would deadlock against a blocked writer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let needle = Self.remoteAttachNeedle(tmuxName: tmuxName)
        guard let line = text.split(separator: "\n").first(where: { $0.contains(needle) && $0.contains("ssh") }),
              let tty = line.split(separator: " ", maxSplits: 1).first, tty != "??" else { return nil }
        let script: String
        if usesITerm {
            script = """
            tell application "iTerm"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with sess in sessions of t
                    try
                      if (tty of sess) is "/dev/\(tty)" then return ((id of w) as string)
                    end try
                  end repeat
                end repeat
              end repeat
              return ""
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if (tty of t) is "/dev/\(tty)" then return (id of w as string)
                  end try
                end repeat
              end repeat
              return ""
            end tell
            """
        }
        guard let found = runOsa(script), !found.isEmpty else { return nil }
        Log.pty.info("remote terminal: found existing window \(found) for \(tmuxName) via \(tty)")
        return found
    }

    /// The window title for a remote session: machine, the folder it runs in,
    /// and — when a directory-scoped Claude login applies — that account's
    /// config dir, so two logins are told apart at a glance.
    nonisolated static func terminalTitle(host: String, directory: String, accountDir: String?) -> String {
        let folder = (directory as NSString).lastPathComponent
        guard let accountDir, !accountDir.isEmpty else { return "\(host)  ·  \(folder)" }
        return "\(host)  ·  \(folder)  ·  \((accountDir as NSString).lastPathComponent)"
    }

    /// Prefer iTerm2 for remote sessions when it's installed — it bridges the
    /// box's clipboard to the Mac, which Terminal.app can't do.
    /// Open a terminal window running `command` — the sign-in for a new
    /// Claude login, which prints a URL and waits for a code, so it has to be
    /// somewhere you can type. `host` wraps it in `ssh -t` for a box.
    func openTerminal(running command: String, on host: String?, title: String) {
        // No quoting anywhere near the launcher: iTerm's `command` splits on
        // spaces with no shell, Terminal's `do script` goes through one, and
        // ssh re-joins whatever it is given for the remote shell to parse —
        // three parsers, and a nested quote survived none of them ("zsh:1:
        // unmatched '"). So the whole thing goes into a script file, run by
        // an interactive login zsh (rc files → `claude` on PATH). For a box
        // the script ships the real one over as base64 and runs it there the
        // same way. The pause at the end keeps a failure on screen.
        let body = "\(command)\necho\necho '── done — press Enter to close ──'\nread -r _\n"
        let stamp = String(UUID().uuidString.prefix(8)).lowercased()
        let local = "/tmp/udha/signin-\(stamp).sh"
        let text: String
        if let host {
            let b64 = Data(body.utf8).base64EncodedString()
            let remote = "/tmp/udha-signin-\(stamp).sh"
            text = "ssh -t \(host) \"echo \(b64) | base64 -d > \(remote); zsh -il \(remote); rm -f \(remote)\"\nrm -f \(local)\n"
        } else {
            text = body + "rm -f \(local)\n"
        }
        do {
            try FileManager.default.createDirectory(atPath: "/tmp/udha", withIntermediateDirectories: true)
            try text.write(toFile: local, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: local)
        } catch {
            Log.pty.error("account: could not write \(local): \(error.localizedDescription)")
            return
        }
        let full = "/bin/zsh -il \(local)"
        let script = full.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let safeTitle = title.replacingOccurrences(of: "\"", with: "")
        let open = Self.usesITerm
            ? """
              tell application "iTerm"
                activate
                set w to (create window with default profile command "\(script)")
                tell current session of w to set name to "\(safeTitle)"
              end tell
              """
            : """
              tell application "Terminal"
                activate
                do script "\(script)"
              end tell
              """
        Task.detached(priority: .userInitiated) {
            _ = Self.runOsa(open)
            Log.pty.info("account: opened a terminal for `\(full)`")
        }
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static var usesITerm: Bool {
        FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
    }

    /// Run an AppleScript and return its trimmed stdout. Reads before waiting.
    nonisolated private static func runOsa(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
#endif
#endif

    /// Spawn a second session pointing at the same directory / command / args
    /// as `sourceID`. The new session gets a fresh UUID and a unique label so
    /// voice commands and tmux session names stay unambiguous.
    @discardableResult
    func duplicate(sessionID sourceID: UUID) -> UUID? {
        // A remote session is duplicated by its host; the copy arrives over the
        // session feed, so there is no local id to return.
#if !UDHA_AGENT
        if let remoteHost, isRemote(sourceID) { remoteHost.duplicate(id: sourceID); return nil }
#endif
        guard let original = config.config.sessions.first(where: { $0.id == sourceID }) else {
            Log.pty.error("duplicate: no config for source \(sourceID.uuidString)")
            return nil
        }
        var copy = original
        copy.id = UUID()
        copy.label = uniqueLabel(basedOn: original.label)
        copy.enabled = true
        // The copy keeps the folder (that is where you were working) but
        // starts in plain sight: duplicating a hidden session is a request to
        // see it.
        copy.hidden = nil
        copy.args = SessionConfig.normalizedClaudeArgs(command: copy.command, args: copy.args)
        config.mutate { $0.sessions.append(copy) }
        do {
            return try spawn(sessionConfig: copy)
        } catch {
            Log.pty.error("duplicate: spawn failed for \(copy.label): \(error.localizedDescription)")
            // Roll back the config insert so we don't leave an orphaned entry.
            config.mutate { $0.sessions.removeAll { $0.id == copy.id } }
            return nil
        }
    }

    /// Rename a session everywhere the label lives: the live snapshot (drives
    /// all UI) and the persisted config. The tmux session name embeds the
    /// original label but is an internal identifier — it is left alone so the
    /// running session, its log pipe, and its Terminal window are undisturbed.
    /// Collisions get a numeric suffix, same as `duplicate`, so voice matching
    /// by label stays unambiguous.
    func rename(sessionID: UUID, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let snap = stateStore.snapshot(id: sessionID),
              trimmed != snap.label else { return }
        // A remote session is owned by its box: renaming it here would be
        // undone by the host's next sessions_delta. Send the rename over and
        // let the delta echo the new label back into the store.
#if !UDHA_AGENT
        if let remoteHost, isRemote(sessionID) {
            remoteHost.rename(id: sessionID, label: trimmed)
            return
        }
#endif
        let taken = Set(
            (config.config.sessions.filter { $0.id != sessionID }.map(\.label)
             + stateStore.all.filter { $0.id != sessionID }.map(\.label))
                .map { $0.lowercased() }
        )
        let final = taken.contains(trimmed.lowercased()) ? uniqueLabel(basedOn: trimmed) : trimmed
        stateStore.update(id: sessionID) { $0.label = final }
        config.mutate { cfg in
            if let idx = cfg.sessions.firstIndex(where: { $0.id == sessionID }) {
                cfg.sessions[idx].label = final
            }
        }
        // The tmux name is derived from the label everywhere — the restore
        // probe, the remote attach line — so it has to move with it, and the
        // snapshot has to carry the new one: it is what rides the wire as
        // `tmux`, and a desktop attaching to a box uses it verbatim.
        if let session = sessions[sessionID] {
            session.rename(to: final)
            stateStore.update(id: sessionID) { $0.tmuxName = session.tmuxName }
        }
        Log.pty.info("renamed session \(snap.label) → \(final)")
    }

    /// Launch an agent: spawn a fresh session (same pattern as `duplicate`) in
    /// the given directory running Claude, then inject the agent's pre-built
    /// prompt once the session has had a moment to come up. The new session is
    /// tagged with the agent's name so the UI can badge it and report when it
    /// finishes.
    ///
    /// `sourceSessionID`, when provided, supplies the working directory and
    /// command to clone (so "run an agent on this session" reuses its folder).
    /// Otherwise `directory` is used with the default `claude` command.
    @discardableResult
    func runAgent(_ agent: Agent, sourceSessionID: UUID? = nil, directory: String? = nil) -> UUID? {
        let dir: String
        let command: String
        let args: [String]
        let env: [String: String]
        var parentID: UUID? = nil
        var folderID: UUID? = nil
        if let sourceID = sourceSessionID,
           let src = config.config.sessions.first(where: { $0.id == sourceID }) {
            dir = directory ?? src.directory
            // An agent run sits in the folder it was launched from.
            folderID = src.folderID
            command = src.command
            args = SessionConfig.normalizedClaudeArgs(command: src.command, args: src.args)
            env = src.env
            // Nest one level deep: if the source is itself an agent run, attach
            // to its parent so all runs for a project sit under that project.
            parentID = src.parentSessionID ?? src.id
        } else if let directory {
            dir = directory
            command = "claude"
            args = SessionConfig.defaultClaudeArgs
            env = [:]
        } else {
            Log.pty.error("runAgent: no source session and no directory")
            return nil
        }

        let folderName = (dir as NSString).lastPathComponent
        var cfg = SessionConfig(
            label: uniqueLabel(basedOn: "\(agent.name) · \(folderName)"),
            directory: dir,
            command: command,
            args: args
        )
        cfg.env = env
        cfg.agentName = agent.name
        cfg.parentSessionID = parentID
        cfg.folderID = folderID
        config.mutate { $0.sessions.append(cfg) }

        do {
            let id = try spawn(sessionConfig: cfg)
            schedulePrompt(sessionID: id, prompt: agent.prompt)
            return id
        } catch {
            Log.pty.error("runAgent: spawn failed for \(cfg.label): \(error.localizedDescription)")
            config.mutate { $0.sessions.removeAll { $0.id == cfg.id } }
            return nil
        }
    }

    /// Wait for the freshly-spawned Claude session to boot, then paste + submit
    /// the prompt. The blocking tmux/paste work runs off the main actor.
    ///
    /// Used by both `runAgent` and `create_session`'s optional first prompt.
    /// Polls for the session to leave `.starting` rather than sleeping a fixed
    /// interval: a cold `claude` on a large repo can take well over the old 4s,
    /// and a paste that lands before the input box is drawn is silently lost —
    /// which is far more visible when a human typed the prompt on their phone.
    func schedulePrompt(sessionID: UUID, prompt: String) {
        guard !prompt.isEmpty else { return }
        Task { @MainActor [weak self] in
            // Wait for the input box, but never hang: after the ceiling, paste
            // anyway — a late paste is recoverable, a dropped one is not.
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                guard let self else { return }
                guard let snap = self.stateStore.all.first(where: { $0.id == sessionID }) else { return }
                if snap.state != .starting { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // Claude draws its box a beat after the process reports ready.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, let session = self.sessions[sessionID] else { return }
            await Task.detached(priority: .userInitiated) {
                _ = session.sendPrompt(prompt)
            }.value
            self.activity.record(.sendInput(sessionID: sessionID, text: "[first prompt sent]"))
            Log.pty.info("injected prompt into session \(sessionID.uuidString)")
        }
    }

    /// Append a numeric suffix to keep session labels unique across the live
    /// store and the persisted config. Voice agent's `snapshot(matching:)`
    /// returns nil on ambiguous matches, so duplicate labels would silently
    /// break "send y to foo" style commands.
    /// The suffix is counted from the *root* label, not from whatever was
    /// handed in: duplicating "scholar-health 2" yields "scholar-health 3", not
    /// "scholar-health 2 2". Without this the counter compounded on every
    /// duplicate of a duplicate ("geo-visibility 3 2 2").
    /// The label a *new* session should carry when the caller wants `desired`.
    /// Returns `desired` untouched when nothing else answers to it, and only
    /// falls back to a numeric suffix on a real collision — two sessions
    /// sharing a name make every by-label lookup (voice tools, the sidebar,
    /// the tmux name) ambiguous.
    func availableLabel(_ desired: String) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return uniqueLabel(basedOn: "session") }
        let taken = Set(
            (config.config.sessions.map(\.label) + stateStore.all.map(\.label))
                .map { $0.lowercased() }
        )
        return taken.contains(trimmed.lowercased()) ? uniqueLabel(basedOn: trimmed) : trimmed
    }

    private func uniqueLabel(basedOn base: String) -> String {
        let root = Self.labelRoot(of: base)
        let taken = Set(
            (config.config.sessions.map { $0.label } + stateStore.all.map { $0.label })
                .map { $0.lowercased() }
        )
        var n = 2
        while taken.contains("\(root) \(n)".lowercased()) { n += 1 }
        return "\(root) \(n)"
    }

    /// Strip trailing " <number>" groups so an already-suffixed label — or a
    /// historically mangled one like "geo-visibility 3 2 2" — collapses back to
    /// the name the user actually chose. Stops if stripping would leave nothing
    /// (a label that is only digits is its own root).
    static func labelRoot(of label: String) -> String {
        var root = label.trimmingCharacters(in: .whitespaces)
        while let sep = root.lastIndex(of: " ") {
            let tail = root[root.index(after: sep)...]
            guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { break }
            let head = root[..<sep].trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty else { break }
            root = head
        }
        return root
    }

    /// Reorder live sessions and mirror the order into the persisted config
    /// so it survives restart. Called by the overlay's and the board's
    /// drag-and-drop.
    ///
    /// A session on a box is owned by that box: its place in the list here is
    /// only a view, and `RemoteHostClient` rebuilds every one of its rows from
    /// a fresh `sessions_full` — in the *host's* order — each time the relay
    /// link cycles, which on a normal day is every half hour or so. So a
    /// dragged box row went back to where it started at the next reconnect,
    /// because nothing had told the box. Now the box's rows are re-read in
    /// their new relative order and sent over as `reorder_sessions`; the agent
    /// runs `setOrder` on its own store and config, and the order it answers a
    /// reconnect with is the one you dragged into.
    func reorder(movingID: UUID, before targetID: UUID) {
        stateStore.reorder(movingID: movingID, before: targetID)
#if !UDHA_AGENT
        if let remoteHost, let host = stateStore.snapshot(id: movingID)?.hostName {
            remoteHost.reorder(order: stateStore.all.filter { $0.hostName == host }.map(\.id))
            return
        }
#endif
        persistOrder()
    }

    /// Apply an order a client dragged into — the whole list for this machine,
    /// as `reorder_sessions` carries it. Ids this machine doesn't know are
    /// skipped and anything unlisted keeps its place behind them, so a stale
    /// list from a client that missed a spawn or a close still lands cleanly.
    func setOrder(_ ids: [UUID]) {
        stateStore.setOrder(ids)
        persistOrder()
    }

    /// Mirror the store's order into `config.sessions`, which is what
    /// `start()` spawns from — so the order survives a restart on this machine
    /// and is the order `sessions_full` reports to every client.
    private func persistOrder() {
        let order = stateStore.orderedIDs
        config.mutate { cfg in
            let byID = Dictionary(uniqueKeysWithValues: cfg.sessions.map { ($0.id, $0) })
            var rebuilt: [SessionConfig] = []
            var seen = Set<UUID>()
            for id in order {
                if let s = byID[id] {
                    rebuilt.append(s)
                    seen.insert(id)
                }
            }
            // Defensive: keep any config-only entries (e.g. disabled, never spawned)
            // in their original slots at the tail so we don't lose them.
            for s in cfg.sessions where !seen.contains(s.id) {
                rebuilt.append(s)
            }
            cfg.sessions = rebuilt
        }
    }

    // MARK: - Folders + hidden

    // Owned by the supervising machine, the way a label is. Every func below
    // routes the same way `rename` does: a remote session or a remote host's
    // folder is forwarded to that host and the store is left alone — the
    // host's delta (row flags) or full push (folder list) is the echo that
    // lands, and `insert` replaces the whole snapshot anyway, so a local edit
    // would only be clobbered. Local edits persist to config and mirror into
    // the store, whose hooks push them to every client.

    /// The one place this machine's folder list is published.
    private func syncFolders() {
        stateStore.setFolders(config.config.sessionFolders, host: nil)
    }

    /// File a session in a folder on its own machine; nil = loose. False when
    /// the folder does not exist on that machine.
    @discardableResult
    func setFolder(sessionID: UUID, folderID: UUID?) -> Bool {
#if !UDHA_AGENT
        if let remoteHost, isRemote(sessionID) {
            remoteHost.setSessionFolder(id: sessionID, folder: folderID)
            return true
        }
#endif
        if let folderID, !config.config.sessionFolders.contains(where: { $0.id == folderID }) { return false }
        guard stateStore.snapshot(id: sessionID) != nil
                || config.config.sessions.contains(where: { $0.id == sessionID }) else { return false }
        stateStore.update(id: sessionID) { $0.folderID = folderID }
        config.mutate { cfg in
            if let i = cfg.sessions.firstIndex(where: { $0.id == sessionID }) { cfg.sessions[i].folderID = folderID }
        }
        return true
    }

    @discardableResult
    func setHidden(sessionID: UUID, hidden: Bool) -> Bool {
#if !UDHA_AGENT
        if let remoteHost, isRemote(sessionID) {
            remoteHost.setSessionHidden(id: sessionID, hidden: hidden)
            return true
        }
#endif
        guard stateStore.snapshot(id: sessionID) != nil
                || config.config.sessions.contains(where: { $0.id == sessionID }) else { return false }
        stateStore.update(id: sessionID) { $0.hidden = hidden }
        config.mutate { cfg in
            if let i = cfg.sessions.firstIndex(where: { $0.id == sessionID }) { cfg.sessions[i].hidden = hidden ? true : nil }
        }
        return true
    }

    /// Create a folder at the top of `host`'s list (nil = this machine). The
    /// caller supplies the id so it can start renaming the row before a remote
    /// host has echoed it; an id that already exists is left as it is.
    @discardableResult
    func createFolder(id: UUID = UUID(), name: String, host: String? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
#if !UDHA_AGENT
        if let host, let remoteHost {
            remoteHost.createFolder(id: id, name: name)
            return true
        }
#endif
        if config.config.sessionFolders.contains(where: { $0.id == id }) { return true }
        config.mutate { $0.sessionFolders.insert(SessionFolder(id: id, name: name), at: 0) }
        syncFolders()
        return true
    }

    @discardableResult
    func renameFolder(id: UUID, to name: String, host: String? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
#if !UDHA_AGENT
        if let host, let remoteHost {
            remoteHost.renameFolder(id: id, name: name)
            return true
        }
#endif
        guard let i = config.config.sessionFolders.firstIndex(where: { $0.id == id }) else { return false }
        config.mutate { $0.sessionFolders[i].name = name }
        syncFolders()
        return true
    }

    /// Ungroup: the folder goes, its sessions stay and become loose.
    @discardableResult
    func deleteFolder(id: UUID, host: String? = nil) -> Bool {
#if !UDHA_AGENT
        if let host, let remoteHost {
            remoteHost.deleteFolder(id: id)
            return true
        }
#endif
        guard config.config.sessionFolders.contains(where: { $0.id == id }) else { return false }
        config.mutate { cfg in
            cfg.sessionFolders.removeAll { $0.id == id }
            for i in cfg.sessions.indices where cfg.sessions[i].folderID == id { cfg.sessions[i].folderID = nil }
        }
        for s in stateStore.all where s.hostName == nil && s.folderID == id {
            stateStore.update(id: s.id) { $0.folderID = nil }
        }
        syncFolders()
        return true
    }

    @discardableResult
    func setFolderHidden(id: UUID, hidden: Bool, host: String? = nil) -> Bool {
#if !UDHA_AGENT
        if let host, let remoteHost {
            remoteHost.setFolderHidden(id: id, hidden: hidden)
            return true
        }
#endif
        guard let i = config.config.sessionFolders.firstIndex(where: { $0.id == id }) else { return false }
        config.mutate { $0.sessionFolders[i].hidden = hidden }
        syncFolders()
        return true
    }

    /// Impose a folder order on `host` (nil = this machine): the known ids
    /// come first in the given order, anything left out keeps its place
    /// behind them — the same rule as `setOrder` for sessions.
    @discardableResult
    func setFolderOrder(_ ids: [UUID], host: String? = nil) -> Bool {
#if !UDHA_AGENT
        if let host, let remoteHost {
            remoteHost.reorderFolders(order: ids)
            return true
        }
#endif
        let current = config.config.sessionFolders
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var next: [SessionFolder] = []
        var seen = Set<UUID>()
        for id in ids where byID[id] != nil && !seen.contains(id) {
            next.append(byID[id]!)
            seen.insert(id)
        }
        for f in current where !seen.contains(f.id) { next.append(f) }
        guard next != current else { return false }
        config.mutate { $0.sessionFolders = next }
        syncFolders()
        return true
    }

    /// Insert on either edge of the target, including after the last folder.
    func reorderFolder(movingID: UUID, before targetID: UUID, host: String? = nil, after: Bool = false) {
        let ids = stateStore.folders(host: host).map(\.id)
        setFolderOrder(SessionFolder.reordered(ids, moving: movingID, target: targetID, after: after), host: host)
    }

    /// Bring back every hidden folder and session on `host` (nil = this
    /// machine). The footer calls it for every machine it knows.
    func unhideAll(host: String? = nil) {
#if !UDHA_AGENT
        if let host, let remoteHost {
            remoteHost.unhideAll()
            return
        }
#endif
        config.mutate { cfg in
            for i in cfg.sessionFolders.indices { cfg.sessionFolders[i].hidden = false }
            for i in cfg.sessions.indices { cfg.sessions[i].hidden = nil }
        }
        for s in stateStore.all where s.hostName == nil && s.hidden {
            stateStore.update(id: s.id) { $0.hidden = false }
        }
        syncFolders()
    }

    /// True when the session runs an assistant that is *not* Claude, so
    /// `ClaudePaneReader` must not be pointed at its pane.
    ///
    /// This is not paranoia about a stray match. Qwen Code paints
    /// "shift + tab to cycle" in its footer, which is one of the three markers
    /// the reader anchors on — so without this it identifies a Qwen pane as
    /// Claude's, and then reads it with Claude's vocabulary: Qwen says "esc to
    /// cancel" where Claude says "esc to interrupt", so `isStreaming` is never
    /// true and every working session reads as a turn that has just ended.
    /// The card says Ready while the model types, and the voice engine
    /// announces a completion each time. A session whose tool we know is not
    /// Claude belongs on the generic classifier, exactly where ChatGPT is.
    private func usesForeignTUI(_ id: UUID) -> Bool {
        guard let tool = stateStore.snapshot(id: id)?.tool else { return false }
        return tool != .claude
    }

    private func handleSnapshot(id: UUID, content: String, destructiveKeywords: [String]) {
        guard !suspended else { return }
        // `content` is raw `capture-pane -pe` output. Read the Claude TUI chrome
        // from it first — when this is a Claude session the pane is the
        // authoritative source and the regex classifier below is skipped
        // entirely.
        let reading = usesForeignTUI(id) ? PaneReading() : ClaudePaneReader.read(raw: content)
        // An overlay (the `/btw` panel, transcript scroller, fork picker) hides
        // every signal. Freeze on the last known phase rather than guessing —
        // treating a covered pane as "not streaming" would latch a false turn
        // end for anyone who scrolls back mid-run.
        if reading.isObscured { return }
        if reading.isClaudeTUI {
            let plain = content.components(separatedBy: "\n").map { RingBuffer.stripANSI($0) }
            applyPaneReading(
                id: id, reading: reading, plain: plain, destructiveKeywords: destructiveKeywords
            )
            return
        }
        // Claude is genuinely gone (quit back to a shell, or this was never a
        // Claude session). Drop the sticky flag so the generic classifier fully
        // takes over again, and clear the phase it left behind — otherwise the
        // card would keep advertising "Ready" for a shell prompt.
        if paneTrackers[id]?.sawClaudeChrome == true {
            paneTrackers[id]?.sawClaudeChrome = false
            paneTrackers[id]?.sawStreaming = false
            stateStore.update(id: id) { $0.setPhase(.idle, detail: nil) }
        }
        paneTrackers[id]?.quietCaptures = 0

        // Snapshot from tmux capture-pane — contains the current visible pane.
        var lines = content.components(separatedBy: "\n")
            .map { line in RingBuffer.stripANSI(line) }
        // capture-pane returns the full pane GRID, including the blank rows
        // below a short-output CLI session's cursor. The classifier only looks
        // at the last ~15 lines, so without trimming, a plain script's prompt
        // sits above a wall of empty rows and never matches. (TUI apps like
        // Claude Code fill the pane bottom, which is why this only bit
        // non-TUI sessions.)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        runClassifier(id: id, lines: lines, destructiveKeywords: destructiveKeywords)
    }

    private func handleOutput(id: UUID, buffer: RingBuffer, destructiveKeywords: [String]) {
        guard !suspended else { return }
        // The `pipe-pane` log is a redraw torrent for a TUI: ANSI-stripped it
        // reads `✻thinking with xhigh effort✢a72577…`, the footer never survives
        // in it, and it also captures the user's own shell commands. That means
        // the idle-veto in `OutputClassifier` can never match here, so any
        // prompt-shaped text scrolling past flips the session to `needsInput` —
        // the source of the needsInput⇄working flapping in udha.log. Once the
        // pane reader has identified a Claude TUI, this path is dead weight.
        if paneTrackers[id]?.sidecarActive == true || isClaudeTUI(id)
            || stateStore.snapshot(id: id)?.tool == .codex { return }
        let lines = buffer.recent(lines: 80)
        runClassifier(id: id, lines: lines, destructiveKeywords: destructiveKeywords)
    }

    /// True once a `capture-pane` read has recognised Claude's chrome.
    private func isClaudeTUI(_ id: UUID) -> Bool {
        paneTrackers[id]?.sawClaudeChrome == true
    }

    // MARK: - Pane-driven status

    /// Turn a `PaneReading` into a phase + state. This is the path every Claude
    /// session takes, including ones that were already running before Udha
    /// launched.
    private func applyPaneReading(
        id: UUID, reading: PaneReading, plain: [String], destructiveKeywords: [String]
    ) {
        var tracker = paneTrackers[id] ?? PaneTracker()
        tracker.sawClaudeChrome = true

        if reading.isStreaming {
            tracker.sawStreaming = true
            tracker.quietCaptures = 0
        } else {
            // Require two consecutive quiet captures (~4s) before calling the
            // turn over. A capture landing mid-repaint can transiently miss
            // "esc to interrupt", and a one-frame glitch must not stamp a false
            // turn end.
            tracker.quietCaptures += 1
        }
        if !tracker.sidecarActive {
            tracker.subagents = reading.subagents.count
        }
        paneTrackers[id] = tracker

        // The usage-limit notice is pane-only: no hook reports the limit being
        // hit, so this has to run whether or not the sidecar owns the phase.
        if let notice = reading.usageLimit { noteUsageLimit(id: id, notice: notice) }

        // A hook feed is exact where this is inferred — let it own the phase.
        guard !tracker.sidecarActive else {
            stateStore.update(id: id) { snap in
                snap.subagentCount = tracker.subagents
                if let q = reading.question { snap.lastQuestion = q }
                // The hook feed reports *that* a dialog is up, never what is on
                // it. Reading the choices is the pane's job either way.
                snap.dialogOptions = reading.options
            }
            return
        }

        let turnEnded = tracker.quietCaptures >= 2
            && (tracker.sawStreaming || reading.finishedDuration != nil)

        let phase: SessionPhase
        var detail: String?
        if reading.hasDialog {
            phase = .awaitingApproval
            detail = nil
        } else if reading.isStreaming {
            if reading.permissionMode == .plan {
                phase = .planning
                detail = reading.spinnerDetail
            } else if let tool = reading.toolName, !reading.isThinking {
                phase = .usingTool
                detail = toolPhrase(name: tool, args: reading.toolArgs)
            } else {
                phase = .thinking
                detail = reading.spinnerDetail
            }
        } else if turnEnded {
            phase = .awaitingReply
            detail = reading.finishedDuration.map { "done in \($0)" }
        } else {
            phase = .idle
            detail = nil
        }

        let newState = state(for: phase)
        let previous = stateStore.snapshot(id: id)

        stateStore.update(id: id) { snap in
            snap.setPhase(phase, detail: detail)
            snap.subagentCount = tracker.subagents
            if let q = reading.question { snap.lastQuestion = q }
            snap.dialogOptions = reading.options
            if snap.state != newState {
                snap.state = newState
                snap.stateEnteredAt = Date()
            }
            if newState != .needsInput { snap.pendingPrompt = nil }
            snap.currentActivity = detail
        }

        // A live dialog is the one case where the pane text matters as text —
        // the voice tools need its style and destructiveness to answer it.
        if reading.hasDialog, previous?.pendingPrompt == nil {
            let classifier = OutputClassifier(destructiveKeywords: destructiveKeywords)
            if let prompt = classifier.classify(lines: plain).pendingPrompt {
                stateStore.update(id: id) { $0.pendingPrompt = prompt }
            }
        }

        if let previous, previous.phase != phase {
            Log.classify.info("phase: \(previous.label) \(previous.phase.rawValue) → \(phase.rawValue)")
        }
        refreshSidecarSnapshot(id: id)
    }

    /// Coarse state for a phase. `SessionState` keeps its exact existing
    /// meaning — the voice engine, tool handlers, menu bar and mobile bridge
    /// all switch on it, so widening it would change their behaviour.
    /// `awaitingReply` maps to `.idle`, which is what a finished turn has
    /// always been; only the *label* gets more precise.
    private func state(for phase: SessionPhase) -> SessionState {
        switch phase {
        case .thinking, .planning, .usingTool: return .working
        case .awaitingApproval:                return .needsInput
        case .awaitingReply, .idle:            return .idle
        case .starting:                        return .starting
        case .finished:                        return .exited
        }
    }

    private func toolPhrase(name: String, args: String?) -> String {
        let arg = args?.trimmingCharacters(in: .whitespaces)
        func firstArg() -> String? {
            guard let arg, !arg.isEmpty else { return nil }
            let head = arg.components(separatedBy: ",").first ?? arg
            return (head as NSString).lastPathComponent
        }
        switch name {
        case "Edit", "Write", "NotebookEdit":
            return firstArg().map { "Editing \($0)" } ?? "Editing"
        case "Read":
            return firstArg().map { "Reading \($0)" } ?? "Reading"
        case "Bash", "BashOutput":
            return firstArg().map { "Running \($0)" } ?? "Running a command"
        case "Grep", "Glob":
            return firstArg().map { "Searching \($0)" } ?? "Searching"
        case "WebFetch", "WebSearch":
            return "Researching"
        case "Task":
            return firstArg().map { "Delegating to \($0)" } ?? "Delegating"
        default:
            return name
        }
    }

    // MARK: - Sidecar-driven status

    /// One JSONL line from Claude's own hook feed. Exact where the pane reader
    /// infers: the tool name and its arguments come straight from `tool_input`.
    private func handleSidecarLine(id: UUID, line: String) {
        guard !suspended else { return }
        guard let event = ClaudeStatusSidecar.parseEvent(line: line) else { return }

        if event.name == "UserPromptSubmit" {
            stateStore.beginAttentionTurn(id: id, at: event.emittedAt ?? Date().timeIntervalSince1970)
        }
        if event.name == "Notification", event.notificationType == "quota_auto_resume_fired",
           let dir = loginDir(for: id) {
            // Claude waited the limit out itself: that login is open again.
            accountPool.clearLimited(dir)
            Log.pty.info("account: \(ClaudeAccountPool.shortName(dir)) usage limit reset (\(stateStore.snapshot(id: id)?.label ?? id.uuidString))")
        }
        var tracker = paneTrackers[id] ?? PaneTracker()
        tracker.sidecarActive = true
        switch event.name {
        case "SubagentStart": tracker.subagents += 1
        case "SubagentStop":  tracker.subagents = max(0, tracker.subagents - 1)
        case "Stop":          tracker.subagents = 0
        default: break
        }
        paneTrackers[id] = tracker

        guard let phase = event.phase else { return }
        let newState = state(for: phase)
        let subagents = tracker.subagents
        if let snap = stateStore.snapshot(id: id), snap.phase != phase {
            Log.classify.info(
                "phase[hook]: \(snap.label) \(snap.phase.rawValue) → \(phase.rawValue) (\(event.name))"
            )
        }

        stateStore.update(id: id) { snap in
            snap.setPhase(phase, detail: event.detail)
            snap.subagentCount = subagents
            snap.currentActivity = event.detail
            // SessionEnd is reported by the exit watcher with a real exit code;
            // don't pre-empt it with a synthesised terminal state.
            if phase != .finished, snap.state != newState {
                snap.state = newState
                snap.stateEnteredAt = Date()
            }
            if newState != .needsInput { snap.pendingPrompt = nil }
        }
        refreshSidecarSnapshot(id: id)
    }

    /// Pull the latest statusLine payload — context window usage and spend.
    /// The file is rewritten in place by the script, so this is a cheap read of
    /// a few KB rather than a growing log.
    private func refreshSidecarSnapshot(id: UUID) {
        guard paneTrackers[id]?.sidecarActive == true,
              let snapshot = ClaudeStatusSidecar.readSnapshot(for: id) else { return }
        stateStore.update(id: id) { snap in
            snap.contextPercent = snapshot.contextPercent
            snap.costCents = snapshot.costCents
            snap.model = snapshot.model
        }
        // A session started before this build, or outside Udha, never told us
        // its login; its transcript path does (`<config dir>/projects/…`).
        if sessionAccount[id] == nil, let path = snapshot.transcriptPath,
           let dir = ClaudeAccountPool.configDir(fromTranscriptPath: path) {
            sessionAccount[id] = dir
        }
        if let limits = snapshot.rateLimits, let dir = sessionAccount[id] {
            accountPool.record(limits, for: dir)
        }
    }

    private func runClassifier(id: UUID, lines: [String], destructiveKeywords: [String]) {
        let classifier = OutputClassifier(destructiveKeywords: destructiveKeywords)
        guard let snap = stateStore.snapshot(id: id) else { return }
        var result = snap.tool == .codex
            ? classifier.classifyCodexPane(lines: lines)
            : classifier.classify(lines: lines)

        // Output-recency fallback: Claude Code's "esc to interrupt" marker is
        // intermittent (disappears during tool calls and frame redraws), so the
        // rule-based classifier frequently returns nil mid-stream. If pipe-pane
        // output arrived in the last 3s and no terminal state was matched, the
        // session is actively producing → treat it as working. This prevents
        // the "says idle while Claude is clearly streaming" bug.
        if snap.tool != .codex, result.state == nil,
           let last = lastOutputAt[id],
           Date().timeIntervalSince(last) < 3.0,
           snap.state != .needsInput {
            result.state = .working
        }

        // Stability filter: don't transition on first observation of a new state.
        // Require it to be seen for >=1.5s OR 2 consecutive identical classifications.
        // This kills the oscillation we were seeing. Exception: `.working` transitions
        // apply instantly — "actively streaming right now" is a fleeting signal; if
        // we wait 1.5s we miss it entirely on short bursts.
        if let newState = result.state, newState != snap.state {
            if newState == .working {
                applyClassification(id: id, newState: newState, result: result, snap: snap)
                pendingClassification.removeValue(forKey: id)
                restartQuietTransitionTimer(for: id)
                return
            }
            let now = Date()
            if let pending = pendingClassification[id], pending.state == newState {
                if now.timeIntervalSince(pending.seenAt) >= 1.5 {
                    applyClassification(id: id, newState: newState, result: result, snap: snap)
                    pendingClassification.removeValue(forKey: id)
                }
            } else {
                pendingClassification[id] = (newState, now)
            }
        } else {
            pendingClassification.removeValue(forKey: id)
            // State is unchanged, but details within the state may have moved —
            // a new prompt text while still in .needsInput, a new error line
            // while still in .errored. Propagate these so downstream (UI + the
            // proactive voice engine) can notice successive events that don't
            // cross a state boundary.
            stateStore.update(id: id) { s in
                if let classified = result.state {
                    s.applyClassifiedState(classified, activity: result.activity)
                }
                if s.state == .needsInput, let prompt = result.pendingPrompt,
                   prompt.text != s.pendingPrompt?.text {
                    s.pendingPrompt = prompt
                }
                if s.state == .errored, let err = result.errorMessage, err != s.lastErrorMessage {
                    s.lastErrorMessage = err
                }
                if let q = result.question, q != s.lastQuestion { s.lastQuestion = q }
            }
        }

        if let last = lastOutputAt[id], Date().timeIntervalSince(last) < 3 {
            restartQuietTransitionTimer(for: id)
        }
    }

    private func applyClassification(id: UUID, newState: SessionState, result: ClassifierResult, snap: SessionSnapshot) {
        let oldState = snap.state.rawValue
        let label = snap.label
        Log.classify.info("classifier: \(label) \(oldState) → \(newState.rawValue)")
        stateStore.update(id: id) { s in
            s.applyClassifiedState(newState, activity: result.activity)
            if let prompt = result.pendingPrompt { s.pendingPrompt = prompt }
            if newState != .needsInput {
                s.pendingPrompt = nil
            }
            if let err = result.errorMessage { s.lastErrorMessage = err }
            // A TUI with no hook feed says what it is waiting on through the
            // classifier; a new turn (working) clears the old question.
            if newState == .working { s.lastQuestion = nil }
            else if let q = result.question { s.lastQuestion = q }
        }
    }


    private func startQuietTransitionTimer(for id: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: .never)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.quietTransition(for: id)
            }
        }
        timer.resume()
        quietTimers[id] = timer
    }

    private func restartQuietTransitionTimer(for id: UUID) {
        quietTimers[id]?.cancel()
        startQuietTransitionTimer(for: id)
    }

    private func quietTransition(for id: UUID) {
        // Claude sessions are driven by the 2s pane poll (or the hook feed),
        // both of which report "still streaming" positively. This timer exists
        // only to rescue non-TUI sessions whose output simply stopped.
        guard !isClaudeTUI(id), paneTrackers[id]?.sidecarActive != true,
              stateStore.snapshot(id: id)?.tool != .codex else { return }
        stateStore.update(id: id) { snap in
            if snap.state == .working {
                snap.applyClassifiedState(.idle)
            }
        }
    }

    // MARK: - Prompt approval / priority

    /// Answer whatever prompt a session is stuck on, matching its style.
    ///
    /// These two used to live in the voice agent's `ToolHandlers` and were
    /// reached from the UI through `tools.invoke(name:)`. That layer went with
    /// the voice feature, but the buttons on the session card did not, so the
    /// behaviour moved to the object that already owns sending keys.
    @discardableResult
    // MARK: - Claude logins (usage-limit failover)

    /// Which login a fresh or reattached session should run under.
    private func chooseLogin(for sessionConfig: SessionConfig, account: ClaudeAccount) -> String {
        let pool = account.pool
        guard pool.count > 1 else { return pool[0] }
        let remembered = sessionConfig.account.map(ClaudeAccountPool.normalized)
        // A live process is on whatever it was started with; changing the
        // env of a reattach changes nothing and would mislabel the row.
        let probe = TmuxSession(id: sessionConfig.id, label: sessionConfig.label, directory: sessionConfig.directory,
                                command: sessionConfig.command, args: sessionConfig.args)
        if probe.isAlive() {
            return remembered.flatMap { pool.contains($0) ? $0 : nil } ?? pool[0]
        }
        guard config.config.accountFailover.startOnLeastUsed else {
            return remembered.flatMap { pool.contains($0) ? $0 : nil } ?? pool[0]
        }
        let chosen = accountPool.choose(from: pool) ?? pool[0]
        if pool.count > 1 {
            Log.pty.info("account: \(sessionConfig.label) starts on \(accountPool.describe(chosen))")
        }
        return chosen
    }

    /// Fires when what is known about the logins changes — a probe landed, a
    /// session moved — so the bridge can push the `accounts` reply unasked.
    var onAccountsUpdated: (() -> Void)?

    // MARK: Editing the pools

    /// Why a pool edit was refused, worded for the settings sheet.
    struct LoginEditError: Error, CustomStringConvertible {
        let description: String
    }

    /// Start a tree: `pathPrefix` runs under `configDir` from now on. The dir
    /// may not exist yet — "Sign in" makes it — but the tree must be new.
    func addClaudeTree(pathPrefix: String, configDir: String) throws {
        let prefix = pathPrefix.trimmingCharacters(in: .whitespaces)
        let dir = configDir.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty, !dir.isEmpty else { throw LoginEditError(description: "A tree needs a folder and a config dir.") }
        let key = ClaudeAccount.normalized(prefix)
        guard !config.config.claudeAccounts.contains(where: { ClaudeAccount.normalized($0.pathPrefix) == key }) else {
            throw LoginEditError(description: "\(prefix) already has a login pool.")
        }
        config.mutate { $0.claudeAccounts.append(ClaudeAccount(pathPrefix: prefix, configDir: dir)) }
        Log.pty.info("account: tree \(prefix) added, runs under \(ClaudeAccountPool.shortName(dir))")
        refreshLoginEmails()
        onAccountsUpdated?()
    }

    /// Forget a tree's pool. Nothing on disk is touched; sessions there go
    /// back to the default login on their next start.
    func removeClaudeTree(pathPrefix: String) throws {
        let key = ClaudeAccount.normalized(pathPrefix)
        guard config.config.claudeAccounts.contains(where: { ClaudeAccount.normalized($0.pathPrefix) == key }) else {
            throw LoginEditError(description: "No pool for \(pathPrefix).")
        }
        config.mutate { $0.claudeAccounts.removeAll { ClaudeAccount.normalized($0.pathPrefix) == key } }
        Log.pty.info("account: tree \(pathPrefix) removed")
        onAccountsUpdated?()
    }

    /// Add a login to a tree's pool: `~/.claude-<name>`, made to behave exactly
    /// like the tree's primary dir — settings, skills, plugins, agents,
    /// CLAUDE.md, history and (through one shared `projects/`) the same
    /// transcripts and memory are *linked*, never copied, and `.claude.json`
    /// is seeded from the primary's trust flags minus its account block. What
    /// this cannot do is sign in: that is `claude auth login` under the new
    /// dir, interactive, which the caller opens a terminal for. Returns the
    /// new dir. The same steps as `udha-agent/scripts/add-claude-login.sh`.
    @discardableResult
    func addClaudeLogin(pathPrefix: String, name: String) throws -> String {
        let key = ClaudeAccount.normalized(pathPrefix)
        guard let index = config.config.claudeAccounts.firstIndex(where: { ClaudeAccount.normalized($0.pathPrefix) == key }) else {
            throw LoginEditError(description: "No pool for \(pathPrefix).")
        }
        let suffix = Self.loginSuffix(from: name)
        guard !suffix.isEmpty else {
            throw LoginEditError(description: "Name the login — an email, or a short name; it becomes ~/.claude-<name>.")
        }
        let account = config.config.claudeAccounts[index]
        let base = ClaudeAccount.normalized(account.configDir)
        let new = ClaudeAccountPool.normalized("~/.claude-\(suffix)")
        guard !account.pool.contains(new) else { throw LoginEditError(description: "\(ClaudeAccountPool.shortName(new)) is already in this pool.") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: base) else {
            throw LoginEditError(description: "\(ClaudeAccountPool.shortName(base)) does not exist yet — sign the primary in first.")
        }
        do {
            try fm.createDirectory(atPath: new, withIntermediateDirectories: true)
            for item in ["projects", "settings.json", "skills", "plugins", "agents", "commands", "CLAUDE.md", "keybindings.json", "history.jsonl"] {
                let src = (base as NSString).appendingPathComponent(item)
                let dst = (new as NSString).appendingPathComponent(item)
                guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst),
                      (try? fm.destinationOfSymbolicLink(atPath: dst)) == nil else { continue }
                try fm.createSymbolicLink(atPath: dst, withDestinationPath: src)
            }
            let seed = (new as NSString).appendingPathComponent(".claude.json")
            if !fm.fileExists(atPath: seed),
               let basePath = ClaudeLoginOverview.claudeJSONPath(configDir: base),
               let data = fm.contents(atPath: basePath),
               var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for k in ["oauthAccount", "userID", "cachedExtraUsageDisabledReason", "hasAvailableSubscription", "subscriptionNoticeCount"] {
                    obj.removeValue(forKey: k)
                }
                obj["hasCompletedOnboarding"] = true
                let out = try JSONSerialization.data(withJSONObject: obj)
                fm.createFile(atPath: seed, contents: out, attributes: [.posixPermissions: 0o600])
            }
        } catch {
            throw LoginEditError(description: "Could not set up \(ClaudeAccountPool.shortName(new)): \(error.localizedDescription)")
        }
        config.mutate { cfg in
            var alts = cfg.claudeAccounts[index].alternates ?? []
            alts.append("~/.claude-\(suffix)")
            cfg.claudeAccounts[index].alternates = alts
        }
        Log.pty.info("account: \(ClaudeAccountPool.shortName(new)) added to the pool of \(account.pathPrefix) — sign it in")
        refreshLoginEmails()
        onAccountsUpdated?()
        return new
    }

    /// Drop a login from its pool. The primary cannot go this way (remove the
    /// tree instead); the dir and its sign-in stay on disk for later.
    func removeClaudeLogin(dir: String) throws {
        let key = ClaudeAccountPool.normalized(dir)
        guard let index = config.config.claudeAccounts.firstIndex(where: { $0.pool.contains(key) }) else {
            throw LoginEditError(description: "\(ClaudeAccountPool.shortName(key)) is not in any pool.")
        }
        guard ClaudeAccount.normalized(config.config.claudeAccounts[index].configDir) != key else {
            throw LoginEditError(description: "\(ClaudeAccountPool.shortName(key)) is the tree's primary login — remove the tree to drop it.")
        }
        config.mutate { cfg in
            cfg.claudeAccounts[index].alternates?.removeAll { ClaudeAccountPool.normalized($0) == key }
        }
        Log.pty.info("account: \(ClaudeAccountPool.shortName(key)) removed from the pool of \(config.config.claudeAccounts[index].pathPrefix)")
        onAccountsUpdated?()
    }

    /// The dir suffix for a login someone typed: an email keeps the part
    /// before the @ ("dev2@example.com" → "dev2"), a path loses its
    /// `~/.claude-` prefix, and anything but letters, digits, dashes, dots
    /// and underscores becomes a dash.
    nonisolated static func loginSuffix(from typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = text.firstIndex(of: "@") { text = String(text[..<at]) }
        for prefix in ["~/.claude-", ".claude-", "claude-"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        let cleaned = String(text.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    /// The command that signs a dir in, for a terminal: prints a URL, takes a
    /// code. With an email it is pre-filled, which is what `add-claude-login.sh`
    /// does too.
    static func signInCommand(configDir: String, email: String? = nil) -> String {
        var cmd = "CLAUDE_CONFIG_DIR=\(ClaudeAccountPool.normalized(configDir)) claude auth login"
        if let email, email.contains("@") { cmd += " --email \(email)" }
        return cmd
    }

    /// Every tree's logins as the UI shows them, for `fetch_accounts`.
    func poolOverviews() -> [ClaudeLoginPoolOverview] {
        config.config.claudeAccounts.map { account in
            ClaudeLoginPoolOverview(pathPrefix: ClaudeAccount.normalized(account.pathPrefix),
                                    members: accountPool.overview(of: account.pool))
        }
    }

    /// What the pane's login strip shows for a local session: which login it
    /// is on and every login its tree has, headroom included. Nil for a
    /// session that is not Claude's or whose tree has no configured login.
    func loginOverview(for id: UUID) -> (current: String?, members: [ClaudeLoginOverview])? {
        guard let cfg = config.config.sessions.first(where: { $0.id == id }), cfg.tool == .claude else { return nil }
        if let account = ClaudeAccount.account(for: cfg.directory, accounts: config.config.claudeAccounts) {
            return (loginDir(for: id).map(ClaudeAccountPool.normalized), accountPool.overview(of: account.pool))
        }
        // No configured login for this tree: it runs on the default `~/.claude`.
        // Still worth a strip — its statusLine reports the same usage — just
        // with nothing to switch to.
        let dir = loginDir(for: id).map(ClaudeAccountPool.normalized) ?? Self.defaultLoginDir
        return (dir, accountPool.overview(of: [dir]))
    }

    /// `~/.claude`, expanded — what every tree without a configured login runs on.
    static var defaultLoginDir: String { ClaudeAccountPool.normalized("~/.claude") }

    /// The default login's headroom, for the `accounts` reply: the row a box
    /// session outside every configured tree gets.
    func defaultLoginOverview() -> ClaudeLoginOverview {
        accountPool.overview(of: [Self.defaultLoginDir])[0]
    }

    /// The pool a session can move within, or nil when its tree has one login.
    func loginPool(for id: UUID) -> [String]? {
        guard let cfg = config.config.sessions.first(where: { $0.id == id }), cfg.tool == .claude,
              let account = ClaudeAccount.account(for: cfg.directory, accounts: config.config.claudeAccounts),
              account.pool.count > 1 else { return nil }
        return account.pool
    }

    /// The login a session is on right now, best knowledge first: what it was
    /// launched with, what the config remembers, what its transcript path
    /// says, else the pool's primary.
    private func loginDir(for id: UUID) -> String? {
        if let dir = sessionAccount[id] { return dir }
        guard let cfg = config.config.sessions.first(where: { $0.id == id }) else { return nil }
        if let dir = cfg.account { return ClaudeAccountPool.normalized(dir) }
        if let path = ClaudeStatusSidecar.latestTranscript(for: id)?.path,
           let dir = ClaudeAccountPool.configDir(fromTranscriptPath: path) { return dir }
        return ClaudeAccount.configDir(for: cfg.directory, accounts: config.config.claudeAccounts)
    }

    /// The pane shows Claude waiting out a usage limit. Mark that login spent
    /// until the clock it printed, and move the session if anywhere is open.
    private func noteUsageLimit(id: UUID, notice: PaneReading.UsageLimitNotice) {
        let now = Date()
        // One notice is one event: it stays painted until the reset, and a
        // process that was just respawned may briefly paint history.
        if let last = lastLimitNotice[id], last.text == notice.text, now.timeIntervalSince(last.at) < 600 { return }
        if let at = lastRotationAt[id], now.timeIntervalSince(at) < 60 { return }
        guard !rotating.contains(id) else { return }
        lastLimitNotice[id] = (notice.text, now)

        let label = stateStore.snapshot(id: id)?.label ?? id.uuidString
        let dir = loginDir(for: id)
        if let dir {
            // Claude's clock beats our guess; a five-hour window is the guess.
            let until = notice.resumesAt.flatMap { ClaudeAccountPool.parseResumeClock($0, now: now) }
                ?? now.addingTimeInterval(5 * 3600)
            accountPool.markLimited(dir, until: until)
        }
        Log.pty.info("account: \(label) hit its usage limit on \(dir.map(ClaudeAccountPool.shortName) ?? "?")"
                     + (notice.resumesAt.map { " (Claude would resume at \($0))" } ?? ""))
        guard config.config.accountFailover.enabled else { return }
        rotateAccount(id: id, reason: "usage limit")
    }

    /// Move a session to the login in its pool with the most headroom, keeping
    /// the conversation: the process is respawned in its own pane under the
    /// other `CLAUDE_CONFIG_DIR` with `--resume <transcript>`, then told to
    /// carry on. False when there is nothing to move to, nothing to resume, or
    /// the session is not a Claude session on a tree with several logins.
    /// `to` names a login in the pool to move to; nil lets the pool pick the
    /// emptiest. A named login is honoured even when it is known to be
    /// limited — you asked for it, and Claude's own auto-continue covers the
    /// wait — so the choice in the pane's menu means what it says.
    @discardableResult
    func rotateAccount(id: UUID, to target: String? = nil, reason: String = "requested") -> Bool {
#if !UDHA_AGENT
        if let remoteHost, isRemote(id) { remoteHost.rotateAccount(id: id, to: target); return true }
#endif
        let label = stateStore.snapshot(id: id)?.label ?? id.uuidString
        guard !rotating.contains(id) else { return false }
        guard let session = sessions[id], stateStore.snapshot(id: id)?.tool == .claude else {
            Log.pty.error("account: \(label) is not a live Claude session")
            return false
        }
        guard let pool = loginPool(for: id) else {
            Log.pty.error("account: \(label) has no login pool (see ClaudeAccount.alternates)")
            return false
        }
        let current = loginDir(for: id) ?? pool[0]
        let next: String
        if let target {
            let wanted = ClaudeAccountPool.normalized(target)
            guard pool.contains(wanted) else {
                Log.pty.error("account: \(label) — \(ClaudeAccountPool.shortName(wanted)) is not in this tree's pool")
                return false
            }
            guard wanted != current else { return false }
            next = wanted
        } else {
            guard let chosen = accountPool.choose(from: pool, avoiding: current), chosen != current else {
                Log.pty.error("account: \(label) has nowhere to go — every login is limited: "
                              + pool.map { accountPool.describe($0) }.joined(separator: ", "))
                activity.record(.error(description: "\(label): every Claude login is at its usage limit"))
                return false
            }
            next = chosen
        }
        guard let transcript = ClaudeStatusSidecar.latestTranscript(for: id) else {
            Log.pty.error("account: \(label) has no transcript on record — cannot resume it on another login")
            return false
        }

        rotating.insert(id)
        var env = session.env
        env["CLAUDE_CONFIG_DIR"] = next
        var args = session.args
        if let i = args.firstIndex(of: "--resume") {
            args.removeSubrange(i..<min(i + 2, args.count))
        }
        args += ["--resume", transcript.path]
        do {
            try session.respawn(env: env, args: args)
        } catch {
            rotating.remove(id)
            Log.pty.error("account: respawn of \(label) failed: \(error.localizedDescription)")
            return false
        }
        let from = ClaudeAccountPool.shortName(current), to = ClaudeAccountPool.shortName(next)
        sessionAccount[id] = next
        paneTrackers[id]?.sawStreaming = false
        paneTrackers[id]?.quietCaptures = 0
        config.mutate { cfg in
            if let i = cfg.sessions.firstIndex(where: { $0.id == id }) { cfg.sessions[i].account = next }
        }
        stateStore.update(id: id) { snap in
            snap.account = to
            snap.state = .starting
            snap.stateEnteredAt = Date()
            snap.setPhase(.starting, detail: "moving to \(to)")
            snap.currentActivity = "moving to \(to)"
            snap.pendingPrompt = nil
        }
        activity.record(.accountRotated(sessionID: id, from: from, to: to, reason: reason))
        Log.pty.info("account: \(label) \(from) → \(accountPool.describe(next)) (\(reason)), resuming \(transcript.sessionID)")
        onAccountsUpdated?()
        Task { await self.continueAfterRotation(id: id, session: session, label: label) }
        return true
    }

    /// Once the resumed Claude shows its prompt, hand it the continuation line.
    /// A dialog instead (workspace trust, a login prompt) is left for the
    /// attention flow: it is on screen and reported like any other.
    private func continueAfterRotation(id: UUID, session: TmuxSession, label: String) async {
        defer {
            rotating.remove(id)
            lastRotationAt[id] = Date()
        }
        let prompt = config.config.accountFailover.continuationPrompt
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard sessions[id] === session, session.isAlive() else {
                Log.pty.error("account: \(label) went away while resuming")
                return
            }
            let content = session.currentSnapshot() ?? ""
            let reading = ClaudePaneReader.read(raw: content)
            guard reading.isClaudeTUI, !reading.isObscured else { continue }
            if reading.hasDialog {
                Log.pty.info("account: \(label) resumed but stopped on a dialog — leaving it for you")
                return
            }
            guard !prompt.isEmpty else { return }
            let sent = await Task.detached(priority: .userInitiated) { session.sendPrompt(prompt) }.value
            if sent {
                stateStore.beginAttentionTurn(id: id)
                Log.pty.info("account: \(label) told to continue")
            } else {
                Log.pty.error("account: \(label) resumed, but the continuation prompt could not be sent")
            }
            return
        }
        Log.pty.error("account: \(label) resumed but never showed a prompt — check the pane")
    }

    /// Every login dir this machine knows: each configured tree's pool and
    /// the default `~/.claude`.
    private var knownLoginDirs: [String] {
        var seen = Set<String>()
        return (config.config.claudeAccounts.flatMap(\.pool) + [Self.defaultLoginDir])
            .filter { seen.insert($0).inserted }
    }

    private var emailRefreshInFlight = false

    /// Read who each login dir is signed in as, off the main actor — the
    /// `.claude.json` a box pre-trusts every project in runs to megabytes —
    /// and hand the answers to the pool. Runs at launch, with every usage
    /// probe, and once on demand when the pane meets a dir it has no email for.
    func refreshLoginEmails() {
        guard !emailRefreshInFlight else { return }
        emailRefreshInFlight = true
        let dirs = knownLoginDirs
        Task.detached(priority: .utility) { [weak self] in
            let found = dirs.map { ($0, ClaudeLoginOverview.readEmail(configDir: $0)) }
            await MainActor.run {
                guard let self else { return }
                var changed = false
                for (dir, email) in found where self.accountPool.emails[ClaudeAccountPool.normalized(dir)] != email {
                    self.accountPool.setEmail(email, for: dir)
                    changed = true
                }
                self.emailRefreshInFlight = false
                Log.pty.info("account emails [\(ObjectIdentifier(self).hashValue % 10000)]: " + found.map { "\(ClaudeAccountPool.shortName($0.0))=\($0.1 ?? "none")" }.joined(separator: ", "))
                if changed { self.onAccountsUpdated?() }
            }
        }
    }

    /// Ask claude.ai how full every pooled login is, on the configured cadence.
    private func probeLoginUsageIfDue() {
        let interval = config.config.accountFailover.usageProbeIntervalSeconds
        guard interval > 0, Date().timeIntervalSince(lastUsageProbeAt) >= interval else { return }
        lastUsageProbeAt = Date()
        // Emails ride the same cadence; the first pass at launch is what
        // names every login before any reading exists.
        refreshLoginEmails()
        // Every login, pooled or not: the per-model (Fable) cap only exists in
        // the probe's reply, and a single login deserves that number too. A
        // dir with no `.credentials.json` (the Mac keeps its token in the
        // Keychain) simply yields nothing.
        let dirs = knownLoginDirs
        guard !dirs.isEmpty else { return }
        // A login some session is running under renews its own token; never
        // rotate it from outside — Claude would be holding a dead refresh
        // token. Every other dir is idle, and idle is when tokens expire.
        let busy = Set(sessions.keys.compactMap { loginDir(for: $0) }.map(ClaudeAccountPool.normalized))
        Task {
            var lines: [String] = []
            for dir in Set(dirs).sorted() {
                if !busy.contains(ClaudeAccountPool.normalized(dir)),
                   let note = await ClaudeUsageProbe.refreshExpiredToken(configDir: dir) {
                    Log.pty.info("account: \(note)")
                    // A refused refresh means the login is dead until someone
                    // signs it in; say so in the strip rather than "no reading".
                    if note.contains("refused") || note.contains("sign it in again") || note.contains("sign ") && note.contains("again") {
                        accountPool.setNeedsSignIn(true, for: dir)
                    }
                }
                if let reading = await ClaudeUsageProbe.fetch(configDir: dir) {
                    accountPool.record(reading, for: dir)
                }
                lines.append(accountPool.describe(dir))
            }
            Log.pty.info("account usage [\(ObjectIdentifier(self).hashValue % 10000)]: " + lines.joined(separator: ", "))
            onAccountsUpdated?()
        }
    }

    func approvePrompt(id: UUID) -> Bool {
        guard let snap = stateStore.snapshot(id: id), let prompt = snap.pendingPrompt else { return false }
        let ok: Bool
        switch prompt.style {
        case .yesNo, .freeform:   ok = sendInput(id: id, text: "y")
        case .numbered:           ok = sendInput(id: id, text: "1")
        case .enterToContinue:    ok = sendKey(id: id, key: "Enter")
        }
        // Left in place when the keystroke fails: clearing it would hide a
        // session that is still stuck.
        guard ok else { return false }
        stateStore.update(id: id) { $0.pendingPrompt = nil }
        activity.record(.approvePrompt(sessionID: id, promptText: prompt.text))
        return true
    }

    /// Refuse whatever prompt a session is stuck on, matching its style.
    @discardableResult
    func rejectPrompt(id: UUID, reason: String? = nil) -> Bool {
        guard let snap = stateStore.snapshot(id: id), let prompt = snap.pendingPrompt else { return false }
        let ok: Bool
        switch prompt.style {
        case .yesNo, .freeform:   ok = sendInput(id: id, text: "n")
        case .numbered:           ok = sendInput(id: id, text: "2")
        case .enterToContinue:    ok = sendKey(id: id, key: "C-c")
        }
        guard ok else { return false }
        if let reason, !reason.isEmpty { _ = sendInput(id: id, text: reason) }
        stateStore.update(id: id) { $0.pendingPrompt = nil }
        activity.record(.rejectPrompt(sessionID: id, promptText: prompt.text, reason: reason))
        return true
    }

    func setPriority(id: UUID, level: SessionPriority) {
        stateStore.update(id: id) { $0.priority = level }
        config.mutate { cfg in
            if let idx = cfg.sessions.firstIndex(where: { $0.id == id }) {
                cfg.sessions[idx].priority = level
            }
        }
        activity.record(.setPriority(sessionID: id, level: level))
    }

}
