import SwiftUI

/// Who uses Udha through the relay, and how much: the big numbers, active
/// people per day, then one row per person. Metadata only — the relay counts
/// connection time, machines and the *kind* of each action, never content.
///
/// Only the relay's admin login gets a report; any other login's request is
/// met with silence, which this pane shows as "not available for this login".
struct UsagePane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    private var client: RemoteHostClient { core.remoteHosts.discovery }
    private var report: RelayUsageReport? { client.usageReport }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                if let report {
                    totals(report)
                    if let id = shell.selectedUsageUser, let person = report.people.first(where: { $0.userId == id }) {
                        detail(person)
                    }
                    days(report)
                    people(report)
                } else {
                    waiting
                }
            }
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .udhaScroll()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Re-asked every 30 s while the section is open, and at once when the
        // range changes. Nothing runs while it is closed.
        .task(id: shell.usageDays) {
            while !Task.isCancelled {
                client.fetchUsage(days: shell.usageDays)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Waiting

    @ViewBuilder
    private var waiting: some View {
        // The relay answers the admin within a moment; silence after that
        // means this login is not the admin (or the relay is unreachable).
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let asked = client.usageRequestedAt
            let silent = asked.map { context.date.timeIntervalSince($0) > 6 } ?? false
            HStack(spacing: 8) {
                if silent {
                    Image(systemName: "lock").foregroundStyle(UdhaTheme.tertiary)
                    Text(asked == nil
                         ? "Not connected to the relay"
                         : "Usage is only available to the relay's owner login")
                        .foregroundStyle(UdhaTheme.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Asking the relay…").foregroundStyle(UdhaTheme.secondary)
                }
            }
            .font(UdhaTheme.text(12.5, .regular))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .udhaCard()
        }
    }

    // MARK: - Totals

    private func totals(_ r: RelayUsageReport) -> some View {
        let active = r.people.filter { $0.activeDays > 0 }
        let today = r.series.last?.activeUsers ?? 0
        let online = r.people.filter(\.onlineNow).count
        let minutes = r.people.reduce(0) { $0 + $1.appMinutes }
        let machines = r.people.reduce(0) { $0 + $1.machinesOnline }
        let actions = r.people.reduce(0) { $0 + $1.totalActions }
        return HStack(alignment: .top, spacing: 30) {
            big("\(active.count)", "active people", size: 34)
            big("\(today)", "active today")
            big("\(online)", "online now", tint: online > 0 ? UdhaTheme.good : UdhaTheme.label)
            big(UdhaFormat.hours(minutes), "in the app")
            big("\(actions)", "actions")
            big("\(machines)", "machines online")
            Spacer(minLength: 0)
            UdhaSegmented(options: [(7, "7 days"), (30, "30 days"), (90, "90 days")], selection: $shell.usageDays)
        }
        .padding(18)
        .udhaCard()
    }

    private func big(_ value: String, _ label: String, size: CGFloat = 24, tint: Color = UdhaTheme.label) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(UdhaTheme.text(size, .bold))
                .tracking(-0.5)
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.tertiary)
        }
    }

    // MARK: - Days

    private func days(_ r: RelayUsageReport) -> some View {
        let peak = max(1, r.series.map(\.activeUsers).max() ?? 1)
        let label = DateFormatter(); label.dateFormat = r.days > 14 ? "d" : "EEE d"
        label.timeZone = TimeZone(identifier: "UTC")
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "Active people per day")
            HStack(alignment: .bottom, spacing: r.days > 30 ? 2 : 6) {
                ForEach(r.series) { d in
                    VStack(spacing: 5) {
                        if r.days <= 30 {
                            Text(d.activeUsers > 0 ? "\(d.activeUsers)" : "")
                                .font(UdhaTheme.text(10.5, .bold)).monospacedDigit()
                                .foregroundStyle(UdhaTheme.label)
                        }
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle().fill(UdhaTheme.accent)
                                .frame(height: d.activeUsers > 0 ? max(3, 110 * CGFloat(d.activeUsers) / CGFloat(peak)) : 0)
                        }
                        .frame(height: 110)
                        .frame(maxWidth: .infinity)
                        .background(UdhaTheme.fill.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("\(d.day) · \(d.activeUsers) active · \(UdhaFormat.hours(d.clientSeconds / 60)) in the app")
                        if r.days <= 30 {
                            Text(d.date.map { label.string(from: $0) } ?? "")
                                .font(UdhaTheme.text(9.5, .medium))
                                .foregroundStyle(UdhaTheme.tertiary)
                        }
                    }
                }
            }
            .padding(16)
            .udhaCard()
        }
    }

    // MARK: - People

    private func people(_ r: RelayUsageReport) -> some View {
        let top = max(1, r.people.map(\.appMinutes).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "By person")
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    header("Person", nil)
                    header("In the app", 200)
                    header("Days", 44, trailing: true)
                    header("Actions", 60, trailing: true)
                    header("Machines", 150)
                    header("Last seen", 80, trailing: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(UdhaTheme.fill)
                ForEach(Array(r.people.enumerated()), id: \.element.id) { index, p in
                    Button {
                        shell.selectedUsageUser = shell.selectedUsageUser == p.userId ? nil : p.userId
                    } label: {
                        row(p, top: top)
                    }
                    .buttonStyle(.plain)
                    .background(shell.selectedUsageUser == p.userId ? UdhaTheme.accentTint : Color.clear)
                    .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                }
            }
            .udhaCard()
            .udhaRounded(UdhaTheme.cardRadius)
        }
    }

    private func row(_ p: RelayUsageReport.Person, top: Int) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(p.onlineNow ? UdhaTheme.good : UdhaTheme.fillStrong).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.label).font(UdhaTheme.text(13, .semibold)).foregroundStyle(UdhaTheme.label).lineLimit(1)
                    if let email = p.email, email != p.label {
                        Mono(email, size: 10, color: UdhaTheme.tertiary).lineLimit(1)
                    }
                }
                if !p.sharedWith.isEmpty { UdhaPill("shared", size: 10, height: 17) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                UdhaBar(fraction: Double(p.appMinutes) / Double(top), color: UdhaTheme.accent, height: 6)
                Text(UdhaFormat.hours(p.appMinutes))
                    .font(UdhaTheme.text(13.5, .bold)).monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(width: 200)
            Text("\(p.activeDays)")
                .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(p.totalActions > 0 ? "\(p.totalActions)" : "—")
                .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(p.machineNames.isEmpty ? "—" : p.machineNames.joined(separator: ", "))
                .font(UdhaTheme.text(11.5, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(p.onlineNow ? "now" : UdhaFormat.agoText(p.lastSeenDate))
                .font(UdhaTheme.text(11.5, .regular)).monospacedDigit()
                .foregroundStyle(p.onlineNow ? UdhaTheme.good : UdhaTheme.tertiary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: - One person

    private func detail(_ p: RelayUsageReport.Person) -> some View {
        let actions = p.actions.sorted { $0.value > $1.value }
        let topAction = max(1, actions.first?.value ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.label).font(UdhaTheme.text(17, .bold)).foregroundStyle(UdhaTheme.label)
                if let email = p.email { Mono(email, size: 11, color: UdhaTheme.tertiary) }
                Spacer()
                Button { shell.selectedUsageUser = nil } label: { Image(systemName: "xmark") }
                    .udhaButton(.ghost, height: 24, hPadding: 7)
            }
            HStack(alignment: .top, spacing: 30) {
                big(UdhaFormat.hours(p.appMinutes), "in the app")
                big(UdhaFormat.hours(p.hostSeconds / 60), "machines online")
                big("\(p.activeDays)", "active days")
                big("\(p.connects)", "connections")
                big("\(p.totalActions)", "actions")
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    UdhaSectionHead(title: "Actions by kind")
                    if actions.isEmpty {
                        Text("None").foregroundStyle(UdhaTheme.tertiary).font(UdhaTheme.text(12, .regular))
                    }
                    ForEach(actions.prefix(12), id: \.key) { kind, count in
                        HStack(spacing: 8) {
                            Mono(kind, size: 11, color: UdhaTheme.secondary).frame(width: 170, alignment: .leading)
                            UdhaBar(fraction: Double(count) / Double(topAction), color: UdhaTheme.accent, height: 5)
                            Text("\(count)").font(UdhaTheme.text(12, .bold)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    UdhaSectionHead(title: "Machines")
                    Text(p.machineNames.isEmpty ? "None" : p.machineNames.joined(separator: "\n"))
                        .font(UdhaTheme.text(12, .regular)).foregroundStyle(UdhaTheme.secondary)
                    if !p.sharedWith.isEmpty {
                        UdhaSectionHead(title: "Shared with them")
                        Text(p.sharedWith.joined(separator: "\n"))
                            .font(UdhaTheme.text(12, .regular)).foregroundStyle(UdhaTheme.secondary)
                    }
                    UdhaSectionHead(title: "Apps")
                    Text(p.apps.isEmpty ? "None" : p.apps.sorted { $0.value > $1.value }.map { "\($0.key) · \($0.value)" }.joined(separator: "\n"))
                        .font(UdhaTheme.text(12, .regular)).foregroundStyle(UdhaTheme.secondary)
                }
                .frame(width: 240, alignment: .leading)
            }
        }
        .padding(18)
        .udhaCard()
    }

    private func header(_ title: String, _ width: CGFloat?, trailing: Bool = false) -> some View {
        Text(title.uppercased())
            .font(UdhaTheme.text(10, .semibold))
            .tracking(0.4)
            .foregroundStyle(UdhaTheme.tertiary)
            .frame(width: width, alignment: trailing ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
