import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One machine's vital signs, as collected *on that machine*.
///
/// Shared by the Mac app and the headless `udha-agent`: the Mac fills this in
/// for itself, the agent fills it in for the box and ships it over the bridge
/// as a `stats` payload. Every field is optional-by-omission — a collector that
/// cannot see something (no GPU, no docker, no hwmon) leaves it empty rather
/// than inventing a zero, because "0 °C" and "no sensor" must not look alike.
struct MachineStats: Sendable, Equatable {
    struct Reading: Sendable, Equatable {
        var label: String
        var celsius: Double
    }

    struct GPU: Sendable, Equatable {
        var name: String = ""
        var utilPercent: Double?
        var memUsedMB: Double?
        var memTotalMB: Double?
        var celsius: Double?
        var watts: Double?
        var fanPercent: Double?
    }

    struct Docker: Sendable, Equatable {
        var running: Int = 0
        var note: String = ""
    }

    /// One mounted drive. A machine can have several — a box with a second
    /// SSD for models or data, a Mac with an external volume — and every one
    /// of them can fill up, so each is reported on its own.
    struct Disk: Sendable, Equatable, Identifiable {
        var id: String { mount }
        /// Where it is mounted: "/", "/mnt/data", "/Volumes/T7".
        var mount: String
        /// The device without "/dev/": "nvme0n1p2", "disk5s1".
        var device: String
        /// "ext4", "apfs", "btrfs", …
        var fsType: String
        var used: UInt64
        var total: UInt64

        var free: UInt64 { total > used ? total - used : 0 }
        var percent: Double? { total > 0 ? Double(used) / Double(total) * 100 : nil }
        var isRoot: Bool { mount == "/" }

        var wire: [String: Any] {
            ["mount": mount, "device": device, "fsType": fsType, "used": used, "total": total]
        }
        init(mount: String, device: String, fsType: String, used: UInt64, total: UInt64) {
            self.mount = mount; self.device = device; self.fsType = fsType
            self.used = used; self.total = total
        }
        init?(wire w: [String: Any]) {
            guard let mount = w["mount"] as? String else { return nil }
            self.mount = mount
            device = w["device"] as? String ?? ""
            fsType = w["fsType"] as? String ?? ""
            used = (w["used"] as? NSNumber)?.uint64Value ?? 0
            total = (w["total"] as? NSNumber)?.uint64Value ?? 0
        }
    }

    struct Net: Sendable, Equatable {
        var interface: String = ""
        var rxBytesPerSec: Double?
        var txBytesPerSec: Double?
    }

    struct Proc: Sendable, Equatable {
        var name: String
        var cpuPercent: Double
    }

    /// One job's share of the machine right now: every process under one
    /// owner — a tmux session, a container, a service, an app — added up.
    struct CPUUser: Sendable, Equatable {
        /// "session" · "container" · "service" · "app" · "system" · "other"
        var kind: String
        /// tmux session name, container name, unit name or program name.
        var name: String
        /// 100 = one core busy.
        var cpuPercent: Double
        var residentBytes: UInt64
        /// NVIDIA SM utilisation summed over the job's processes, and the
        /// video memory they hold. Zero on a machine without one.
        var gpuPercent: Double = 0
        var vramBytes: UInt64 = 0
        var processes: Int
        /// The busiest commands inside it, with how many of each.
        var commands: [Command]

        struct Command: Sendable, Equatable {
            var name: String
            var count: Int
            var cpuPercent: Double
        }
    }

    struct Tool: Sendable, Equatable {
        var name: String
        var version: String
    }

    /// The relay link as the machine itself sees it. Only a host fills this in.
    struct Relay: Sendable, Equatable {
        var instanceID: String = ""
        var url: String = ""
        var transport: String = ""
        var connectedAt: Date?
        var lastPongAt: Date?
        var rttMilliseconds: Double?
        var capabilities: [String] = []
        var deltaSeq: Int = 0
        var signedIn: Bool = false
    }

    struct ConnectionError: Sendable, Equatable {
        var at: Date
        var code: String
        var text: String
    }

