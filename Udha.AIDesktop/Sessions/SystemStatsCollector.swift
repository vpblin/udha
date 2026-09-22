import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads this machine's vitals. One implementation per platform behind one API,
/// so the Mac app and the Linux agent report the same shape.
///
/// Deliberately stateful: CPU load and network throughput are *rates*, which
/// only exist as the difference between two samples, so the collector keeps the
/// previous one. It also caches the slow probes — `ps`, `docker`, `who` and the
/// toolchain versions each spawn a process, and a 5-second poll must not spawn
/// six of them every tick.
///
/// `@unchecked Sendable` + a lock because it is called from a detached task and
/// its cache is the only mutable state.
final class SystemStatsCollector: @unchecked Sendable {
    private let lock = NSLock()

    private var lastCPU: (busy: Double, total: Double)?
    private var lastNet: (name: String, rx: UInt64, tx: UInt64, at: Date)?

    private struct Cached<T> { var value: T; var at: Date }
    private var cachedProcesses: Cached<[MachineStats.Proc]>?
    private var cachedDocker: Cached<MachineStats.Docker?>?
    private var cachedUsers: Cached<Int>?
    private var cachedTools: Cached<[MachineStats.Tool]>?

    init() {}

    /// Collect everything. Blocking; call it off the main actor.
    ///
    /// - Parameter sessionCount: how many sessions the supervisor holds. The
    ///   collector cannot know this — asking tmux would count sessions Udha
    ///   does not own — so the caller supplies it.
    func collect(sessionCount: Int) -> MachineStats {
        var s = MachineStats()
        s.host = Self.hostName
        s.arch = Self.unameMachine()
        s.kernel = Self.unameRelease()
        s.cpuThreads = ProcessInfo.processInfo.processorCount
        s.sessionCount = sessionCount
        s.load = Self.loadAverages()
        s.uptimeSeconds = Self.uptimeSeconds()
        s.agentResidentBytes = Self.residentBytes()
        s.tmuxNote = Self.tmuxNote()
        s.cpuPercent = cpuPercent()
        s.net = netThroughput()
        s.topProcesses = cached(&cachedProcesses, every: 10) { Self.topProcesses() } ?? []
        s.loggedInUsers = cached(&cachedUsers, every: 120) { Self.loggedInUsers() } ?? 0
        s.tools = cached(&cachedTools, every: 900) { Self.toolVersions() } ?? []

        let disk = Self.diskUsage()
        s.diskUsed = disk.used
        s.diskTotal = disk.total
        s.diskDevice = Self.rootDevice()

        let mem = Self.memory()
        s.memoryUsed = mem.used
        s.memoryTotal = mem.total
        s.swapUsed = mem.swapUsed
        s.swapTotal = mem.swapTotal

#if os(macOS)
        s.os = Self.macOSName()
        s.cpuModel = Self.sysctlString("machdep.cpu.brand_string")
        s.agentKind = "Udha.app"
        // No public API reads Apple-silicon die temperatures, and there is no
        // discrete GPU or docker daemon to query — report nothing rather than
        // a plausible-looking zero.
        s.collector = "host_statistics · statvfs · getifaddrs · ps"
#else
        s.os = Self.linuxPrettyName()
        s.cpuModel = Self.linuxCPUModel()
        s.agentKind = "udha-agent"
        s.temperatures = Self.linuxTemperatures()
        s.gpu = Self.nvidiaGPU()
        s.docker = cached(&cachedDocker, every: 30) { Self.dockerSummary() } ?? nil
        s.collector = "/proc · hwmon · statvfs · nvidia-smi · docker"
#endif
        return s
    }

    // MARK: - Cache

    private func cached<T>(_ slot: inout Cached<T>?, every seconds: TimeInterval, _ make: () -> T) -> T? {
        lock.lock()
        if let slot, Date().timeIntervalSince(slot.at) < seconds {
            let v = slot.value
            lock.unlock()
            return v
        }
        lock.unlock()
        let fresh = make()
        lock.lock()
        slot = Cached(value: fresh, at: Date())
        lock.unlock()
        return fresh
    }

