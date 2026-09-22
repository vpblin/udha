import Foundation
import Observation

@MainActor
@Observable
final class AppCore {
    let config: ConfigStore
    let keychain: KeychainStore
    let stateStore: SessionStateStore
    let sessionManager: SessionManager
    let activity: ActivityLog
    let slack: SlackManager
    let mobileBridgeAuth0: Auth0Client
    let mobileBridgeRelay: RelayClient
    let mobileBridge: MobileBridge
    /// Drives another machine's sessions over the relay when a host is picked.
    let remoteHostClient: RemoteHostClient
    /// Which host this desktop is showing: nil = this Mac's own sessions.
    private(set) var currentHostName: String? = nil
    /// Vitals for the Machines section — this Mac's own, plus the tailnet view.
    let machines: MachineMonitor
    let awake: AwakeManager
    let terminalAccess: TerminalAccess
    let accessibility: AccessibilityAccess
    let inputLock: InputLockManager
    let agents: AgentStore
    let systemAudioAccess: SystemAudioAccess
    let meetingCalendar: MeetingCalendar
    let meetings: MeetingCenter
    let meetingAutoDetector: MeetingAutoDetector
    let screenRecordingAccess: ScreenRecordingAccess
    let cameraAccess: CameraAccess
    let recordings: RecordingCenter

    /// Live terminals drawn inside the window, one per session, created on
    /// demand and only while `config.embeddedTerminal` is on.
    let embeddedTerminals = EmbeddedTerminalStore()