    // Identity
    var host: String = ""
    var os: String = ""
    var kernel: String = ""
    var arch: String = ""
    var cpuModel: String = ""
    var cpuThreads: Int = 0
    var uptimeSeconds: Double = 0
    var agentKind: String = ""          // "Udha.app" / "udha-agent"
    var agentVersion: String = ""
    var agentResidentBytes: UInt64 = 0

    // Load
    var cpuPercent: Double?
    var load: [Double] = []

    // Memory
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    // Disk — the root volume, kept as flat fields because every older client
    // (and the phone) reads these. `disks` is every mounted drive, root first.
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskDevice: String = ""
    var disks: [Disk] = []

    var temperatures: [Reading] = []
    var gpu: GPU?
    var docker: Docker?
    var net: Net?
    var topProcesses: [Proc] = []
    /// Nil when the collector predates it (an agent not yet rebuilt), empty
    /// when nothing is busy, nil on the very first sample too.
    var cpuUsers: [CPUUser]?
    var tools: [Tool] = []

    // Sessions as the machine itself counts them
    var sessionCount: Int = 0
    var tmuxNote: String = ""
    var loggedInUsers: Int = 0

    /// Human list of where the numbers came from, shown under "Resources".
    var collector: String = ""
    var relay: Relay?
    var logTail: [String] = []
    var errors: [ConnectionError] = []
    var sampledAt: Date = Date()

    var memoryPercent: Double? {
        guard memoryTotal > 0 else { return nil }
        return Double(memoryUsed) / Double(memoryTotal) * 100
    }

    var diskPercent: Double? {
        guard diskTotal > 0 else { return nil }
        return Double(diskUsed) / Double(diskTotal) * 100
    }

    /// The drive closest to full — the one worth a warning, which is not
    /// always the root drive once a machine has more than one.
    var fullestDisk: Disk? {
        disks.filter { $0.total > 0 }.max { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }

    func temperature(matching needles: [String]) -> Double? {
        for needle in needles {
            if let hit = temperatures.first(where: { $0.label.lowercased().contains(needle) }) {
                return hit.celsius
            }
        }
        return nil
    }
}

// MARK: - Wire format

extension MachineStats {
    /// JSON-ready dictionary for the `stats` bridge payload. Flat where it can
    /// be, nested only where a group is genuinely optional.
    var wire: [String: Any] {
        var w: [String: Any] = [
            "host": host, "os": os, "kernel": kernel, "arch": arch,
            "cpuModel": cpuModel, "cpuThreads": cpuThreads,
            "uptimeSeconds": uptimeSeconds,
            "agentKind": agentKind, "agentVersion": agentVersion,
            "agentResidentBytes": agentResidentBytes,
            "load": load,
            "memoryUsed": memoryUsed, "memoryTotal": memoryTotal,
            "swapUsed": swapUsed, "swapTotal": swapTotal,
            "diskUsed": diskUsed, "diskTotal": diskTotal, "diskDevice": diskDevice,
            "disks": disks.map(\.wire),
            "sessionCount": sessionCount, "tmuxNote": tmuxNote,
            "loggedInUsers": loggedInUsers,
            "collector": collector,
            "sampledAt": sampledAt.timeIntervalSince1970,
            "temperatures": temperatures.map { ["label": $0.label, "celsius": $0.celsius] },
            "topProcesses": topProcesses.map { ["name": $0.name, "cpuPercent": $0.cpuPercent] },
            "tools": tools.map { ["name": $0.name, "version": $0.version] },
            "logTail": logTail,
            "errors": errors.map { ["at": $0.at.timeIntervalSince1970, "code": $0.code, "text": $0.text] },
        ]
        if let cpuPercent { w["cpuPercent"] = cpuPercent }
        if let cpuUsers {
            w["cpuUsers"] = cpuUsers.map { u -> [String: Any] in
                ["kind": u.kind, "name": u.name, "cpuPercent": u.cpuPercent,
                 "residentBytes": u.residentBytes, "processes": u.processes,
                 "gpuPercent": u.gpuPercent, "vramBytes": u.vramBytes,
                 "commands": u.commands.map { ["name": $0.name, "count": $0.count, "cpuPercent": $0.cpuPercent] }]
            }
        }
        if let gpu {
            var g: [String: Any] = ["name": gpu.name]
            if let v = gpu.utilPercent { g["utilPercent"] = v }
            if let v = gpu.memUsedMB { g["memUsedMB"] = v }
            if let v = gpu.memTotalMB { g["memTotalMB"] = v }
            if let v = gpu.celsius { g["celsius"] = v }
            if let v = gpu.watts { g["watts"] = v }
            if let v = gpu.fanPercent { g["fanPercent"] = v }
            w["gpu"] = g
        }
        if let docker { w["docker"] = ["running": docker.running, "note": docker.note] }
        if let net {
            var n: [String: Any] = ["interface": net.interface]
            if let v = net.rxBytesPerSec { n["rxBytesPerSec"] = v }
            if let v = net.txBytesPerSec { n["txBytesPerSec"] = v }
            w["net"] = n
        }
        if let relay {
            var r: [String: Any] = [
                "instanceId": relay.instanceID, "url": relay.url,
                "transport": relay.transport, "capabilities": relay.capabilities,
                "deltaSeq": relay.deltaSeq, "signedIn": relay.signedIn,
            ]
            if let v = relay.connectedAt { r["connectedAt"] = v.timeIntervalSince1970 }
            if let v = relay.lastPongAt { r["lastPongAt"] = v.timeIntervalSince1970 }
            if let v = relay.rttMilliseconds { r["rttMilliseconds"] = v }
            w["relay"] = r
        }
        return w
    }

