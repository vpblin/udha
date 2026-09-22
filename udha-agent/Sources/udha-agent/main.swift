// udha-agent: Udha without the window. Supervises the tmux/Claude sessions on
// this machine and serves them to the phone/iPad through the relay, exactly as
// the Mac app does — this box just shows up as a second instance to pair with.
//
//   udha-agent            run the daemon (what systemd starts)
//   udha-agent login      one-time Auth0 sign-in; prints the URL to open
//   udha-agent logout     forget the relay credentials
//   udha-agent status     what the agent would connect as
//   udha-agent configure  set the relay URL / Auth0 tenant (see --help)
//   udha-agent accounts   every Claude login pool on this box, with headroom
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Single source of truth lives in the shared `UdhaBuild`, so the agent and
/// the app never disagree about what version reported a reading.
let agentVersion = UdhaBuild.agentVersion

@MainActor
final class AgentCore {
    let keychain: KeychainStore
    let config: ConfigStore
    let stateStore: SessionStateStore
    let activity: ActivityLog
    let sessionManager: SessionManager
    let agents: AgentStore
    let auth0: Auth0Client
    let relay: RelayClient
    let bridge: MobileBridge

    init() {
        keychain = KeychainStore(service: "udha")
        config = ConfigStore()
        config.load()
        Log.verbose = config.config.verboseLogging
        // No Terminal.app here: never try to reclaim or open windows.
        if config.config.reclaimTerminalWindows {
            config.mutate { $0.reclaimTerminalWindows = false }
        }
        TmuxSession.reclaimTerminalWindows = false

        stateStore = SessionStateStore()
        activity = ActivityLog()
        sessionManager = SessionManager(stateStore: stateStore, config: config, activity: activity)
        agents = AgentStore()

        let bridgeCfg = config.config.mobileBridge
        auth0 = Auth0Client(keychain: keychain,
                            domain: bridgeCfg.auth0Domain,
                            clientID: bridgeCfg.auth0ClientID,
                            audience: bridgeCfg.auth0Audience)
        let instanceName = bridgeCfg.instanceName.isEmpty
            ? ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "udha-agent"
            : bridgeCfg.instanceName
        relay = RelayClient(keychain: keychain, auth0: auth0,
                            relayURL: bridgeCfg.relayURL, instanceName: instanceName)
        bridge = MobileBridge(auth0: auth0, relay: relay, config: config,
                              stateStore: stateStore, sessionManager: sessionManager)
        bridge.agentStore = agents
        bridge.activity = activity
    }

    private var started = false