    // MARK: - CPU (rate)

    private func cpuPercent() -> Double? {
        guard let now = Self.cpuTicks() else { return nil }
        lock.lock()
        let previous = lastCPU
        lastCPU = now
        lock.unlock()
        guard let previous else { return nil }
        let dTotal = now.total - previous.total
        let dBusy = now.busy - previous.busy
        guard dTotal > 0 else { return nil }
        return max(0, min(100, dBusy / dTotal * 100))
    }

    private static func cpuTicks() -> (busy: Double, total: Double)? {
#if os(macOS)
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
#else
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = stat.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return nil }
        let fields = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard fields.count >= 5 else { return nil }
        let idle = fields[3] + fields[4]                 // idle + iowait
        let total = fields.reduce(0, +)
        return (total - idle, total)
#endif
    }

    // MARK: - Network (rate)

    private func netThroughput() -> MachineStats.Net? {
        guard let sample = Self.primaryInterface() else { return nil }
        let now = Date()
        lock.lock()
        let previous = lastNet
        lastNet = (sample.name, sample.rx, sample.tx, now)
        lock.unlock()
        var net = MachineStats.Net(interface: sample.name)
        if let previous, previous.name == sample.name {
            let seconds = now.timeIntervalSince(previous.at)
            if seconds > 0.5, sample.rx >= previous.rx, sample.tx >= previous.tx {
                net.rxBytesPerSec = Double(sample.rx - previous.rx) / seconds
                net.txBytesPerSec = Double(sample.tx - previous.tx) / seconds
            }
        }
        return net
    }

    /// The busiest real interface. Loopback and the container plumbing
    /// (`veth*`, `br-*`, `docker0`) would otherwise dwarf the physical link.
    private static func primaryInterface() -> (name: String, rx: UInt64, tx: UInt64)? {
        var best: (name: String, rx: UInt64, tx: UInt64)?
        for entry in interfaceCounters() {
            let n = entry.name
            // "lo" on Linux, "lo0" on Darwin — matching only the exact name
            // let the Mac report its loopback as the busiest interface.
            if n.hasPrefix("lo") || n.hasPrefix("veth") || n.hasPrefix("br-") || n.hasPrefix("docker")
                || n.hasPrefix("bridge") || n.hasPrefix("utun") || n.hasPrefix("gif")
                || n.hasPrefix("stf") || n.hasPrefix("awdl") || n.hasPrefix("llw") { continue }
            if best == nil || entry.rx > best!.rx { best = entry }
        }
        return best
    }

    private static func interfaceCounters() -> [(name: String, rx: UInt64, tx: UInt64)] {
#if os(macOS)
        var out: [(String, UInt64, UInt64)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let raw = entry.pointee.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            out.append((String(cString: entry.pointee.ifa_name), UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes)))
        }
        return out
#else
        guard let text = try? String(contentsOfFile: "/proc/net/dev", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst(2).compactMap { line in
            let halves = line.split(separator: ":", maxSplits: 1)
            guard halves.count == 2 else { return nil }
            let name = halves[0].trimmingCharacters(in: .whitespaces)
            let fields = halves[1].split(separator: " ").compactMap { UInt64($0) }
            guard fields.count >= 9 else { return nil }
            return (name, fields[0], fields[8])
        }
#endif
    }

    // MARK: - Memory

    private static func memory() -> (used: UInt64, total: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
#if os(macOS)
        let total = ProcessInfo.processInfo.physicalMemory
        var used: UInt64 = 0
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // What Activity Monitor calls "Memory Used": resident anonymous
            // pages plus wired plus what the compressor holds. File-backed
            // cache is excluded — it is reclaimable, not pressure.
            used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }
        return (used, total, swapUsed, swapTotal)
#else
        var values: [String: UInt64] = [:]
        if let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let kb = UInt64(parts[1].split(separator: " ").first ?? "") else { continue }
                values[String(parts[0])] = kb * 1024
            }
        }
        let total = values["MemTotal"] ?? 0
        // Match `free`: available already accounts for reclaimable cache.
        let available = values["MemAvailable"] ?? values["MemFree"] ?? 0
        let swapTotal = values["SwapTotal"] ?? 0
        let swapFree = values["SwapFree"] ?? 0
        return (total > available ? total - available : 0, total,
                swapTotal > swapFree ? swapTotal - swapFree : 0, swapTotal)
