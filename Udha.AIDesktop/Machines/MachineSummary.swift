import Foundation

/// One machine as the Machines section sees it: this Mac, or a box running
/// `udha-agent` that the relay has told us about.
///
/// Built in one place because the sidebar row and the detail pane must never
/// disagree about whether a machine is online — a rail that says "Connected"
/// beside a pane that says "No relay connection" is worse than either.
struct MachineSummary: Identifiable, Equatable {
    /// Nil for this Mac. Doubles as the relay host name and the SSH alias.
    var host: String?
    var id: String { host ?? "__local__" }
    var isLocal: Bool { host == nil }

    var name: String
    /// Whether the machine is reachable at all right now.
    var online: Bool
    /// Whether this desktop is currently consuming its sessions.
    var connected: Bool
    /// "Udha.app · home instance" / "udha-agent 0.2.0 · systemd --user".
    var role: String
    /// OS line for the rail: "Ubuntu 26.04.1 LTS".
    var platform: String
    /// The long identity line under the title.
    var meta: String
    /// Relay round trip, already formatted.
    var latency: String
    var stateLabel: String
    var sessionsSummary: String

    var stats: MachineStats?
    var link: TailscaleLink?
    var sessions: [SessionSnapshot]
    /// Why there is no `stats`, when there isn't. Nil when stats are present.
    var statsNote: String?
    /// Why the machine is not online, when it isn't.
    var offlineNote: String?

    static func == (a: MachineSummary, b: MachineSummary) -> Bool {
        a.host == b.host && a.online == b.online && a.connected == b.connected
            && a.latency == b.latency && a.stateLabel == b.stateLabel
            && a.sessionsSummary == b.sessionsSummary && a.stats == b.stats
            && a.link == b.link && a.sessions.map(\.id) == b.sessions.map(\.id)
    }
}

@MainActor
enum MachineDirectory {

    /// This Mac first, then every machine the account has paired with.
    static func summaries(core: AppCore, shell: UdhaShellModel? = nil) -> [MachineSummary] {
        [local(core: core)] + core.knownHostNames.map { remote(core: core, host: $0) }
    }

    static func summary(core: AppCore, host: String?) -> MachineSummary {
        guard let host else { return local(core: core) }
        return remote(core: core, host: host)
    }

    // MARK: - This Mac

    private static func local(core: AppCore) -> MachineSummary {
        let stats = core.machines.local
        let sessions = core.stateStore.visible.filter { $0.hostName == nil }
        let name = core.mobileBridgeRelay.instanceName
        let link = core.machines.selfLink
        let bridgeUp = core.mobileBridgeRelay.state.isConnected

        return MachineSummary(
            host: nil,
            name: name.isEmpty ? "This Mac" : name,
            online: true,
            connected: true,
            role: bridgeUp ? "\(UdhaBuild.kind) \(UdhaBuild.version) · home instance"
                           : "\(UdhaBuild.kind) \(UdhaBuild.version) · bridge offline",
            platform: stats?.os ?? "macOS",
            meta: metaLine(stats: stats, instance: core.mobileBridgeRelay.instanceID),
            latency: rtt(core.mobileBridgeRelay.rttMilliseconds),
            stateLabel: "This Mac · always live",
            sessionsSummary: sessionSummary(sessions),
            stats: stats,
            link: link,
            sessions: sessions,
            statsNote: stats == nil ? "Sampling…" : nil,
            offlineNote: nil
        )
    }

    // MARK: - A remote box

    private static func remote(core: AppCore, host: String) -> MachineSummary {
        let client = core.remoteHostClient
        let isCurrent = core.currentHostName == host
        let connected = isCurrent && client.state == .connected
        let online = client.onlineHosts.contains(host)
        let stats = connected ? client.hostStats : nil
        let sessions = core.stateStore.visible.filter { $0.hostName == host }
        let link = core.machines.links[host.lowercased()]

        let state: String
        if connected { state = "Connected · showing its sessions" }
        else if isCurrent { state = pairingLabel(client.state) }
        else if online { state = "Online · not connected" }
        else { state = "Offline" }

        var statsNote: String?
        if stats == nil {
            if !online { statsNote = "No reading — the machine is not on the relay." }
            else if !connected { statsNote = "Connect to this machine to read its resources." }
            else if client.hostStatsUnsupported {
                statsNote = "This machine's udha-agent predates the stats reply. Reinstall it with udha-agent/install.sh."
            } else { statsNote = "Waiting for the first reading…" }
        }

        var offlineNote: String?
        if !online {
            if let link, !link.online {
                offlineNote = "Not on the relay, and Tailscale last saw it \(UdhaFormat.agoText(link.lastHandshake)). Power it on, then check `systemctl --user status udha-agent`."
            } else if link != nil {
                offlineNote = "Tailscale can see the machine but it is not on the relay — the agent is not running or not signed in. Try `systemctl --user restart udha-agent`."
            } else {
                offlineNote = "Neither the relay nor Tailscale can see this machine."
            }
        }

        return MachineSummary(
            host: host,
            name: host,
            online: online,
            connected: connected,
            role: stats.map { "\($0.agentKind) \($0.agentVersion) · systemd --user" } ?? "udha-agent",
            platform: stats?.os ?? link?.os.capitalized ?? "—",
            meta: metaLine(stats: stats, instance: stats?.relay?.instanceID ?? host),
            // The box measures its own relay round trip and reports it; fall
            // back to that when this desktop has not timed a pong yet, so the
            // number and the chart beside it never disagree.
            latency: connected ? rtt(client.rttMilliseconds ?? stats?.relay?.rttMilliseconds)
                               : rtt(link?.rttMilliseconds),
            stateLabel: state,
            sessionsSummary: online ? sessionSummary(sessions) : "last seen \(UdhaFormat.agoText(link?.lastHandshake))",
            stats: stats,
            link: link,
            sessions: sessions,
            statsNote: statsNote,
            offlineNote: offlineNote
        )
    }

    // MARK: - Text

    private static func pairingLabel(_ state: RemoteHostClient.State) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .pairing:    return "Pairing…"
        case .failed(let why): return why
        case .idle:       return "Not connected"
        case .connected:  return "Connected"
        }
    }

    private static func metaLine(stats: MachineStats?, instance: String) -> String {
        guard let stats else { return "instance \(instance)" }
        var parts: [String] = []
        if !stats.os.isEmpty { parts.append(stats.os) }
        if !stats.kernel.isEmpty { parts.append(stats.kernel) }
        if !stats.arch.isEmpty { parts.append(stats.arch) }
        if !stats.cpuModel.isEmpty {
            parts.append(stats.cpuThreads > 0 ? "\(stats.cpuModel) (\(stats.cpuThreads)T)" : stats.cpuModel)
        }
        if stats.memoryTotal > 0 { parts.append(UdhaFormat.bytes(stats.memoryTotal)) }
        parts.append("instance \(instance)")
        return parts.joined(separator: " · ")
    }

    static func sessionSummary(_ sessions: [SessionSnapshot]) -> String {
        guard !sessions.isEmpty else { return "no sessions" }
        let working = sessions.filter { $0.state == .working }.count
        return "\(sessions.count) session\(sessions.count == 1 ? "" : "s") · \(working) working"
    }

    static func rtt(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms >= 100 ? String(format: "%.0f ms", ms) : String(format: "%.1f ms", ms)
    }
}
