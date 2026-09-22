import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lets this desktop drive the sessions of *another* Udha host (the headless
/// `udha-agent` on the dev box) through the relay — the client half of the same
/// protocol `MobileBridge` speaks as a host. The overlay, sidebar and cards need
/// no changes: this feeds the shared `SessionStateStore`, and `SessionManager`
/// forwards actions here while a host is selected.
///
/// It is deliberately its own small client rather than a reuse of `RelayClient`
/// (which is hard-wired to the `/home` role): a home announces sessions, a client
/// discovers hosts, pairs, and consumes them.
@MainActor
@Observable
final class RemoteHostClient {
    enum State: Equatable {
        case idle
        case connecting
        case pairing
        case connected      // paired + handshaken, receiving sessions
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Hosts the relay says are online for this account, by display name.
    private(set) var onlineHosts: [String] = []
    private(set) var activeHostName: String?
    /// Fires after the relay reports the host list, so the app can auto-connect.
    var onHostsDiscovered: (([String]) -> Void)?
    /// The host's recent working directories, for the New Session sheet.
    private(set) var recentDirs: [String] = []

    /// The host's own reading of itself, answered by `fetch_stats`. Nil until
    /// the first reply — and cleared when the host goes away, so the Machines
    /// pane can never show a dead box's last known CPU as if it were live.
    private(set) var hostStats: MachineStats?
    /// When that reading landed here.
    private(set) var hostStatsAt: Date?
    /// Set when the host answered the handshake without the `stats` capability
    /// (an agent built before this existed).
    private(set) var hostStatsUnsupported = false
    /// The agent predates `reorder_sessions`: a dragged row still moves here,
    /// but the box never learns, so the next reconnect puts it back.
    private(set) var hostReorderUnsupported = false
    /// The agent predates session folders: it sends no `folders` list and
    /// would drop every folder verb on the floor, so the board offers none
    /// of them for this host until its agent is rebuilt.
    private(set) var hostFoldersUnsupported = false
    /// The host's agent predates login pools: it cannot move a session to
    /// another Claude login, so the menu item stays off for its rows.
    private(set) var hostAccountsUnsupported = false
    /// The host's Claude logins per tree, with headroom, as its `accounts`
    /// reply last said. Asked for on connect and pushed by the host after
    /// every probe or move, so the pane's login strip reads the box's own
    /// numbers. Cleared with the host.
    private(set) var hostAccounts: [ClaudeLoginPoolOverview] = []
    /// The host's default `~/.claude` login, for its sessions outside every
    /// configured tree.
    private(set) var hostDefaultLogin: ClaudeLoginOverview?

    /// The pool the host keeps for a session there, matched by its directory
    /// as the host spells it — the row's `directory` is the host's path.
    func hostPool(for directory: String) -> ClaudeLoginPoolOverview? {
        hostAccounts.filter { $0.covers(directory) }.max { $0.pathPrefix.count < $1.pathPrefix.count }
    }

    /// Round trip to the relay on this socket, measured off the keepalive.
    private(set) var rttMilliseconds: Double?
    private(set) var lastPongAt: Date?
    private var lastPingAt: Date?
    /// When anything last arrived that actually came *from the host*, as
    /// opposed to from the relay in front of it. These are two different
    /// liveness questions and the pong only answers the second one: the relay
    /// can drop the host with a 1011 and keep answering our pings perfectly,
    /// which leaves the pong clock fresh while the box is unreachable.
    private var lastHostMessageAt: Date?
    private(set) var recentErrors: [MachineStats.ConnectionError] = []

    /// Ask the host to report its vitals. Cheap on the wire; the host does the
    /// expensive part and only when asked, so a closed Machines tab costs
    /// nothing at all.
    func changeAttention(id: UUID, action: String, eventID: String?, enabled: Bool) {
        var payload: [String: Any] = ["type": "attention_action", "id": id.uuidString,
                                      "action": action, "enabled": enabled]
        if let eventID { payload["eventID"] = eventID }
        sendToHost(payload)
    }

    func requestStats() {
        guard state == .connected else { return }
        sendToHost(["type": "fetch_stats"])
    }

    private func record(_ code: String, _ text: String) {
        recentErrors.insert(MachineStats.ConnectionError(at: Date(), code: code, text: text), at: 0)
        if recentErrors.count > 8 { recentErrors.removeLast(recentErrors.count - 8) }
    }

    /// One page of the host's filesystem, as answered by `list_directory`.
    struct DirectoryListing: Equatable {
        struct Entry: Identifiable, Equatable {
            var id: String { path }
            let name: String
            let path: String
            let isRepo: Bool
        }
        let path: String
        let parent: String      // "" at the root
        let entries: [Entry]    // directories only
        let showHidden: Bool
        let error: String?
    }
    /// The latest listing received; the folder picker observes this.
    private(set) var directoryListing: DirectoryListing?

    /// Why the host's last `create_session` failed, until it is dismissed.
    private(set) var createFailure: String?
    func clearCreateFailure() { createFailure = nil }

    /// Why the host refused to make a folder, until it is dismissed.
    private(set) var createDirFailure: String?
    func clearCreateDirFailure() { createDirFailure = nil }

    /// Make `name` inside `path` on the host. The host answers with
    /// `directory_created` and then a listing *of the new folder*, so the
    /// picker walks into it without a second round trip.
    func createDirectory(in path: String?, name: String, showHidden: Bool = false) {
        createDirFailure = nil
        sendToHost(["type": "create_directory", "path": path ?? "",
                    "name": name, "showHidden": showHidden])
    }

    /// Ask the host for the folders under `path` (nil/empty = its home).
    func listDirectory(_ path: String?, showHidden: Bool = false) {
        sendToHost(["type": "list_directory", "path": path ?? "", "showHidden": showHidden])
    }

    private let auth0: Auth0Client
    private let relayURL: String
    private let stateStore: SessionStateStore
    /// This desktop's own home instance id — never offer to pair with yourself.
    private let excludeInstanceID: String?

    private var socket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var activeInstanceID: String?
    private var knownHosts: [String: String] = [:]
    private var wantHostName: String?
    private var listenGen = 0
    private var pingTimer: Timer?
    private var reconnectAttempts = 0
    /// How long without a pong before the socket is presumed dead. Pings go
    /// every 25s, so this is three missed in a row.
    private static let pongTimeout: TimeInterval = 80
    /// How long a *paired* host may stay silent before the pairing is presumed
    /// stale. Generous next to `pongTimeout`: a host with live sessions sends
    /// deltas constantly, but one supervising nothing but idle panes can
    /// legitimately have little to say, and re-pairing costs a round trip.
    private static let hostSilenceTimeout: TimeInterval = 150
    private var manualClose = false

    init(auth0: Auth0Client, relayURL: String, stateStore: SessionStateStore, excludeInstanceID: String? = nil) {
        self.auth0 = auth0
        self.relayURL = relayURL
        self.stateStore = stateStore
        self.excludeInstanceID = excludeInstanceID
    }

    // MARK: - Lifecycle

    /// Open the relay as a client to *discover* this account's hosts (populating
    /// `onlineHosts`) without pairing with any. Call once the desktop is signed
    /// in; pairing happens later via `pair(withHostNamed:)`.
    func startDiscovery() {
        manualClose = false
        guard socket == nil else { return }
        openSocket()
    }

    /// Pair with a discovered host by name (case-insensitive, e.g. "devbox")
    /// and start receiving its sessions. Connects first if discovery isn't up.
    func pair(withHostNamed hostName: String) {
        wantHostName = hostName
        manualClose = false
        guard socket != nil else { openSocket(); return }
        if let iid = knownHosts.first(where: { $0.key.compare(hostName, options: .caseInsensitive) == .orderedSame })?.value {
            beginPairing(instanceID: iid, name: hostName)
        }
        // Otherwise we pair as soon as the relay reports it online.
    }

    /// Stop showing a host's sessions but keep the discovery socket open, so the
    /// host menu still lists what's online.
    func unpair() {
        wantHostName = nil
        if activeInstanceID != nil { _ = sendRaw(["type": "set_active_instance", "instanceId": ""]) }
        removeOwnSessions()
        activeInstanceID = nil
        activeHostName = nil
        recentDirs = []
        if socket != nil { state = .connected }  // still discovering
    }

    /// Drop this host's sessions from the shared store — never the local ones.
    private func removeOwnSessions() {
        hostStats = nil
        hostAccounts = []
        hostDefaultLogin = nil
        hostStatsAt = nil
        guard let host = activeHostName else { return }
        for snap in stateStore.all where snap.hostName == host { stateStore.remove(id: snap.id) }
        // An unpaired host leaves no empty folder groups behind either.
        stateStore.setFolders([], host: host)
    }

    func disconnect() {
        manualClose = true
        stopPing()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        listenGen &+= 1
        removeOwnSessions()
        activeInstanceID = nil
        activeHostName = nil
        state = .idle
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// Whether this client is actually paired with a host right now, as opposed
    /// to merely remembering which one it wants. The difference matters after a
    /// host drops off the relay.
    var isPaired: Bool { activeInstanceID != nil }

    private func openSocket() {
        guard !relayURL.isEmpty else { state = .failed("Relay not configured"); return }
        state = .connecting
        listenGen &+= 1
        let gen = listenGen
        Task { @MainActor in
            let token: String
            do { token = try await auth0.getValidAccessToken() }
            catch { state = .failed("Sign in required"); return }
            guard gen == listenGen else { return }
            guard var comps = URLComponents(string: relayURL.hasSuffix("/") ? relayURL + "client" : relayURL + "/client") else {
                state = .failed("Bad relay URL"); return
            }
            comps.queryItems = [URLQueryItem(name: "token", value: token)]
            guard let url = comps.url else { state = .failed("Bad relay URL"); return }
            let task = session.webSocketTask(with: url)
            self.socket = task
            task.resume()
            Log.bridge.info("remote-host: connecting to \(self.relayURL)/client, want host \(self.wantHostName ?? "?")")
            listen(gen: gen)
            startPing(gen: gen)
        }
    }

    // MARK: - Receiving

    private func listen(gen: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while gen == self.listenGen, let task = self.socket {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data): if let t = String(data: data, encoding: .utf8) { self.handle(t) }
                    @unknown default: break
                    }
                } catch {
                    self.handleClose(error)
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        // Host-forwarded payloads arrive wrapped; relay-direct ones don't.
        if (json["type"] as? String) == "relay", let payload = json["payload"] as? [String: Any] {
            // Everything wrapped in `relay` was forwarded from the host, which
            // makes this the one place worth stamping: it proves the box is
            // still on the other end, not merely that the relay is.
            lastHostMessageAt = Date()
            handlePayload(payload)
        } else {
            handleRelayDirect(json)
        }
    }

    private func handleRelayDirect(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "pong":
            let now = Date()
            lastPongAt = now
            if let sent = lastPingAt { rttMilliseconds = now.timeIntervalSince(sent) * 1000 }
            return
        case "paired_instances":
            let list = (json["instances"] as? [[String: Any]]) ?? []
            onlineHosts = list.compactMap { entry in
                guard entry["isOnline"] as? Bool ?? false,
                      (entry["instanceId"] as? String) != excludeInstanceID else { return nil }
                return entry["name"] as? String
            }
            for entry in list where (entry["isOnline"] as? Bool ?? false) { considerHost(entry) }
            Log.bridge.info("remote-host: hosts online = [\(onlineHosts.joined(separator: ", "))]")
            if state == .connecting { state = .connected }  // discovery established
            onHostsDiscovered?(onlineHosts)
        case "instance_online":
            // The relay announces a host with `metadata: null` — it only learns
            // the name at pairing time and never re-sends it — so a host that
            // has paired before is recognisable here by id alone. Without this
            // fallback a box that blinked off the relay (Cloudflare recycles the
            // socket every few hours) came back paired and streaming but was
            // never put back in `onlineHosts`, and the Machines pane filed it
            // under Offline with "No relay connection" beside live vitals.
            if let n = hostName(in: json), !onlineHosts.contains(n) {
                onlineHosts.append(n)
            }
            // A host we think we are already paired to announcing itself means
            // it has just (re)joined the relay, so whatever we are holding
            // predates it. Release it here and let `considerHost` pair again —
            // the agent re-announces about a second after a 1011, which makes
            // this the fast path and the silence watchdog the backstop. Note
            // the id is unchanged across such a reconnect, so it cannot be the
            // thing that tells us; the announcement itself is.
            if let iid = json["instanceId"] as? String, iid == activeInstanceID {
                Log.bridge.info("remote-host: \(self.activeHostName ?? "host") re-announced — releasing the old pairing")
                removeOwnSessions()
                activeInstanceID = nil
            }
            considerHost(json)
        case "instance_offline":
            let goneID = json["instanceId"] as? String
            if let goneID, let name = knownHosts.first(where: { $0.value == goneID })?.key {
                onlineHosts.removeAll { $0 == name }
            }
            if activeInstanceID == goneID {
                record("offline", "\(activeHostName ?? "host") dropped off the relay")
                state = .failed("Host went offline")
                removeOwnSessions()          // reads activeHostName — must run first
                // Release the pairing. Without this the host can never come
                // back on its own: `considerHost` only auto-pairs while
                // `activeInstanceID` is nil, so a host that blinked off the
                // relay would sit offline until the app was restarted, even
                // though it announced itself again seconds later. `wantHostName`
                // is deliberately kept — that is what makes the re-pair happen.
                activeInstanceID = nil
            }
        case "pair_success":
            guard let iid = json["instanceId"] as? String, iid == activeInstanceID else { return }
            state = .pairing
            _ = sendRaw(["type": "set_active_instance", "instanceId": iid])
            sendToHost(["type": "hello", "protocol": 2,
                        "capabilities": ["delta", "actions", "terminal", "diff", "rename", "stats", "reorder", "folders", "accounts"]])
            sendToHost(["type": "list_sessions_full"])
            sendToHost(["type": "list_recent_dirs"])
        case "pair_failed":
            state = .failed("Pairing failed: \((json["error"] as? String) ?? "unknown")")
        default:
            break
        }
    }

    /// A host entry from `paired_instances` / `instance_online`: pair if it's
    /// the one we're waiting for.
    private func considerHost(_ entry: [String: Any]) {
        guard let name = hostName(in: entry), let iid = entry["instanceId"] as? String,
              iid != excludeInstanceID else { return }
        knownHosts[name] = iid
        if !onlineHosts.contains(name) { onlineHosts.append(name) }
        guard activeInstanceID == nil, let want = wantHostName,
              name.compare(want, options: .caseInsensitive) == .orderedSame else { return }
        beginPairing(instanceID: iid, name: name)
    }

    /// The host's name from a relay entry: `name` (paired_instances), then
    /// `metadata.name`, then — for an `instance_online` that carries neither —
    /// whatever name this id was known by the last time it paired.
    private func hostName(in entry: [String: Any]) -> String? {
        if let n = entry["name"] as? String { return n }
        if let n = (entry["metadata"] as? [String: Any])?["name"] as? String { return n }
        if let iid = entry["instanceId"] as? String {
            return knownHosts.first(where: { $0.value == iid })?.key
        }
        return nil
    }

    private func beginPairing(instanceID iid: String, name: String) {
        activeInstanceID = iid
        activeHostName = name
        // Pairing is only attempted with a host the relay says is up, so it is
        // online by definition — including on the watchdog's re-pair path,
        // which reaches here without ever passing through `considerHost`.
        if !onlineHosts.contains(name) { onlineHosts.append(name) }
        // Start the silence clock at the attempt, not at the first reply, so a
        // pairing that is accepted and then never speaks is caught too.
        lastHostMessageAt = Date()
        state = .pairing
        Log.bridge.info("remote-host: pairing with \(name) (\(iid))")
        _ = sendRaw(["type": "pair_request", "instanceId": iid, "pairingToken": ""])
    }

    private func handlePayload(_ p: [String: Any]) {
        switch p["type"] as? String {
        case "hello_ack":
            // Only the answer to *our* hello. The host fans its replies out to
            // every client subscribed to it, so the iPhone handshaking with the
            // same box delivers its `hello_ack` here too — and that ack carries
            // the phone's negotiated capabilities, not ours. Consuming it made
            // this Mac conclude the box "has no stats capability" (the phone
            // never asks for stats) and stop reading its vitals until the next
            // re-pair.
            guard state == .pairing else {
                Log.bridge.debug("remote-host: ignoring a hello_ack meant for another client")
                return
            }
            state = .connected
            reconnectAttempts = 0   // this one worked; don't carry old backoff
            let caps = Set((p["capabilities"] as? [String]) ?? [])
            hostStatsUnsupported = !caps.contains("stats")
            hostReorderUnsupported = !caps.contains("reorder")
            hostFoldersUnsupported = !caps.contains("folders")
            hostAccountsUnsupported = !caps.contains("accounts")
            Log.bridge.info("remote-host: connected to \(self.activeHostName ?? "?") caps=\(caps.sorted().joined(separator: ","))")
            if hostStatsUnsupported {
                Log.bridge.info("remote-host: \(self.activeHostName ?? "?") has no stats capability — agent predates it")
            } else {
                requestStats()
            }
            if !hostAccountsUnsupported { requestAccounts() }
            if hostReorderUnsupported {
                Log.bridge.info("remote-host: \(self.activeHostName ?? "?") has no reorder capability — a dragged order won't survive a reconnect until the agent is rebuilt")
            }
            if hostFoldersUnsupported {
                Log.bridge.info("remote-host: \(self.activeHostName ?? "?") has no folders capability — folder actions are off for it until the agent is rebuilt")
            }
        case "stats":
            guard let raw = p["stats"] as? [String: Any] else { return }
            hostStats = MachineStats(wire: raw)
            hostStatsAt = Date()
        case "action_result":
            if ["add_claude_tree", "remove_claude_tree", "add_claude_login", "remove_claude_login"]
                .contains((p["action"] as? String) ?? "") {
                handleLoginEditResult(p)
            }
        case "accounts":
            hostAccounts = ((p["pools"] as? [[String: Any]]) ?? []).compactMap(ClaudeLoginPoolOverview.init(wire:))
            hostDefaultLogin = (p["default"] as? [String: Any]).flatMap(ClaudeLoginOverview.init(wire:))
        case "recent_dirs":
            recentDirs = (p["directories"] as? [String]) ?? []
        case "directory_listing":
            let entries = ((p["entries"] as? [[String: Any]]) ?? []).compactMap { e -> DirectoryListing.Entry? in
                guard let name = e["name"] as? String, let path = e["path"] as? String else { return nil }
                return .init(name: name, path: path, isRepo: e["isRepo"] as? Bool ?? false)
            }
            directoryListing = DirectoryListing(path: p["path"] as? String ?? "",
                                                parent: p["parent"] as? String ?? "",
                                                entries: entries,
                                                showHidden: p["showHidden"] as? Bool ?? false,
                                                error: p["error"] as? String)
        case "directory_created":
            // Only the refusal needs carrying: the success case is immediately
            // followed by the listing, which is the visible answer.
            if (p["ok"] as? Bool) != true {
                let why = (p["error"] as? String) ?? "The host could not create that folder."
                Log.bridge.error("remote create_directory failed: \(why)")
                createDirFailure = why
            }
        case "session_create_failed":
            // The host knows exactly why (a missing binary, a git failure, a
            // bad path) and says so. Dropping it left the sheet closing on
            // silence and nothing on the board to explain it.
            let message = (p["error"] as? String) ?? "The host refused to create the session."
            Log.bridge.error("remote create failed: \(message)")
            createFailure = message
        case "sessions_full":
            // Folders before rows, so `visible` is right on every insert (each
            // one invalidates the UI). An older agent sends no list → [].
            stateStore.setFolders(((p["folders"] as? [[String: Any]]) ?? []).compactMap(SessionFolder.init(wire:)),
                                  host: activeHostName)
            applyFull((p["sessions"] as? [[String: Any]]) ?? [])
        case "sessions_delta":
            applyDelta(changed: (p["changed"] as? [[String: Any]]) ?? [],
                       removed: (p["removed"] as? [String]) ?? [])
        default:
            break
        }
    }

    // MARK: - Store mapping

    private func tagged(_ row: [String: Any]) -> SessionSnapshot? {
        guard var snap = SessionSnapshot(wireRow: row) else { return nil }
        snap.hostName = activeHostName
        return snap
    }

    private func applyFull(_ rows: [[String: Any]]) {
        let incoming = rows.compactMap(tagged)
        let keep = Set(incoming.map(\.id))
        // Reconcile only this host's rows; local sessions live alongside them.
        for existing in stateStore.all
        where existing.hostName == activeHostName && !keep.contains(existing.id) {
            stateStore.remove(id: existing.id)
        }
        for snap in incoming { stateStore.insert(snap) }
    }

    private func applyDelta(changed: [[String: Any]], removed: [String]) {
        for row in changed { if let snap = tagged(row) { stateStore.insert(snap) } }
        for idStr in removed { if let id = UUID(uuidString: idStr) { stateStore.remove(id: id) } }
    }

    // MARK: - Actions (called by SessionManager while a host is active)

    func sendInput(id: UUID, text: String) { sendToHost(["type": "send_input", "id": id.uuidString, "text": text, "submit": true]) }
    func sendRawText(id: UUID, text: String) { sendToHost(["type": "send_input", "id": id.uuidString, "text": text, "submit": false]) }
    func sendKey(id: UUID, key: String) { sendToHost(["type": "send_keys", "id": id.uuidString, "keys": key]) }
    func approve(id: UUID, option: Int? = nil) {
        var m: [String: Any] = ["type": "approve", "id": id.uuidString]
        if let option { m["option"] = option }
        sendToHost(m)
    }
    func deny(id: UUID) { sendToHost(["type": "deny", "id": id.uuidString]) }
    func interrupt(id: UUID) { sendToHost(["type": "interrupt", "id": id.uuidString]) }
    func close(id: UUID) { sendToHost(["type": "close_session", "id": id.uuidString]) }
    func rename(id: UUID, label: String) { sendToHost(["type": "rename_session", "id": id.uuidString, "label": label]) }
    func releaseWindowSize(id: UUID) { sendToHost(["type": "release_terminal_size", "id": id.uuidString]) }
    /// The host's whole list in the order it now has here. The agent persists
    /// it, so it is the order the next `sessions_full` — and the next
    /// reconnect — comes back in.
    func reorder(order: [UUID]) {
        if hostReorderUnsupported {
            Log.bridge.error("remote-host: \(self.activeHostName ?? "?") can't persist the order — rebuild its agent")
        }
        sendToHost(["type": "reorder_sessions", "order": order.map(\.uuidString)])
    }
    func duplicate(id: UUID) { sendToHost(["type": "duplicate_session", "id": id.uuidString]) }
    /// Move the session to another Claude login in its pool — `to` names one
    /// (a config dir from `hostAccounts`), nil lets the host pick the
    /// emptiest — and the host echoes it in the row's `account`.
    func rotateAccount(id: UUID, to target: String? = nil) {
        var payload: [String: Any] = ["type": "rotate_account", "id": id.uuidString]
        if let target { payload["to"] = target }
        sendToHost(payload)
    }

    func requestAccounts() {
        guard state == .connected else { return }
        sendToHost(["type": "fetch_accounts"])
    }

    // MARK: Editing the host's pools

    /// Why the host refused the last pool edit, until dismissed.
    private(set) var loginEditFailure: String?
    func clearLoginEditFailure() { loginEditFailure = nil }
    /// The dir the host just made for a new login, waiting to be signed in.
    /// The sheet opens a terminal for it and then clears this.
    private(set) var loginDirToSignIn: String?
    func clearLoginDirToSignIn() { loginDirToSignIn = nil }

    func addClaudeTree(pathPrefix: String, configDir: String) {
        loginEditFailure = nil
        sendToHost(["type": "add_claude_tree", "pathPrefix": pathPrefix, "configDir": configDir])
    }
    func removeClaudeTree(pathPrefix: String) {
        loginEditFailure = nil
        sendToHost(["type": "remove_claude_tree", "pathPrefix": pathPrefix])
    }
    func addClaudeLogin(pathPrefix: String, name: String) {
        loginEditFailure = nil
        sendToHost(["type": "add_claude_login", "pathPrefix": pathPrefix, "name": name])
    }
    func removeClaudeLogin(dir: String) {
        loginEditFailure = nil
        sendToHost(["type": "remove_claude_login", "dir": dir])
    }

    /// The host's answer to a pool edit.
    private func handleLoginEditResult(_ p: [String: Any]) {
        let action = (p["action"] as? String) ?? ""
        if (p["ok"] as? Bool) == true {
            if action == "add_claude_login", let dir = p["dir"] as? String { loginDirToSignIn = dir }
        } else {
            let why = (p["error"] as? String) ?? "The host refused."
            Log.bridge.error("remote \(action) failed: \(why)")
            loginEditFailure = why
        }
    }
    /// `tool` names the assistant to run ("claude" / "codex"); omitting it
    /// leaves the host on Claude, which is what every build before this one did.
    /// `folder` files the new session in one of the host's folders.
    func createSession(directory: String, label: String?, prompt: String?,
                       tool: String? = nil, permission: String?, resume: String? = nil,
                       folder: UUID? = nil) {
        var m: [String: Any] = ["type": "create_session", "directory": directory]
        if let label, !label.isEmpty { m["label"] = label }
        if let prompt, !prompt.isEmpty { m["prompt"] = prompt }
        if let tool, !tool.isEmpty { m["tool"] = tool }
        if let permission { m["permission"] = permission }
        if let resume, !resume.isEmpty { m["resume"] = resume }
        if let folder { m["folder"] = folder.uuidString }
        sendToHost(m)
    }

    // MARK: Folders + hidden

    // The host owns these the way it owns labels: nothing is written to the
    // store here. The box applies the change and its delta / full push is the
    // echo the board draws from.

    private func foldersGuard(_ what: String) {
        if hostFoldersUnsupported {
            Log.bridge.error("remote-host: \(self.activeHostName ?? "?") can't \(what) — rebuild its agent")
        }
    }
    func setSessionFolder(id: UUID, folder: UUID?) {
        foldersGuard("file a session")
        var m: [String: Any] = ["type": "set_session_folder", "id": id.uuidString]
        if let folder { m["folder"] = folder.uuidString }
        sendToHost(m)
    }
    func setSessionHidden(id: UUID, hidden: Bool) {
        foldersGuard("hide a session")
        sendToHost(["type": "set_session_hidden", "id": id.uuidString, "hidden": hidden])
    }
    func createFolder(id: UUID, name: String) {
        foldersGuard("create a folder")
        sendToHost(["type": "create_folder", "id": id.uuidString, "name": name])
    }
    func renameFolder(id: UUID, name: String) {
        foldersGuard("rename a folder")
        sendToHost(["type": "rename_folder", "id": id.uuidString, "name": name])
    }
    func deleteFolder(id: UUID) {
        foldersGuard("ungroup a folder")
        sendToHost(["type": "delete_folder", "id": id.uuidString])
    }
    func setFolderHidden(id: UUID, hidden: Bool) {
        foldersGuard("hide a folder")
        sendToHost(["type": "set_folder_hidden", "id": id.uuidString, "hidden": hidden])
    }
    func unhideAll() {
        foldersGuard("unhide")
        sendToHost(["type": "unhide_all"])
    }
    func reorderFolders(order: [UUID]) {
        foldersGuard("reorder folders")
        sendToHost(["type": "reorder_folders", "order": order.map(\.uuidString)])
    }

    // MARK: - Sending

    @discardableResult
    private func sendRaw(_ message: [String: Any]) -> Bool {
        guard let socket else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let str = String(data: data, encoding: .utf8) else { return false }
        socket.send(.string(str)) { error in
            if let error { Log.bridge.error("remote-host send failed: \(error.localizedDescription)") }
        }
        return true
    }

    @discardableResult
    private func sendToHost(_ payload: [String: Any]) -> Bool {
        guard let iid = activeInstanceID else { return false }
        return sendRaw(["type": "relay", "instanceId": iid, "payload": payload])
    }

    // MARK: - Keepalive / reconnect

    private func startPing(gen: Int) {
        stopPing()
        // Start the clock now: the watchdog below measures from the last thing
        // we heard, and on a fresh socket that is the connection itself.
        lastPongAt = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, gen == self.listenGen else { return }
                // The relay can stop answering without ever closing the TCP
                // connection — it drops the host with a 1011 and this client is
                // never told. Nothing then arrives, no close fires, and the box
                // reads as offline until the app is relaunched. `lastPongAt`
                // was recorded and never read, so that state was invisible.
                // Treat silence as death and reconnect, which re-pairs.
                if let last = self.lastPongAt, Date().timeIntervalSince(last) > Self.pongTimeout {
                    let quiet = Int(Date().timeIntervalSince(last))
                    Log.bridge.error("remote-host: no pong for \(quiet)s — treating the relay as gone, reconnecting")
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    self.handleClose(NSError(
                        domain: "udha.remotehost", code: -1001,
                        userInfo: [NSLocalizedDescriptionKey: "Relay stopped responding (\(quiet)s without a pong)"]
                    ))
                    return
                }
                // The relay answering is not the host answering, so reconcile
                // the pairing ourselves on every tick rather than trusting the
                // relay to have told us anything. Two ways to be wrong:
                //
                //  - Paired, but nothing has come through for a while (the
                //    relay 1011'd the host and kept ponging us happily).
                //  - Not paired but wanting to be — `instance_offline` released
                //    the pairing and the `instance_online` that should have
                //    followed never arrived. Nothing else is coming: the relay
                //    pushes `paired_instances` only on connect, and there is no
                //    verb to ask again. Only we can break that deadlock.
                //
                // `beginPairing` restamps the clock and sets the id, so each
                // path retries at most once per `hostSilenceTimeout`.
                if let want = self.wantHostName {
                    if self.activeInstanceID == nil, self.knownHosts[want] != nil {
                        self.repairHost(reason: "unpaired while wanted")
                        return
                    }
                    if self.activeInstanceID != nil, let heard = self.lastHostMessageAt,
                       Date().timeIntervalSince(heard) > Self.hostSilenceTimeout {
                        self.repairHost(reason: "\(Int(Date().timeIntervalSince(heard)))s")
                        return
                    }
                }
                self.lastPingAt = Date()
                _ = self.sendRaw(["type": "ping"])
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t
    }

    private func stopPing() { pingTimer?.invalidate(); pingTimer = nil }

    /// Drop a pairing we no longer believe in and pair again, without touching
    /// the socket — the relay is fine, it is the host behind it that changed.
    ///
    /// This is the same recovery `instance_offline` performs, reached by
    /// noticing the silence ourselves. It has to exist because the relay does
    /// not always tell us: a 1011 is the relay's *own* internal error, and the
    /// socket it tears down is the host's, so the notification that would have
    /// reached us is exactly the thing that didn't survive. Without this the
    /// client sits on a pairing that no longer exists — pinging happily,
    /// pongs coming back — and ignores the host's re-announce, because
    /// `considerHost` only auto-pairs while `activeInstanceID` is nil.
    private func repairHost(reason: String) {
        let name = activeHostName ?? wantHostName
        guard let name, let iid = knownHosts[name] ?? activeInstanceID else { return }
        activeHostName = name
        Log.bridge.error("remote-host: \(name) \(reason) — re-pairing")
        record("stale", "\(name): \(reason); re-pairing")
        removeOwnSessions()      // reads activeHostName — must run before it moves
        activeInstanceID = nil
        beginPairing(instanceID: iid, name: name)
    }

    private func handleClose(_ error: Error) {
        stopPing()
        socket = nil
        activeInstanceID = nil
        hostStats = nil
        hostAccounts = []
        hostDefaultLogin = nil
        hostStatsAt = nil
        if manualClose { state = .idle; return }
        record("close", error.localizedDescription)
        state = .failed(error.localizedDescription)
        // Reconnect with backoff — the host may just be rebooting.
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        reconnectAttempts += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.manualClose else { return }
            self.openSocket()
        }
    }
}