    init() {
        let keychain = KeychainStore(service: Bundle.main.bundleIdentifier ?? "udha")
        // Before anything reads a credential: drain the old ACL-gated keychain.
        keychain.migrateLegacyItems()
        let config = ConfigStore()
        self.keychain = keychain
        self.config = config

        let stateStore = SessionStateStore()
        self.stateStore = stateStore

        let activity = ActivityLog()
        self.activity = activity

        let sessionManager = SessionManager(
            stateStore: stateStore,
            config: config,
            activity: activity
        )
        self.sessionManager = sessionManager

        let slack = SlackManager(
            config: config,
            keychain: keychain
        )
        self.slack = slack

        config.load()
        Log.verbose = config.config.verboseLogging
        TmuxSession.reclaimTerminalWindows = config.config.reclaimTerminalWindows

        // Mobile Bridge — instantiated unconditionally so the UI can sign in /
        // toggle without restarting the app, but `start()` is gated on the
        // config flag. When the flag is off, the relay never opens, MobileBridge
        // never receives messages, and the local voice path runs identically to
        // the pre-bridge code.
        let bridgeCfg = config.config.mobileBridge
        let auth0 = Auth0Client(
            keychain: keychain,
            domain: bridgeCfg.auth0Domain,
            clientID: bridgeCfg.auth0ClientID,
            audience: bridgeCfg.auth0Audience
        )
        self.mobileBridgeAuth0 = auth0
        let instanceName = bridgeCfg.instanceName.isEmpty
            ? (Host.current().localizedName ?? "Udha")
            : bridgeCfg.instanceName
        let relayClient = RelayClient(
            keychain: keychain,
            auth0: auth0,
            relayURL: bridgeCfg.relayURL,
            instanceName: instanceName
        )
        self.mobileBridgeRelay = relayClient
        self.remoteHostClient = RemoteHostClient(auth0: auth0,
                                                 relayURL: bridgeCfg.relayURL,
                                                 stateStore: stateStore,
                                                 excludeInstanceID: relayClient.instanceID)
        self.machines = MachineMonitor(stateStore: stateStore, remoteHost: self.remoteHostClient)
        let bridge = MobileBridge(
            auth0: auth0,
            relay: relayClient,
            config: config,
            stateStore: stateStore,
            sessionManager: sessionManager
        )
        self.mobileBridge = bridge

        self.awake = AwakeManager()
        self.terminalAccess = TerminalAccess()

        // Input lock — constructor is inert (no tap, no hotkey, no timer);
        // everything engages via apply()/lock(). config.load() ran above, so
        // the stored InputLockConfig is already populated.
        let accessibility = AccessibilityAccess()
        self.accessibility = accessibility
        self.inputLock = InputLockManager(accessibility: accessibility, config: config)

        let agents = AgentStore()
        self.agents = agents
        agents.load()

        // Meeting recorder — everything here is inert at construction: no
        // audio taps, no TCC prompts (the system-audio permission is only
        // probed at first meeting start), no LLM traffic.
        let systemAudioAccess = SystemAudioAccess()
        self.systemAudioAccess = systemAudioAccess
        let meetingCalendar = MeetingCalendar()
        self.meetingCalendar = meetingCalendar
        let claude = ClaudeClient(keychain: keychain, config: config)
        let meetingStore = MeetingStore()
        let meetings = MeetingCenter(
            store: meetingStore,
            claude: claude,
            config: config,
            keychain: keychain,
            activity: activity,
            systemAudioAccess: systemAudioAccess,
            calendar: meetingCalendar
        )
        self.meetings = meetings
        meetingStore.load()
        // Reading the grant is not a prompt. If Calendar is already allowed,
        // name whatever recordings still carry a placeholder title.
        meetingCalendar.check()
        if meetingCalendar.status == .ok {
            Task { await meetings.backfillCalendar() }
        }

        // The bridge is constructed before these stores exist, so hand them
        // over now. Without them the meetings and agents tabs on mobile simply
        // return empty lists rather than failing.
        bridge.meetingStore = meetingStore
        bridge.meetingCenter = meetings
        bridge.agentStore = agents
        bridge.activity = activity
        self.meetingAutoDetector = MeetingAutoDetector(config: config)

        // Video recorder — inert at construction, exactly like the meeting
        // recorder above: no SCStream, no capture session, and deliberately no
        // TCC probe. Probing screen access at startup would raise the Screen
        // Recording prompt on every launch; it fires at first record instead.
        let screenRecordingAccess = ScreenRecordingAccess()
        self.screenRecordingAccess = screenRecordingAccess
        let cameraAccess = CameraAccess()
        self.cameraAccess = cameraAccess
        let recordingStore = RecordingStore()
        self.recordings = RecordingCenter(
            store: recordingStore,
            config: config,
            keychain: keychain,
            screenAccess: screenRecordingAccess,
            cameraAccess: cameraAccess,
            auth0: auth0
        )
        recordingStore.load()
        // Same late wiring as the meeting and agent stores: the bridge is built
        // before this exists, and an absent store degrades to an empty list.
        bridge.recordingCenter = self.recordings

        // The video recorder holds the mic, which the meeting auto-detector
        // reads as "a call started". Without this, every screen recording
        // spawns a phantom meeting alongside it.
        meetingAutoDetector.suppressAutoStart = { [weak recordings = self.recordings] in
            recordings?.isRecordingOrSettling ?? false
        }
    }

    /// Point the whole desktop UI — overlay, sidebar, cards, ⌘K — at
    /// another machine's sessions (the headless `udha-agent` on the dev box), or
    /// back at this Mac. The agent stays the sole supervisor of its box; this is
    /// a client view of it, so desk and iPad show the same sessions.
    ///
    /// Requires the desktop to be signed in to the bridge (Settings → Mobile
    /// Bridge). Switching parks the current view's sessions and restores them on
    /// the way back, so flipping hosts never loses the other side's list.
    /// Open relay discovery so the sidebar can list other machines. Safe to call
    /// repeatedly — the client no-ops if a socket is already up. Call this both
    /// at launch and right after a bridge sign-in, since the app is often
    /// launched signed-out and the tokens arrive later.
    func ensureRemoteDiscovery() {
        guard mobileBridgeAuth0.hasCachedTokens else { return }
        // Auto-connect the first host the relay reports, so both machines'
        // sessions show without a click. Overridable from the sidebar.
        remoteHostClient.onHostsDiscovered = { [weak self] hosts in
            guard let self else { return }
            self.rememberHosts(hosts)
            guard self.currentHostName == nil, let first = hosts.sorted().first else { return }
            self.selectHost(first)
        }
        remoteHostClient.startDiscovery()
    }

