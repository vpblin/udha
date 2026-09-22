import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
#endif

enum TmuxError: Error, LocalizedError {
    case tmuxNotFound
    case commandFailed(String, Int32, String)
    case commandDiedImmediately(String, String)

    var errorDescription: String? {
        switch self {
        case .tmuxNotFound: return "tmux not found. Install via `brew install tmux`."
        case .commandFailed(let cmd, let code, let msg): return "tmux `\(cmd)` failed (\(code)): \(msg)"
        case .commandDiedImmediately(let cmd, let tail):
            let detail = tail.isEmpty ? "" : " — \(tail)"
            return "`\(cmd)` exited immediately, so the tmux session was gone before it could be wired up. Check the command is installed and on PATH\(detail)."
        }
    }
}

final class TmuxSession: @unchecked Sendable {

    /// Mirrors `AppConfig.reclaimTerminalWindows`. When false, a restored
    /// session opens its own Terminal window instead of reattaching to the one
    /// tmux is already displaying it in. Static because attach happens deep in
    /// `start()`, far from any config reference, and this is read-only after
    /// AppCore's init sets it.
    nonisolated(unsafe) static var reclaimTerminalWindows: Bool = true
    let id: UUID
    private(set) var label: String
    /// Always `Self.tmuxName(id:label:)` for the *current* label — see
    /// `rename(to:)`. Every client derives the name from the label instead of
    /// being told it, so the two must never drift apart.
    private(set) var tmuxName: String
    let logPath: URL
    let directory: String
    let command: String
    /// `var` only for `respawn(env:args:)`, which replaces the process in the
    /// same pane with a different launch line.
    private(set) var args: [String]
    private(set) var env: [String: String]
    /// When non-nil, `claude` is launched with `--settings <path>` so its hooks
    /// and status line report into the sidecar. Injected at launch only — never
    /// persisted into `SessionConfig.args`, so toggling the feature off doesn't
    /// leave a stale flag in the saved config.
    let sidecarSettingsPath: String?

    private var tailProcess: Process?
    private var outHandle: FileHandle?
    private var sidecarTailProcess: Process?
    private var sidecarHandle: FileHandle?
    private var pollTimer: DispatchSourceTimer?
    private var pinnedPollCount = 0
    private var lastReportedPinned = false
    /// Fires when the window flips between client-driven and pinned sizing.
    var onSizePinnedChange: ((Bool) -> Void)?
    private(set) var terminalWindowID: String?

    var onData: ((Data) -> Void)?
    /// Raw `capture-pane -pe` output — escapes intact, because ANSI dim is the
    /// only way to tell a typed draft from a ghost suggestion.
    var onSnapshot: ((String) -> Void)?
    var onSidecarLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Where tmux actually lives on this Mac. Internal rather than private so
    /// the embedded terminal can attach with the same binary the supervisor
    /// spawned with — two tmuxes on one machine would not share a server.
    static let tmuxPath: String = {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return "/opt/homebrew/bin/tmux"
    }()

