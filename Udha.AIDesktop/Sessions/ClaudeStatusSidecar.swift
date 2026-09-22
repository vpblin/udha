import Foundation

/// Push-based status feed from Claude Code itself.
///
/// Claude Code can run a command on every lifecycle event (hooks) and on every
/// status-line repaint. We point both at tiny shell scripts that dump their
/// stdin JSON into `/tmp/udha/status/<session-uuid>.*`, then tail those files —
/// the same `tail -F` idiom the pane log already uses, so no ports, no
/// entitlements, no daemon.
///
/// This is strictly better than reading the pane (exact tool names and
/// arguments, unambiguous turn ends, real context-window usage) but only
/// applies to sessions Udha launches *after* the feature is on. The pane reader
/// stays the universal fallback, and for non-Claude commands it's the only
/// source.
///
/// Verified against Claude Code 2.1.217: `--settings` merges with (and takes
/// precedence over) `~/.claude/settings.json`, and every event name below is
/// present in that build.
enum ClaudeStatusSidecar {

    // MARK: - Locations

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Udha.AI/hooks", isDirectory: true)
    }

    /// Kept under /tmp alongside the pane logs. These are pure scratch: losing
    /// them to a /tmp sweep costs nothing, the next event recreates the file.
    static let statusDirectory = URL(fileURLWithPath: "/tmp/udha/status", isDirectory: true)

    static var settingsPath: URL { supportDirectory.appendingPathComponent("sidecar-settings.json") }
    private static var hookScriptPath: URL { supportDirectory.appendingPathComponent("udha-hook.sh") }
    private static var statusLineScriptPath: URL { supportDirectory.appendingPathComponent("udha-statusline.sh") }

    static func eventsFile(for id: UUID) -> URL {
        statusDirectory.appendingPathComponent("\(id.uuidString.lowercased()).jsonl")
    }

    static func snapshotFile(for id: UUID) -> URL {
        statusDirectory.appendingPathComponent("\(id.uuidString.lowercased()).status.json")
    }

    // MARK: - Install

    /// Hooks Udha subscribes to. `Notification` carries the permission /
    /// idle-prompt transitions; `Stop` fires whenever Claude hands control back,
    /// including when it ends its turn by asking a question.
    private static let hookEvents = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
        "Stop", "SubagentStart", "SubagentStop", "SessionEnd",
    ]

    /// Writes the scripts and settings file. Idempotent — rewritten on every
    /// launch so an edited or truncated script self-heals, same philosophy as
    /// the bundle verification in `run.sh`.
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: statusDirectory, withIntermediateDirectories: true)

        // Appends each event as one line. `tr` collapses any embedded newlines
        // so a pretty-printed payload can't break the JSONL framing. Deliberately
        // dependency-free (no jq/python) — it runs on every tool call.
        let hookScript = """
        #!/bin/sh
        d="${UDHA_STATUS_DIR:-/tmp/udha/status}"
        id="${UDHA_SESSION_ID:-}"
        [ -z "$id" ] && exit 0
        mkdir -p "$d"
        { printf '{"udha_at":%s,"payload":' "$(date +%s)"; tr -d '\\r\\n'; printf '}\\n'; } >> "$d/$id.jsonl"
        exit 0
        """

        // Overwrites rather than appends: the payload is ~5KB and repaints fire
        // on every assistant message plus the refresh timer, so appending would
        // reach megabytes in a long session. Only the newest snapshot matters.
        // temp + mv keeps the reader from ever seeing a half-written file.
        let statusLineScript = """
        #!/bin/sh
        d="${UDHA_STATUS_DIR:-/tmp/udha/status}"
        id="${UDHA_SESSION_ID:-}"
        if [ -n "$id" ]; then
          mkdir -p "$d"
          tmp="$d/.$id.status.tmp"
          tr -d '\\r\\n' > "$tmp"
          mv -f "$tmp" "$d/$id.status.json"
        else
          cat > /dev/null
        fi
        printf 'udha'
        """

        try write(hookScript, to: hookScriptPath, executable: true)
        try write(statusLineScript, to: statusLineScriptPath, executable: true)

        // Claude runs hook commands through `/bin/sh -c`, so the path must be
        // quoted: the default install location contains a space ("Application
        // Support") and unquoted it fails with
        // `/bin/sh: /Users/you/Library/Application: No such file or directory`,
        // silently killing every hook.
        let hookCommand = shellQuoted(hookScriptPath.path)

        var hooks: [String: Any] = [:]
        for event in hookEvents {
            var matcherGroup: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand]]
            ]
            // Only the tool-scoped events take a matcher; supplying one on the
            // others is meaningless noise.
            if event == "PreToolUse" || event == "PostToolUse" {
                matcherGroup["matcher"] = "*"
            }
            hooks[event] = [matcherGroup]
        }

        let settings: [String: Any] = [
            "hooks": hooks,
            "statusLine": [
                "type": "command",
                "command": shellQuoted(statusLineScriptPath.path),
                // Seconds (schema: min 1) — "in addition to event-driven updates".
                "refreshInterval": 3,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: settingsPath, options: .atomic)
        Log.pty.info("sidecar installed at \(settingsPath.path)")
    }

    /// Single-quote for `/bin/sh`, escaping any embedded quote the POSIX way
    /// (close, escaped quote, reopen).
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func write(_ contents: String, to url: URL, executable: Bool) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
    }

    /// Clear a session's feed files so a relaunched session doesn't replay the
    /// previous run's events.
    static func reset(for id: UUID) {
        try? FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: eventsFile(for: id))
        try? FileManager.default.removeItem(at: snapshotFile(for: id))
    }

    // MARK: - Events

    struct Event {
        var name: String
        var toolName: String?
        var toolInput: [String: Any]?
        var notificationType: String?
        var emittedAt: Double? = nil

        /// What the overlay should say while this event is the latest one.
        var phase: SessionPhase? {
            switch name {
            case "UserPromptSubmit":            return .thinking
            case "PreToolUse":                  return .usingTool
            // A tool finishing hands control back to the model to reason about
            // the result — it is not a turn end.
            case "PostToolUse":                 return .thinking
            case "Stop":                        return .awaitingReply
            case "SessionEnd":                  return .finished
            case "Notification":
                switch notificationType {
                case "permission_prompt", "elicitation_dialog": return .awaitingApproval
                case "idle_prompt", "agent_needs_input":        return .awaitingReply
                default:                                        return nil
                }
            default:                            return nil
            }
        }

        /// Human phrasing for `PreToolUse`, built from the tool's own arguments
        /// so the card names the file being edited rather than "Running 2 shell
        /// commands" left over from three steps ago.
        var detail: String? {
            guard let toolName else { return nil }
            let input = toolInput ?? [:]
            func str(_ key: String) -> String? {
                (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            func base(_ path: String) -> String { (path as NSString).lastPathComponent }

            switch toolName {
            case "Edit", "Write", "NotebookEdit":
                return str("file_path").map { "Editing \(base($0))" } ?? "Editing"
            case "Read":
                return str("file_path").map { "Reading \(base($0))" } ?? "Reading"
            case "Bash", "BashOutput":
                return str("command").map { "Running \(truncate($0, 48))" } ?? "Running a command"
            case "Grep", "Glob":
                return str("pattern").map { "Searching \(truncate($0, 32))" } ?? "Searching"
            case "WebFetch", "WebSearch":
                return "Researching"
            case "Task", "Agent":
                return str("subagent_type").map { "Delegating to \($0)" } ?? "Delegating"
            default:
                return toolName
            }
        }

        private func truncate(_ s: String, _ n: Int) -> String {
            let flat = s.replacingOccurrences(of: "\n", with: " ")
            return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
        }
    }

    static func parseEvent(line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let obj = (envelope["payload"] as? [String: Any]) ?? envelope
        guard let name = obj["hook_event_name"] as? String else { return nil }
        return Event(
            name: name,
            toolName: obj["tool_name"] as? String,
            toolInput: obj["tool_input"] as? [String: Any],
            notificationType: obj["notification_type"] as? String,
            emittedAt: envelope["udha_at"] as? Double
        )
    }

    /// Read only the recent tail; old lifecycle history must never be replayed as live activity.
    static func latestInputTime(for id: UUID) -> Double? {
        guard let file = try? FileHandle(forReadingFrom: eventsFile(for: id)) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        try? file.seek(toOffset: size > 262144 ? size - 262144 : 0)
        guard let data = try? file.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").reversed().lazy.compactMap { line -> Double? in
            guard let event = parseEvent(line: String(line)), event.name == "UserPromptSubmit" else { return nil }
            return event.emittedAt
        }.first
    }

    // MARK: - statusLine snapshot

    struct Snapshot {
        var contextPercent: Int?
        var costCents: Int?
        /// The model Claude is currently on, as Claude names it itself
        /// ("Opus 5", "Fable 5.1", "Sonnet 5"). Taken from statusLine rather
        /// than inferred, so switching model mid-session is picked up on the
        /// next tick instead of being stuck at whatever it launched with.
        var model: String?
        /// Claude's own id for the conversation and the .jsonl it is writing —
        /// what `--resume` needs to pick the same conversation up under
        /// another login.
        var claudeSessionID: String?
        var transcriptPath: String?
        /// The documented `rate_limits` block: how full this login's five-hour
        /// and weekly windows are, as of the last API response.
        var rateLimits: ClaudeAccountUsage?
    }

    /// Claude's session id and transcript path for a session, from the newest
    /// status feed line that carries both — the statusLine snapshot first, then
    /// the hook events. nil for a session with no feed (started outside Udha,
    /// or before its first hook fired).
    static func latestTranscript(for id: UUID) -> (sessionID: String, path: String)? {
        if let snap = readSnapshot(for: id), let sid = snap.claudeSessionID, let path = snap.transcriptPath,
           FileManager.default.fileExists(atPath: path) {
            return (sid, path)
        }
        guard let content = try? String(contentsOf: eventsFile(for: id), encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let obj = (envelope["payload"] as? [String: Any]) ?? envelope
            guard let sid = obj["session_id"] as? String, let path = obj["transcript_path"] as? String,
                  FileManager.default.fileExists(atPath: path) else { continue }
            return (sid, path)
        }
        return nil
    }

    static func readSnapshot(for id: UUID) -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotFile(for: id)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var snapshot = Snapshot()
        // `used_percentage` is null until the first API call of the session.
        if let cw = obj["context_window"] as? [String: Any],
           let pct = cw["used_percentage"] as? Double {
            snapshot.contextPercent = Int(pct.rounded())
        }
        if let cost = obj["cost"] as? [String: Any],
           let usd = cost["total_cost_usd"] as? Double {
            // Whole cents: the raw float drifts continuously and
            // `SessionStateStore.update` de-dupes by equality, so storing it
            // would invalidate every observer on every repaint.
            snapshot.costCents = Int((usd * 100).rounded())
        }
        if let model = obj["model"] as? [String: Any],
           let name = model["display_name"] as? String, !name.isEmpty {
            snapshot.model = name
        }
        snapshot.claudeSessionID = obj["session_id"] as? String
        snapshot.transcriptPath = obj["transcript_path"] as? String
        if let limits = obj["rate_limits"] as? [String: Any] {
            snapshot.rateLimits = ClaudeAccountUsage.fromStatusLine(limits)
        }
        return snapshot
    }
}