    /// Keep a record of every machine this account has paired with, so one that
    /// is powered off is still listed — offline, with a reason — instead of
    /// silently disappearing from the Machines section.
    func rememberHosts(_ hosts: [String]) {
        let fresh = hosts.filter { !$0.isEmpty && !config.config.mobileBridge.knownHosts.contains($0) }
        guard !fresh.isEmpty else { return }
        config.mutate { $0.mobileBridge.knownHosts = (fresh + $0.mobileBridge.knownHosts).sorted() }
    }

    /// Machines this account knows about, online or not, excluding this Mac.
    var knownHostNames: [String] {
        let online = remoteHostClient.onlineHosts
        return Array(Set(online + config.config.mobileBridge.knownHosts)).sorted()
    }

    enum HandoffState: Equatable { case idle, staging(String), done(String), failed(String) }
    /// Progress of a drag-to-move handoff, for a small banner in the UI.
    private(set) var handoffState: HandoffState = .idle

    /// Move a local session to `host`, carrying its Claude conversation: stage the
    /// working tree + transcript over SSH, close the Mac session, then spawn a
    /// `claude --resume` session on the host and switch the view there.
    func handoffSession(_ id: UUID, toHost host: String) {
        guard let snap = stateStore.snapshot(id: id), snap.hostName == nil else { return }  // local only
        guard let plan = SessionHandoff.plan(for: snap) else {
            handoffState = .failed(SessionHandoff.Failure.notResumable.localizedDescription)
            return
        }
        handoffState = .staging(plan.label)
        Log.app.info("handoff: moving \(plan.label) → \(host) (claude session \(plan.claudeSessionID))")
        Task { @MainActor in
            do {
                let pcCwd = try await SessionHandoff.stage(plan, toHost: host, accounts: config.config.claudeAccounts)
                // Files + transcript are on the host now, so the chat is safe even
                // if the spawn below fails. Close the Mac session while still local.
                sessionManager.removeSession(id: id)
                // Make sure we're connected to the host, then wait for the pairing
                // to settle before asking it to resume the session.
                if currentHostName != host { selectHost(host) }
                for _ in 0..<40 {
                    if remoteHostClient.state == .connected { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                remoteHostClient.createSession(directory: pcCwd, label: plan.label,
                                               prompt: nil, permission: nil, resume: plan.claudeSessionID)
                handoffState = .done(plan.label)
                Log.app.info("handoff: \(plan.label) resumed on \(host) in \(pcCwd)")
            } catch {
                handoffState = .failed(error.localizedDescription)
                Log.app.error("handoff failed: \(error.localizedDescription)")
            }
        }
    }

    func clearHandoffState() { handoffState = .idle }

    func selectHost(_ name: String?) {
        let target = (name?.isEmpty ?? true) ? nil : name
        // Naming the host that is already current is normally a no-op — except
        // when the link to it is down, which is exactly when you click it. A
        // plain `target != currentHostName` guard makes a dropped host
        // permanently unclickable, since the desktop still calls it current.
        if target == currentHostName, target == nil || remoteHostClient.isPaired { return }
        if let target {
            // Connect: the host's sessions join the store next to the local
            // ones (each row is tagged with its host; actions route per row).
            sessionManager.remoteHost = remoteHostClient
            remoteHostClient.pair(withHostNamed: target)
            currentHostName = target
            Log.bridge.info("host connected → \(target)")
        } else {
            remoteHostClient.unpair()          // drops only that host's rows
            sessionManager.remoteHost = nil
            currentHostName = nil
            Log.bridge.info("host disconnected")
        }
    }

    func start() {
        AudioPlayer.shared.start()
        awake.apply(config.config.awake)

        // Input lock goes live early so the lock hotkey works even while the
        // slow Terminal-reclaim work below is still blocking the main thread.
        accessibility.check()
        inputLock.start()
        inputLock.apply(config.config.inputLock)

        // Verify (and auto-repair) the Apple Events grant that drives Terminal
        // BEFORE restoreSessions() exercises it via window reclaim. A revoked
        // grant otherwise silently breaks click-to-focus and new-session.
        terminalAccess.checkAndAutoRepair()

        // Start the mobile bridge BEFORE restoreSessions(). restoreSessions()
        // does synchronous Apple-events work to reclaim Terminal windows, which
        // can block the main thread for a long time when many tmux sessions
        // exist. Since the bridge is independent of sessions, we get it online
        // first so iPhone handoff works even while Terminal reattach is slow.
        if config.config.mobileBridge.enabled {
            Log.bridge.info("AppCore.start: starting bridge (enabled=true, instance=\(mobileBridgeRelay.instanceID))")
            mobileBridge.start()
        } else {
            Log.bridge.info("AppCore.start: mobile bridge disabled in config")
        }
        // Renames that never reached the share page (offline, signed out) are
        // pushed again once the bridge has had a moment to sign in.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await self?.recordings.syncPendingTitles()
        }
        // The monitor reports this Mac the same way the agent reports a box, so
        // the Machines pane reads one shape for both. Wired here rather than in
        // the initialiser because the bridge is built after the monitor.
        machines.relayInfo = { [weak self] in
            guard let self else { return MachineStats.Relay() }
            return MachineStats.Relay(
                instanceID: mobileBridgeRelay.instanceID,
                url: mobileBridgeRelay.relayURL,
                transport: mobileBridgeRelay.transportName,
                connectedAt: mobileBridgeRelay.connectedAt,
                lastPongAt: mobileBridgeRelay.lastPongAt,
                rttMilliseconds: mobileBridgeRelay.rttMilliseconds,
                capabilities: mobileBridge.v2.capabilities.sorted(),
                deltaSeq: mobileBridge.v2.seq,
                signedIn: mobileBridgeAuth0.hasCachedTokens
            )
        }
        // Discover other machines on the relay so the sidebar can offer them.
        ensureRemoteDiscovery()
        // Dev convenience: UDHA_REMOTE_HOST=<name> auto-selects a host at launch.
        if let host = ProcessInfo.processInfo.environment["UDHA_REMOTE_HOST"], !host.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.selectHost(host)
            }
        }

        sessionManager.restoreSessions()
        slack.start()
        meetingAutoDetector.start(center: meetings)
    }

    func shutdown() {
        // First, unconditionally: a live event tap must never outlast a clean
        // quit, and nothing below is allowed to fail before it's released.
        // (On SIGKILL the kernel reclaims the tap's mach port anyway.)
        inputLock.shutdown()
        // A live meeting must be stamped ended (and its files flushed) before
        // the process dies, or next launch shows a corrupt half-meeting.
        meetings.emergencyStop()
        // Same reasoning for video: the .mov files are fragmented so they stay
        // playable without a final moov atom, but the metadata has to be
        // stamped or next launch finds a recording stuck in `.capturing`.
        recordings.emergencyStop()
        slack.stop()
        mobileBridge.stop()
        // Detach every embedded terminal before the session teardown below:
        // each remote one is an SSH connection, and leaving them to be reaped
        // by process death is how you end up with orphaned clients holding a
        // tmux window at the wrong size on the next attach.
        embeddedTerminals.closeAll()
        sessionManager.shutdownAll()
        awake.shutdown()
        config.save()
    }
}
