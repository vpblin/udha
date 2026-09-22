import Foundation
import Observation

/// What Tailscale knows about one machine. The *Mac* is the only place this can
/// be read for every machine at once — a peer's handshake, route and key expiry
/// are properties of this node's view of the tailnet, not of the peer — so it
/// is collected here rather than asked for over the bridge.
struct TailscaleLink: Sendable, Equatable {
    var name: String = ""
    var address: String = ""
    var dnsName: String = ""
    var os: String = ""
    var online: Bool = false
    var lastHandshake: Date?
    var currentAddress: String = ""
    var derpRegion: String = ""
    var keyExpiry: Date?
    var rttMilliseconds: Double?

    /// "direct · 192.168.1.20:41641", or the DERP relay when the direct path failed.
    var route: String {
        if !currentAddress.isEmpty { return "direct · \(currentAddress)" }
        if !derpRegion.isEmpty { return "relayed · DERP \(derpRegion)" }
        return online ? "connected" : "—"
    }

    var derpNote: String {
        guard !derpRegion.isEmpty else { return "—" }
        return currentAddress.isEmpty ? "\(derpRegion) — carrying traffic" : "\(derpRegion) — not in use"
    }
}

/// Collects what the Machines section shows: this Mac's own vitals, and the
/// tailnet's view of every machine.
///
/// Two deliberate properties. It only runs while the Machines section is on
/// screen (`viewers`) — a stats poll spawns processes, and a tab nobody is
/// looking at must cost nothing. And it never fabricates: a probe that fails
/// leaves the field nil, so the pane can say "—" instead of a stale number
/// that looks live.
@MainActor
@Observable
final class MachineMonitor {
    /// This Mac, as read on this Mac.
    private(set) var local: MachineStats?
    /// Tailnet peers by lowercased host name, including this Mac.
    private(set) var links: [String: TailscaleLink] = [:]
    /// This Mac's own tailnet entry. Looked up by key would not work: Tailscale
    /// knows this machine as "MacBook Pro (6)" while the relay calls it
    /// "Laptop", and neither name is derivable from the other.
    private(set) var selfLink: TailscaleLink?
    /// Set when the `tailscale` CLI isn't installed or refuses to talk.
    private(set) var tailscaleNote: String?
    private(set) var lastLocalSampleAt: Date?
    /// The recent past of every reading, so the pane can draw the shape of a
    /// number instead of only its current value. Filled from the same samples
    /// the pane already causes — nothing is collected for the charts alone.
    let history = MachineHistory()

    /// Views that currently want readings, by name. Reference-counted rather
    /// than a single flag because two panes read stats now — the Machines
    /// section and the sessions board — and with a bare Bool, leaving one for
    /// the other would stop the poll: SwiftUI runs the arriving view's
    /// `onAppear` before the departing view's `onDisappear`.
    private(set) var viewers: Set<String> = []

    var isActive: Bool { !viewers.isEmpty }

    func addViewer(_ key: String) {
        let wasIdle = viewers.isEmpty
        viewers.insert(key)
        if wasIdle { start() }
    }

    func removeViewer(_ key: String) {
        viewers.remove(key)
        if viewers.isEmpty { stop() }
    }

    private let stateStore: SessionStateStore
    private let remoteHost: RemoteHostClient
    /// Reads this Mac's own relay link. A closure because the bridge is built
    /// after this object and would otherwise be a retain cycle through AppCore.
    var relayInfo: (() -> MachineStats.Relay)?
    private let collector = SystemStatsCollector()
    private var statsTask: Task<Void, Never>?
    private var linkTask: Task<Void, Never>?

    init(stateStore: SessionStateStore, remoteHost: RemoteHostClient) {
        self.stateStore = stateStore
        self.remoteHost = remoteHost
    }

    // MARK: - Polling