#endif
    }

    // MARK: - Disk

    private static func diskUsage() -> (used: UInt64, total: UInt64) {
        var fs = statvfs()
        guard statvfs("/", &fs) == 0 else { return (0, 0) }
        let unit = UInt64(fs.f_frsize)
        let total = UInt64(fs.f_blocks) * unit
        let free = UInt64(fs.f_bavail) * unit
        return (total > free ? total - free : 0, total)
    }

    private static func rootDevice() -> String {
#if os(macOS)
        return "APFS · /"
#else
        guard let mounts = try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8) else { return "/" }
        for line in mounts.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count >= 2, fields[1] == "/", fields[0].hasPrefix("/dev/") {
                return String(fields[0].dropFirst(5))
            }
        }
        return "/"
#endif
    }

    // MARK: - Identity

    private static var hostName: String {
        ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init)
            ?? ProcessInfo.processInfo.hostName
    }

    private static func loadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return [] }
        return values
    }

    private static func uptimeSeconds() -> Double {
#if os(macOS)
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
#else
        guard let text = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8),
              let first = text.split(separator: " ").first, let seconds = Double(first) else { return 0 }
        return seconds
#endif
    }

    private static func residentBytes() -> UInt64 {
#if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
#else
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return 0 }
        let fields = text.split(separator: " ")
        guard fields.count >= 2, let pages = UInt64(fields[1]) else { return 0 }
        return pages * UInt64(sysconf(Int32(_SC_PAGESIZE)))
#endif
    }

    private static func tmuxNote() -> String {
        if let dir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"], !dir.isEmpty {
            return "\(dir)/tmux-\(getuid())/default"
        }
#if os(macOS)
        return "/private/tmp/tmux-\(getuid())/default"
#else
        return "/tmp/tmux-\(getuid())/default"
#endif
    }

#if os(macOS)
    private static func macOSName() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
