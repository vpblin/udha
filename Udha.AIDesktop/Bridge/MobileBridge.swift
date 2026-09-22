import Foundation
import Observation

/// Coordinates the mobile bridge: who currently owns the voice session, signed
/// URL minting for the iPhone client, and routing the agent's tool calls back
/// to this Mac for execution.
///
/// Audio frames never flow through this class — they go iPhone↔ElevenLabs
/// directly. We only carry: handoff signaling, signed URLs, context snapshots,
/// and tool call/result JSON.
@MainActor
@Observable
final class MobileBridge {
    enum Endpoint: String, Sendable {
        case none, local, remote
    }

    enum Status: Sendable, Equatable {
        case off
        case startingRelay
        case awaitingMobile
        case mobileActive
        case error(String)
    }

    private(set) var endpoint: Endpoint = .none
    private(set) var status: Status = .off
    private(set) var lastError: String?

    let auth0: Auth0Client
    let relay: RelayClient
#if !UDHA_AGENT
#endif
    let config: ConfigStore
    let stateStore: SessionStateStore
    let sessionManager: SessionManager

    /// All protocol-v2 state (capabilities, delta sequence, terminal attach).
    /// Grouped so `MobileBridgeV2.swift` can be a pure extension.
    let v2 = BridgeV2State()

    /// Injected after construction: these stores are built later in `AppCore`
    /// than the bridge is, matching how `contextFeed.sessionManager` is wired.
    /// Absent stores degrade to empty lists rather than failing.
    var agentStore: AgentStore?
    var activity: ActivityLog?
#if !UDHA_AGENT
    var meetingStore: MeetingStore?
    var meetingCenter: MeetingCenter?
    /// The recording library. The phone reads it, retitles and deletes from it;
    /// capture stays here, where the camera and the encoder are.
    var recordingCenter: RecordingCenter?
#endif

    /// True while the local voice session was running before the iPhone claimed
    /// the floor. We restart it on hand-back to match the user's prior intent.
#if !UDHA_AGENT
#endif

#if UDHA_AGENT
    /// Headless agent: no voice pipeline, no meeting or recording stores.
    init(auth0: Auth0Client,
         relay: RelayClient,
         config: ConfigStore,
         stateStore: SessionStateStore,
         sessionManager: SessionManager) {
        self.auth0 = auth0
        self.relay = relay
        self.config = config
        self.stateStore = stateStore
        self.sessionManager = sessionManager
        wire()
    }
#else
    init(auth0: Auth0Client,
         relay: RelayClient,
         config: ConfigStore,
         stateStore: SessionStateStore,
         sessionManager: SessionManager) {
        self.auth0 = auth0
        self.relay = relay
        self.config = config
        self.stateStore = stateStore
        self.sessionManager = sessionManager
        wire()
    }
#endif