    private func start() {
        statsTask?.cancel()
        linkTask?.cancel()
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.sampleLocal()
                self?.remoteHost.requestStats()
                // Record the reply to the *previous* request, which has landed
                // by now: the poll is a request/response over the relay, so
                // there is nothing to store at the instant we ask.
                self?.recordRemote()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        linkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.sampleTailnet()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func stop() {
        statsTask?.cancel(); statsTask = nil
        linkTask?.cancel(); linkTask = nil
    }

    /// Force one round now — what the Reconnect / refresh affordances call.
    func refresh() {
        Task { @MainActor in
            await sampleLocal()
            remoteHost.requestStats()
            await sampleTailnet()
        }
    }

    private func sampleLocal() async {
        let localSessions = stateStore.all.filter { $0.hostName == nil }.count
        let collector = self.collector
        var stats = await Task.detached(priority: .utility) {
            collector.collect(sessionCount: localSessions)
        }.value
        stats.agentKind = UdhaBuild.kind
        stats.agentVersion = UdhaBuild.version
        stats.logTail = FileLogger.shared.tail(lines: 8)
        stats.relay = relayInfo?()
        local = stats
        lastLocalSampleAt = Date()
        history.record(id: "__local__", stats: stats, sessions: localSessions,
                       rttMilliseconds: stats.relay?.rttMilliseconds)
    }

    /// Store the connected box's latest reading. Keyed by host name — the same
    /// id `MachineSummary` uses — and dropped when the machine goes offline, so
    /// a box that comes back does not draw a line straight across the gap.
    private func recordRemote() {
        guard let host = remoteHost.activeHostName else { return }
        guard let stats = remoteHost.hostStats else { return }
        guard remoteHost.onlineHosts.contains(host) else {
            history.forget(id: host)
            return
        }
        history.record(id: host, stats: stats,
                       sessions: stateStore.all.filter { $0.hostName == host }.count,
                       rttMilliseconds: remoteHost.rttMilliseconds)
    }

    private func sampleTailnet() async {
        let reading = await Task.detached(priority: .utility) { TailscaleCLI.status() }.value
        if let me = reading.selfLink { selfLink = me }
        if let found = reading.links {
            // Keep the RTTs already measured — `status` does not carry them.
            var merged = found
            for (key, old) in links where merged[key] != nil {
                merged[key]?.rttMilliseconds = old.rttMilliseconds
            }
            links = merged
        }
        tailscaleNote = reading.note
        await measureLatencies()
    }

    /// `tailscale status` reports no latency, so each online peer is pinged.
    /// Capped at three peers and 2s each: this is a status panel, not a probe.
    private func measureLatencies() async {
        let me = selfLink?.name.lowercased()
        let targets = links.values
            .filter { $0.online && !$0.name.isEmpty && $0.name.lowercased() != me }
            .prefix(3)
            .map(\.name)
        for name in targets {
            let ms = await Task.detached(priority: .utility) { TailscaleCLI.ping(name) }.value
            links[name.lowercased()]?.rttMilliseconds = ms
        }
    }

    // MARK: - Actions

    /// Restart the agent on a remote box over SSH. The host name doubles as an
    /// SSH alias (Tailscale MagicDNS resolves it from anywhere), which is the
    /// same assumption session handoff already makes.
    func restartAgent(on host: String) async -> String {
        let result = await Task.detached(priority: .userInitiated) {
            SystemStatsCollector.run("ssh", ["-o", "ConnectTimeout=8", "-o", "BatchMode=yes", host,
                                             "systemctl --user restart udha-agent && systemctl --user is-active udha-agent"],
                                     timeout: 25)
        }.value
        guard let result, result.contains("active") else { return "Could not restart udha-agent on \(host)" }
        return "udha-agent restarted on \(host)"
    }
}


// MARK: - Tailscale CLI

/// Reads the tailnet through the `tailscale` binary.
///
/// A free enum rather than methods on the monitor: every call here blocks on a
/// subprocess and runs from a detached task, and main-actor-isolated statics
/// cannot be called from one.
enum TailscaleCLI {
    /// The CLI lives in two places depending on how Tailscale was installed —
    /// the standalone package symlinks it into /usr/local/bin, the App Store
    /// build keeps it inside the bundle.
    private static let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/bin/tailscale",
    ]

    private static func binary() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Peers by lowercased host name, including this machine, plus this
    /// machine's own entry called out separately. `note` is set only when the
    /// read failed, and is what the pane shows instead.
    static func status() -> (links: [String: TailscaleLink]?, selfLink: TailscaleLink?, note: String?) {
        guard let path = binary() else { return (nil, nil, "tailscale CLI not installed") }
        guard let json = runJSON(path, ["status", "--json"]) else {
            return (nil, nil, "tailscale status failed — is the daemon running?")
        }
        var out: [String: TailscaleLink] = [:]
        var me: TailscaleLink?
        if let raw = json["Self"] as? [String: Any], let link = parsePeer(raw) {
            out[link.name.lowercased()] = link
            me = link
        }
        for (_, raw) in (json["Peer"] as? [String: Any]) ?? [:] {
            guard let dict = raw as? [String: Any], let link = parsePeer(dict) else { continue }
            out[link.name.lowercased()] = link
        }
        return (out, me, nil)
    }

    static func ping(_ host: String) -> Double? {
        guard let path = binary(),
              let out = runText(path, ["ping", "-c", "1", "--timeout", "2s", host]) else { return nil }
        // "pong from devbox (100.64.0.2) via 192.168.1.20:41641 in 6ms"
        guard let token = out.split(separator: " ").last(where: { $0.hasSuffix("ms") }) else { return nil }
        return Double(token.dropLast(2))
    }

    private static func parsePeer(_ d: [String: Any]) -> TailscaleLink? {
        guard let name = d["HostName"] as? String, !name.isEmpty else { return nil }
        var link = TailscaleLink(name: name)
        link.address = (d["TailscaleIPs"] as? [String])?.first ?? ""
        link.dnsName = (d["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? ""
        link.os = d["OS"] as? String ?? ""
        link.online = d["Online"] as? Bool ?? false
        link.currentAddress = d["CurAddr"] as? String ?? ""
        link.derpRegion = d["Relay"] as? String ?? ""
        link.lastHandshake = parseDate(d["LastHandshake"] as? String)
        link.keyExpiry = parseDate(d["KeyExpiry"] as? String)
        return link
    }

    /// Tailscale stamps RFC 3339 with fractional seconds, but an unset
    /// timestamp comes back as year 1 rather than as an absent key.
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("0001-") else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func runJSON(_ path: String, _ args: [String]) -> [String: Any]? {
        guard let text = runText(path, args), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func runText(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
