import Foundation

/// Protocol v2 for the mobile bridge: pushed session state, remote action
/// verbs, diff review, terminal frames, meetings and agents.
///
/// Kept in an extension beside `MobileBridge` rather than inside it because v1
/// must stay readable and provably untouched — an iPhone that never sends
/// `hello` has to behave exactly as it did before this file existed.
///
/// All mutable v2 state lives in `BridgeV2State` so the extension needs no
/// stored properties of its own.

// MARK: - Routing

extension MobileBridge {

    /// Everything protocol v2 adds. Returns false for a type it does not know,
    /// so the caller can log it exactly as before.
    @discardableResult
    func handleV2Payload(_ payload: [String: Any]) -> Bool {
        guard let type = payload["type"] as? String else { return false }
        let id = (payload["id"] as? String).flatMap(UUID.init(uuidString:))

        switch type {
        case "hello":            handleHello(payload)
        case "attention_action":
            guard let id, let action = payload["action"] as? String,
                  stateStore.snapshot(id: id)?.hostName == nil else {
                ack("attention_action", id: id, ok: false, error: "unknown session")
                return true
            }
            let ok = sessionManager.changeAttention(id: id, action: action,
                eventID: payload["eventID"] as? String, enabled: payload["enabled"] as? Bool ?? false)
            ack("attention_action", id: id, ok: ok, error: ok ? nil : "This attention item is no longer open.")

        // --- actions -----------------------------------------------------
        case "send_input":       handleSendInput(payload, id: id)
        case "send_keys":        handleSendKeys(payload, id: id)
        case "interrupt":        handleInterrupt(id: id)
        case "approve":          handleApprove(payload, id: id)
        case "deny":             handleDeny(id: id)
        case "kill_session":     handleKillSession(payload, id: id)
        case "rename_session":   handleRenameSession(payload, id: id)
        case "reorder_sessions": handleReorderSessions(payload)

        // --- folders + hidden (`id` is the folder's for the folder verbs) ---
        case "set_session_folder": handleSetSessionFolder(payload, id: id)
        case "set_session_hidden": handleSetSessionHidden(payload, id: id)
        case "create_folder":      handleCreateFolder(payload, id: id)
        case "rename_folder":      handleRenameFolder(payload, id: id)
        case "delete_folder":      handleDeleteFolder(id: id)
        case "set_folder_hidden":  handleSetFolderHidden(payload, id: id)
        case "reorder_folders":    handleReorderFolders(payload)
        case "unhide_all":
            sessionManager.unhideAll()
            logRemote("unhide_all", id: nil)
            ack("unhide_all", id: nil, ok: true)
        case "rotate_account":   handleRotateAccount(payload, id: id)
        case "fetch_accounts":
            // Re-read who each dir is signed in as before answering: this is
            // what the settings sheet asks after a sign-in finished.
            sessionManager.refreshLoginEmails()
            sendAccounts()
        case "add_claude_tree", "remove_claude_tree", "add_claude_login", "remove_claude_login":
            handleLoginEdit(type, payload)

        // --- review ------------------------------------------------------
        case "fetch_diff":       handleFetchDiff(payload, id: id)

        // --- machine -----------------------------------------------------
        case "fetch_stats":      handleFetchStats()

        // --- attachments -------------------------------------------------
        case "put_attachment":   handlePutAttachment(payload, id: id)

        // --- terminal ----------------------------------------------------
        case "attach_terminal":  handleAttachTerminal(payload, id: id)
        case "detach_terminal":  handleDetachTerminal()
        case "resize_terminal":  handleResizeTerminal(payload, id: id)
        case "release_terminal_size": handleReleaseTerminalSize(id: id)
        case "fetch_scrollback": handleFetchScrollback(payload, id: id)

#if !UDHA_AGENT
        // --- meetings ----------------------------------------------------
        case "list_meetings":    sendMeetingsFull()
        case "fetch_meeting":    sendMeetingDetail(payload["id"] as? String)
        case "start_meeting":    handleStartMeeting(payload)
        case "stop_meeting":     handleStopMeeting()
        case "meeting_action_done": handleActionItemDone(payload)
        case "meeting_update_notes": handleUpdateMeetingNotes(payload)
        case "meeting_ask":      handleMeetingAsk(payload)
        case "push_local_meeting":  handlePushLocalMeeting(payload)

        // --- videos ------------------------------------------------------
        case "list_videos":      sendVideosFull()
        case "rename_video":     handleRenameVideo(payload, id: id)
        case "delete_video":     handleDeleteVideo(payload, id: id)
#endif

        // --- agents ------------------------------------------------------
        case "list_agents":      sendAgentsFull()
        case "run_agent":        handleRunAgent(payload)

        default:                 return false
        }
        return true
    }

