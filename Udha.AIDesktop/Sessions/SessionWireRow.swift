import Foundation

extension SessionSnapshot {

    /// The single session-row serializer for the mobile protocol.
    ///
    /// `sessions_full` and `sessions_delta` both go through here, so the two
    /// can never drift. Lives on the snapshot rather than on `MobileBridge` so
    /// it can be tested directly against the client's decoder — that round trip
    /// is the actual contract between the two repos.
    ///
    /// The v1 fields keep their exact previous shape; everything added by v2 is
    /// optional, because a client may be an older build.
    func wireRow(staleAfter: Double) -> [String: Any] {
        var row: [String: Any] = [
            "id": id.uuidString,
            "label": label,
            "directory": directory,

            // v1 — byte-identical to what the original iPhone build reads.
            "state": state.rawValue,
            "stateEnteredSecAgo": Int(Date().timeIntervalSince(stateEnteredAt)),
            "priority": priority.rawValue,
            "hasPendingPrompt": pendingPrompt != nil,

            // v2
            "phase": phase.rawValue,
            "phaseEnteredSecAgo": Int(Date().timeIntervalSince(phaseEnteredAt)),
            "attention": attention(staleAfter: staleAfter).wireValue,
            "stale": isStale(staleAfter: staleAfter),
            "subagentCount": subagentCount,
            // Literally what it says: a Claude TUI, which is what the client
            // reads the pane as. A ChatGPT or Qwen session is not one — so this
            // asks for Claude rather than for "not Codex", which would have
            // quietly claimed every assistant added after it.
            "isClaudeTUI": (tool ?? .claude) == .claude && (contextPercent != nil || phase != .starting),
            "isWorktree": directory.contains("-wt/"),
        ]
        if supportsAttentionEvents { row["attentionState"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(attentionState))) ?? [:] }
        if let phaseDetail { row["phaseDetail"] = phaseDetail }
        // Absent means Claude to every client that predates the choice, which
        // is exactly what those clients were looking at.
        if let tool { row["tool"] = tool.rawValue }
        // The real tmux name, so a client attaches to what exists rather than
        // to a name re-derived from a label that may have been changed since.
        if let tmuxName { row["tmux"] = tmuxName }
        if sizePinned { row["sizePinned"] = true }
        if let contextPercent { row["contextPercent"] = contextPercent }
        // Whole cents, never a Double: the statusLine feed reports a drifting
        // float, and a delta keyed on it would never stop firing.
        if let costCents { row["costCents"] = costCents }
        if let model { row["model"] = model }
        // Which login, for a tree with several. Absent = the only one.
        if let account { row["account"] = account }
        // Which machine is running this. The Mac's store holds the box's
        // sessions alongside its own — that is what makes the desktop board two
        // columns — and without this the phone received both sets in one list
        // with nothing to tell them apart. Absent means "the host you are
        // talking to", which is what every row was before this existed.
        if let hostName { row["host"] = hostName }
        // Folder + hidden, optional by absence: a loose, visible row carries
        // neither key, which is every row an older client ever saw. The
        // folder itself travels in the `folders` list beside `sessions_full`.
        if let folderID { row["folder"] = folderID.uuidString }
        if hidden { row["hidden"] = true }
        if let lastQuestion { row["lastQuestion"] = lastQuestion }
        if !dialogOptions.isEmpty {
            row["options"] = dialogOptions.map { option in
                ["n": option.number, "label": option.label, "selected": option.isSelected] as [String: Any]
            }
        }
        if let currentActivity { row["activity"] = currentActivity }
        // Why it died. Without this a crashed session on a box renders as a bare
        // "Crashed" with the reason sitting in that machine's log.
        if let lastErrorMessage { row["lastError"] = lastErrorMessage }
        if let prompt = pendingPrompt?.text { row["promptText"] = prompt }
        // A branch Udha recorded at creation wins over the path guess: the
        // `-wt/` leaf folds `/` to `-`, so `udha/cov-a3f2` is not recoverable
        // from its own directory. Sessions predating the stored field — every
        // one already on disk — keep the original derivation exactly.
        if let stored = branch, !stored.isEmpty {
            row["branch"] = stored
            row["repo"] = Self.repoName(from: directory)
        } else if isWorktreePath, let derived = Self.branchName(from: directory) {
            row["branch"] = derived
            row["repo"] = Self.repoName(from: directory)
        }
        return row
    }

    private var isWorktreePath: Bool { directory.contains("-wt/") }

    /// `/x/scholar-health-wt/udha-cov` -> `udha-cov`
    static func branchName(from directory: String) -> String? {
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// `/x/scholar-health-wt/udha-cov` -> `scholar-health`
    static func repoName(from directory: String) -> String? {
        let parent = ((directory as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard parent.hasSuffix("-wt") else { return parent.isEmpty ? nil : parent }
        return String(parent.dropLast(3))
    }
}

extension SessionSnapshot {
    /// Reconstructs a snapshot from a `wireRow` payload — the client side of the
    /// same contract `wireRow(staleAfter:)` writes. Used by `RemoteHostClient`
    /// so the desktop can render sessions supervised on another machine.
    ///
    /// Some fields the desktop stores are never on the wire (a prompt's `style`
    /// / `isDestructive`, exit codes): the host owns those, and every remote
    /// action is answered by the host, so the client only needs enough to
    /// render and to know a prompt is waiting.
    init?(wireRow r: [String: Any]) {
        guard let idStr = r["id"] as? String, let id = UUID(uuidString: idStr),
              let label = r["label"] as? String,
              let stateRaw = r["state"] as? String, let state = SessionState(rawValue: stateRaw)
        else { return nil }

        self.id = id
        self.label = label
        self.directory = r["directory"] as? String ?? ""
        self.state = state
        self.stateEnteredAt = Date().addingTimeInterval(-Double(r["stateEnteredSecAgo"] as? Int ?? 0))
        self.currentActivity = r["activity"] as? String
        self.lastErrorMessage = r["lastError"] as? String
        self.lastSpoken = nil
        self.priority = (r["priority"] as? String).flatMap(SessionPriority.init(rawValue:)) ?? .normal
        self.exitCode = nil
        self.agentName = r["agentName"] as? String
        self.parentSessionID = nil
        self.branch = r["branch"] as? String
        self.tool = (r["tool"] as? String).flatMap(SessionTool.init(rawValue:))
        self.tmuxName = r["tmux"] as? String
        self.sizePinned = (r["sizePinned"] as? Bool) ?? false
        self.phase = (r["phase"] as? String).flatMap(SessionPhase.init(rawValue:)) ?? .starting
        self.phaseDetail = r["phaseDetail"] as? String
        self.phaseEnteredAt = Date().addingTimeInterval(-Double(r["phaseEnteredSecAgo"] as? Int ?? 0))
        self.subagentCount = r["subagentCount"] as? Int ?? 0
        self.contextPercent = r["contextPercent"] as? Int
        self.costCents = r["costCents"] as? Int
        self.model = r["model"] as? String
        self.account = r["account"] as? String
        self.folderID = (r["folder"] as? String).flatMap(UUID.init(uuidString:))
        self.hidden = (r["hidden"] as? Bool) ?? false
        self.supportsAttentionEvents = r["attentionState"] != nil
        if let raw = r["attentionState"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(SessionAttentionState.self, from: data) {
            self.attentionState = decoded
        }
        self.lastQuestion = r["lastQuestion"] as? String
        self.dialogOptions = (r["options"] as? [[String: Any]])?.compactMap { o in
            guard let n = o["n"] as? Int, let label = o["label"] as? String else { return nil }
            return PaneReading.DialogOption(number: n, label: label, isSelected: o["selected"] as? Bool ?? false)
        } ?? []
        if r["hasPendingPrompt"] as? Bool ?? false {
            let text = (r["promptText"] as? String) ?? (r["lastQuestion"] as? String) ?? ""
            self.pendingPrompt = PendingPrompt(text: text, style: .freeform, isDestructive: false, detectedAt: Date())
        } else {
            self.pendingPrompt = nil
        }
    }
}