    /// Shared tail of both initialisers.
    private func wire() {

        relay.onMessage = { [weak self] inbound in
            self?.handleInbound(inbound)
        }

        // Every store mutation becomes a candidate delta. `enqueueDelta` is a
        // no-op unless a v2 client negotiated the `delta` capability, so this
        // costs nothing when only the old iPhone build is paired.
        stateStore.onAttentionEvent = { [weak self] snap, event in
            // Let the pane supply approval text and avoid interrupting someone
            // who immediately answered, dismissed, or snoozed the request.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // A hidden session stays quiet too: hidden means out of
                // sight everywhere, the phone's banner included.
                guard let self, let current = self.stateStore.snapshot(id: snap.id),
                      self.stateStore.isVisible(current),
                      let live = current.attentionState.events.first(where: { $0.id == event.id }), live.visible else { return }
                self.relay.sendRelay(["type": "notify", "sessionId": current.id.uuidString,
                    "eventId": live.id, "title": "\(current.label) · \(live.kind.label)",
                    "body": live.summary, "createdAt": live.createdAt])
            }
        }
        stateStore.onChange = { [weak self] changed, removed in
            self?.enqueueDelta(changed: changed, removed: removed)
        }
        // Pane captures already happen every 2s for the status reader; forward
        // the attached one rather than starting a second poll.
        sessionManager.onWindowSizeReleased = { [weak self] id in
            self?.forgetResize(of: id)
        }
        sessionManager.onPaneCapture = { [weak self] id, content in
            self?.forwardPaneCapture(id: id, content: content)
        }
        // A probe landed or a session moved: the pane's login strip on the
        // other machine should say so without asking.
        sessionManager.onAccountsUpdated = { [weak self] in
            self?.sendAccounts()
        }
    }

    // MARK: - Lifecycle

    /// Bring the bridge online: connect to the relay (after a refresh / sign-in
    /// if necessary). Idempotent.
    func start() {
        Log.bridge.info("start() called; current status=\(String(describing: status)) hasCachedTokens=\(auth0.hasCachedTokens)")
        guard status == .off || isError else {
            Log.bridge.info("start() noop — already \(String(describing: status))")
            return
        }
        status = .startingRelay
        lastError = nil
        if relay.relayURL.isEmpty {
            Log.bridge.error("start() blocked — no relay URL configured")
            status = .error("Relay not configured")
            lastError = "Relay not configured"
            return
        }
        // Ensure we have a token first; relay.connect() will also try, but doing
        // it explicitly surfaces a clearer error to the UI when the user hasn't
        // signed in yet.
        if !auth0.hasCachedTokens {
            Log.bridge.error("start() blocked — no cached Auth0 tokens (sign in via Settings → Mobile Bridge)")
            status = .error("Sign in required")
            lastError = "Sign in required"
            return
        }
        Log.bridge.info("calling relay.connect() — relayURL=\(relay.relayURL) instance=\(relay.instanceID)")
        relay.connect()
        // Optimistic; relay state will flip to .connected once the handshake
        // completes. We treat "relay open, no mobile claim yet" as awaitingMobile.
        status = .awaitingMobile
    }

    func stop() {
        // Releasing first ensures any active iPhone gets a clean voice_state
        // update before we drop the socket.
        if endpoint == .remote { sendVoiceState(by: "none") }
        endpoint = .none
        relay.disconnect()
        status = .off
    }

    private var isError: Bool {
        if case .error = status { return true } else { return false }
    }

    // MARK: - Inbound from relay

    private func handleInbound(_ inbound: RelayInbound) {
        switch inbound {
        case .clientPayload(let payload):
            handleClientPayload(payload)
        case .relayDirect(let json):
            handleRelayDirect(json)
        }
    }

    private func handleClientPayload(_ payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }
        Log.bridge.debug("client payload: type=\(type)")
        switch type {
        // The voice feature was removed from the desktop, so every build now
        // answers the way the headless agent always did. The verbs stay in the
        // protocol because an older iOS build still sends them and deserves a
        // clean refusal rather than silence.
        case "voice_claim":
            relay.sendRelay(["type": "voice_claim_response", "ok": false,
                             "error": "Voice is not available on this machine"])
        case "voice_release", "tool_call":
            break
        case "ping":
            relay.sendRelay(["type": "pong"])

        // --- Session management (iPhone "Sessions" tab) ---
        case "list_sessions_full":
            sendSessionsFull()
        case "list_recent_dirs":
            sendRecentDirs()
        case "create_session":
            handleCreateSession(payload)
        case "duplicate_session":
            handleDuplicateSession(payload)
        case "close_session":
            handleCloseSession(payload)
        case "list_directory":
            handleListDirectory(payload)
        case "create_directory":
            handleCreateDirectory(payload)
        case "list_branches":
            handleListBranches(payload)

        default:
            // Everything protocol v2 adds. Unknown to v2 as well → log as before.
            if !handleV2Payload(payload) {
                Log.bridge.debug("ignoring client payload type=\(type)")
            }
        }
    }

    // MARK: - Session management

    /// Both `sessions_full` and `sessions_delta` serialize through
    /// `wireRow` in `MobileBridgeV2.swift`, so the two can never drift.
    /// The v1 fields keep their exact previous shape.
    func sendSessionsFull() {
        sendSessionsFullV2()
    }

    private func sendRecentDirs() {
        let dirs = config.recentDirectoriesForDisplay
        relay.sendRelay([
            "type": "recent_dirs",
            "directories": dirs,
        ])
    }

    private func handleCreateSession(_ payload: [String: Any]) {
        let rawDir = (payload["directory"] as? String) ?? ""
        let trimmed = rawDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            relay.sendRelay([
                "type": "session_create_failed",
                "error": "directory required",
            ])
            return
        }
        // Expand `~`, resolve symlinks for safety.
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            relay.sendRelay([
                "type": "session_create_failed",
                "error": "not a directory: \(expanded)",
            ])
            return
        }
        // A worktree request replaces the session directory with a fresh
        // checkout. Everything here happens *before* the config is touched, so
        // a git failure leaves no trace but the error message.
        var workingDir = expanded
        var branch: String? = nil
        var createdWorktree: (path: String, repoRoot: String)? = nil
        if let spec = payload["worktree"] as? [String: Any] {
            let requested = (spec["branch"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !requested.isEmpty else {
                relay.sendRelay(["type": "session_create_failed", "error": "worktree branch required"])
                return
            }
            guard let repoRoot = GitWorktree.repoRoot(for: expanded) else {
                relay.sendRelay([
                    "type": "session_create_failed",
                    "error": "not a git repository: \(expanded)",
                ])
                return
            }
            // Absent `newBranch`, assume a new branch — that is what the old
            // (ignored) spec meant and what the sheet defaults to.
            let isNew = (spec["newBranch"] as? Bool) ?? true
            let base = (spec["base"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch GitWorktree.create(repoRoot: repoRoot, branch: requested,
                                      base: base, isNewBranch: isNew) {
            case .success(let path):
                workingDir = path
                branch = requested
                createdWorktree = (path, repoRoot)
                Log.bridge.info("created worktree \(path) on \(requested)")
            case .failure(let failure):
                // git's own text, not ours — it explains "branch already
                // exists" and "invalid reference" far better than we would.
                relay.sendRelay(["type": "session_create_failed", "error": failure.message])
                return
            }
        }

        // Suffix on collision, same as the Mac's own sheet: two sessions under
        // one name make every by-label lookup — voice tools, the sidebar, the
        // tmux name — point at whichever was found first.
        let label: String = sessionManager.availableLabel({
            if let provided = (payload["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !provided.isEmpty { return provided }
            return (workingDir as NSString).lastPathComponent
        }())
        // Which assistant to run. Absent = Claude, which is the only thing
        // hosts ran before this field existed.
        let tool = (payload["tool"] as? String).flatMap(SessionTool.init(rawValue:)) ?? .claude
        var cfg = SessionConfig(label: label, directory: workingDir, command: tool.command)
        cfg.branch = branch
        // "New session here" on a folder. An unknown id (the folder went
        // meanwhile) or none at all means loose — never a failed create.
        if let f = (payload["folder"] as? String).flatMap(UUID.init(uuidString:)),
           config.config.sessionFolders.contains(where: { $0.id == f }) {
            cfg.folderID = f
        }
        // Permission posture, the same four rungs the Mac's own sheet offers for
        // that assistant. An unknown or absent value falls back to the tool's
        // default, so an older client keeps behaving exactly as it did.
        cfg.args = tool.args(permission: payload["permission"] as? String)
        // Session handoff: resume an existing Claude conversation whose transcript
        // was copied onto this host first. `--resume <id>` makes Claude reopen
        // that chat instead of starting fresh. Only Claude carries a transcript
        // here — the handoff reads it from Claude's own status feed.
        if tool == .claude, let resume = payload["resume"] as? String, !resume.isEmpty {
            cfg.args += ["--resume", resume]
        }
        config.mutate { $0.sessions.append(cfg) }
        // Record the repo, not the worktree: recents stay useful across many
        // worktrees cut from one project.
        config.recordRecentDirectory(createdWorktree?.repoRoot ?? expanded)
        do {
            _ = try sessionManager.spawn(sessionConfig: cfg)
            Log.bridge.info("created session \(label) at \(workingDir)")
            if let prompt = (payload["prompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                sessionManager.schedulePrompt(sessionID: cfg.id, prompt: prompt)
            }
            var out: [String: Any] = [
                "type": "session_created",
                "id": cfg.id.uuidString,
                "label": label,
                "directory": workingDir,
            ]
            if let branch { out["branch"] = branch }
            if let f = cfg.folderID { out["folder"] = f.uuidString }
            relay.sendRelay(out)
            // Push the updated full list so the iPhone UI refreshes.
            sendSessionsFull()
        } catch {
            // Roll back the config addition since spawn failed.
            config.mutate { $0.sessions.removeAll(where: { $0.id == cfg.id }) }
            // …and the row `spawn` left in the store marked crashed. On this
            // side the failure is reported explicitly below, so a ghost card
            // for a session that never ran is pure noise — and it outlives the
            // config entry, which is what put a dead name in front of "Open in
            // Terminal" (`can't find session: udha-…`).
            sessionManager.stateStore.remove(id: cfg.id)
            sendSessionsFull()
            // …and the worktree, so a failed spawn doesn't leave an orphan
            // checkout behind for the user to find and wonder about.
            if let created = createdWorktree {
                GitWorktree.remove(path: created.path, repoRoot: created.repoRoot)
            }
            relay.sendRelay([
                "type": "session_create_failed",
                "error": error.localizedDescription,
            ])
        }
    }

    /// Clone an existing session's directory / command / args. All the work is
    /// `SessionManager.duplicate`, which the Mac's own sidebar already uses —
    /// this is only the wire verb it never had.
    private func handleDuplicateSession(_ payload: [String: Any]) {
        guard let idStr = payload["id"] as? String, let id = UUID(uuidString: idStr) else {
            relay.sendRelay(["type": "session_create_failed", "error": "missing id"])
            return
        }
        guard let newID = sessionManager.duplicate(sessionID: id) else {
            relay.sendRelay(["type": "session_create_failed", "error": "duplicate failed"])
            return
        }
        let label = config.config.sessions.first(where: { $0.id == newID })?.label ?? ""
        Log.bridge.info("duplicated session \(idStr) -> \(newID.uuidString)")
        relay.sendRelay([
            "type": "session_created",
            "id": newID.uuidString,
            "label": label,
        ])
        sendSessionsFull()
    }

    /// Branches of the repo containing `directory`, so the phone's worktree
    /// picker isn't a free-text field typed on a software keyboard.
    private func handleListBranches(_ payload: [String: Any]) {
        let raw = (payload["directory"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.isEmpty, let repoRoot = GitWorktree.repoRoot(for: expanded) else {
            relay.sendRelay([
                "type": "branches",
                "directory": expanded,
                "branches": [] as [Any],
                "error": "not a git repository",
            ])
            return
        }
        let found = GitWorktree.branches(in: repoRoot)
        var out: [String: Any] = [
            "type": "branches",
            "directory": repoRoot,
            "branches": found.all,
        ]
        if let current = found.current { out["current"] = current }
        relay.sendRelay(out)
    }

    private func handleCloseSession(_ payload: [String: Any]) {
        guard let idStr = payload["id"] as? String, let id = UUID(uuidString: idStr) else {
            relay.sendRelay(["type": "session_close_failed", "error": "missing id"])
            return
        }
        sessionManager.removeSession(id: id) // also removes from config.sessions
        relay.sendRelay(["type": "session_closed", "id": idStr])
        sendSessionsFull()
    }

    /// Lists subdirectories of `path` so the iPhone can show a folder picker
    /// that walks the Mac's filesystem. Files are filtered out (only dirs are
    /// useful as Claude session roots). Empty / missing path defaults to $HOME.
    private func handleListDirectory(_ payload: [String: Any]) {
        let raw = (payload["path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let showHidden = (payload["showHidden"] as? Bool) ?? false
        let basePath: String = {
            if let raw, !raw.isEmpty {
                return (raw as NSString).expandingTildeInPath
            }
            return NSHomeDirectory()
        }()
        let resolved = (basePath as NSString).standardizingPath
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            relay.sendRelay([
                "type": "directory_listing",
                "path": resolved,
                "error": "not a directory",
                "entries": [] as [Any],
            ])
            return
        }
        let parent = (resolved as NSString).deletingLastPathComponent
        var entries: [[String: Any]] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: resolved) {
            for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                if !showHidden && name.hasPrefix(".") { continue }
                let full = (resolved as NSString).appendingPathComponent(name)
                var sub: ObjCBool = false
                if FileManager.default.fileExists(atPath: full, isDirectory: &sub), sub.boolValue {
                    entries.append([
                        "name": name,
                        "path": full,
                        // A plain stat, not `git rev-parse` — one subprocess
                        // per entry would make browsing a big folder crawl.
                        // `.git` is a file, not a directory, inside a worktree.
                        "isRepo": FileManager.default.fileExists(
                            atPath: (full as NSString).appendingPathComponent(".git")),
                    ])
                }
            }
        }
        relay.sendRelay([
            "type": "directory_listing",
            "path": resolved,
            "parent": resolved == "/" ? "" : parent,
            "entries": entries,
            "showHidden": showHidden,
        ])
    }

    /// Make one new folder inside `path` and answer with the fresh listing, so
    /// the picker lands showing what it just created rather than having to ask
    /// again. Deliberately one level: `name` is a single path component, never
    /// a path, so a client cannot walk out of the parent it is browsing.
    private func handleCreateDirectory(_ payload: [String: Any]) {
        let rawParent = ((payload["path"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = ((payload["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = (rawParent.isEmpty ? NSHomeDirectory() : (rawParent as NSString).expandingTildeInPath as String)
        let resolvedParent = (parent as NSString).standardizingPath

        func fail(_ why: String) {
            relay.sendRelay(["type": "directory_created", "ok": false, "error": why,
                             "path": resolvedParent])
        }
        guard !rawName.isEmpty else { return fail("No name given") }
        guard !rawName.contains("/"), rawName != ".", rawName != ".." else {
            return fail("A folder name cannot contain “/”")
        }
        var parentIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedParent, isDirectory: &parentIsDir),
              parentIsDir.boolValue else {
            return fail("\(resolvedParent) is not a folder")
        }
        let full = (resolvedParent as NSString).appendingPathComponent(rawName)
        guard !FileManager.default.fileExists(atPath: full) else {
            return fail("“\(rawName)” already exists")
        }
        do {
            try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: false)
        } catch {
            return fail(error.localizedDescription)
        }
        Log.bridge.info("created directory \(full)")
        relay.sendRelay(["type": "directory_created", "ok": true, "path": full])
        // Re-list the *new* folder: the caller is about to start a session in it.
        handleListDirectory(["path": full,
                             "showHidden": (payload["showHidden"] as? Bool) ?? false])
    }

    private func handleRelayDirect(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        Log.bridge.debug("relay direct: type=\(type)")
        switch type {
        case "validate_pairing":
            // Auto-accept: any request that reached us has already been gated
            // by the relay to messages from this same Auth0 user.
            handleValidatePairing(json)
        case "instance_online", "instance_offline", "paired_instances":
            // Informational; UI doesn't need them. iPhone uses these to find us.
            break
        default:
            break
        }
    }


    private func handleValidatePairing(_ json: [String: Any]) {
        guard let requestId = json["requestId"] as? String else {
            Log.bridge.error("validate_pairing missing requestId")
            return
        }
        // Accept any pair request; relay has already verified same-user.
        let metadata: [String: Any] = [
            "instanceId": relay.instanceID,
            "name": relay.instanceName,
            "kind": "udha-desktop",
        ]
        relay.send([
            "type": "pairing_valid",
            "requestId": requestId,
            "valid": true,
            "metadata": metadata,
        ])
        Log.bridge.info("pairing accepted for requestId=\(requestId)")
    }

    private func sendVoiceState(by: String) {
        relay.sendRelay([
            "type": "voice_state",
            "by": by,
            "instanceId": relay.instanceID,
        ])
    }
}
