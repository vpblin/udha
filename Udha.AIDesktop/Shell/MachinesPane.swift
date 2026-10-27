import SwiftUI

/// The Machines detail pane: one machine's link, resources, temperatures,
/// sessions, toolchain and agent log — every number carrying the shape it has
/// been making.
///
/// Everything here is measured, never inferred. A number the collector could
/// not read renders as "—", and a section that cannot be filled says why in
/// plain words — a dashboard whose gauges keep displaying the last good value
/// after the machine went away is worse than one that admits it lost contact.
struct MachinesPane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel
    /// Temperature groups opened to show their individual sensors.
    @State private var openTemperatureGroups: Set<String> = []

    private var machines: [MachineSummary] { MachineDirectory.summaries(core: core) }

    private var machine: MachineSummary {
        MachineDirectory.summary(core: core, host: shell.selectedMachine)
    }

    /// The machine the toolchain column compares against: the other one that
    /// actually reported versions.
    private var counterpart: MachineSummary? {
        machines.first { $0.id != machine.id && !($0.stats?.tools.isEmpty ?? true) }
    }

    /// The level at which a reading stops being information and starts being a
    /// warning.
    private var hotAbove: Double { 80 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                if let note = machine.offlineNote { offlineBanner(note) }
                headerCard
                resourcesSection
                cpuJobsSection
                temperaturesSection
                sessionsSection
                HStack(alignment: .top, spacing: UdhaTheme.cardGap) {
                    toolchainSection.frame(maxWidth: .infinity, alignment: .topLeading)
                    errorsSection.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                logSection
            }
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .udhaScroll()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // First visit lands on the machine that runs the work, not on the
            // Mac — the Mac is the thing you are already looking at.
            if !shell.machinePicked {
                shell.selectedMachine = core.connectedHostNames.first ?? core.remoteHosts.onlineHosts.sorted().first
                shell.machinePicked = true
            }
            core.machines.addViewer("machines")
        }
        .onDisappear { core.machines.removeViewer("machines") }
    }

    // MARK: - Header card

    /// Name, link pill, role, the meta line, the actions — and under a
    /// hairline the six head stats, each with its recent shape.
    private var headerCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(machine.name)
                            .font(UdhaTheme.text(22, .bold))
                            .tracking(-0.3)
                            .foregroundStyle(UdhaTheme.label)
                            .lineLimit(1)
                        linkPill
                        UdhaPill(machine.role, size: 11, height: 20)
                    }
                    Text(machine.meta)
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                actions
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            HRule(color: UdhaTheme.hairline)
            headStats
        }
        .udhaCard()
        .udhaRounded(UdhaTheme.cardRadius)
    }

    private var linkPill: some View {
        let online = machine.online
        let word = online ? (machine.connected || machine.isLocal ? "Connected" : "Online") : "Offline"
        return HStack(spacing: 5) {
            Circle().fill(online ? UdhaTheme.good : UdhaTheme.bad).frame(width: 6, height: 6)
            Text(word).font(UdhaTheme.text(11, .semibold))
        }
        .foregroundStyle(online ? UdhaTheme.goodInk : UdhaTheme.badInk)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 20)
        .background(Capsule().fill(online ? UdhaTheme.goodTint : UdhaTheme.badTint))
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if let host = machine.host {
                if machine.connected {
                    Button {
                        core.disconnectHost(host)
                        shell.say("Disconnected from \(host) — its sessions left the list")
                    } label: { Text("Disconnect") }
                    .udhaButton(.ghost, height: 26)
                } else if !machine.online {
                    Button {
                        core.forgetHost(host)
                        shell.selectedMachine = nil
                        shell.say("Forgot \(host)")
                    } label: { Text("Forget") }
                    .udhaButton(.ghost, height: 26)
                    .help("Remove this machine from the list. It comes back if it ever goes online again.")
                } else {
                    Button {
                        core.connectHost(host)
                        shell.say("Connecting to \(host)…")
                    } label: { Text("Connect") }
                    .udhaButton(.primary, height: 26)
                    .disabled(!machine.online)
                }
            }

            Button {
                MachineActions.openTerminal(host: machine.host)
                shell.say(machine.host.map { "Opened an SSH terminal on \($0)" } ?? "Opened Terminal")
            } label: {
                Text(machine.isLocal ? "Open Terminal" : "Open in Terminal")
            }
            .udhaButton(.ghost, height: 26)

            Button {
                core.machines.refresh()
                shell.say("Re-reading \(machine.name)…")
            } label: {
                Text("Refresh")
            }
            .udhaButton(machine.host == nil || machine.connected ? .primary : .ghost, height: 26)

            Menu {
                if let host = machine.host {
                    Button("Reconnect the relay link") {
                        core.disconnectHost(host)
                        core.connectHost(host)
                        shell.say("Re-pairing with \(host)…")
                    }
                    Button("Restart udha-agent over SSH") { restartAgent(host) }
                    Divider()
                    Button("Copy ssh command") { MachineActions.copy("ssh \(host)") }
                    if let address = machine.link?.address {
                        Button("Copy Tailscale address") { MachineActions.copy(address) }
                    }
                    Button("Copy instance id") {
                        MachineActions.copy(machine.stats?.relay?.instanceID ?? host)
                    }
                } else {
                    Button("Restart the bridge") {
                        core.mobileBridge.stop()
                        core.mobileBridge.start()
                        shell.say("Bridge restarted")
                    }
                    Button("Reveal log in Finder") { MachineActions.revealLog() }
                    Button("Copy instance id") { MachineActions.copy(core.mobileBridgeRelay.instanceID) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UdhaTheme.label)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous).fill(UdhaTheme.fill))
        }
    }

    private func restartAgent(_ host: String) {
        shell.say("Restarting udha-agent on \(host)…")
        Task {
            let result = await core.machines.restartAgent(on: host)
            shell.say(result)
            core.machines.refresh()
        }
    }

    // MARK: - Head stats

    /// Six numbers, each with the shape it has been making. The Link cell
    /// carries the tailnet's verdict instead of a chart: "connected" is not a
    /// quantity, and whether Tailscale is up is the thing you actually want
    /// beside it when it says Offline.
    private var headStats: some View {
        let stats = machine.stats
        let id = machine.id
        let history = core.machines.history
        let cells: [HeadStat] = [
            HeadStat(label: "Link",
                     value: machine.online ? (machine.connected || machine.isLocal ? "Connected" : "Online") : "Offline",
                     color: machine.online ? UdhaTheme.goodInk : UdhaTheme.badInk,
                     note: linkNote,
                     noteHot: machine.link?.online != true && !machine.isLocal),
            HeadStat(label: "Relay RTT", value: machine.latency,
                     series: history.series(id, .rtt)),
            HeadStat(label: "CPU", value: UdhaFormat.percent(stats?.cpuPercent),
                     color: (stats?.cpuPercent ?? 0) >= 90 ? UdhaTheme.warn : UdhaTheme.label,
                     series: history.series(id, .cpu)),
            HeadStat(label: "Memory", value: memoryHeadline(stats),
                     color: (stats?.memoryPercent ?? 0) >= 90 ? UdhaTheme.warn : UdhaTheme.label,
                     series: history.series(id, .memory)),
            HeadStat(label: "Sessions", value: "\(machine.sessions.count)",
                     series: history.series(id, .sessions)),
            HeadStat(label: "Uptime", value: stats.map { UdhaFormat.uptime($0.uptimeSeconds) } ?? "—"),
        ]
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                VStack(alignment: .leading, spacing: 3) {
                    Text(cell.label)
                        .font(UdhaTheme.text(11, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                    Text(cell.value)
                        .font(UdhaTheme.text(18, .semibold))
                        .tracking(-0.2)
                        .monospacedDigit()
                        .foregroundStyle(cell.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Group {
                        if let note = cell.note {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(cell.noteHot ? UdhaTheme.bad : UdhaTheme.good)
                                    .frame(width: 6, height: 6)
                                Text(note)
                                    .font(UdhaTheme.text(11, .regular))
                                    .foregroundStyle(cell.noteHot ? UdhaTheme.badInk : UdhaTheme.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else if let series = cell.series {
                            Sparkline(values: series, color: UdhaTheme.accent, lineWidth: 1.5,
                                      fill: UdhaTheme.accentTint)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(height: 24)
                    .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 14)
                .overlay(alignment: .leading) { if index > 0 { VRule(color: UdhaTheme.hairline) } }
            }
        }
    }

    private struct HeadStat {
        var label: String
        var value: String
        var color: Color = UdhaTheme.label
        var note: String? = nil
        var noteHot: Bool = false
        var series: [Double]? = nil
    }

    /// What the tailnet says about this machine, in one line. This is what the
    /// removed Link table was mostly read for: whether SSH will work at all.
    private var linkNote: String {
        guard let link = machine.link else {
            return core.machines.tailscaleNote ?? "not in the tailnet"
        }
        if !link.online {
            if let expiry = link.keyExpiry, expiry < Date() { return "Tailscale down · key expired" }
            return "Tailscale down · last seen \(UdhaFormat.agoText(link.lastHandshake))"
        }
        let where_ = link.address.isEmpty ? link.route : link.address
        return "Tailscale up · \(where_)"
    }

    private func memoryHeadline(_ stats: MachineStats?) -> String {
        guard let stats, stats.memoryTotal > 0 else { return "—" }
        return "\(UdhaFormat.bytes(stats.memoryUsed)) / \(UdhaFormat.bytes(stats.memoryTotal))"
    }

    private func offlineBanner(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UdhaTheme.badInk)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("No relay connection")
                    .font(UdhaTheme.text(13, .semibold))
                    .foregroundStyle(UdhaTheme.label)
                Text(note)
                    .font(UdhaTheme.text(12, .regular))
                    .foregroundStyle(UdhaTheme.badInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .udhaCard(fill: UdhaTheme.badTint)
    }

    // MARK: - Resources

    /// Four measurements over the time you have been watching, each a card
    /// with a bar for the level now and a line for where it has been.
    private var resourcesSection: some View {
        let stats = machine.stats
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Resources",
                            note: stats?.collector ?? (machine.statsNote ?? "no collector"))

            if let stats {
                HStack(alignment: .top, spacing: UdhaTheme.cardGap) {
                    ForEach(Array(charts(stats).enumerated()), id: \.offset) { _, chart in
                        chartCard(chart)
                    }
                }
                HStack(alignment: .top, spacing: UdhaTheme.cardGap) {
                    ForEach(Array(subStats(stats).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.0)
                                .font(UdhaTheme.text(11, .regular))
                                .foregroundStyle(UdhaTheme.secondary)
                            Mono(item.1, size: 11, color: UdhaTheme.label).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 11)
                        .padding(.bottom, 13)
                        .udhaCard()
                    }
                }
            } else {
                Text(machine.statsNote ?? "No reading.")
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .udhaCard()
            }
        }
    }

    private struct Chart {
        var label: String
        var value: String
        var note: String
        var series: [Double]
        var percent: Double?
        var hot: Bool
        /// How much time the series covers. "—" until there are two samples.
        var span: String
        /// Set when a machine has more than one drive: the card then shows
        /// every drive in place of the root drive's line.
        var drives: [MachineStats.Disk] = []
    }

    private func charts(_ s: MachineStats) -> [Chart] {
        let id = machine.id
        let history = core.machines.history

        let cpuNote: String = {
            var parts: [String] = []
            if !s.load.isEmpty {
                parts.append("load " + s.load.map { String(format: "%.2f", $0) }.joined(separator: " · "))
            }
            if s.cpuThreads > 0 { parts.append("\(s.cpuThreads) threads") }
            if let t = s.temperature(matching: ["tctl", "package", "core"]) { parts.append(UdhaFormat.celsius(t)) }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }()

        let memNote = s.swapTotal > 0
            ? "swap \(UdhaFormat.bytes(s.swapUsed)) / \(UdhaFormat.bytes(s.swapTotal))"
            : "no swap"

        let diskTemp = s.temperature(matching: ["nvme"]).map(UdhaFormat.celsius)
        let drives = s.disks.filter { $0.total > 0 }
        let diskNote: String = {
            if drives.count > 1 {
                let capacity = drives.reduce(UInt64(0)) { $0 + $1.total }
                return (["\(drives.count) drives · \(UdhaFormat.bytes(capacity))"] + [diskTemp].compactMap { $0 })
                    .joined(separator: " · ")
            }
            var parts = [s.diskDevice]
            if s.diskTotal > s.diskUsed {
                parts.append("\(UdhaFormat.bytes(s.diskTotal - s.diskUsed)) free")
            }
            if let diskTemp { parts.append(diskTemp) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }()
        let diskHot = ((s.fullestDisk?.percent ?? s.diskPercent) ?? 0) >= hotAbove
        let diskChart: Chart = {
            guard drives.count > 1 else {
                return Chart(label: "Disk",
                             value: s.diskTotal > 0 ? "\(UdhaFormat.bytes(s.diskUsed)) / \(UdhaFormat.bytes(s.diskTotal))" : "—",
                             note: diskNote, series: history.series(id, .disk), percent: s.diskPercent,
                             hot: diskHot, span: history.span(id, .disk))
            }
            // Several drives: what you can still write is the number that
            // matters, so the headline is free space across all of them.
            // The headline only warns when the machine as a whole is running
            // out; a single full drive is amber in its own row and segment.
            let free = drives.reduce(UInt64(0)) { $0 + $1.free }
            let capacity = drives.reduce(UInt64(0)) { $0 + $1.total }
            let usedPercent = Double(capacity - min(free, capacity)) / Double(capacity) * 100
            return Chart(label: "Storage", value: "\(UdhaFormat.bytes(free)) free", note: diskNote,
                         series: [], percent: nil, hot: usedPercent >= hotAbove, span: "", drives: drives)
        }()

        let gpu = s.gpu
        let gpuNote: String = {
            guard let gpu else { return machine.isLocal ? "no discrete GPU collector on macOS" : "no GPU found" }
            var parts: [String] = [gpu.name]
            if let used = gpu.memUsedMB, let total = gpu.memTotalMB {
                parts.append("\(UdhaFormat.bytes(UInt64(used * 1e6))) / \(UdhaFormat.bytes(UInt64(total * 1e6)))")
            }
            if let t = gpu.celsius { parts.append(UdhaFormat.celsius(t)) }
            if let w = gpu.watts { parts.append(String(format: "%.0f W", w)) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }()

        return [
            Chart(label: "CPU", value: UdhaFormat.percent(s.cpuPercent), note: cpuNote,
                  series: history.series(id, .cpu), percent: s.cpuPercent,
                  hot: (s.cpuPercent ?? 0) >= hotAbove, span: history.span(id, .cpu)),
            Chart(label: "Memory", value: memoryHeadline(s), note: memNote,
                  series: history.series(id, .memory), percent: s.memoryPercent,
                  hot: (s.memoryPercent ?? 0) >= hotAbove, span: history.span(id, .memory)),
            diskChart,
            Chart(label: "GPU", value: UdhaFormat.percent(gpu?.utilPercent), note: gpuNote,
                  series: history.series(id, .gpu), percent: gpu?.utilPercent,
                  hot: (gpu?.utilPercent ?? 0) >= hotAbove, span: history.span(id, .gpu)),
        ]
    }

    private func chartCard(_ chart: Chart) -> some View {
        let stroke = chart.hot ? UdhaTheme.warn : UdhaTheme.accent
        let tint = chart.hot ? UdhaTheme.warnTint : UdhaTheme.accentTint
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(chart.label)
                    .font(UdhaTheme.text(12, .medium))
                    .foregroundStyle(UdhaTheme.secondary)
                Spacer(minLength: 4)
                Text(chart.value)
                    .font(UdhaTheme.text(16, .semibold))
                    .tracking(-0.2)
                    .monospacedDigit()
                    .foregroundStyle(chart.hot ? UdhaTheme.warn : UdhaTheme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if chart.drives.count > 1 {
                DriveSegments(drives: chart.drives, hotAbove: hotAbove)
                    .padding(.top, 10)
                driveRows(chart.drives)
                    .frame(minHeight: 50, alignment: .center)
                    .padding(.top, 12)
            } else {
                UdhaBar(fraction: (chart.percent ?? 0) / 100, color: stroke)
                    .padding(.top, 10)
                Sparkline(values: chart.series, color: stroke, lineWidth: 1.75, fill: tint)
                    .frame(height: 50)
                    .padding(.top, 12)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(chart.series.count > 1 || !chart.drives.isEmpty ? chart.note : "collecting — \(chart.note)")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(chart.span)
                    .font(UdhaTheme.text(11, .regular))
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .udhaCard(hoverLift: true)
    }

    /// One line per drive under the Storage card's bar: where it is
    /// mounted, how full, and what is left on it.
    private func driveRows(_ disks: [MachineStats.Disk]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(disks) { disk in
                let hot = (disk.percent ?? 0) >= hotAbove
                HStack(spacing: 10) {
                    Mono(disk.mount, size: 11.5, color: UdhaTheme.label)
                        .lineLimit(1)
                        .frame(width: 58, alignment: .leading)
                        .help([disk.device, disk.fsType].filter { !$0.isEmpty }.joined(separator: " · "))
                    UdhaBar(fraction: (disk.percent ?? 0) / 100,
                            color: hot ? UdhaTheme.warn : UdhaTheme.accent, height: 4)
                    Text("\(UdhaFormat.bytes(disk.free)) free")
                        .font(UdhaTheme.text(11.5, hot ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(hot ? UdhaTheme.warn : UdhaTheme.secondary)
                        .lineLimit(1)
                        .frame(width: 82, alignment: .trailing)
                }
            }
        }
    }

    private func subStats(_ s: MachineStats) -> [(String, String)] {
        let network: String = {
            guard let net = s.net else { return "—" }
            guard net.rxBytesPerSec != nil || net.txBytesPerSec != nil else { return net.interface }
            return "\(net.interface) · ↓\(UdhaFormat.rate(net.rxBytesPerSec)) ↑\(UdhaFormat.rate(net.txBytesPerSec))"
        }()

        let docker: String = {
            guard let d = s.docker else { return machine.isLocal ? "not collected on macOS" : "not installed" }
            return d.running == 0 ? "none running" : "\(d.running) running · \(d.note)"
        }()

        let top: String = {
            if let first = s.cpuUsers?.first {
                return "\(jobName(first)) · \(Int((first.cpuPercent / Double(max(1, s.cpuThreads))).rounded()))%"
            }
            return s.topProcesses.first.map { "\($0.name) \(Int($0.cpuPercent.rounded()))%" } ?? "—"
        }()

        let agent = "\(s.agentKind) \(s.agentVersion) · rss \(UdhaFormat.bytes(s.agentResidentBytes))"

        return [("Network", network), ("Docker", docker),
                ("Busiest", top), ("Supervisor", agent)]
    }

    // MARK: - CPU by job

    private static let jobColors: [Color] = [.blue, .purple, .orange, .pink, .teal, .green, .indigo, .mint, .brown, .cyan]

    /// What is eating the CPU right now, one row per job — numbers first.
    /// Share is of the whole machine (all cores = 100%).
    @ViewBuilder
    private var cpuJobsSection: some View {
        if let s = machine.stats {
            let cores = Double(max(1, s.cpuThreads))
            let jobs = s.cpuUsers ?? []
            let busy = s.cpuPercent ?? 0
            let listed = jobs.reduce(0) { $0 + $1.cpuPercent } / cores
            VStack(alignment: .leading, spacing: 8) {
                UdhaSectionHead(title: "CPU by job", note: s.cpuUsers == nil ? "agent update needed" : "live")
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 28) {
                        bigNumber("\(Int(busy.rounded()))%", "CPU", tint: busy >= 85 ? UdhaTheme.bad : (busy >= 60 ? UdhaTheme.warn : UdhaTheme.label))
                        bigNumber(String(format: "%.1f", busy / 100 * cores), "of \(Int(cores)) cores")
                        bigNumber(s.load.first.map { String(format: "%.1f", $0) } ?? "—", "load")
                        if let gpu = s.gpu {
                            let util = gpu.utilPercent ?? 0
                            bigNumber("\(Int(util.rounded()))%", "GPU",
                                      tint: util >= 85 ? UdhaTheme.bad : (util >= 60 ? UdhaTheme.warn : UdhaTheme.label))
                            if let used = gpu.memUsedMB, let total = gpu.memTotalMB {
                                bigNumber(String(format: "%.1f", used / 1024), "of \(Int((total / 1024).rounded())) GB VRAM")
                            }
                        }
                        bigNumber("\(jobs.count)", "busy jobs")
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    // Whole machine as one bar: each job its colour, the rest grey.
                    GeometryReader { geo in
                        HStack(spacing: 1.5) {
                            ForEach(Array(jobs.enumerated()), id: \.offset) { index, job in
                                Rectangle().fill(Self.jobColors[index % Self.jobColors.count])
                                    .frame(width: max(2, geo.size.width * min(1, job.cpuPercent / cores / 100)))
                                    .help("\(jobName(job)) · \(Int((job.cpuPercent / cores).rounded()))%")
                            }
                            Rectangle().fill(UdhaTheme.tertiary.opacity(0.35))
                                .frame(width: max(0, geo.size.width * max(0, busy - listed) / 100))
                            Spacer(minLength: 0)
                        }
                        .background(UdhaTheme.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .animation(.easeInOut(duration: 0.5), value: jobs.map(\.cpuPercent))
                    }
                    .frame(height: 10)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    if !jobs.isEmpty {
                        HStack(spacing: 14) {
                            columnLabel("Job", width: nil)
                            columnLabel("Share", width: 170)
                            columnLabel("Cores", width: 52, trailing: true)
                            columnLabel("Mem", width: 64, trailing: true)
                            if s.gpu != nil {
                                columnLabel("GPU", width: 48, trailing: true)
                                columnLabel("VRAM", width: 64, trailing: true)
                            }
                            columnLabel("Procs", width: 44, trailing: true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(UdhaTheme.fill)
                        .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }

                        ForEach(Array(jobs.enumerated()), id: \.offset) { index, job in
                            cpuJobRow(job, color: Self.jobColors[index % Self.jobColors.count], cores: cores, hasGPU: s.gpu != nil)
                                .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                        }
                    }
                }
                .udhaCard()
                .udhaRounded(UdhaTheme.cardRadius)
            }
        }
    }

    private func bigNumber(_ value: String, _ label: String, tint: Color = UdhaTheme.label) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(UdhaTheme.text(24, .bold))
                .tracking(-0.4)
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
        }
    }

    /// The Udha session a tmux name belongs to on this machine, if any.
    private func session(for job: MachineStats.CPUUser) -> SessionSnapshot? {
        guard job.kind == "session" else { return nil }
        return machine.sessions.first { snap in
            snap.tmuxName == job.name || job.name.hasSuffix("-" + TmuxSession.shortID(for: snap.id))
        }
    }

    private func jobName(_ job: MachineStats.CPUUser) -> String {
        session(for: job)?.label ?? job.name
    }

    private func jobIcon(_ kind: String) -> String {
        switch kind {
        case "session": "terminal"
        case "container": "shippingbox"
        case "service": "gearshape"
        case "app": "app"
        case "system": "cpu"
        default: "circle.dashed"
        }
    }

    private func cpuJobRow(_ job: MachineStats.CPUUser, color: Color, cores: Double, hasGPU: Bool) -> some View {
        let share = job.cpuPercent / cores
        let linked = session(for: job)
        let commands = job.commands.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }.joined(separator: "  ")
        return HStack(spacing: 14) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 26)
                Image(systemName: jobIcon(job.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(UdhaTheme.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(jobName(job))
                        .font(UdhaTheme.text(12.5, .semibold))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    Mono(commands, size: 10.5, color: UdhaTheme.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(job.kind) · \(job.name)")

            HStack(spacing: 8) {
                UdhaBar(fraction: share / 100, color: color, height: 6)
                Text("\(Int(share.rounded()))%")
                    .font(UdhaTheme.text(14, .bold))
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.label)
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 170)

            Text(String(format: "%.1f", job.cpuPercent / 100))
                .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
                .frame(width: 52, alignment: .trailing)
            Text(UdhaFormat.bytes(job.residentBytes))
                .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
                .frame(width: 64, alignment: .trailing)
            if hasGPU {
                let active = job.gpuPercent > 0
                Text(active ? "\(Int(job.gpuPercent.rounded()))%" : "—")
                    .font(UdhaTheme.text(13, active ? .bold : .medium)).monospacedDigit()
                    .foregroundStyle(active ? UdhaTheme.label : UdhaTheme.tertiary)
                    .frame(width: 48, alignment: .trailing)
                Text(job.vramBytes > 0 ? UdhaFormat.bytes(job.vramBytes) : "—")
                    .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                    .foregroundStyle(job.vramBytes > 0 ? UdhaTheme.secondary : UdhaTheme.tertiary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text("\(job.processes)")
                .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if let linked { shell.select(session: linked.id) } }
        .hoverBackground()
    }

    // MARK: - Temperatures

    /// One row per component (CPU, GPU, SSD, RAM, …), led by its hottest
    /// sensor; click to see every sensor under it. All rows share one 20–100 °C
    /// scale, so rows compare at a glance, and each line has a 10 °C minimum
    /// height, so a degree of jitter draws as the flat line it is instead of
    /// filling the row. A box with no hwmon says so instead of drawing rows at
    /// 0 °C — "cold" and "no sensor" must never render alike.
    private var temperaturesSection: some View {
        let readings = machine.stats?.temperatures ?? []
        let id = machine.id
        let history = core.machines.history
        let span = history.span(id, .cpu)
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Temperatures", note: temperatureSource)

            if readings.isEmpty {
                Text(machine.stats == nil
                     ? (machine.statsNote ?? "No reading.")
                     : (machine.isLocal
                        ? "macOS has no public sensor API, so the Mac reports no temperatures."
                        : "This machine has not reported any temperature sensors."))
                    .font(UdhaTheme.text(12.5, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .udhaCard()
            } else {
                VStack(spacing: 0) {
                    temperatureScaleHeader
                    ForEach(temperatureGroups(readings), id: \.name) { group in
                        let open = openTemperatureGroups.contains(group.name)
                        let hottest = group.sensors[0]
                        temperatureRow(name: group.name,
                                       detail: group.sensors.count > 1
                                           ? "\(group.sensors.count) sensors · hottest shown"
                                           : temperatureDescription(hottest.reading.label).detail,
                                       celsius: hottest.reading.celsius,
                                       others: group.sensors.dropFirst().map(\.reading.celsius),
                                       series: history.temperature(id, label: hottest.reading.label),
                                       span: span,
                                       disclosure: group.sensors.count > 1 ? open : nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard group.sensors.count > 1 else { return }
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if open { openTemperatureGroups.remove(group.name) }
                                    else { openTemperatureGroups.insert(group.name) }
                                }
                            }
                            .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
                        if open {
                            ForEach(group.sensors, id: \.reading.label) { sensor in
                                temperatureRow(name: sensor.name,
                                               detail: "\(temperatureDescription(sensor.reading.label).detail)\nSensor: \(sensor.reading.label)",
                                               celsius: sensor.reading.celsius,
                                               others: [],
                                               series: history.temperature(id, label: sensor.reading.label),
                                               span: span,
                                               disclosure: nil,
                                               indent: 22)
                                    .background(UdhaTheme.fill.opacity(0.5))
                            }
                        }
                    }
                }
                .udhaCard()
                .udhaRounded(UdhaTheme.cardRadius)
            }
        }
    }

    private struct TemperatureSensor {
        var name: String
        var reading: MachineStats.Reading
    }

    /// Sensors gathered under the component they measure ("SSD · overall" and
    /// "SSD · sensor 1" are both SSD), hottest first inside each group. Groups
    /// keep the order the machine reported them in, so rows don't swap places
    /// as temperatures move.
    private func temperatureGroups(_ readings: [MachineStats.Reading]) -> [(name: String, sensors: [TemperatureSensor])] {
        var order: [String] = []
        var groups: [String: [TemperatureSensor]] = [:]
        for index in readings.indices {
            let name = temperatureName(at: index, in: readings)
            let component = temperatureDescription(readings[index].label).name
                .components(separatedBy: " · ").first ?? name
            if groups[component] == nil { order.append(component) }
            groups[component, default: []].append(TemperatureSensor(name: name, reading: readings[index]))
        }
        return order.map { key in
            (key, groups[key]!.sorted { $0.reading.celsius > $1.reading.celsius })
        }
    }

    private static let temperatureScale: ClosedRange<Double> = 20...100
    private static let tempNameWidth: CGFloat = 190
    private static let tempValueWidth: CGFloat = 62
    private static let tempScaleWidth: CGFloat = 240

    /// The shared scale's ticks over the column they label.
    private var temperatureScaleHeader: some View {
        HStack(spacing: 16) {
            Spacer().frame(width: Self.tempNameWidth + Self.tempValueWidth + 16)
            GeometryReader { geo in
                ForEach([20.0, 40, 60, 80, 100], id: \.self) { mark in
                    Text("\(Int(mark))°")
                        .font(UdhaTheme.text(10, .regular))
                        .monospacedDigit()
                        .foregroundStyle(UdhaTheme.tertiary)
                        .fixedSize()
                        .position(x: Self.scaleX(mark, width: geo.size.width), y: geo.size.height / 2)
                }
            }
            .frame(width: Self.tempScaleWidth, height: 14)
            Text("Trend")
                .font(UdhaTheme.text(10, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private static func scaleX(_ celsius: Double, width: CGFloat) -> CGFloat {
        let r = temperatureScale
        let unit = (min(max(celsius, r.lowerBound), r.upperBound) - r.lowerBound) / (r.upperBound - r.lowerBound)
        return CGFloat(unit) * width
    }

    private var temperatureSource: String {
        guard machine.stats != nil else { return machine.statsNote ?? "no collector" }
        if machine.isLocal { return "no public sensor API on macOS" }
        return (machine.stats?.temperatures.isEmpty ?? true)
            ? "no sensors reported"
            : "Live hardware sensors · click a component for every sensor"
    }

    /// Translate known drivers without guessing what an unlabelled motherboard
    /// probe measures. Display names never replace the raw history/wire labels.
    private func temperatureDescription(_ label: String) -> (name: String, detail: String) {
        let raw = label.lowercased()
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        let sensor = parts.count > 1 ? parts[1] : ""
        if raw.hasPrefix("nvme") {
            return sensor.lowercased() == "composite"
                ? ("SSD · overall", "Overall NVMe drive temperature")
                : ("SSD · \(sensor.isEmpty ? "sensor" : sensor.lowercased())", "Additional temperature sensor inside an NVMe drive")
        }
        if raw.hasPrefix("k10temp") || raw.hasPrefix("zenpower") {
            if sensor.lowercased() == "tctl" {
                return ("CPU · cooling control", "AMD CPU reading used for cooling control; may include a temperature offset")
            }
            if sensor.lowercased().hasPrefix("tccd") {
                return ("CPU · chiplet \(sensor.dropFirst(4))", "Temperature of a group of CPU cores, not an individual core")
            }
            return ("CPU · \(sensor.lowercased() == "tdie" ? "die" : "sensor")", "Temperature measured inside the AMD CPU")
        }
        if raw.hasPrefix("coretemp") {
            return ("CPU · \(sensor.isEmpty ? "sensor" : sensor)", "Intel CPU package or individual core temperature")
        }
        if raw.hasPrefix("spd5118") || raw.hasPrefix("jc42") {
            return ("RAM", "Temperature sensor on a memory module; numbering identifies readings, not motherboard slots")
        }
        if raw.hasPrefix("r8169") {
            return ("Ethernet adapter", "Temperature of the wired network controller")
        }
        if raw.hasPrefix("amdgpu") {
            let kind = sensor.lowercased()
            let suffix = kind == "edge" ? "edge" : kind == "junction" ? "hotspot" : kind == "mem" ? "memory" : "sensor"
            return ("AMD GPU · \(suffix)", "AMD graphics temperature; separate from any NVIDIA graphics card")
        }
        if raw.hasPrefix("nvidia") || raw.hasPrefix("gpu") {
            return ("GPU", "Graphics processor temperature")
        }
        return (label, "Hardware temperature sensor; its component has not been identified")
    }

    private func temperatureName(at index: Int, in readings: [MachineStats.Reading]) -> String {
        let name = temperatureDescription(readings[index].label).name
        let matches = readings.indices.filter { temperatureDescription(readings[$0].label).name == name }
        guard matches.count > 1, let ordinal = matches.firstIndex(of: index) else { return name }
        return "\(name) \(ordinal + 1)"
    }

    /// One line of the table: name, the reading, where it sits on the shared
    /// scale (the range it has covered as a soft band, the reading as a dot,
    /// the group's other sensors as ticks), its trend, and its peak.
    private func temperatureRow(name: String,
                                detail: String,
                                celsius: Double,
                                others: [Double],
                                series: [Double],
                                span: String,
                                disclosure: Bool?,
                                indent: CGFloat = 0) -> some View {
        let hot = celsius >= 80
        let warm = celsius >= 55
        let tint = hot ? UdhaTheme.bad : (warm ? UdhaTheme.warn : UdhaTheme.accent)
        let low = series.min() ?? celsius
        let high = series.max() ?? celsius
        let peak: String = series.count > 1 ? "peak \(Int(high.rounded()))° · \(span)" : "collecting"
        return HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 6) {
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UdhaTheme.tertiary)
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Text(name)
                    .font(UdhaTheme.text(12.5, indent > 0 ? .regular : .medium))
                    .foregroundStyle(indent > 0 ? UdhaTheme.secondary : UdhaTheme.label)
                    .lineLimit(1)
            }
            .padding(.leading, indent)
            .frame(width: Self.tempNameWidth, alignment: .leading)
            .help(detail)

            Text(UdhaFormat.celsius(celsius))
                .font(UdhaTheme.text(indent > 0 ? 13 : 15, .semibold))
                .monospacedDigit()
                .foregroundStyle(hot ? UdhaTheme.bad : (warm ? UdhaTheme.warnInk : UdhaTheme.label))
                .frame(width: Self.tempValueWidth, alignment: .leading)

            GeometryReader { geo in
                let w = geo.size.width
                let mid = geo.size.height / 2
                ZStack(alignment: .topLeading) {
                    Capsule().fill(UdhaTheme.fill)
                        .frame(width: w, height: 4)
                        .position(x: w / 2, y: mid)
                    // Warm and hot zones, faint, so the dot reads against them.
                    Rectangle().fill(UdhaTheme.warn.opacity(0.18))
                        .frame(width: Self.scaleX(80, width: w) - Self.scaleX(55, width: w), height: 4)
                        .position(x: (Self.scaleX(55, width: w) + Self.scaleX(80, width: w)) / 2, y: mid)
                    Rectangle().fill(UdhaTheme.bad.opacity(0.18))
                        .frame(width: w - Self.scaleX(80, width: w), height: 4)
                        .position(x: (Self.scaleX(80, width: w) + w) / 2, y: mid)
                    Capsule().fill(tint.opacity(0.35))
                        .frame(width: max(4, Self.scaleX(high, width: w) - Self.scaleX(low, width: w)), height: 8)
                        .position(x: (Self.scaleX(low, width: w) + Self.scaleX(high, width: w)) / 2, y: mid)
                    ForEach(Array(others.enumerated()), id: \.offset) { _, value in
                        Rectangle().fill(UdhaTheme.tertiary)
                            .frame(width: 1.5, height: 10)
                            .position(x: Self.scaleX(value, width: w), y: mid)
                    }
                    Circle().fill(tint)
                        .overlay(Circle().stroke(UdhaTheme.card, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .position(x: Self.scaleX(celsius, width: w), y: mid)
                        .animation(.easeInOut(duration: 0.6), value: celsius)
                }
            }
            .frame(width: Self.tempScaleWidth, height: 14)

            Sparkline(values: series, color: tint, lineWidth: 1.25, fill: tint.opacity(0.10), minSpan: 10)
                .frame(height: 20)
                .frame(maxWidth: .infinity)

            Text(peak)
                .font(UdhaTheme.text(11, .regular))
                .monospacedDigit()
                .foregroundStyle(UdhaTheme.tertiary)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, indent > 0 ? 6 : 10)
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        let stale = core.config.config.staleAfterSeconds
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Sessions on this machine", note: machine.stats?.tmuxNote ?? "")

            VStack(spacing: 0) {
                sessionCountRow

                if machine.sessions.isEmpty {
                    Text(sessionsEmptyNote)
                        .font(UdhaTheme.text(12.5, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
                } else {
                    HStack(spacing: 12) {
                        columnLabel("Session", width: nil)
                        columnLabel("State", width: 110)
                        columnLabel("tmux session", width: 240)
                        columnLabel("Context", width: 130)
                        columnLabel("Cost", width: 80, trailing: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(UdhaTheme.fill)
                    .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
                    .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }

                    ForEach(machine.sessions) { snap in
                        let style = UdhaSessionStyle(snapshot: snap, staleAfter: stale)
                        SessionTableRow(snap: snap, style: style) {
                            shell.select(session: snap.id)
                        }
                        .contextMenu {
                            Button("Open in Terminal") { core.sessionManager.showSession(id: snap.id) }
                            if let host = machine.host {
                                Button("Copy attach command") {
                                    MachineActions.copy(SessionManager.remoteAttachCommand(host: host, tmuxName: snap.tmuxTarget))
                                }
                            }
                        }
                    }

                    Text(MachineDirectory.sessionSummary(machine.sessions).prefix(1).uppercased()
                         + MachineDirectory.sessionSummary(machine.sessions).dropFirst()
                         + (machine.isLocal ? "." : " · reattached by the agent before the relay came up."))
                        .font(UdhaTheme.text(11.5, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .udhaCard()
            .udhaRounded(UdhaTheme.cardRadius)
        }
    }

    /// The headline count with its own line beside it — how many sessions this
    /// machine has been holding while you watched, which is what tells you a
    /// hand-off actually landed.
    private var sessionCountRow: some View {
        let series = core.machines.history.series(machine.id, .sessions)
        return HStack(alignment: .center, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(machine.sessions.count)")
                    .font(UdhaTheme.text(26, .bold))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.label)
                Text(machine.sessions.isEmpty
                     ? "tmux sessions — nothing to reattach"
                     : "tmux sessions · \(machine.sessions.filter { $0.state == .working }.count) working")
                    .font(UdhaTheme.text(12, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
            }
            Sparkline(values: series, color: UdhaTheme.accent, lineWidth: 1.75, fill: UdhaTheme.accentTint)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
            Text(core.machines.history.span(machine.id, .sessions))
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var sessionsEmptyNote: String {
        if !machine.online { return "Nothing to list — the machine is not reachable." }
        if !machine.isLocal && !machine.connected {
            return "Connect to this machine to see the sessions it is supervising."
        }
        return "No sessions here. `tmux ls` is empty, so there was nothing for the supervisor to reattach."
    }

    private func columnLabel(_ title: String, width: CGFloat?, trailing: Bool = false) -> some View {
        Group {
            if let width {
                Text(title).frame(width: width, alignment: trailing ? .trailing : .leading)
            } else {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(UdhaTheme.text(11, .medium))
        .foregroundStyle(UdhaTheme.secondary)
    }

    // MARK: - Toolchain + errors

    private var toolchainSection: some View {
        let mine = machine.stats?.tools ?? []
        let theirs = counterpart?.stats?.tools ?? []
        let drifted = mine.filter { tool in
            guard let other = theirs.first(where: { $0.name == tool.name }) else { return false }
            return other.version != tool.version
        }.count

        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Toolchain",
                            note: mine.isEmpty ? nil : (drifted == 0 ? "in step" : "\(drifted) version\(drifted == 1 ? "" : "s") drifted"),
                            noteColor: drifted == 0 ? UdhaTheme.secondary : UdhaTheme.warnInk,
                            noteIsMono: false)

            VStack(spacing: 0) {
                if mine.isEmpty {
                    Text(machine.statsNote ?? "No versions reported.")
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    HStack(spacing: 0) {
                        columnLabel("Tool", width: nil)
                        columnLabel(machine.name, width: nil)
                        columnLabel(counterpart?.name ?? "—", width: nil)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(UdhaTheme.fill)
                    .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }

                    ForEach(Array(mine.enumerated()), id: \.offset) { index, tool in
                        let other = theirs.first { $0.name == tool.name }
                        let drift = other != nil && other!.version != tool.version
                        HStack(spacing: 0) {
                            Text(tool.name)
                                .font(UdhaTheme.text(12.5, .medium))
                                .foregroundStyle(UdhaTheme.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Mono(tool.version, size: 11, color: UdhaTheme.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Mono(other?.version ?? "—", size: 11,
                                 color: drift ? UdhaTheme.warnInk : UdhaTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                    }
                }
            }
            .udhaCard()
            .udhaRounded(UdhaTheme.cardRadius)
        }
    }

    private var errorsSection: some View {
        let errors = machine.isLocal ? core.mobileBridgeRelay.recentErrors
                                     : (machine.stats?.errors ?? core.remoteHosts.client(for: machine.host)?.recentErrors ?? [])
        let drops = MachineHistory.dropsPerHour(errors)
        let total = Int(drops.reduce(0, +))
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Connection drop-outs",
                            note: total == 0 ? "none in 24 h" : "\(total) drop-out\(total == 1 ? "" : "s") · 24 h")

            VStack(alignment: .leading, spacing: 0) {
                // The errors carry their own timestamps, so unlike the resource
                // charts this one is real history from the first sample: an hour
                // per point, a day across.
                Sparkline(values: drops, color: total == 0 ? UdhaTheme.accent : UdhaTheme.bad,
                          lineWidth: 1.5, fill: total == 0 ? UdhaTheme.accentTint : UdhaTheme.badTint)
                    .frame(height: 36)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                HStack {
                    Text("24 h ago")
                    Spacer(minLength: 8)
                    Text("now")
                }
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)

                if errors.isEmpty {
                    Text("None recorded since launch.")
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
                } else {
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        HStack(alignment: .top, spacing: 12) {
                            Mono(UdhaFormat.timeOfDay(error.at), size: 11)
                                .frame(width: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(error.code)
                                    .font(UdhaTheme.text(12, .semibold))
                                    .foregroundStyle(UdhaTheme.badInk)
                                Text(error.text)
                                    .font(UdhaTheme.text(12, .regular))
                                    .foregroundStyle(UdhaTheme.label)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
                    }
                }

                Text("Reconnects back off 1s → 30s. Close 4002 means the relay gave this instance id to another connection, and retrying stops rather than starting a takeover war.")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) { HRule(color: UdhaTheme.hairline) }
            }
            .udhaCard()
            .udhaRounded(UdhaTheme.cardRadius)
        }
    }

    // MARK: - Log

    private var logSection: some View {
        let lines = machine.isLocal ? (core.machines.local?.logTail ?? []) : (machine.stats?.logTail ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Supervisor log", note: machine.isLocal
                            ? "~/Library/Logs/Udha.AI/udha.log"
                            : "~/.local/state/udha/udha.log")

            Group {
                if lines.isEmpty {
                    Text(machine.statsNote ?? "Nothing logged yet.")
                        .font(UdhaTheme.text(12, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .padding(16)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(UdhaTheme.mono(11))
                                .foregroundStyle(UdhaTheme.inkCode)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                    .background(UdhaTheme.fill)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .udhaCard()
            .udhaRounded(UdhaTheme.cardRadius)
        }
    }
}

/// One row of the sessions table: name · state chip · tmux · context bar · cost.
private struct SessionTableRow: View {
    let snap: SessionSnapshot
    let style: UdhaSessionStyle
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(snap.label)
                    .font(UdhaTheme.text(12.5, .medium))
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                style.chip
                    .frame(width: 110, alignment: .leading)
                Mono(snap.tmuxTarget, size: 11)
                    .lineLimit(1)
                    .frame(width: 240, alignment: .leading)
                HStack(spacing: 8) {
                    UdhaBar(fraction: Double(snap.contextPercent ?? 0) / 100, color: style.mark,
                            height: 5, track: UdhaTheme.fillStrong)
                    Text(snap.contextPercent.map { "\($0)%" } ?? "—")
                        .font(UdhaTheme.text(11, .regular))
                        .monospacedDigit()
                        .foregroundStyle(UdhaTheme.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .frame(width: 130)
                Text(UdhaFormat.cents(snap.costCents))
                    .font(UdhaTheme.text(12, .regular))
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.label)
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.leading, hovering ? 22 : 16)
            .padding(.trailing, 16)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity)
            .background(hovering ? UdhaTheme.fill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
        .onHover { hovering = $0 }
        .animation(UdhaTheme.quick, value: hovering)
    }
}

/// The Storage card's bar: one segment per drive, each as wide as its share
/// of the machine's total capacity and filled as far as it is used, so a
/// small full drive next to a big empty one reads as exactly that.
private struct DriveSegments: View {
    var drives: [MachineStats.Disk]
    var hotAbove: Double
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let capacity = drives.reduce(0.0) { $0 + Double($1.total) }
            let usable = max(0, geo.size.width - gap * CGFloat(drives.count - 1))
            HStack(spacing: gap) {
                ForEach(drives) { disk in
                    let hot = (disk.percent ?? 0) >= hotAbove
                    let width = capacity > 0 ? usable * CGFloat(Double(disk.total) / capacity) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(UdhaTheme.fill)
                        Capsule().fill(hot ? UdhaTheme.warn : UdhaTheme.accent)
                            .frame(width: max(0, min(1, (disk.percent ?? 0) / 100)) * width)
                            .animation(.easeInOut(duration: 0.6), value: disk.percent)
                    }
                    .frame(width: width)
                    .help("\(disk.mount) · \(UdhaFormat.bytes(disk.used)) / \(UdhaFormat.bytes(disk.total))")
                }
            }
        }
        .frame(height: 6)
    }
}