    func run() {
        Log.app.info("udha-agent \(agentVersion) starting on \(relay.instanceName) (instance=\(relay.instanceID))")
        // Reattach any live sessions immediately — that works with no relay at
        // all, so the phone finds them already running the moment it connects.
        sessionManager.restoreSessions()
        Log.app.info("udha-agent ready: \(config.config.sessions.count) configured sessions")
        if auth0.hasCachedTokens {
            bringBridgeUp()
        } else {
            // Not signed in yet. Don't exit — systemd would just restart-loop.
            // Idle and watch for `udha-agent login` to drop credentials in, then
            // connect without needing a service restart.
            Log.app.info("udha-agent: no credentials yet — waiting for `udha-agent login`")
            let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] t in
                Task { @MainActor in
                    guard let self, self.auth0.hasCachedTokens else { return }
                    t.invalidate()
                    Log.app.info("udha-agent: credentials appeared — connecting")
                    self.bringBridgeUp()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func bringBridgeUp() {
        guard !started else { return }
        started = true
        bridge.start()
    }

    func login() async {
        do {
            let user = try await auth0.signIn()
            print("Signed in as \(user). Credentials stored in ~/.config/udha/secrets.json.")
            exit(0)
        } catch {
            fputs("Sign-in failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    func logout() {
        auth0.signOut()
        print("Signed out.")
    }

    /// `udha-agent configure --relay-url wss://… --auth0-domain … --auth0-client-id … --auth0-audience … [--name …]`
    /// Nothing is baked into the binary: a fresh box has to be told which
    /// relay to join before `login` can do anything.
    func configure(_ args: [String]) {
        var it = args.makeIterator()
        var changed = false
        while let flag = it.next() {
            guard let value = it.next() else {
                fputs("configure: \(flag) needs a value\n", stderr); exit(64)
            }
            config.mutate { c in
                switch flag {
                case "--relay-url":       c.mobileBridge.relayURL = value
                case "--auth0-domain":    c.mobileBridge.auth0Domain = value
                case "--auth0-client-id": c.mobileBridge.auth0ClientID = value
                case "--auth0-audience":  c.mobileBridge.auth0Audience = value
                case "--name":            c.mobileBridge.instanceName = value
                default:
                    fputs("configure: unknown flag \(flag)\n", stderr); exit(64)
                }
                c.mobileBridge.enabled = true
            }
            changed = true
        }
        if !changed {
            print("usage: udha-agent configure --relay-url wss://… --auth0-domain … --auth0-client-id … --auth0-audience … [--name …]")
            exit(64)
        }
        print("Saved. Restart the service (systemctl --user restart udha-agent) for it to take effect.")
        status()
    }

    /// `udha-agent accounts`: each `ClaudeAccount` tree, the logins in its pool,
    /// who each one is signed in as (`claude auth status`) and how full it is
    /// (the same probe the daemon ranks them by). What to read before asking
    /// why a session moved, or whether a fourth login is actually signed in.
    func accounts() async {
        let accounts = config.config.claudeAccounts
        guard !accounts.isEmpty else {
            print("no Claude logins configured (config.json → claudeAccounts)"); return
        }
        for account in accounts {
            print("\(account.pathPrefix)")
            for dir in account.pool {
                let who = Self.claudeAuthStatus(configDir: dir)
                let usage = await ClaudeUsageProbe.fetch(configDir: dir)
                let reading = usage?.summary ?? (ClaudeUsageProbe.accessToken(configDir: dir) == nil
                    ? "no usable token (sign in, or run a session there)" : "probe failed")
                print("  \(ClaudeAccountPool.shortName(dir).padding(toLength: 14, withPad: " ", startingAt: 0)) \(who.padding(toLength: 30, withPad: " ", startingAt: 0)) \(reading)   \(dir)")
            }
        }
    }

    /// The email `claude auth status` reports for a config dir, or why not.
    private static func claudeAuthStatus(configDir: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "auth", "status"]
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = configDir
        env["PATH"] = TmuxSession.loginPath
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "claude not found" }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "not signed in" }
        guard (obj["loggedIn"] as? Bool) == true else { return "not signed in" }
        return (obj["email"] as? String) ?? "signed in"
    }

    func status() {
        let c = config.config.mobileBridge
        print("udha-agent \(agentVersion)")
        print("instance:  \(relay.instanceName) (\(relay.instanceID))")
        print("relay:     \(c.relayURL.isEmpty ? "(not configured — run `udha-agent configure`)" : c.relayURL)")
        print("auth0:     \(c.auth0Domain) client=\(c.auth0ClientID.prefix(6))… audience=\(c.auth0Audience)")
        print("signed in: \(auth0.hasCachedTokens ? "yes" : "no")")
        print("sessions:  \(config.config.sessions.count) configured")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Udha.AI").path ?? "?"
        print("config:    \(support)/config.json")
    }
}

// Ctrl-C / systemd stop: exit promptly. tmux sessions outlive us by design.
signal(SIGINT)  { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

let command = CommandLine.arguments.dropFirst().first ?? "run"
/// The daemon's object graph. Held here for the life of the process — the Mac
/// app's AppDelegate plays this role; without it everything the relay's weak
/// callbacks point at is gone the moment `run()` returns.
nonisolated(unsafe) var agentCore: AgentCore?
Task { @MainActor in
    RelayClient.socketFactory = { NIORelaySocket() }
    let core = AgentCore()
    agentCore = core
    switch command {
    case "run":     core.run()
    case "login":   await core.login()
    case "logout":  core.logout(); exit(0)
    case "status":  core.status(); exit(0)
    case "configure": core.configure(Array(CommandLine.arguments.dropFirst(2))); exit(0)
    case "accounts": await core.accounts(); exit(0)
    case "version", "--version": print(agentVersion); exit(0)
    default:
        fputs("usage: udha-agent [run|login|logout|status|configure|accounts|version]\n", stderr); exit(64)
    }
}
RunLoop.main.run()
