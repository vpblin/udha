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

    struct Net: Sendable, Equatable {
        var interface: String = ""
        var rxBytesPerSec: Double?
        var txBytesPerSec: Double?
    }

    struct Proc: Sendable, Equatable {
        var name: String
        var cpuPercent: Double
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

    // Disk (the root volume)
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskDevice: String = ""

    var temperatures: [Reading] = []
    var gpu: GPU?
    var docker: Docker?
    var net: Net?
    var topProcesses: [Proc] = []
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