    // MARK: - Handshake

    private func handleHello(_ payload: [String: Any]) {
        let clientCaps = Set((payload["capabilities"] as? [String]) ?? [])
        let version = (payload["protocol"] as? Int) ?? 1

        // A fresh handshake means the old client is gone. Give its pane back
        // before forgetting that we ever resized it — the new client will ask
        // for its own size on attach.
        restoreWindowSizeIfNeeded()
        v2.reset()
        v2.protocolVersion = version
        // Only agree to what both sides implement.
        v2.capabilities = clientCaps.intersection(BridgeV2State.serverCapabilities)

        Log.bridge.info("hello: protocol=\(version) kind=\(UdhaBuild.instanceKind) caps=\(v2.capabilities.sorted().joined(separator: ","))")

        relay.sendRelay([
            "type": "hello_ack",
            "protocol": 2,
            "capabilities": Array(v2.capabilities),
            "instanceKind": UdhaBuild.instanceKind,
            "staleAfterSec": config.config.staleAfterSeconds,
        ])
        sendQuickCommands()
        // A fresh full snapshot always follows the handshake, so the client
        // starts from a known state before any delta arrives.
        sendSessionsFull()
    }

    func sendQuickCommands() {
        relay.sendRelay([
            "type": "quick_commands",
            "commands": config.config.quickCommands.map(\.wireValue),
        ])
    }

    // MARK: - Row serialization

    /// Delegates to `SessionSnapshot.wireRow` so the serializer can be unit
    /// tested against the mobile decoder without building a whole bridge.
    func wireRow(_ snap: SessionSnapshot) -> [String: Any] {
        snap.wireRow(staleAfter: config.config.staleAfterSeconds)
    }

    /// Only this machine's own sessions.
    ///
    /// The store also holds the sessions of whatever box this Mac is paired
    /// with — that is what makes the desktop board two columns — but this host
    /// cannot *serve* one: there is no local pane to capture, scroll back
    /// through or resize, so a forwarded box row listed beautifully on the phone
    /// and then refused every action with "unknown session", behind a terminal
    /// that never drew a frame. The box serves its own sessions; the phone
    /// reaches them by switching machines, which is the model the rest of the
    /// client already follows.
    var clientVisibleSessions: [SessionSnapshot] {
        stateStore.all.filter { $0.hostName == nil }
    }

    func sendSessionsFullV2() {
        // Hidden rows are still sent: a client needs them to offer "Unhide
        // all", and `hidden` on the row says what to do with them. The folder
        // list rides here and only here — a folder edit is a full push.
        relay.sendRelay([
            "type": "sessions_full",
            "sessions": clientVisibleSessions.map { wireRow($0) },
            "folders": stateStore.folders(host: nil).map(\.wireValue),
        ])
        // A full snapshot supersedes anything queued.
        _ = v2.drainWithoutSequencing()
    }

    // MARK: - Delta push

    /// Called from `SessionStateStore.onChange` for every mutation.
    func enqueueDelta(changed: SessionSnapshot?, removed: UUID?) {
        // v1 clients get nothing pushed — exactly today's behaviour.
        guard v2.isV2, v2.capabilities.contains("delta") else { return }

        // Neither changed nor removed means the set is the same but its order
        // is not — a drag-reorder in the sidebar. There is no row to put in a
        // delta, so without a full snapshot the new order would never reach a
        // client until something else happened to trigger a refresh.
        if changed == nil && removed == nil {
            scheduleReorderPush()
            return
        }
        // Same rule as the full snapshot: a row this host cannot serve must not
        // reach the client, or the list grows a session every action will refuse.
        // A removal is still forwarded — harmless for an id the client never had,
        // and the one way a row that predates this rule ever leaves the list.
        if let changed, changed.hostName != nil { return }
        v2.enqueue(changed: changed, removed: removed)
        scheduleFlush()
    }

