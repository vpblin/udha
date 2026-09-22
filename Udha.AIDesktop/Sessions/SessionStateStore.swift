import Foundation
import Observation

@MainActor
@Observable
final class SessionStateStore {
    private var attentionURL: URL?
    private(set) var attentionPersistenceError: String?
    private var savedAttention: [String: SessionAttentionState] = [:]
    var onAttentionEvent: ((SessionSnapshot, AttentionEvent) -> Void)?

    func loadAttention(from url: URL) {
        attentionURL = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: SessionAttentionState].self, from: data) {
            savedAttention = saved
        }
    }

    @discardableResult
    private func saveAttention(_ snapshot: SessionSnapshot) -> Bool {
        attentionPersistenceError = nil
        guard snapshot.hostName == nil else { return true }
        var next = savedAttention
        next[snapshot.id.uuidString] = snapshot.attentionState
        guard let attentionURL else { savedAttention = next; return true }
        do {
            try FileManager.default.createDirectory(at: attentionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: attentionURL, options: .atomic)
            savedAttention = next
            return true
        } catch { attentionPersistenceError = error.localizedDescription; Log.pty.error("Could not save attention inbox: \(error.localizedDescription)"); return false }
    }

    private(set) var snapshots: [UUID: SessionSnapshot] = [:]
    private(set) var orderedIDs: [UUID] = []
    var focusedSessionID: UUID?

    /// Ordered snapshots, maintained as a stored property rather than recomputed
    /// on every access. Views read this several times per body evaluation
    /// (`UdhaSidebar`, `EdgeOverlayView`, `MenuBarStatusView`), and recomputing it
    /// meant an O(n) `compactMap` plus a full copy of every `SessionSnapshot`
    /// each time. Rebuilt only when the inputs actually change.
    private(set) var all: [SessionSnapshot] = []

    /// `all` minus the rows hidden themselves or filed in a hidden folder.
    /// Every list, count and announcement reads this one; `all` is for the
    /// plumbing that must still see a hidden session (the bridge, which has
    /// to send it so a client can unhide it; the supervisor, which keeps
    /// classifying it). Stored and rebuilt with `all`, for the same reason.
    private(set) var visible: [SessionSnapshot] = []

    /// Session folders per machine, in display order. Keyed by host name,
    /// "" for this machine — the same split as `SessionSnapshot.hostName`.
    /// This machine's list is a mirror of `AppConfig.sessionFolders`; a
    /// remote host's arrived on the wire with its `sessions_full`.
    private var foldersByHost: [String: [SessionFolder]] = [:]

    /// Fires after any mutation that changed something. `changed` carries the
    /// affected snapshot, `removed` the id that went away.
    ///
    /// Hooked to `rebuildAll` rather than to `update` alone: `insert`,
    /// `transition` and `remove` all mutate too, so observing only `update`
    /// would miss every spawn and every close.
    var onChange: ((_ changed: SessionSnapshot?, _ removed: UUID?) -> Void)?

    private func rebuildAll(changed: SessionSnapshot? = nil, removed: UUID? = nil) {
        all = orderedIDs.compactMap { snapshots[$0] }
        visible = all.filter(isVisible)
        onChange?(changed, removed)
    }

    // MARK: - Folders + hidden

    func folders(host: String?) -> [SessionFolder] {
        foldersByHost[host ?? ""] ?? []
    }

    func folder(id: UUID, host: String?) -> SessionFolder? {
        folders(host: host).first { $0.id == id }
    }

    /// Hidden itself, or filed in a hidden folder. A `folderID` the store
    /// does not know reads as loose: `delete_folder` lands as a row delta and
    /// a folder-list push that can arrive in either order.
    func isVisible(_ snap: SessionSnapshot) -> Bool {
        if snap.hidden { return false }
        guard let f = snap.folderID else { return true }
        return !(folder(id: f, host: snap.hostName)?.hidden ?? false)
    }

    /// Replace one machine's folder list. Only this machine's list announces
    /// itself through `onChange` (with nothing changed or removed — the shape
    /// the bridge already turns into a coalesced full push, exactly as a
    /// reorder does): a remote host's list *came* from the wire, and
    /// re-announcing it would make this machine's bridge push a pointless
    /// full snapshot to the iPad.
    func setFolders(_ list: [SessionFolder], host: String?) {
        let key = host ?? ""
        guard (foldersByHost[key] ?? []) != list else { return }
        foldersByHost[key] = list.isEmpty ? nil : list
        visible = all.filter(isVisible)
        if host == nil { onChange?(nil, nil) }
    }

    /// What the "N folders and M sessions hidden" footer counts, across every
    /// machine: hidden folders, plus every session out of sight for either
    /// reason.
    var hiddenCounts: (folders: Int, sessions: Int) {
        (foldersByHost.values.flatMap { $0 }.filter(\.hidden).count,
         all.count - visible.count)
    }

    var active: [SessionSnapshot] {
        all.filter { $0.state != .exited && $0.state != .crashed }
    }

    func snapshot(id: UUID) -> SessionSnapshot? {
        snapshots[id]
    }

    func snapshot(matching label: String) -> SessionSnapshot? {
        let target = label.lowercased()
        let exact = all.first { $0.label.lowercased() == target }
        if let exact { return exact }
        let prefixMatches = all.filter { $0.label.lowercased().hasPrefix(target) }
        return prefixMatches.count == 1 ? prefixMatches.first : nil
    }

    func matches(label: String) -> [SessionSnapshot] {
        let target = label.lowercased()
        return all.filter { $0.label.lowercased().contains(target) }
    }

    func insert(_ snapshot: SessionSnapshot) {
        var snapshot = snapshot
        if snapshots[snapshot.id] == nil, snapshot.hostName == nil,
           let saved = savedAttention[snapshot.id.uuidString] { snapshot.attentionState = saved }
        if let existing = snapshots[snapshot.id] {
            guard existing != snapshot else { return }
        } else {
            orderedIDs.append(snapshot.id)
        }
        snapshots[snapshot.id] = snapshot
        rebuildAll(changed: snapshot)
    }

    func remove(id: UUID) {
        guard snapshots.removeValue(forKey: id) != nil else { return }
        orderedIDs.removeAll { $0 == id }
        if focusedSessionID == id { focusedSessionID = nil }
        rebuildAll(removed: id)
    }

    func update(id: UUID, _ block: (inout SessionSnapshot) -> Void) {
        guard let existing = snapshots[id] else { return }
        var snap = existing
        block(&snap)
        if snap.hostName == nil {
            reconcileAttention(previous: existing, current: &snap)
        }
        // Assigning unconditionally would notify @Observable even when the
        // block changed nothing — and `capture-pane` runs a classify pass per
        // session every 2s, so no-op updates were invalidating the entire UI
        // several times a second while everything sat idle.
        guard snap != existing else { return }
        if snap.attentionState != existing.attentionState && !saveAttention(snap) { return }
        snapshots[id] = snap
        rebuildAll(changed: snap)
        if snap.hostName == nil {
            let previousIDs = Set(existing.attentionState.events.map(\.id))
            for event in snap.attentionState.events where !previousIDs.contains(event.id) && event.state == .open {
                if event.kind.needsAction || event.source == "watch"
                    || (event.kind == .review && snap.attentionState.notifyReviews)
                    || (event.kind == .completed && snap.attentionState.notifyCompletions) {
                    onAttentionEvent?(snap, event)
                }
            }
        }
    }

    /// Move `movingID` so it lands at the slot currently occupied by
    /// `targetID` (i.e. dropping onto a card inserts the dragged card before
    /// it). No-op if either id is unknown or if they're already adjacent in
    /// the requested direction.
    func reorder(movingID: UUID, before targetID: UUID) {
        guard movingID != targetID,
              let from = orderedIDs.firstIndex(of: movingID),
              let to = orderedIDs.firstIndex(of: targetID) else { return }
        orderedIDs.remove(at: from)
        let insertAt = (from < to) ? to - 1 : to
        orderedIDs.insert(movingID, at: insertAt)
        rebuildAll()
    }

    /// Impose a whole order at once: the known ids in `ids` come first, in
    /// that order, and anything the list left out keeps its current relative
    /// place behind them. Unknown ids are ignored, so a list from another
    /// machine that names a session this store has since dropped is harmless.
    /// The host applies the order a client dragged into; the client applies
    /// the order a host sent back.
    func setOrder(_ ids: [UUID]) {
        var next: [UUID] = []
        var seen = Set<UUID>()
        for id in ids where snapshots[id] != nil && !seen.contains(id) {
            next.append(id)
            seen.insert(id)
        }
        for id in orderedIDs where !seen.contains(id) { next.append(id) }
        guard next != orderedIDs else { return }
        orderedIDs = next
        rebuildAll()
    }

    func transition(id: UUID, to newState: SessionState) -> Bool {
        guard let snap = snapshots[id] else { return false }
        guard snap.state != newState else { return false }
        update(id: id) { value in
            value.state = newState
            value.stateEnteredAt = Date()
        }
        return true
    }

    private func reconcileAttention(previous old: SessionSnapshot, current snap: inout SessionSnapshot) {
        let working: Set<SessionPhase> = [.thinking, .planning, .usingTool]
        let wasResting = old.phase == .awaitingReply || old.phase == .idle || old.state == .completed
            || (snap.tool != .claude && (old.state == .idle || old.state == .needsInput))
        let started = working.contains(snap.phase) && !working.contains(old.phase)
            || (snap.tool != .claude && snap.state == .working && old.state != .working)
        if started && wasResting {
            if !snap.attentionState.awaitingWorkAfterInput { snap.attentionState.beginTurn() }
            snap.attentionState.awaitingWorkAfterInput = false
            snap.lastQuestion = nil
        }
        if working.contains(snap.phase) || snap.state == .working {
            if started { snap.attentionState.awaitingWorkAfterInput = false }
            if snap.attentionState.notifyWhenDone { snap.attentionState.watchSawWork = true }
            snap.lastQuestion = nil
        }
        if snap.phase == .awaitingApproval && old.phase != .awaitingApproval {
            if !snap.attentionState.events.contains(where: { $0.source == "approval" && $0.state != .resolved }) {
                snap.attentionState.add(kind: .approval, summary: "Approval needed to continue",
                    detail: snap.pendingPrompt?.text ?? snap.phaseDetail, source: "approval")
            }
        } else if old.phase == .awaitingApproval && snap.phase != .awaitingApproval {
            snap.attentionState.resolve(source: "approval")
        }
        if snap.phase == .awaitingApproval,
           let text = snap.pendingPrompt?.text ?? snap.phaseDetail, !text.isEmpty,
           let index = snap.attentionState.events.lastIndex(where: { $0.source == "approval" && $0.state == .open }) {
            snap.attentionState.events[index].summary = String(text.prefix(180))
            snap.attentionState.events[index].detail = String(text.prefix(2000))
        }
        // An idle prompt or a Stop hook only means the turn ended. Completion
        // watches are satisfied by task_completed (or a successful process exit).
        if (snap.state == .errored || snap.state == .crashed) && snap.state != old.state {
            snap.attentionState.add(kind: .blocked, summary: "Session needs help",
                                    detail: snap.lastErrorMessage, source: "error")
        } else if snap.state == .working { snap.attentionState.resolve(source: "error") }
        if snap.state == .exited && old.state != .exited {
            for i in snap.attentionState.events.indices where snap.attentionState.events[i].kind.needsAction {
                snap.attentionState.events[i].state = .resolved
            }
            if snap.exitCode == 0 { _ = snap.attentionState.complete(summary: "Session finished successfully.") }
            else { snap.attentionState.notifyWhenDone = false; snap.attentionState.watchSawWork = false }
        }
    }

    func beginAttentionTurn(id: UUID, at time: Double = Date().timeIntervalSince1970) {
        // The submit path and lifecycle hook can describe the same input.
        guard time > (snapshots[id]?.attentionState.turnStartedAt ?? 0) else { return }
        update(id: id) {
            $0.attentionState.beginTurn(at: time)
            $0.attentionState.awaitingWorkAfterInput = ![.thinking, .planning, .usingTool].contains($0.phase)
            $0.lastQuestion = nil
        }
    }

    @discardableResult
    func changeAttention(id: UUID, action: String, eventID: String? = nil, enabled: Bool = false) -> Bool {
        attentionPersistenceError = nil
        guard let snap = snapshots[id], snap.hostName == nil else { return false }
        if ["dismiss", "resolve", "snooze"].contains(action) {
            guard let index = snap.attentionState.events.firstIndex(where: { $0.id == eventID && $0.state == .open }) else { return false }
            update(id: id) {
                switch action {
                case "snooze": $0.attentionState.events[index].snoozedUntil = Date().timeIntervalSince1970 + 900
                case "resolve": $0.attentionState.events[index].state = .resolved
                default: $0.attentionState.events[index].state = .dismissed
                }
            }
        } else if ["watch", "reviews", "completions"].contains(action) {
            update(id: id) {
                switch action {
                case "watch":
                    $0.attentionState.notifyWhenDone = enabled
                    $0.attentionState.watchSawWork = enabled && ($0.state == .working || [.thinking, .planning, .usingTool].contains($0.phase))
                case "reviews": $0.attentionState.notifyReviews = enabled
                default: $0.attentionState.notifyCompletions = enabled
                }
            }
        } else { return false }
        return attentionPersistenceError == nil
    }

    func processAttentionCommand(id: UUID, command: [String: Any]) -> [String: Any] {
        guard let snap = snapshot(id: id), let commandID = command["commandID"] as? String,
              let action = command["action"] as? String else { return ["ok": false] }
        if snap.attentionState.processedCommands.contains(commandID) { return ["ok": true, "eventID": commandID] }
        guard let created = command["createdAt"] as? Double,
              created >= snap.attentionState.turnStartedAt, created <= Date().timeIntervalSince1970 + 30 else {
            return ["ok": false, "message": "This request belongs to an earlier turn."]
        }
        if action == "resolve_attention" {
            return ["ok": changeAttention(id: id, action: "resolve", eventID: command["eventID"] as? String)]
        }
        let kind: AttentionEvent.Kind? = action == "task_completed" ? .completed
            : (command["kind"] as? String).flatMap(AttentionEvent.Kind.init(rawValue:))
        guard ["request_attention", "task_completed"].contains(action), let kind,
              let summary = command["summary"] as? String, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["ok": false, "message": "A kind and summary are required."]
        }
        var eventID = commandID
        update(id: id) { s in
            let watched = kind == .completed && s.attentionState.notifyWhenDone
            if kind == .completed {
                s.attentionState.notifyWhenDone = false
                s.attentionState.watchSawWork = false
                for i in s.attentionState.events.indices where s.attentionState.events[i].kind.needsAction {
                    s.attentionState.events[i].state = .resolved
                }
            }
            let event = s.attentionState.add(kind: kind, summary: summary, detail: command["detail"] as? String,
                url: command["url"] as? String, id: commandID, source: watched ? "watch" : "agent", at: created)
            if event == nil, let previous = s.attentionState.events.last(where: { $0.turnID == s.attentionState.turnID && $0.kind == kind && $0.summary == summary }) { eventID = previous.id }
            s.attentionState.processedCommands.append(commandID)
            s.attentionState.processedCommands = Array(s.attentionState.processedCommands.suffix(500))
        }
        guard snapshot(id: id)?.attentionState.processedCommands.contains(commandID) == true else {
            return ["ok": false, "message": "Could not persist the attention request."]
        }
        return ["ok": true, "eventID": eventID]
    }

    func recordSpoken(id: UUID, text: String) {
        update(id: id) { $0.lastSpoken = SpokenRecord(text: text, at: Date()) }
    }
}