    init(wire w: [String: Any]) {
        host = w["host"] as? String ?? ""
        os = w["os"] as? String ?? ""
        kernel = w["kernel"] as? String ?? ""
        arch = w["arch"] as? String ?? ""
        cpuModel = w["cpuModel"] as? String ?? ""
        cpuThreads = w["cpuThreads"] as? Int ?? 0
        uptimeSeconds = w["uptimeSeconds"] as? Double ?? 0
        agentKind = w["agentKind"] as? String ?? ""
        agentVersion = w["agentVersion"] as? String ?? ""
        agentResidentBytes = (w["agentResidentBytes"] as? NSNumber)?.uint64Value ?? 0
        cpuPercent = w["cpuPercent"] as? Double
        load = w["load"] as? [Double] ?? []
        memoryUsed = (w["memoryUsed"] as? NSNumber)?.uint64Value ?? 0
        memoryTotal = (w["memoryTotal"] as? NSNumber)?.uint64Value ?? 0
        swapUsed = (w["swapUsed"] as? NSNumber)?.uint64Value ?? 0
        swapTotal = (w["swapTotal"] as? NSNumber)?.uint64Value ?? 0
        diskUsed = (w["diskUsed"] as? NSNumber)?.uint64Value ?? 0
        diskTotal = (w["diskTotal"] as? NSNumber)?.uint64Value ?? 0
        diskDevice = w["diskDevice"] as? String ?? ""
        disks = ((w["disks"] as? [[String: Any]]) ?? []).compactMap(Disk.init(wire:))
        // An agent built before `disks` sends only the root fields: show that
        // one drive rather than an empty list.
        if disks.isEmpty, diskTotal > 0 {
            disks = [Disk(mount: "/", device: diskDevice, fsType: "", used: diskUsed, total: diskTotal)]
        }
        sessionCount = w["sessionCount"] as? Int ?? 0
        tmuxNote = w["tmuxNote"] as? String ?? ""
        loggedInUsers = w["loggedInUsers"] as? Int ?? 0
        collector = w["collector"] as? String ?? ""
        sampledAt = (w["sampledAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        temperatures = ((w["temperatures"] as? [[String: Any]]) ?? []).compactMap {
            guard let l = $0["label"] as? String, let c = $0["celsius"] as? Double else { return nil }
            return Reading(label: l, celsius: c)
        }
        topProcesses = ((w["topProcesses"] as? [[String: Any]]) ?? []).compactMap {
            guard let n = $0["name"] as? String, let c = $0["cpuPercent"] as? Double else { return nil }
            return Proc(name: n, cpuPercent: c)
        }
        cpuUsers = (w["cpuUsers"] as? [[String: Any]]).map { rows in
            rows.compactMap { r in
                guard let name = r["name"] as? String, let cpu = r["cpuPercent"] as? Double else { return nil }
                let commands = ((r["commands"] as? [[String: Any]]) ?? []).compactMap { c -> CPUUser.Command? in
                    guard let n = c["name"] as? String else { return nil }
                    return CPUUser.Command(name: n, count: c["count"] as? Int ?? 1,
                                           cpuPercent: c["cpuPercent"] as? Double ?? 0)
                }
                return CPUUser(kind: r["kind"] as? String ?? "other", name: name, cpuPercent: cpu,
                               residentBytes: (r["residentBytes"] as? NSNumber)?.uint64Value ?? 0,
                               gpuPercent: r["gpuPercent"] as? Double ?? 0,
                               vramBytes: (r["vramBytes"] as? NSNumber)?.uint64Value ?? 0,
                               processes: r["processes"] as? Int ?? 1, commands: commands)
            }
        }
        tools = ((w["tools"] as? [[String: Any]]) ?? []).compactMap {
            guard let n = $0["name"] as? String, let v = $0["version"] as? String else { return nil }
            return Tool(name: n, version: v)
        }
        logTail = w["logTail"] as? [String] ?? []
        errors = ((w["errors"] as? [[String: Any]]) ?? []).compactMap {
            guard let at = $0["at"] as? Double, let c = $0["code"] as? String, let t = $0["text"] as? String
            else { return nil }
            return ConnectionError(at: Date(timeIntervalSince1970: at), code: c, text: t)
        }
        if let g = w["gpu"] as? [String: Any] {
            gpu = GPU(name: g["name"] as? String ?? "",
                      utilPercent: g["utilPercent"] as? Double,
                      memUsedMB: g["memUsedMB"] as? Double,
                      memTotalMB: g["memTotalMB"] as? Double,
                      celsius: g["celsius"] as? Double,
                      watts: g["watts"] as? Double,
                      fanPercent: g["fanPercent"] as? Double)
        }
        if let d = w["docker"] as? [String: Any] {
            docker = Docker(running: d["running"] as? Int ?? 0, note: d["note"] as? String ?? "")
        }
        if let n = w["net"] as? [String: Any] {
            net = Net(interface: n["interface"] as? String ?? "",
                      rxBytesPerSec: n["rxBytesPerSec"] as? Double,
                      txBytesPerSec: n["txBytesPerSec"] as? Double)
        }
        if let r = w["relay"] as? [String: Any] {
            relay = Relay(instanceID: r["instanceId"] as? String ?? "",
                          url: r["url"] as? String ?? "",
                          transport: r["transport"] as? String ?? "",
                          connectedAt: (r["connectedAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                          lastPongAt: (r["lastPongAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
                          rttMilliseconds: r["rttMilliseconds"] as? Double,
                          capabilities: r["capabilities"] as? [String] ?? [],
                          deltaSeq: r["deltaSeq"] as? Int ?? 0,
                          signedIn: r["signedIn"] as? Bool ?? false)
        }
    }
}

// MARK: - Build identity

/// What this binary calls itself. The agent and the app report the same field,
/// so the Machines pane can say which one is supervising a box.
enum UdhaBuild {
    /// Bumped by hand. Also what `udha-agent version` prints.
    static let agentVersion = "0.2.0"

    static var kind: String {
#if UDHA_AGENT
        "udha-agent"
#else
        "Udha.app"
#endif
    }

    static var version: String {
#if UDHA_AGENT
        agentVersion
#else
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
#endif
    }

    /// What the phone is told in `hello_ack` and `home_info`. The phone keys
    /// copy and icons off this ("udha-headless" has no camera, screen or video
    /// library), so a Linux agent must not call itself a desktop.
    static var instanceKind: String {
#if UDHA_AGENT
        "udha-headless"
#else
        "udha-desktop"
#endif
    }
}
