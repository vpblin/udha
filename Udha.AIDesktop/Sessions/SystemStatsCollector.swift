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
    /// One collection at a time. Two clients (the Mac and the phone) can ask
    /// within the same second, and two overlapping `collect`s raced on the
    /// rate samples and on the cache slots — `cached(&slot…)` holds an inout
    /// access to the slot across the whole probe.
    private let collectLock = NSLock()

    private var lastCPU: (busy: Double, total: Double)?
    private var lastNet: (name: String, rx: UInt64, tx: UInt64, at: Date)?

    private struct Cached<T> { var value: T; var at: Date }
    private var cachedProcesses: Cached<[MachineStats.Proc]>?
    private var cachedDocker: Cached<MachineStats.Docker?>?
    private var cachedUsers: Cached<Int>?
    private var cachedTools: Cached<[MachineStats.Tool]>?
    private var cachedPanes: Cached<[Int32: String]>?
    private var cachedContainers: Cached<[String: String]>?
    /// Per-process CPU ticks from the last sample, keyed by pid and checked
    /// against the start time so a reused pid is never read as one process.
    private var lastProcs: (at: Date, ticks: [Int32: (start: UInt64, ticks: UInt64)])?

    init() {}

    /// Collect everything. Blocking; call it off the main actor.
    ///
    /// - Parameter sessionCount: how many sessions the supervisor holds. The
    ///   collector cannot know this — asking tmux would count sessions Udha
    ///   does not own — so the caller supplies it.
    func collect(sessionCount: Int) -> MachineStats {
        collectLock.lock()
        defer { collectLock.unlock() }
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
        s.cpuUsers = cpuUsers()
        s.loggedInUsers = cached(&cachedUsers, every: 120) { Self.loggedInUsers() } ?? 0
        s.tools = cached(&cachedTools, every: 900) { Self.toolVersions() } ?? []

        let disk = Self.diskUsage()
        s.diskUsed = disk.used
        s.diskTotal = disk.total
        s.diskDevice = Self.rootDevice()
        s.disks = Self.mountedDisks()

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
        guard let stat = Self.procText("/proc/stat"),
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
        guard let text = Self.procText("/proc/net/dev") else { return [] }
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
        if let text = Self.procText("/proc/meminfo") {
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

    /// Every mounted drive worth watching, root first, then by mount point.
    ///
    /// "Worth watching" means a real filesystem on a real device: no tmpfs,
    /// overlay, squashfs snaps, loop devices, docker's own mounts, the EFI
    /// partition, or anything under 1 GB. A drive mounted twice (a bind mount,
    /// btrfs subvolumes) is listed once, at its shortest mount point.
    /// Reads a /proc file to its end. Foundation's `String(contentsOfFile:)`
    /// trusts the size `stat` reports, and procfs reports 0, so on Linux it
    /// returns one page (~4 KB) and stops: on a box with Docker and snaps
    /// /proc/self/mounts is 46 KB and a second drive mounted after boot sits
    /// past the cut, so it never showed up. Read in a loop until EOF instead.
    static func procText(_ path: String) -> String? {
        guard let f = fopen(path, "r") else { return nil }
        defer { fclose(f) }
        var data = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = fread(&chunk, 1, chunk.count, f)
            if n > 0 { data.append(contentsOf: chunk[0..<n]) }
            if n < chunk.count { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func mountedDisks() -> [MachineStats.Disk] {
        var disks: [MachineStats.Disk] = []
#if os(macOS)
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var seen = Set<String>()
        for i in 0..<Int(count) {
            var fs = buffer[i]
            let flags = UInt32(fs.f_flags)
            let mount = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard flags & UInt32(MNT_LOCAL) != 0 else { continue }
            // The system's own APFS volumes (Data, Preboot, VM, …) carry
            // MNT_DONTBROWSE and share the root container's space; listing
            // them would show the same free space several times.
            guard mount == "/" || flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
            guard !["devfs", "autofs", "nullfs", "lifs"].contains(type) else { continue }
            guard from.hasPrefix("/dev/"), !seen.contains(from) else { continue }
            let unit = UInt64(fs.f_bsize)
            let total = UInt64(fs.f_blocks) * unit
            let free = UInt64(fs.f_bavail) * unit
            guard total >= 1_000_000_000 else { continue }
            seen.insert(from)
            disks.append(.init(mount: mount, device: String(from.dropFirst(5)), fsType: type,
                               used: total > free ? total - free : 0, total: total))
        }
#else
        guard let table = Self.procText("/proc/self/mounts") else { return [] }
        let realFilesystems: Set<String> = ["ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "jfs",
                                            "reiserfs", "ntfs", "ntfs3", "fuseblk", "exfat", "vfat", "hfsplus"]
        let skipped = ["/boot", "/snap", "/var/lib/docker", "/var/snap", "/run", "/proc", "/sys", "/dev"]
        var byDevice: [String: MachineStats.Disk] = [:]
        for line in table.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 3 else { continue }
            let device = String(fields[0])
            let mount = unescapeMountField(String(fields[1]))
            let type = String(fields[2])
            guard realFilesystems.contains(type) else { continue }
            guard type == "zfs" || device.hasPrefix("/dev/"), !device.hasPrefix("/dev/loop") else { continue }
            guard !skipped.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) else { continue }
            if let existing = byDevice[device], existing.mount.count <= mount.count { continue }
            var fs = statvfs()
            guard statvfs(mount, &fs) == 0 else { continue }
            let unit = UInt64(fs.f_frsize)
            let total = UInt64(fs.f_blocks) * unit
            let free = UInt64(fs.f_bavail) * unit
            guard total >= 1_000_000_000 else { continue }
            byDevice[device] = .init(mount: mount,
                                     device: device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device,
                                     fsType: type, used: total > free ? total - free : 0, total: total)
        }
        disks = Array(byDevice.values)
#endif
        return disks.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            return a.mount < b.mount
        }
    }

#if !os(macOS)
    /// /proc/mounts writes a space in a mount point as `\040` (octal), and
    /// likewise tab, newline and backslash.
    private static func unescapeMountField(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var out = [UInt8]()
        let bytes = Array(raw.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\"), i + 3 < bytes.count,
               let v = UInt8(String(decoding: bytes[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                out.append(v); i += 4
            } else {
                out.append(bytes[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
#endif

    private static func rootDevice() -> String {
#if os(macOS)
        return "APFS · /"
#else
        guard let mounts = Self.procText("/proc/self/mounts") else { return "/" }
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
        guard let text = Self.procText("/proc/uptime"),
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
        guard let text = Self.procText("/proc/self/statm") else { return 0 }
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
        guard let text = Self.procText("/proc/cpuinfo") else { return "" }
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

    // MARK: - CPU by job

    private struct ProcRow {
        var pid: Int32
        var ppid: Int32
        var comm: String
        var cpu: Double          // 100 = one core
        var rss: UInt64
        var cgroup: String?      // Linux only, read lazily
        var gpu: Double = 0      // NVIDIA SM %
        var vram: UInt64 = 0
    }

    /// What is using the CPU *now*, rolled up by owner: the Udha/tmux session a
    /// process descends from, else its container, its systemd unit or its app.
    /// A process list ranked by name ("chrome 65%" ×4) hides that four renderers
    /// and four encoders are one video render; the owner is what you can act on.
    private func cpuUsers() -> [MachineStats.CPUUser]? {
        let panes = cached(&cachedPanes, every: 10) { Self.tmuxPanes() } ?? [:]
#if os(macOS)
        let rows = Self.macProcesses()
        let containers: [String: String] = [:]
#else
        guard var rows = linuxProcessRates() else { return nil }
        let gpu = Self.nvidiaProcesses()
        if !gpu.isEmpty {
            for i in rows.indices {
                if let g = gpu[rows[i].pid] { rows[i].gpu = g.sm; rows[i].vram = g.fb }
            }
        }
        let containers = cached(&cachedContainers, every: 30) { Self.dockerContainers() } ?? [:]
#endif
        guard !rows.isEmpty else { return [] }
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [Int32: (kind: String, name: String)] = [:]

        func owner(_ pid: Int32, depth: Int = 0) -> (kind: String, name: String) {
            if let hit = memo[pid] { return hit }
            var result: (kind: String, name: String)
            if let session = panes[pid] {
                result = ("session", session)
            } else if let row = byPID[pid], row.ppid > 1, depth < 64, byPID[row.ppid] != nil,
                      case let parent = owner(row.ppid, depth: depth + 1), parent.kind == "session" {
                result = parent
            } else {
                result = Self.ownerOutsideTmux(byPID[pid], containers: containers)
            }
            memo[pid] = result
            return result
        }

        struct Acc { var cpu = 0.0; var rss: UInt64 = 0; var gpu = 0.0; var vram: UInt64 = 0; var procs = 0; var cmds: [String: (Int, Double)] = [:] }
        var totals: [String: (kind: String, name: String, acc: Acc)] = [:]
        for row in rows {
            let who = owner(row.pid)
            let key = who.kind + ":" + who.name
            var entry = totals[key] ?? (who.kind, who.name, Acc())
            entry.acc.cpu += row.cpu
            entry.acc.rss += row.rss
            entry.acc.gpu += row.gpu
            entry.acc.vram += row.vram
            entry.acc.procs += 1
            let c = entry.acc.cmds[row.comm] ?? (0, 0)
            entry.acc.cmds[row.comm] = (c.0 + 1, c.1 + row.cpu)
            totals[key] = entry
        }
        // Ranked by whichever of the two it is heavier on: a model holding the
        // GPU at 90% is as busy as a build holding every core.
        let cores = Double(max(1, ProcessInfo.processInfo.processorCount))
        // VRAM counts too (1 GB ≈ 2%), so an idle model server still holding
        // the card's memory is listed.
        func weight(_ a: Acc) -> Double { max(a.cpu / cores, a.gpu, Double(a.vram) / 1e9 * 2) }
        return totals.values
            .filter { $0.acc.cpu >= 0.5 || $0.acc.vram > 0 || $0.acc.gpu > 0 }
            .sorted { weight($0.acc) > weight($1.acc) }
            .prefix(12)
            .map { entry in
                let commands = entry.acc.cmds
                    .sorted { $0.value.1 > $1.value.1 }
                    .prefix(3)
                    .map { MachineStats.CPUUser.Command(name: $0.key, count: $0.value.0, cpuPercent: $0.value.1) }
                return MachineStats.CPUUser(kind: entry.kind, name: entry.name, cpuPercent: entry.acc.cpu,
                                            residentBytes: entry.acc.rss,
                                            gpuPercent: entry.acc.gpu, vramBytes: entry.acc.vram,
                                            processes: entry.acc.procs,
                                            commands: commands)
            }
    }

    /// pane pid → tmux session name, for every pane on the default server.
    private static func tmuxPanes() -> [Int32: String] {
        guard let out = run("tmux", ["list-panes", "-a", "-F", "#{pane_pid} #{session_name}"], timeout: 5) else { return [:] }
        var map: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1)
            if f.count == 2, let pid = Int32(f[0]) { map[pid] = String(f[1]) }
        }
        return map
    }

    private static func ownerOutsideTmux(_ row: ProcRow?, containers: [String: String]) -> (kind: String, name: String) {
        guard let row else { return ("other", "?") }
#if os(macOS)
        // "/Applications/Google Chrome.app/Contents/…/Helper" → "Google Chrome"
        if let range = row.comm.range(of: ".app/") {
            let app = row.comm[..<range.lowerBound].split(separator: "/").last.map(String.init) ?? row.comm
            return ("app", app)
        }
        let name = row.comm.split(separator: "/").last.map(String.init) ?? row.comm
        return (row.ppid <= 1 ? "system" : "app", name)
#else
        if row.ppid == 2 || row.pid == 2 { return ("system", "kernel") }
        let cgroup = row.cgroup ?? ""
        let leaf = cgroup.split(separator: "/").last.map(String.init) ?? ""
        if leaf.hasPrefix("docker-"), leaf.hasSuffix(".scope") {
            let id = String(leaf.dropFirst(7).dropLast(6))
            return ("container", containers[String(id.prefix(12))] ?? String(id.prefix(12)))
        }
        if let range = cgroup.range(of: "/docker/") {
            let id = String(cgroup[range.upperBound...].prefix(12))
            return ("container", containers[id] ?? id)
        }
        if leaf.hasSuffix(".service"), !leaf.hasPrefix("user@") {
            return ("service", String(leaf.dropLast(8)))
        }
        if leaf.hasPrefix("tmux-spawn-") { return ("session", "tmux · detached") }
        if leaf.hasPrefix("session-"), leaf.hasSuffix(".scope") { return ("other", "ssh · \(row.comm)") }
        return ("other", row.comm)
#endif
    }

#if os(macOS)
    /// macOS `ps` %CPU is already a short decaying average of recent use, so no
    /// second sample is needed. Paths, not names, so apps can be grouped.
    private static func macProcesses() -> [ProcRow] {
        guard let out = run("ps", ["-Ao", "pid=,ppid=,pcpu=,rss=,comm="], timeout: 5) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let ppid = Int32(f[1]),
                  let cpu = Double(f[2]), let rss = UInt64(f[3]) else { return nil }
            return ProcRow(pid: pid, ppid: ppid, comm: String(f[4]), cpu: cpu, rss: rss * 1024, cgroup: nil)
        }
    }
#else
    /// Real current CPU per process: the change in utime+stime between two
    /// samples. `ps %CPU` on Linux is a lifetime average and ranks a job that
    /// was busy an hour ago above one burning eight cores right now. With no
    /// recent previous sample it takes two, 0.4 s apart.
    private func linuxProcessRates() -> [ProcRow]? {
        lock.lock()
        let previous = lastProcs
        lock.unlock()
        var base = previous
        if base == nil || Date().timeIntervalSince(base!.at) > 30 {
            let seed = Self.readProcStats()
            base = (Date(), Dictionary(seed.map { ($0.pid, (start: $0.start, ticks: $0.ticks)) },
                                      uniquingKeysWith: { a, _ in a }))
            usleep(400_000)
        }
        let now = Date()
        let current = Self.readProcStats()
        lock.lock()
        lastProcs = (now, Dictionary(current.map { ($0.pid, (start: $0.start, ticks: $0.ticks)) },
                                     uniquingKeysWith: { a, _ in a }))
        lock.unlock()
        guard let base else { return nil }
        let dt = now.timeIntervalSince(base.at)
        guard dt > 0.1 else { return nil }
        let hz = Double(sysconf(Int32(_SC_CLK_TCK)))
        let page = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        return current.map { p in
            var used: UInt64 = 0
            if let before = base.ticks[p.pid], before.start == p.start, p.ticks >= before.ticks {
                used = p.ticks - before.ticks
            }
            let cgroup = try? String(contentsOfFile: "/proc/\(p.pid)/cgroup", encoding: .utf8)
            return ProcRow(pid: p.pid, ppid: p.ppid, comm: p.comm,
                           cpu: Double(used) / hz / dt * 100, rss: p.rssPages * page,
                           cgroup: cgroup?.split(separator: "\n").last.map(String.init))
        }
    }

    private struct ProcStat { var pid: Int32; var ppid: Int32; var comm: String; var ticks: UInt64; var start: UInt64; var rssPages: UInt64 }

    private static func readProcStats() -> [ProcStat] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return entries.compactMap { entry in
            guard let pid = Int32(entry),
                  let text = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                  let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
            let comm = String(text[text.index(after: open)..<close])
            // Fields after the name, starting at field 3 (state).
            let rest = text[text.index(after: close)...].split(separator: " ")
            guard rest.count > 21, let ppid = Int32(rest[1]),
                  let utime = UInt64(rest[11]), let stime = UInt64(rest[12]),
                  let start = UInt64(rest[19]), let rss = UInt64(rest[21]) else { return nil }
            return ProcStat(pid: pid, ppid: ppid, comm: comm, ticks: utime + stime, start: start, rssPages: rss)
        }
    }

    /// pid → (SM %, framebuffer bytes) from one `nvidia-smi pmon` sample.
    /// "-" means the driver saw no work in the window, read as zero.
    private static func nvidiaProcesses() -> [Int32: (sm: Double, fb: UInt64)] {
        guard let out = run("nvidia-smi", ["pmon", "-c", "1", "-s", "um"], timeout: 4) else { return [:] }
        var map: [Int32: (sm: Double, fb: UInt64)] = [:]
        for line in out.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count > 9, let pid = Int32(f[1]) else { continue }
            let sm = Double(f[3]) ?? 0
            let fb = (UInt64(f[9]) ?? 0) * 1_048_576
            let prev = map[pid] ?? (0, 0)
            map[pid] = (prev.sm + sm, prev.fb + fb)
        }
        return map
    }

    /// 12-char container id → name.
    private static func dockerContainers() -> [String: String] {
        guard let out = run("docker", ["ps", "--format", "{{.ID}} {{.Names}}"], timeout: 6) else { return [:] }
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 1)
            if f.count == 2 { map[String(f[0].prefix(12))] = String(f[1]) }
        }
        return map
    }
#endif

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
#if os(Linux)
        return spawnCapture(tool, arguments, path: searchPath, timeout: timeout)
#else
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
        let data = output.fileHandleForReading.readToEndRetryingInterrupts()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
#endif
    }

#if os(Linux)
    /// `posix_spawn` + `poll` + `waitpid`, all on the calling thread.
    ///
    /// Foundation's `Process` on Linux corrupted the agent's heap: it keeps a
    /// process-wide SIGCHLD dispatch source, and the old timeout watchdog held
    /// each finished `Process` until its deadline and freed it on a dispatch
    /// thread while the tmux poller was spawning processes of its own. The
    /// agent died with "double free or corruption" every few hours (twelve
    /// core dumps 2026-10-07…09), dropping every client's link each time.
    /// Nothing here touches Foundation or Dispatch, so nothing outlives the
    /// call and nothing runs on another thread.
    private static func spawnCapture(_ tool: String, _ arguments: [String], path: String,
                                     timeout: TimeInterval) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readEnd = fds[0], writeEnd = fds[1]
        // Close-on-exec, so a child spawned elsewhere never inherits them.
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        let argv = (["/usr/bin/env", tool] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/usr/bin/env", &actions, nil, argv, envp)
        close(writeEnd)
        guard rc == 0 else { close(readEnd); return nil }

        // Read until EOF or the deadline, then kill whatever is left.
        var data = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let n = read(readEnd, &buffer, buffer.count)
            if n > 0 { data.append(contentsOf: buffer[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            break   // EOF or error
        }
        close(readEnd)
        if timedOut { kill(pid, SIGKILL) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        // WIFEXITED && WEXITSTATUS == 0, spelled out (the macros are not imported).
        guard !timedOut, (status & 0x7f) == 0, ((status >> 8) & 0xff) == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
#endif
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