    /// Coalesced: a drag emits a reorder per frame, and each one would
    /// otherwise be a full session list on the wire.
    private func scheduleReorderPush() {
        guard v2.reorderTask == nil else { return }
        v2.reorderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.v2.reorderTask = nil
            self.sendSessionsFull()
        }
    }

    private func scheduleFlush() {
        guard v2.flushTask == nil else { return }
        v2.flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.v2.flushTask = nil
            self.flushDelta()
        }
    }

    private func flushDelta() {
        guard let batch = v2.drain() else { return }
        relay.sendRelay([
            "type": "sessions_delta",
            "seq": batch.seq,
            "changed": batch.changed.map { wireRow($0) },
            "removed": batch.removed.map(\.uuidString),
        ])
    }

    // MARK: - Machine stats

    /// Answer `fetch_stats` with this machine's vitals.
    ///
    /// The reading itself is done off the main actor: it stats filesystems and,
    /// on Linux, shells out to `nvidia-smi` and `docker`, none of which belongs
    /// on the actor that also drives the UI and the session classifier. What is
    /// read *here* is the part only the main actor knows — the relay link and
    /// the session count — and it is captured before the hop.
    private func handleFetchStats() {
        // The count the client can reconcile against its own list.
        let sessionCount = clientVisibleSessions.count
        let link = MachineStats.Relay(
            instanceID: relay.instanceID,
            url: relay.relayURL,
            transport: relay.transportName,
            connectedAt: relay.connectedAt,
            lastPongAt: relay.lastPongAt,
            rttMilliseconds: relay.rttMilliseconds,
            capabilities: v2.capabilities.sorted(),
            deltaSeq: v2.seq,
            signedIn: auth0.hasCachedTokens
        )
        let errors = relay.recentErrors
        let logTail = FileLogger.shared.tail(lines: 8)
        let collector = v2.statsCollector

        Task.detached(priority: .utility) { [weak self] in
            var stats = collector.collect(sessionCount: sessionCount)
            stats.relay = link
            stats.errors = errors
            stats.logTail = logTail
            stats.agentKind = UdhaBuild.kind
            stats.agentVersion = UdhaBuild.version
            await MainActor.run {
                self?.relay.sendRelay(["type": "stats", "stats": stats.wire])
            }
        }
    }

    // MARK: - Actions

    func ack(_ action: String, id: UUID?, ok: Bool, error: String? = nil) {
        var payload: [String: Any] = ["type": "action_result", "action": action, "ok": ok]
        if let id { payload["id"] = id.uuidString }
        if let error { payload["error"] = error }
        relay.sendRelay(payload)
    }

    func logRemote(_ verb: String, id: UUID?, detail: String? = nil) {
        activity?.record(.remoteAction(sessionID: id, verb: verb, detail: detail, source: "mobile"))
    }

    private func handleSendInput(_ payload: [String: Any], id: UUID?) {
        guard let id, stateStore.snapshot(id: id) != nil else {
            ack("send_input", id: id, ok: false, error: "unknown session")
            return
        }
        let text = (payload["text"] as? String) ?? ""
        guard !text.isEmpty else {
            ack("send_input", id: id, ok: false, error: "empty text")
            return
        }
        let submit = (payload["submit"] as? Bool) ?? true
        // `sendInput` is the verified send-keys -l + Enter path; `sendRaw`
        // types without submitting. Do not "improve" either.
        let ok = submit ? sessionManager.sendInput(id: id, text: text)
                        : sessionManager.sendRaw(id: id, text: text)
        logRemote("send_input", id: id, detail: text)
        ack("send_input", id: id, ok: ok, error: ok ? nil : "send failed")
    }

    private func handleSendKeys(_ payload: [String: Any], id: UUID?) {
        guard let id, stateStore.snapshot(id: id) != nil else {
            ack("send_keys", id: id, ok: false, error: "unknown session")
            return
        }
        let keys = (payload["keys"] as? [String]) ?? []
        // Reject the whole message on any invalid element — these become
        // arguments to tmux send-keys, so a permissive validator is a shell
        // injection surface.
        guard TmuxKeyValidator.validate(keys) else {
            ack("send_keys", id: id, ok: false, error: "invalid key sequence")
            return
        }
        var ok = true
        for key in keys where !sessionManager.sendKey(id: id, key: key) { ok = false }
        logRemote("send_keys", id: id, detail: keys.joined(separator: " "))
        ack("send_keys", id: id, ok: ok, error: ok ? nil : "send failed")
    }

    private func handleInterrupt(id: UUID?) {
        guard let id, stateStore.snapshot(id: id) != nil else {
            ack("interrupt", id: id, ok: false, error: "unknown session")
            return
        }
        let ok = sessionManager.sendKey(id: id, key: "Escape")
        logRemote("interrupt", id: id)
        ack("interrupt", id: id, ok: ok, error: ok ? nil : "send failed")
    }

    /// The safety-critical guard of this workstream.
    ///
    /// A phone card can be seconds stale. Without this check an "Approve" tap
    /// aimed at a dialog that has already closed would land as a bare `1` or
    /// Enter in whatever the session moved on to.
    private func handleApprove(_ payload: [String: Any], id: UUID?) {
        guard let id, let snap = stateStore.snapshot(id: id) else {
            ack("approve", id: id, ok: false, error: "unknown session")
            return
        }
        // The guard's real job is stopping a stale tap from pressing a digit
        // into a session that has moved on. Keying it to `phase` alone was too
        // strict: the sidecar owns the phase and does not flag every dialog, so
        // a genuine prompt could be refused — and the phone rendered the
        // refusal nowhere, which read as the session being frozen.
        //
        // Options currently parsed off the pane are the direct evidence that a
        // dialog is on screen right now, so either is enough.
        guard snap.phase == .awaitingApproval || !snap.dialogOptions.isEmpty else {
            ack("approve", id: id, ok: false, error: "no dialog on screen")
            return
        }
        // Never press a digit the dialog is not offering.
        if let requested = payload["option"] as? Int, !snap.dialogOptions.isEmpty,
           !snap.dialogOptions.contains(where: { $0.number == requested }) {
            ack("approve", id: id, ok: false, error: "option \(requested) is not on this dialog")
            return
        }
        let option = payload["option"] as? Int
        let key = option.map(String.init) ?? "1"
        let ok = sessionManager.sendKey(id: id, key: key)
        logRemote("approve", id: id, detail: snap.pendingPrompt?.text)
        activity?.record(.approvePrompt(sessionID: id,
                                        promptText: snap.pendingPrompt?.text ?? snap.phaseDetail ?? ""))
        ack("approve", id: id, ok: ok, error: ok ? nil : "send failed")
    }

    private func handleDeny(id: UUID?) {
        guard let id, let snap = stateStore.snapshot(id: id) else {
            ack("deny", id: id, ok: false, error: "unknown session")
            return
        }
        guard snap.phase == .awaitingApproval else {
            ack("deny", id: id, ok: false, error: "no dialog visible")
            return
        }
        // Claude's permission dialogs put "No" last; Escape is the reliable
        // dismissal across every variant of it.
        let ok = sessionManager.sendKey(id: id, key: "Escape")
        logRemote("deny", id: id, detail: snap.pendingPrompt?.text)
        activity?.record(.rejectPrompt(sessionID: id,
                                       promptText: snap.pendingPrompt?.text ?? "",
                                       reason: "denied from mobile"))
        ack("deny", id: id, ok: ok, error: ok ? nil : "send failed")
    }

    private func handleKillSession(_ payload: [String: Any], id: UUID?) {
        guard (payload["confirm"] as? Bool) == true else {
            ack("kill_session", id: id, ok: false, error: "confirm required")
            return
        }
        guard let id, stateStore.snapshot(id: id) != nil else {
            ack("kill_session", id: id, ok: false, error: "unknown session")
            return
        }
        // terminate, not remove: the tmux session dies but the SessionConfig
        // survives so the label can be respawned. `close_session` is the
        // destructive one and keeps its v1 behaviour.
        sessionManager.terminateSession(id: id)
        logRemote("kill_session", id: id)
        ack("kill_session", id: id, ok: true)
    }

    /// Rename from the phone. The label is this app's own — sidebar, overlay
    /// and voice matching all read it — so `SessionManager.rename` is the only
    /// thing that may write it: it de-duplicates against every other session
    /// and updates the live snapshot and the persisted config together.
    ///
    /// No `sessions_delta` is sent from here. Renaming mutates the snapshot,
    /// and the store's change hook already pushes that — sending one here too
    /// would double up and burn a sequence number the client checks for gaps.
    private func handleRenameSession(_ payload: [String: Any], id: UUID?) {
        let label = ((payload["label"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, stateStore.snapshot(id: id) != nil else {
            ack("rename_session", id: id, ok: false, error: "unknown session")
            return
        }
        guard !label.isEmpty else {
            ack("rename_session", id: id, ok: false, error: "empty label")
            return
        }
        sessionManager.rename(sessionID: id, to: label)
        logRemote("rename_session", id: id, detail: label)
        ack("rename_session", id: id, ok: true)
    }

    /// A client dragged this machine's rows into a new order and sends the
    /// whole list back. Applied to the store and persisted into config, so it
    /// is the order every `sessions_full` reports from now on — including the
    /// one that follows the client's next reconnect, which used to undo the
    /// drag. The store's reorder fires `onChange` with nothing changed and
    /// nothing removed, which `enqueueDelta` already turns into a coalesced
    /// full push to every client.
    private func handleReorderSessions(_ payload: [String: Any]) {
        let ids = ((payload["order"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else {
            ack("reorder_sessions", id: nil, ok: false, error: "empty order")
            return
        }
        sessionManager.setOrder(ids)
        logRemote("reorder_sessions", id: nil, detail: "\(ids.count) sessions")
        ack("reorder_sessions", id: nil, ok: true)
    }

    // MARK: - Folders + hidden

    // Same rule as `rename_session`: nothing is pushed from here. A session's
    // folder or hidden flag is a snapshot change, which the store's hook
    // already sends as a delta; a change to the folder list goes through
    // `setFolders(host: nil)`, which fires the hook with nothing changed and
    // nothing removed — the shape `enqueueDelta` turns into a coalesced full
    // push, the only message that carries the list. And, as with
    // `attention_action`, a row this machine merely forwards for another host
    // is refused: its own host owns it.

    private func handleSetSessionFolder(_ payload: [String: Any], id: UUID?) {
        guard let id, let snap = stateStore.snapshot(id: id), snap.hostName == nil else {
            ack("set_session_folder", id: id, ok: false, error: "unknown session")
            return
        }
        // Absent, null or "" all mean loose.
        let folder = (payload["folder"] as? String).flatMap(UUID.init(uuidString:))
        guard sessionManager.setFolder(sessionID: id, folderID: folder) else {
            ack("set_session_folder", id: id, ok: false, error: "unknown folder")
            return
        }
        logRemote("set_session_folder", id: id, detail: folder?.uuidString ?? "none")
        ack("set_session_folder", id: id, ok: true)
    }

    /// Move a session to another Claude login in its pool, now. `to` names
    /// the login (its config dir, as `accounts` listed it); without it the
    /// host picks the emptiest. The row's `account` is the echo.
    private func handleRotateAccount(_ payload: [String: Any], id: UUID?) {
        guard let id, let snap = stateStore.snapshot(id: id), snap.hostName == nil else {
            ack("rotate_account", id: id, ok: false, error: "unknown session")
            return
        }
        guard sessionManager.loginPool(for: id) != nil else {
            ack("rotate_account", id: id, ok: false, error: "this session's folder has one Claude login")
            return
        }
        let target = payload["to"] as? String
        let ok = sessionManager.rotateAccount(id: id, to: target, reason: "requested")
        logRemote("rotate_account", id: id, detail: ok ? "moved" : "no login open")
        ack("rotate_account", id: id, ok: ok, error: ok ? nil : "no other login is open — see the host log")
    }

    /// Every tree's logins with their headroom, as the pane's login strip
    /// shows them. Answers `fetch_accounts`, and is pushed whenever the
    /// manager learns something new (a probe, a move).
    /// The settings sheet editing this machine's pools from another machine.
    /// Each verb acks with the sheet's wording on refusal, and a fresh
    /// `accounts` follows either way so the list it shows is the truth.
    private func handleLoginEdit(_ verb: String, _ payload: [String: Any]) {
        let prefix = (payload["pathPrefix"] as? String) ?? ""
        do {
            switch verb {
            case "add_claude_tree":
                try sessionManager.addClaudeTree(pathPrefix: prefix, configDir: (payload["configDir"] as? String) ?? "")
            case "remove_claude_tree":
                try sessionManager.removeClaudeTree(pathPrefix: prefix)
            case "add_claude_login":
                let dir = try sessionManager.addClaudeLogin(pathPrefix: prefix, name: (payload["name"] as? String) ?? "")
                relay.sendRelay(["type": "action_result", "action": verb, "ok": true, "dir": dir])
                logRemote(verb, id: nil, detail: dir)
                sendAccounts()
                return
            case "remove_claude_login":
                try sessionManager.removeClaudeLogin(dir: (payload["dir"] as? String) ?? "")
            default:
                return
            }
            logRemote(verb, id: nil, detail: prefix)
            ack(verb, id: nil, ok: true)
        } catch {
            logRemote(verb, id: nil, detail: "refused: \(error)")
            ack(verb, id: nil, ok: false, error: "\(error)")
        }
        sendAccounts()
    }

    func sendAccounts() {
        guard v2.isV2, v2.capabilities.contains("accounts") else { return }
        relay.sendRelay(["type": "accounts",
                         "pools": sessionManager.poolOverviews().map(\.wire),
                         "default": sessionManager.defaultLoginOverview().wire])
    }

    private func handleSetSessionHidden(_ payload: [String: Any], id: UUID?) {
        guard let id, let snap = stateStore.snapshot(id: id), snap.hostName == nil else {
            ack("set_session_hidden", id: id, ok: false, error: "unknown session")
            return
        }
        let hidden = (payload["hidden"] as? Bool) ?? true
        sessionManager.setHidden(sessionID: id, hidden: hidden)
        logRemote("set_session_hidden", id: id, detail: hidden ? "hidden" : "shown")
        ack("set_session_hidden", id: id, ok: true)
    }

    private func handleCreateFolder(_ payload: [String: Any], id: UUID?) {
        let name = ((payload["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ack("create_folder", id: id, ok: false, error: "empty name")
            return
        }
        let folderID = id ?? UUID()
        _ = sessionManager.createFolder(id: folderID, name: name)
        logRemote("create_folder", id: nil, detail: name)
        ack("create_folder", id: folderID, ok: true)
    }

    private func handleRenameFolder(_ payload: [String: Any], id: UUID?) {
        let name = ((payload["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ack("rename_folder", id: id, ok: false, error: "empty name")
            return
        }
        guard let id, sessionManager.renameFolder(id: id, to: name) else {
            ack("rename_folder", id: id, ok: false, error: "unknown folder")
            return
        }
        logRemote("rename_folder", id: nil, detail: name)
        ack("rename_folder", id: id, ok: true)
    }

    private func handleDeleteFolder(id: UUID?) {
        guard let id, sessionManager.deleteFolder(id: id) else {
            ack("delete_folder", id: id, ok: false, error: "unknown folder")
            return
        }
        logRemote("delete_folder", id: nil, detail: id.uuidString)
        ack("delete_folder", id: id, ok: true)
    }

    /// The client dragged this machine's folders into a new order and sends
    /// the whole list back, the same way `reorder_sessions` does.
    private func handleReorderFolders(_ payload: [String: Any]) {
        let ids = ((payload["order"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else {
            ack("reorder_folders", id: nil, ok: false, error: "empty order")
            return
        }
        sessionManager.setFolderOrder(ids)
        logRemote("reorder_folders", id: nil, detail: "\(ids.count) folders")
        ack("reorder_folders", id: nil, ok: true)
    }

    private func handleSetFolderHidden(_ payload: [String: Any], id: UUID?) {
        let hidden = (payload["hidden"] as? Bool) ?? true
        guard let id, sessionManager.setFolderHidden(id: id, hidden: hidden) else {
            ack("set_folder_hidden", id: id, ok: false, error: "unknown folder")
            return
        }
        logRemote("set_folder_hidden", id: nil, detail: hidden ? "hidden" : "shown")
        ack("set_folder_hidden", id: id, ok: true)
    }

    // MARK: - Diff

    private func handleFetchDiff(_ payload: [String: Any], id: UUID?) {
        guard let id, let snap = stateStore.snapshot(id: id) else {
            ack("fetch_diff", id: id, ok: false, error: "unknown session")
            return
        }
        let mode = (payload["mode"] as? String) ?? "working"
        let directory = snap.directory
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached { GitDiff.run(directory: directory, mode: mode) }.value
            var out: [String: Any] = [
                "type": "diff_result",
                "id": id.uuidString,
                "mode": mode,
                "stat": result.stat,
                "truncated": result.truncated,
                "files": result.files.map { file in
                    [
                        "path": file.path,
                        "patch": file.patch,
                        "additions": file.additions,
                        "deletions": file.deletions,
                        "truncated": file.truncated,
                    ] as [String: Any]
                },
            ]
            if let error = result.error { out["error"] = error }
            self.relay.sendRelay(out)
        }
    }

    // MARK: - Terminal frames

    private func handleAttachTerminal(_ payload: [String: Any], id: UUID?) {
        guard let id, let snap = stateStore.snapshot(id: id) else {
            ack("attach_terminal", id: id, ok: false, error: "unknown session")
            return
        }
        // A client holding a row from before `clientVisibleSessions` existed.
        // Say where the session actually is rather than acking a pane that will
        // never draw: the answer is a sentence the user can act on.
        if let host = snap.hostName {
            ack("attach_terminal", id: id, ok: false,
                error: "that session runs on \(host) — switch machines to watch it")
            return
        }
        v2.attachedSessionID = id
        v2.lastFrame = nil
        v2.frameSeq = 0
        v2.attachedAt = Date()
        v2.actualSize = sessionManager.session(for: id)?.windowSize()
        logRemote("attach_terminal", id: id)
        ack("attach_terminal", id: id, ok: true)
        // The client has always sent its grid here; until now the host ignored
        // it and every phone squinted at a pane sized for a 5K display.
        if let cols = payload["cols"] as? Int, let rows = payload["rows"] as? Int {
            applyResize(id: id, cols: cols, rows: rows)
        }
        // Send the current pane immediately rather than waiting for the next
        // poll, so opening the terminal is not a two-second blank.
        if let content = sessionManager.session(for: id)?.currentSnapshot() {
            forwardFrame(id: id, content: content)
        }
    }

    private func handleDetachTerminal() {
        restoreWindowSizeIfNeeded()
        v2.attachedSessionID = nil
        v2.lastFrame = nil
        ack("detach_terminal", id: nil, ok: true)
    }

    // MARK: - Terminal sizing

    /// Resize the pane to the client's character grid.
    ///
    /// Sizing tmux to the phone rather than shrinking the phone's font is the
    /// only way the text is actually right: a pane laid out for 362 columns
    /// cannot be re-wrapped to 44 after the fact, because the TUI has already
    /// drawn its boxes and alignment for the width it was given.
    private func handleResizeTerminal(_ payload: [String: Any], id: UUID?) {
        guard v2.capabilities.contains("resize") else {
            ack("resize_terminal", id: id, ok: false, error: "capability not negotiated")
            return
        }
        guard let id, let cols = payload["cols"] as? Int, let rows = payload["rows"] as? Int else {
            ack("resize_terminal", id: id, ok: false, error: "bad request")
            return
        }
        guard id == v2.attachedSessionID else {
            ack("resize_terminal", id: id, ok: false, error: "session not attached")
            return
        }
        applyResize(id: id, cols: cols, rows: rows)
        ack("resize_terminal", id: id, ok: true)
    }

    private func applyResize(id: UUID, cols: Int, rows: Int) {
        guard v2.capabilities.contains("resize") else { return }
        guard let session = sessionManager.session(for: id) else { return }

        // Repeating a size we already applied would cost a SIGWINCH and a full
        // TUI repaint for no change — and the client resends on every attach.
        if let requested = v2.requestedSize, requested == (cols, rows),
           v2.resizedSessionID == id { return }

        // Never resize out from under a dialog. Every resize repaints the TUI,
        // and doing that beneath a permission prompt the user is reaching for
        // is how a "yes" lands on the wrong option.
        if stateStore.snapshot(id: id)?.phase == .awaitingApproval {
            Log.pty.info("deferring resize of \(session.tmuxName) — dialog on screen")
            return
        }

        // Restore whatever was resized before this, if it was another session.
        if let previous = v2.resizedSessionID, previous != id {
            restoreWindowSizeIfNeeded()
        }
        if v2.sizeBeforeResize == nil {
            v2.sizeBeforeResize = session.windowSize()
            v2.resizedSessionID = id
        }
        guard session.resizeWindow(cols: cols, rows: rows) else { return }
        v2.requestedSize = (cols, rows)
        v2.actualSize = session.windowSize()
        // The pane just reflowed, so the cached frame is stale by definition —
        // clearing it forces the next capture through instead of being
        // suppressed as a duplicate.
        v2.lastFrame = nil
        if let content = session.currentSnapshot() {
            forwardFrame(id: id, content: content)
        }
    }

    /// A desktop found this window still phone-sized and asked for it back.
    /// Goes through the manager so the tmux option is cleared and the store
    /// updated the same way a local release is; `onWindowSizeReleased` then
    /// clears the bookkeeping here.
    private func handleReleaseTerminalSize(id: UUID?) {
        guard let id, stateStore.snapshot(id: id) != nil else {
            ack("release_terminal_size", id: id, ok: false, error: "unknown session")
            return
        }
        sessionManager.releaseWindowSize(id: id)
        logRemote("release_terminal_size", id: id, detail: nil)
        ack("release_terminal_size", id: id, ok: true)
    }

    /// Forget a resize the desktop undid behind our back, so the phone's next
    /// request for that grid is applied rather than de-duplicated away.
    func forgetResize(of id: UUID) {
        guard v2.resizedSessionID == id else { return }
        v2.sizeBeforeResize = nil
        v2.resizedSessionID = nil
        v2.requestedSize = nil
    }

    /// Hand the window back to the Mac. Safe to call when nothing was resized.
    func restoreWindowSizeIfNeeded() {
        guard let id = v2.resizedSessionID else { return }
        sessionManager.session(for: id)?.restoreWindowSize(to: v2.sizeBeforeResize)
        v2.sizeBeforeResize = nil
        v2.resizedSessionID = nil
        v2.requestedSize = nil
        v2.actualSize = nil
    }

    /// Called from `SessionManager.onPaneCapture` for every session.
    func forwardPaneCapture(id: UUID, content: String) {
        guard v2.isV2, v2.capabilities.contains("terminal"),
              v2.attachedSessionID == id else { return }
        // Safety timeout: a client that vanished without detaching must not
        // stream forever.
        if let attachedAt = v2.attachedAt, Date().timeIntervalSince(attachedAt) > 600 {
            restoreWindowSizeIfNeeded()
            v2.attachedSessionID = nil
            relay.sendRelay(["type": "terminal_detached", "id": id.uuidString, "reason": "timeout"])
            return
        }
        forwardFrame(id: id, content: content)
    }

    private func forwardFrame(id: UUID, content: String) {
        // `capture-pane` returns the whole pane GRID, so an idle session sends
        // its handful of real lines followed by every blank row beneath them.
        // Left in, the client scrolls to the bottom of that block and lands in
        // empty space. Trimming here also keeps the blank rows off the relay.
        let trimmed = TerminalFrameText.trimTrailingBlankLines(content)
        // Compare after trimming: a change confined to trailing blanks is not
        // a change worth a frame.
        guard trimmed != v2.lastFrame else { return }
        v2.lastFrame = trimmed
        v2.frameSeq += 1
        var frame: [String: Any] = [
            "type": "terminal_frame",
            "id": id.uuidString,
            "seq": v2.frameSeq,
            "ansi": trimmed,
        ]
        // Report the grid this frame was actually drawn at. The client asks for
        // a size but does not get to assume it won: tmux clamps, and a stale
        // request would leave the phone rendering to the wrong width.
        if let size = v2.actualSize {
            frame["cols"] = size.cols
            frame["rows"] = size.rows
        }
        relay.sendRelay(frame)
    }

    private func handleFetchScrollback(_ payload: [String: Any], id: UUID?) {
        // Note what this needs: a *live local pane*, not a row in the store.
        // Saying "unknown session" when the row plainly exists on screen is what
        // made a forwarded box session look like a client bug for an evening.
        guard let id else {
            ack("fetch_scrollback", id: id, ok: false, error: "unknown session")
            return
        }
        guard let session = sessionManager.session(for: id) else {
            let snap = stateStore.snapshot(id: id)
            ack("fetch_scrollback", id: id, ok: false,
                error: snap == nil
                    ? "unknown session"
                    : "no live pane for it on this machine"
                      + (snap?.hostName.map { " — it runs on \($0)" } ?? ""))
            return
        }
        let lines = min((payload["lines"] as? Int) ?? 500, 2000)
        let offset = max((payload["offset"] as? Int) ?? 0, 0)
        let text = session.captureHistory(offset: offset, lines: lines)
        relay.sendRelay([
            "type": "scrollback_chunk",
            "id": id.uuidString,
            "ansi": text,
            "offset": offset,
            "lines": lines,
            "more": !text.isEmpty,
        ])
    }

    // MARK: - Agents

    func sendAgentsFull() {
        guard let store = agentStore else {
            relay.sendRelay(["type": "agents_full", "agents": [] as [Any]])
            return
        }
        relay.sendRelay([
            "type": "agents_full",
            "agents": store.agents.map { agent -> [String: Any] in
                [
                    "id": agent.slug,
                    "name": agent.name,
                    "summary": agent.description,
                    "body": agent.prompt.components(separatedBy: "\n"),
                ]
            },
        ])
    }

    private func handleRunAgent(_ payload: [String: Any]) {
        guard let store = agentStore,
              let slug = payload["id"] as? String,
              let agent = store.agent(slug: slug) else {
            ack("run_agent", id: nil, ok: false, error: "unknown agent")
            return
        }
        let directory = payload["directory"] as? String
        guard let sessionID = sessionManager.runAgent(agent, directory: directory) else {
            ack("run_agent", id: nil, ok: false, error: "could not start agent")
            return
        }
        logRemote("run_agent", id: sessionID, detail: agent.name)
        relay.sendRelay(["type": "agent_started", "sessionId": sessionID.uuidString])
        sendSessionsFull()
    }
}