    /// The PATH a session's command is launched with.
    ///
    /// tmux inherits the environment of whoever started its server — for us
    /// that's the app, and a GUI-launched app gets launchd's bare
    /// `/usr/bin:/bin:/usr/sbin:/sbin`. Tools installed per-user are then
    /// simply not on PATH (`claude` lives in `~/.local/bin`), and the failure
    /// is deeply misleading: `new-session` still succeeds, the command dies
    /// instantly, the session dies with it, the last session dying takes the
    /// server down — and the first thing to notice is `pipe-pane`, three calls
    /// later, reporting "no server running".
    ///
    /// So ask the user's login shell what PATH they actually have and pass it
    /// on the launch line. Bounded wait: a shell whose rc files hang must not
    /// take session spawning with it.
    static let loginPath: String = {
        var resolved = ""
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        // Read on a background queue: a login shell that chatters more than the
        // pipe buffer holds would otherwise block on write while we wait.
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if (try? p.run()) != nil {
            if done.wait(timeout: .now() + 5) == .timedOut {
                p.terminate()
                _ = done.wait(timeout: .now() + 1)
            }
            p.waitUntilExit()
            // Interactive rc files may print banners; PATH is the last line.
            resolved = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }

        var entries = resolved.split(separator: ":").map(String.init)
        // Union with our own PATH plus the usual install prefixes, so a shell
        // that fails to answer still leaves us better off than launchd's default.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbacks = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/bin",
               "/opt/homebrew/bin", "/usr/local/bin",
               "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for entry in fallbacks where !entry.isEmpty && !entries.contains(entry) {
            entries.append(entry)
        }
        let path = entries.joined(separator: ":")
        Log.pty.info("session PATH resolved from \(shell): \(path)")
        return path
    }()

    init(
        id: UUID,
        label: String,
        directory: String,
        command: String,
        args: [String],
        env: [String: String] = [:],
        sidecarSettingsPath: String? = nil
    ) {
        self.id = id
        self.label = label
        self.env = env
        self.sidecarSettingsPath = sidecarSettingsPath
        self.tmuxName = Self.tmuxName(id: id, label: label)
        self.logPath = URL(fileURLWithPath: "/tmp/udha/\(tmuxName).log")
        self.directory = directory
        self.command = command
        self.args = args
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: Self.tmuxPath) else {
            throw TmuxError.tmuxNotFound
        }

        try FileManager.default.createDirectory(
            at: logPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let alreadyRunning = isAlive()
        if alreadyRunning {
            Log.pty.info("tmux session \(self.tmuxName) already exists — reattaching")
            FileManager.default.createFile(atPath: logPath.path, contents: Data())
            _ = try? runTmux(args: ["pipe-pane", "-t", tmuxName])
        } else {
            FileManager.default.createFile(atPath: logPath.path, contents: Data())
            // Fresh session: drop any feed left by a previous run under this id
            // so its old events aren't replayed as current status.
            if sidecarSettingsPath != nil { ClaudeStatusSidecar.reset(for: id) }
            try runTmux(args: ["new-session", "-d", "-s", tmuxName, "-c", directory, launchCommand()], detached: true)
            // `new-session` reports success for a command that dies on the spot,
            // and the dying session can take the whole server with it. Catch it
            // here, where we still know which command was meant to run, instead
            // of letting `pipe-pane` report "no server running" a line later.
            Thread.sleep(forTimeInterval: 0.25)
            guard isAlive() else {
                throw TmuxError.commandDiedImmediately(command, Self.lookupFailure(for: command))
            }
            Log.pty.info("tmux session \(self.tmuxName) created")
        }

        try runTmux(args: ["pipe-pane", "-o", "-t", tmuxName, "cat >> \(logPath.path)"])

        if !alreadyRunning {
            openInTerminal()
        } else if Self.reclaimTerminalWindows, let existing = findExistingWindowID() {
            // Reattach to whichever Terminal window is already showing this session.
            terminalWindowID = existing
            Log.pty.info("session \(self.tmuxName) reclaimed Terminal window \(existing)")
        }
        startTailing()
        // Tail the hook feed when this session can actually produce one: either
        // we just launched it with `--settings`, or it already has events on
        // disk from a previous Udha run (the claude process outlives us, so a
        // restart must not orphan a feed that's still being written). Sessions
        // that were started outside Udha never emit, and tailing those would be
        // one idle `tail -F` apiece, forever, on a file nothing writes.
        if !alreadyRunning || hasExistingSidecarFeed { startSidecarTailing() }
        startExitWatcher()
        startSnapshotPolling()
    }

    /// The shell line tmux runs. Env vars go in front of the binary so they
    /// land in Claude's environment — and therefore in every hook subprocess it
    /// spawns, which is how the hook script knows which Udha session it belongs
    /// to.
    private func launchCommand() -> String {
        // PATH first so a per-session override in `env` still wins.
        var assignments: [String] = ["PATH=\(shellEscape(Self.loginPath))"]
        if sidecarSettingsPath != nil {
            assignments.append("UDHA_SESSION_ID=\(shellEscape(id.uuidString.lowercased()))")
            assignments.append("UDHA_STATUS_DIR=\(shellEscape(ClaudeStatusSidecar.statusDirectory.path))")
        }
        // `SessionConfig.env` has existed since the config was written but was
        // never actually applied to the spawned process until now.
        for key in env.keys.sorted() {
            assignments.append("\(key)=\(shellEscape(env[key] ?? ""))")
        }

        var parts = [command] + args
        // Only Claude understands --settings; a plain shell session would choke.
        if let sidecarSettingsPath, command == "claude" {
            parts += ["--settings", sidecarSettingsPath]
        }
        return (assignments + parts.map(shellEscape)).joined(separator: " ")
    }

    private func startSnapshotPolling() {
        stopSnapshotPolling()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let content = self.capturePane()
            if !content.isEmpty {
                self.onSnapshot?(content)
            }
            // Every fifth tick (~10s) ask whether a phone visit left the window
            // pinned. It is one more tmux round-trip, so not every tick, and
            // only reported on change so the store isn't touched for nothing.
            self.pinnedPollCount &+= 1
            if self.pinnedPollCount % 5 == 1 {
                let pinned = self.isWindowSizePinned()
                if pinned != self.lastReportedPinned {
                    self.lastReportedPinned = pinned
                    self.onSizePinnedChange?(pinned)
                }
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopSnapshotPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// The most recent `capture-pane` output, if the poller has run once.
    /// Lets a client that has just attached get a frame straight away rather
    /// than staring at a blank pane until the next poll tick.
    private(set) var lastSnapshot: String?

    func currentSnapshot() -> String? {
        lastSnapshot ?? {
            let content = capturePaneLines(start: 0)
            return content.isEmpty ? nil : content
        }()
    }

    private func capturePane() -> String {
        let content = capturePaneLines(start: 0)
        lastSnapshot = content
        return content
    }

    func captureScrollback(maxLines: Int = 200) -> String {
        capturePaneLines(start: -maxLines)
    }

    /// A page of history above the visible pane, addressed upward from the top
    /// of the screen. `offset` 0 is the page immediately above the live view.
    func captureHistory(offset: Int, lines: Int) -> String {
        let start = -(offset + lines)
        let end = -(offset + 1)
        return capturePaneRange(start: start, end: end)
    }

    private func capturePaneRange(start: Int, end: Int) -> String {
        runCapture(extraArgs: ["-S", "\(start)", "-E", "\(end)"])
    }

    private func capturePaneLines(start: Int) -> String {
        runCapture(extraArgs: start < 0 ? ["-S", "\(start)"] : [])
    }

    private func runCapture(extraArgs: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        // `-e` keeps the ANSI escapes. The pane reader needs them: Claude renders
        // its ghost next-prompt suggestions in ANSI dim and text you actually
        // typed in bright white, and that's the only way to tell them apart.
        // Consumers that want plain text strip it themselves (`RingBuffer`
        // already does on append).
        p.arguments = ["capture-pane", "-p", "-e", "-t", tmuxName] + extraArgs
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch { return "" }
        // Drain the pipe BEFORE waiting. capture-pane on a wide pane (e.g. an
        // ultrawide terminal capturing 200 scrollback lines) easily exceeds the
        // 64KB pipe buffer; if we waitUntilExit() first, tmux blocks on write()
        // while we block on wait() — a deadlock that froze the whole app at
        // launch (restoreSessions runs this synchronously on the main thread).
        // readDataToEndOfFile() drains until tmux closes stdout, so it can't
        // stall; the process is already done by the time we reap it.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Window geometry

    /// The pane's current character grid, or nil if tmux doesn't know it.
    func windowSize() -> (cols: Int, rows: Int)? {
        guard let out = try? runTmux(args: [
            "display", "-p", "-t", tmuxName, "#{window_width}x#{window_height}",
        ]) else { return nil }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
        guard parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]) else { return nil }
        return (c, r)
    }

    /// Resizes the window to an exact character grid.
    ///
    /// `resize-window` implicitly switches this window to `window-size manual`,
    /// which is what makes the size *stick*: the global default is
    /// `window-size latest`, under which tmux would immediately snap the window
    /// back to whatever the attached Terminal.app client is. The manual mode is
    /// undone by `restoreWindowSize()`.
    ///
    /// The attached Terminal window keeps its own size and letterboxes the
    /// smaller pane inside it. That is cosmetic and reverses on restore.
    @discardableResult
    func resizeWindow(cols: Int, rows: Int) -> Bool {
        // A floor purely against nonsense — a mismeasured client asking for
        // three columns would render the TUI unreadable at both ends. There is
        // no *upper* concern: Claude Code truncates its chrome to the width it
        // is given rather than wrapping it, so narrow is safe.
        let c = max(Self.minimumColumns, min(cols, 500))
        let r = max(Self.minimumRows, min(rows, 200))
        do {
            try runTmux(args: ["resize-window", "-t", tmuxName, "-x", "\(c)", "-y", "\(r)"])
            Log.pty.info("resized \(self.tmuxName) to \(c)x\(r)")
            return true
        } catch {
            Log.pty.error("resize-window \(self.tmuxName) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Hands the window back to whichever client is attached.
    ///
    /// Both halves matter. Resizing to the old grid alone would leave the
    /// window pinned at `manual`, so the pane would stay phone-shaped on the
    /// Mac forever after a single phone visit — clearing the option is what
    /// actually restores normal behaviour, and the explicit resize just avoids
    /// a visible flicker while tmux recomputes.
    ///
    /// `-u` unsets rather than assigning `latest`. The window inherited its
    /// sizing from the global option before we touched it, and writing a
    /// concrete value would quietly override a user who runs, say,
    /// `window-size largest` — restoring state means restoring it, not
    /// substituting the default.
    /// Order matters and is not interchangeable: `resize-window` is itself what
    /// sets `manual`, so unsetting first and resizing second would hand the
    /// window back and then immediately re-pin it. Resize, *then* release.
    func restoreWindowSize(to previous: (cols: Int, rows: Int)?) {
        if let previous {
            try? runTmux(args: [
                "resize-window", "-t", tmuxName,
                "-x", "\(previous.cols)", "-y", "\(previous.rows)",
            ])
        }
        try? runTmux(args: ["set-option", "-w", "-t", tmuxName, "-u", "window-size"])
        Log.pty.info("restored \(self.tmuxName) to client-driven sizing")
    }

    /// Releases a pinned window without resizing it first — the shape the
    /// desktop asks for when it finds a session still phone-sized. Attached
    /// clients drive the size again from the next redraw.
    func releaseWindowSize() {
        restoreWindowSize(to: nil)
    }

    /// Whether the window is pinned to a manual size, which is what a phone
    /// visit leaves behind. `-q` keeps a vanished session from printing.
    func isWindowSizePinned() -> Bool {
        guard let out = try? runTmux(args: ["show-options", "-wqv", "-t", tmuxName, "window-size"]) else {
            return false
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "manual"
    }

    static let minimumColumns = 20
    static let minimumRows = 10

    /// Returns true only if both the literal text AND the trailing Enter
    /// keystroke were accepted by tmux. Silent failure here is what made the
    /// voice agent confidently report "sent" while the terminal saw nothing.
    @discardableResult
    func sendInput(text: String) -> Bool {
        do {
            try runTmux(args: ["send-keys", "-t", tmuxName, "-l", text])
            try runTmux(args: ["send-keys", "-t", tmuxName, "Enter"])
            return true
        } catch {
            Log.pty.error("send-keys to \(tmuxName) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Deliver a large, multi-line prompt to the session as a single bracketed
    /// paste, then submit it. Used to inject an agent's pre-built prompt once
    /// Claude is up and running.
    ///
    /// `send-keys -l` would submit at every embedded newline (Claude treats a
    /// bare Enter as "send"), shredding a multi-paragraph prompt into dozens of
    /// half-messages. Instead we stage the text in a tmux paste buffer and
    /// `paste-buffer -p` (bracketed paste), which Claude Code's TUI receives as
    /// one atomic multi-line input; a separate Enter afterwards submits it.
    ///
    /// Runs blocking `tmux` calls (and a short settle sleep) — call it OFF the
    /// main thread.
    @discardableResult
    func sendPrompt(_ text: String) -> Bool {
        let bufferName = "udha-agent-\(id.uuidString.prefix(8).lowercased())"
        let promptURL = logPath.deletingLastPathComponent()
            .appendingPathComponent("\(tmuxName).prompt")
        do {
            try text.write(to: promptURL, atomically: true, encoding: .utf8)
            try runTmux(args: ["load-buffer", "-b", bufferName, promptURL.path])
            try runTmux(args: ["paste-buffer", "-d", "-p", "-b", bufferName, "-t", tmuxName])
            // Let the TUI register the paste before we submit, otherwise the
            // Enter can race ahead of the inserted text.
            Thread.sleep(forTimeInterval: 0.5)
            try runTmux(args: ["send-keys", "-t", tmuxName, "Enter"])
            try? FileManager.default.removeItem(at: promptURL)
            return true
        } catch {
            Log.pty.error("sendPrompt to \(tmuxName) failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func sendRaw(text: String) -> Bool {
        do {
            try runTmux(args: ["send-keys", "-t", tmuxName, "-l", text])
            return true
        } catch {
            Log.pty.error("send-keys raw to \(tmuxName) failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func sendKey(_ key: String) -> Bool {
        do {
            try runTmux(args: ["send-keys", "-t", tmuxName, key])
            return true
        } catch {
            Log.pty.error("send-keys \(key) to \(tmuxName) failed: \(error.localizedDescription)")
            return false
        }
    }

    func bringToFront() {
        // Try the cached window id first.
        if let windowID = terminalWindowID, focusWindow(id: windowID) {
            return
        }
        // Otherwise, scan Terminal for any tab already attached to our tmux session.
        if let windowID = findExistingWindowID() {
            terminalWindowID = windowID
            _ = focusWindow(id: windowID)
            return
        }
        // Nothing found — open a fresh one.
        openInTerminal()
    }

    /// Attempts to focus a Terminal window by id. Returns false if the window no longer exists.
    ///
    /// Cross-Space raising is fragile. Layered approach:
    ///   1. Terminal's own `set index ... to 1` to win the in-app z-order.
    ///   2. System Events `perform action "AXRaise"` on the front Terminal
    ///      window — the Accessibility API is the only path that unconditionally
    ///      drags the window's Space to the front. Requires the user to grant
    ///      Accessibility permission to Udha (System Settings → Privacy &
    ///      Security → Accessibility) — first invocation triggers the prompt.
    ///   3. AppKit `NSRunningApplication.activate` as a fallback if Accessibility
    ///      isn't granted.
    private func focusWindow(id windowID: String) -> Bool {
        let script = """
        tell application "Terminal"
          try
            set idx to index of window id \(windowID)
            set index of window id \(windowID) to 1
          on error
            return "missing"
          end try
        end tell
        tell application "System Events"
          try
            tell process "Terminal"
              set frontmost to true
              try
                perform action "AXRaise" of window 1
              end try
            end tell
          end try
        end tell
        return "ok"
        """
        let result = runAppleScript(script, context: "focusWindow")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result == "ok" else {
            Log.pty.error("focusWindow(\(windowID)) for \(self.tmuxName) did not return ok (got \(result ?? "<nil>"))")
            return false
        }
#if canImport(AppKit)
        if let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first {
            terminal.activate(options: [.activateAllWindows])
        }
#endif
        return true
    }

    /// Asks tmux which tty is attached to this session, then asks Terminal which window owns that tty.
    /// This is the authoritative lookup — no guessing from titles.
    private func findExistingWindowID() -> String? {
#if !canImport(AppKit)
        return nil
#endif
        for tty in attachedTTYs() {
            let script = """
            tell application "Terminal"
              set foundID to ""
              repeat with w in windows
                repeat with t in tabs of w
                  try
                    if (tty of t) is "\(tty)" then
                      set foundID to (id of w as string)
                      exit repeat
                    end if
                  end try
                end repeat
                if foundID is not "" then exit repeat
              end repeat
              return foundID
            end tell
            """
            if let raw = runAppleScript(script, context: "findExistingWindowID")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return nil
    }

    /// Returns the list of ttys currently attached to this tmux session.
    private func attachedTTYs() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        p.arguments = ["list-clients", "-t", tmuxName, "-F", "#{client_tty}"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func detach() {
        tailProcess?.terminate()
        tailProcess = nil
        outHandle?.readabilityHandler = nil
        outHandle = nil
        stopSidecarTailing()
        stopSnapshotPolling()
    }

    private func stopSidecarTailing() {
        sidecarTailProcess?.terminate()
        sidecarTailProcess = nil
        sidecarHandle?.readabilityHandler = nil
        sidecarHandle = nil
    }

    /// Recover output plumbing after the machine wakes from sleep. A long sleep
    /// breaks every path the classifier depends on:
    ///   - the GCD poll timer stops/coalesces and may not resume,
    ///   - the `tail -F` readability source goes stale,
    ///   - /tmp pruning can delete the log file mid-sleep, so tmux's pipe-pane
    ///     keeps writing to an orphaned inode that `tail` no longer sees.
    /// When all of these die, a session parked at a prompt is never
    /// re-classified, so its state silently freezes. Rebuild all three and fire
    /// one immediate snapshot so recovery is instant, not up-to-2s later.
    /// Safe to call off the main thread.
    func handleSystemWake() {
        guard isAlive() else { return }
        // Re-point pipe-pane at a fresh log file and restart the tail follower.
        tailProcess?.terminate()
        tailProcess = nil
        outHandle?.readabilityHandler = nil
        outHandle = nil
        _ = try? runTmux(args: ["pipe-pane", "-t", tmuxName])               // stop stale pipe
        FileManager.default.createFile(atPath: logPath.path, contents: Data())
        _ = try? runTmux(args: ["pipe-pane", "-o", "-t", tmuxName, "cat >> \(logPath.path)"])
        startTailing()
        // The sidecar follower is a `tail -F` too, so it goes stale the same
        // way — but only rebuild it for sessions that actually had one.
        let hadSidecarTail = sidecarTailProcess != nil
        stopSidecarTailing()
        if hadSidecarTail { startSidecarTailing() }
        // Restart the capture-pane poller (independent of the log file) and
        // classify the current pane right now.
        startSnapshotPolling()
        let content = capturePane()
        if !content.isEmpty { onSnapshot?(content) }
    }

    func kill() {
        try? runTmux(args: ["kill-session", "-t", tmuxName])
        detach()
    }

    /// Replace the running process with a fresh launch of the same command in
    /// the same pane — `respawn-pane -k` — leaving the tmux session, every
    /// attached client (a phone, the embedded terminal, an SSH window), the
    /// `pipe-pane` log and the status-feed follower exactly where they are.
    /// This is how a session changes Claude login without changing identity:
    /// the new process is told `--resume <transcript>` by the caller, so it is
    /// the same conversation on the other side. Verified on the box that the
    /// pane's pipe survives the respawn (`#{pane_pipe}` stays 1).
    func respawn(env newEnv: [String: String], args newArgs: [String]) throws {
        env = newEnv
        args = newArgs
        try runTmux(args: ["respawn-pane", "-k", "-t", tmuxName, "-c", directory, launchCommand()])
        Log.pty.info("tmux session \(self.tmuxName) respawned: \(command) \(newArgs.joined(separator: " "))")
    }

    /// Kill the tmux session AND close the Terminal window that was attached
    /// to it. The tty → window lookup goes through `tmux list-clients`, so it
    /// must happen BEFORE the kill — hence this wraps the whole teardown.
    /// Blocking AppleScript plus a settle sleep — call OFF the main thread.
    func killAndCloseTerminal() {
        let ttys = attachedTTYs()
        let cachedWindowID = terminalWindowID
        kill()
        // Give the attach client's shell a beat to fall back to its prompt so
        // Terminal doesn't raise a "terminate running processes?" sheet.
        Thread.sleep(forTimeInterval: 0.3)
        for tty in ttys {
            if closeTerminalWindow(owningTTY: tty) { return }
        }
        // No attached client (window may have been closed or detached by the
        // user) — fall back to the window id recorded when we opened it.
        if let windowID = cachedWindowID {
            _ = runAppleScript("""
            tell application "Terminal"
              try
                close window id \(windowID) saving no
              end try
            end tell
            """, context: "killAndCloseTerminal")
        }
    }

    /// Close the Terminal window owning `tty`. Only closes the window when
    /// that tab is its ONLY tab (the single-tab windows Udha opens), so a
    /// user's unrelated tabs are never taken down with it. Returns true if
    /// the window was found (closed or deliberately left open).
    private func closeTerminalWindow(owningTTY tty: String) -> Bool {
        let script = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) is "\(tty)" then
                  if (count of tabs of w) is 1 then
                    close w saving no
                    return "closed"
                  else
                    return "multi-tab"
                  end if
                end if
              end try
            end repeat
          end repeat
          return "not-found"
        end tell
        """
        let result = runAppleScript(script, context: "closeTerminalWindow")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result == "multi-tab" {
            Log.pty.info("not closing Terminal window for \(self.tmuxName) — other tabs are open in it")
            return true
        }
        return result == "closed"
    }

    /// Every tmux session name currently on the server, or `nil` when tmux
    /// itself couldn't be consulted (binary missing, exec failed). The nil case
    /// matters: callers that prune state for "dead" sessions must not read an
    /// unreachable tmux as "nothing is alive" and wipe everything.
    /// A running server with zero sessions, and a server that isn't running at
    /// all, both return an empty set — after a reboot nothing is alive, and
    /// that is a fact, not a failure.
    static func liveSessionNames() -> Set<String>? {
        guard FileManager.default.fileExists(atPath: tmuxPath) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        p.arguments = ["list-sessions", "-F", "#{session_name}"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let noServer = errText.lowercased().contains("no server running")
                || errText.lowercased().contains("no sessions")
            guard noServer else {
                Log.pty.error("tmux list-sessions failed (\(p.terminationStatus)): \(errText)")
                return nil
            }
            return []
        }
        return Set(
            outText.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    /// The uuid fragment every `udha-…` tmux name ends with. Matching on this
    /// rather than the whole name is what makes liveness survive a name the
    /// label has since moved away from (`repairName`).
    static func shortID(for id: UUID) -> String {
        id.uuidString.prefix(8).lowercased()
    }

    /// The tmux session name for a session — derivable anywhere from its id and
    /// label, so a remote client can build the `tmux attach` command without the
    /// host telling it the name.
    static func tmuxName(id: UUID, label: String) -> String {
        let shortID = shortID(for: id)
        let safeLabel = label.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "udha-\(safeLabel.isEmpty ? shortID : safeLabel)-\(shortID)"
    }

    /// Names the likely cause when a launch command vanishes instantly: by far
    /// the most common one is that the binary isn't on the PATH we hand tmux.
    private static func lookupFailure(for command: String) -> String {
        // An explicit path was given; PATH has nothing to do with it.
        guard !command.contains("/") else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["sh", "-c", "command -v \(command)"]
        p.environment = ["PATH": loginPath]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? "" : "`\(command)` is not on PATH (\(loginPath))"
    }

    /// Follow a label change into tmux, so the name stays derivable from the
    /// label. The pipe, the tail and the log path are untouched: tmux keeps
    /// them on the pane, and this object keeps writing where it always did.
    /// Any client attached — an iTerm window, the embedded terminal — follows
    /// the session across the rename on its own.
    ///
    /// Renames used to leave the tmux name alone on purpose, and the restore
    /// path paid for it: `restoreSessions` probes the name derived from the
    /// *saved* label, so a renamed session came back as "not running" at the
    /// next launch and was silently left out of the list — alive in tmux,
    /// invisible in Udha. Six sessions vanished that way on a remote box when the
    /// agent restarted on 2026-09-11. The remote "Open in Terminal" derives the
    /// same name and was broken by the same drift.
    func rename(to newLabel: String) {
        let newName = Self.tmuxName(id: id, label: newLabel)
        let oldName = tmuxName
        label = newLabel
        guard newName != oldName else { return }
        do {
            _ = try runTmux(args: ["rename-session", "-t", oldName, newName])
            tmuxName = newName
            Log.pty.info("tmux session \(oldName) renamed to \(newName)")
        } catch {
            // Keep the name we know is live; `repairName` will catch up at the
            // next launch, and everything on this object keeps working now.
            Log.pty.error("rename-session \(oldName) → \(newName) failed: \(error.localizedDescription)")
        }
    }

    /// If no session answers to this object's name but one still carries its
    /// uuid fragment under an older label, rename it into line so the restore
    /// that follows finds it. `live` is `liveSessionNames()`, fetched once by
    /// the caller for the whole restore pass. True when a repair happened.
    @discardableResult
    func repairName(live: Set<String>) -> Bool {
        guard !live.contains(tmuxName) else { return false }
        let suffix = "-" + Self.shortID(for: id)
        guard let stale = live.first(where: { $0.hasSuffix(suffix) }) else { return false }
        do {
            _ = try runTmux(args: ["rename-session", "-t", stale, tmuxName])
            Log.pty.info("tmux session \(stale) renamed to \(self.tmuxName) to match its label")
            return true
        } catch {
            Log.pty.error("rename-session \(stale) → \(self.tmuxName) failed: \(error.localizedDescription)")
            return false
        }
    }

    func isAlive() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        p.arguments = ["has-session", "-t", tmuxName]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func openInTerminal() {
#if !canImport(AppKit)
        return   // no Mac Terminal on the headless agent
#endif
        // Double-check: another entry point may have captured this window in the meantime.
        if let existing = findExistingWindowID() {
            terminalWindowID = existing
            _ = focusWindow(id: existing)
            return
        }
        let script = """
        tell application "Terminal"
          activate
          set newTab to do script "\(Self.tmuxPath) attach -t \(tmuxName)"
          set custom title of newTab to "\(tmuxName)"
          set winID to id of window 1
          return winID as string
        end tell
        """
        let result = runAppleScript(script, context: "openInTerminal")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let result, !result.isEmpty, Int(result) != nil {
            terminalWindowID = result
            Log.pty.info("opened Terminal window \(result) for \(self.tmuxName)")
        } else {
            Log.pty.error("openInTerminal for \(self.tmuxName) returned no window id (got \(result ?? "<nil>")) — Terminal Apple Event likely failed/denied")
        }
    }

    private func startTailing() {
        let p = Process()
        p.executableURL = Self.tailBinary
        p.arguments = ["-F", "-n", "+1", logPath.path]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()

        let handle = outPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if !data.isEmpty {
                self?.onData?(data)
            }
        }

        do {
            try p.run()
            self.tailProcess = p
            self.outHandle = handle
        } catch {
            Log.pty.error("tail failed: \(error.localizedDescription)")
        }
    }

    /// Whether this session already has hook events on disk — the marker that
    /// a still-running claude process was launched with Udha's settings.
    private var hasExistingSidecarFeed: Bool {
        let path = ClaudeStatusSidecar.eventsFile(for: id).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? 0
        return size > 0
    }

    /// The `tail` to follow files with. On Ubuntu 26.04 `/usr/bin/tail` is
    /// the Rust uutils rewrite, and its `-F` watches the *directory* of the
    /// file: every rewrite of any sibling — twenty Claude sessions each
    /// overwriting `<id>.status.json` a few times a second — wakes every
    /// sidecar follower in `/tmp/udha/status`, which then re-opens and reads
    /// the neighbours' files end to end. Twenty followers at ~100% CPU each
    /// held the 9800X3D at 86 °C (2026-09-18). GNU tail ships beside it as
    /// `gnutail` and follows only its own file, so it is preferred wherever
    /// it exists; macOS's BSD tail is fine.
    static let tailBinary: URL = {
        for path in ["/usr/bin/gnutail", "/usr/local/bin/gtail", "/opt/homebrew/bin/gtail", "/usr/bin/tail"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/tail")
    }()

    /// Follow the hook sidecar's JSONL feed. Same `tail -F` shape as the pane
    /// log, including surviving the file not existing yet — the first hook
    /// fires only once Claude has finished booting.
    private func startSidecarTailing() {
        guard sidecarSettingsPath != nil else { return }
        let path = ClaudeStatusSidecar.eventsFile(for: id).path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }

        let p = Process()
        p.executableURL = Self.tailBinary
        p.arguments = ["-F", "-n", "0", path]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()

        let handle = outPipe.fileHandleForReading
        var partial = ""
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            var lines = (partial + chunk).components(separatedBy: "\n")
            partial = lines.removeLast()
            for line in lines where !line.isEmpty {
                self?.onSidecarLine?(line)
            }
        }

        do {
            try p.run()
            sidecarTailProcess = p
            sidecarHandle = handle
        } catch {
            Log.pty.error("sidecar tail failed for \(self.tmuxName): \(error.localizedDescription)")
        }
    }

    private func startExitWatcher() {
        let name = tmuxName
        let weakHandler = { [weak self] (code: Int32) in
            self?.onExit?(code)
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
                p.arguments = ["has-session", "-t", name]
                p.standardOutput = Pipe()
                p.standardError = Pipe()
                do { try p.run() } catch { break }
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    weakHandler(0)
                    break
                }
            }
        }
    }

    /// Runs a tmux command and returns its stdout.
    ///
    /// `detached` is for commands that spawn the tmux **server** (`new-session`):
    /// the server daemonises holding whatever stdout/stderr it inherited, and on
    /// Linux it never closes them, so a pipe here would make `readDataToEndOfFile`
    /// block forever after the client has already exited (macOS tmux closes them,
    /// which is why this only bit the headless agent). Detached commands get
    /// `/dev/null` for stdio — their output is never consumed anyway — and their
    /// success is confirmed by `isAlive()` at the call site.
    @discardableResult
    private func runTmux(args: [String], detached: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        p.arguments = args
        if detached {
            // `new-session` starts the tmux **server** (a daemon) and the client
            // then exits — but on swift-corelibs-foundation the exited client is
            // left a zombie and `waitUntilExit()` never returns for it, wedging
            // whatever thread called us (here, the main actor — so the whole
            // agent freezes). Never block on it: give the daemon null stdio so it
            // inherits nothing of ours, launch, and let the call site confirm the
            // session came up via `isAlive()`. Reaping is best-effort, off-thread.
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            DispatchQueue.global(qos: .utility).async { p.waitUntilExit() }
            return ""
        }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw TmuxError.commandFailed(args.joined(separator: " "), p.terminationStatus, errText.isEmpty ? outText : errText)
        }
        return outText
    }

    /// Runs an AppleScript via osascript. `context` labels the call site in logs.
    /// Previously this discarded stderr and the exit code, so a denied Apple Event
    /// (e.g. TCC Automation not granted, errAEEventNotPermitted / -1743) produced a
    /// silent nil — the source of "hover/new-session just stopped working with no error".
    private func runAppleScript(_ source: String, context: String) -> String? {
#if !canImport(AppKit)
        return nil
#endif
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            Log.pty.error("osascript[\(context)] for \(self.tmuxName) failed to launch: \(error.localizedDescription)")
            return nil
        }
        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.terminationStatus != 0 || !errText.isEmpty {
            Log.pty.error("osascript[\(context)] for \(self.tmuxName) exit=\(p.terminationStatus) stderr=\(errText.isEmpty ? "<none>" : errText) stdout=\(outText.isEmpty ? "<none>" : outText)")
        }
        return outText
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SessionSnapshot {
    /// What to hand `tmux -t` for this session: the exact name when the host
    /// reported it, otherwise a pattern on the uuid fragment every name ends
    /// in (`*-8c7c11ee`), which tmux resolves by fnmatch. The pattern is what
    /// keeps a session that was renamed on a box running an older agent
    /// reachable — that agent still derives the name from the label at spawn
    /// but never sends it, and the label it was spawned with is gone.
    var tmuxTarget: String {
        tmuxName ?? "*-\(TmuxSession.shortID(for: id))"
    }
}