#else
    private static func linuxPrettyName() -> String {
        guard let text = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else { return "Linux" }
        for line in text.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            return line.dropFirst("PRETTY_NAME=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return "Linux"
    }

    private static func linuxCPUModel() -> String {
        guard let text = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n") where line.hasPrefix("model name") {
            return line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        return ""
    }

    /// Every `hwmon` sensor the kernel exposes, labelled by chip. `nct6683`
    /// (the MSI super-I/O) publishes fans and pwm too, but read-only in the
    /// in-tree driver, so this only reads temperatures.
    private static func linuxTemperatures() -> [MachineStats.Reading] {
        let fm = FileManager.default
        let root = "/sys/class/hwmon"
        guard let chips = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var out: [MachineStats.Reading] = []
        for chip in chips.sorted() {
            let dir = "\(root)/\(chip)"
            let chipName = (try? String(contentsOfFile: "\(dir)/name", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? chip
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() where file.hasPrefix("temp") && file.hasSuffix("_input") {
                guard let raw = try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8),
                      let milli = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                let labelFile = file.replacingOccurrences(of: "_input", with: "_label")
                let label = (try? String(contentsOfFile: "\(dir)/\(labelFile)", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (label?.isEmpty == false) ? "\(chipName) \(label!)" : chipName
                out.append(MachineStats.Reading(label: name, celsius: milli / 1000))
            }
        }
        return out
    }

    private static func nvidiaGPU() -> MachineStats.GPU? {
        let query = "name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed"
        guard let out = run("nvidia-smi", ["--query-gpu=\(query)", "--format=csv,noheader,nounits"], timeout: 4),
              let line = out.split(separator: "\n").first else { return nil }
        let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 7 else { return nil }
        return MachineStats.GPU(name: f[0], utilPercent: Double(f[1]), memUsedMB: Double(f[2]),
                                memTotalMB: Double(f[3]), celsius: Double(f[4]),
                                watts: Double(f[5]), fanPercent: Double(f[6]))
    }

    /// Container *count* only. `docker stats` needs a full second per container
    /// and would blow any sane poll interval; the per-container breakdown is a
    /// thing to open a terminal for.
    private static func dockerSummary() -> MachineStats.Docker? {
        guard let ids = run("docker", ["ps", "-q"], timeout: 6) else { return nil }
        let running = ids.split(separator: "\n").filter { !$0.isEmpty }.count
        guard running > 0 else { return MachineStats.Docker(running: 0, note: "none running") }
        let names = run("docker", ["ps", "--format", "{{.Names}}"], timeout: 6)?
            .split(separator: "\n").prefix(3).joined(separator: " · ") ?? ""
        return MachineStats.Docker(running: running, note: names)
    }
#endif

    // MARK: - Processes / users / tools

    private static func topProcesses() -> [MachineStats.Proc] {
#if os(macOS)
        let args = ["-Aceo", "pcpu,comm", "-r"]
#else
        let args = ["-eo", "pcpu,comm", "--sort=-pcpu"]
#endif
        guard let out = run("ps", args, timeout: 5) else { return [] }
        return out.split(separator: "\n").dropFirst().prefix(3).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, let cpu = Double(fields[0]), cpu > 0 else { return nil }
            return MachineStats.Proc(name: String(fields[1].prefix(24)), cpuPercent: cpu)
        }
    }

    private static func loggedInUsers() -> Int {
        guard let out = run("who", [], timeout: 5) else { return 0 }
        let names = out.split(separator: "\n").compactMap { $0.split(separator: " ").first }
        return Set(names).count
    }

    private static func toolVersions() -> [MachineStats.Tool] {
        let probes: [(String, String, [String])] = [
            ("claude", "claude", ["--version"]),
            ("node", "node", ["--version"]),
            ("git", "git", ["--version"]),
            ("tmux", "tmux", ["-V"]),
            ("swift", "swift", ["--version"]),
        ]
        return probes.compactMap { name, binary, args in
            guard let out = run(binary, args, timeout: 8), !out.isEmpty else { return nil }
            let first = out.split(separator: "\n").first.map(String.init) ?? ""
            return MachineStats.Tool(name: name, version: shortVersion(first))
        }
    }

    /// "git version 2.45.2" → "2.45.2"; "v22.12.0" → "22.12.0".
    private static func shortVersion(_ line: String) -> String {
        let cleaned = line.trimmingCharacters(in: .whitespaces)
        let token = cleaned.split(separator: " ").first { part in
            let head = part.hasPrefix("v") ? part.dropFirst() : part[...]
            return head.first?.isNumber == true && head.contains(".")
        }
        guard let token else { return String(cleaned.prefix(24)) }
        return String(token.hasPrefix("v") ? token.dropFirst() : token)
    }

    // MARK: - Subprocess

    /// Runs a tool and returns its stdout, or nil if it is missing, fails, or
    /// outlives `timeout`. The PATH is widened by hand: a `systemd --user`
    /// service and a GUI app both inherit a minimal one that has neither
    /// Homebrew nor `~/.local/bin` in it.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPath = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                          "/usr/sbin", "/sbin"].joined(separator: ":")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Kill anything that hangs — a wedged `docker` must never pin the
        // collector, which would stall every later sample behind it.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - uname

/// `utsname` fields are fixed-size C char tuples, so they are read as raw
/// bytes rather than through a KeyPath.
///
/// Read in place, through a pointer to the field. Copying the tuple out as an
/// `Any` first — which is what this used to do — boxes it, and the bytes you
/// then read are the box's header, not the string: that is the "�q,�s" that
/// showed up as every machine's kernel and architecture.
extension SystemStatsCollector {
    static func unameRelease() -> String {
        var info = utsname()
        guard Foundation.uname(&info) == 0 else { return "" }
        let size = MemoryLayout.size(ofValue: info.release)
        return withUnsafePointer(to: &info.release) { field in
            field.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
    }

    static func unameMachine() -> String {
        var info = utsname()
        guard Foundation.uname(&info) == 0 else { return "" }
        let size = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { field in
            field.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
    }
}
