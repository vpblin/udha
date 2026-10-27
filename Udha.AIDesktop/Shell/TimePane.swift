import SwiftUI

/// Hours worked in one week, by org, day and client. Numbers first: the big
/// figures across the top, a stacked bar per day, then one row per client.
struct TimePane: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    private static let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .green, .indigo, .mint, .brown, .cyan, .yellow]

    private var week: TimeWeek? {
        core.time.week(starting: shell.selectedWeek)
    }

    /// One colour per client, in the order the rules list them, so a client
    /// keeps its colour from week to week.
    private func color(_ name: String) -> Color {
        if name == TimeWeek.unassigned { return UdhaTheme.tertiary.opacity(0.6) }
        let index = core.config.config.timeTracking.clients.firstIndex { $0.name == name } ?? 0
        return Self.palette[index % Self.palette.count]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UdhaTheme.cardGap) {
                if let week {
                    totals(week)
                    days(week)
                    clients(week)
                    if !core.time.hostsWithoutActivity.isEmpty {
                        Text("Not counted: \(core.time.hostsWithoutActivity.joined(separator: ", ")) — agent update needed")
                            .font(UdhaTheme.text(11.5, .regular))
                            .foregroundStyle(UdhaTheme.warn)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Counting…").foregroundStyle(UdhaTheme.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .udhaCard()
                }
            }
            .padding(.horizontal, UdhaTheme.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .udhaScroll()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { core.time.refresh(weekStarting: shell.selectedWeek) }
        .onChange(of: shell.selectedWeek) { _, start in core.time.refresh(weekStarting: start) }
    }

    // MARK: - Totals

    private func totals(_ w: TimeWeek) -> some View {
        let orgs = w.byOrg.filter { $0.key != "—" }.sorted { $0.value > $1.value }
        let unassigned = w.clients.first { $0.name == TimeWeek.unassigned }?.minutes ?? 0
        return HStack(alignment: .top, spacing: 30) {
            big(UdhaFormat.hours(w.minutes), "worked", size: 34)
            ForEach(orgs, id: \.key) { org, minutes in
                big(UdhaFormat.hours(minutes), "\(org) · \(percent(minutes, of: w.minutes))")
            }
            big(UdhaFormat.hours(w.meetingMinutes), "meetings")
            big("\(w.prompts)", "prompts")
            if unassigned > 0 { big(UdhaFormat.hours(unassigned), "unassigned", tint: UdhaTheme.warn) }
            Spacer(minLength: 0)
            Button {
                core.time.refresh(weekStarting: shell.selectedWeek)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .udhaButton(.ghost, height: 26, hPadding: 8)
            .disabled(core.time.isComputing)
            .help("Recount")
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

    private func percent(_ part: Int, of whole: Int) -> String {
        whole > 0 ? "\(Int((Double(part) / Double(whole) * 100).rounded()))%" : "—"
    }

    // MARK: - Days

    private func days(_ w: TimeWeek) -> some View {
        let peak = max(60, w.days.map(\.minutes).max() ?? 60)
        let order = w.clients.map(\.name)
        let day = DateFormatter(); day.dateFormat = "EEE"
        let date = DateFormatter(); date.dateFormat = "d"
        let span = DateFormatter(); span.dateFormat = "HH:mm"
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "By day")
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(w.days) { d in
                    VStack(spacing: 6) {
                        Text(d.minutes > 0 ? UdhaFormat.hours(d.minutes) : "—")
                            .font(UdhaTheme.text(12.5, .bold)).monospacedDigit()
                            .foregroundStyle(d.minutes > 0 ? UdhaTheme.label : UdhaTheme.tertiary)
                        VStack(spacing: 1) {
                            Spacer(minLength: 0)
                            ForEach(order.reversed(), id: \.self) { name in
                                if let m = d.byClient[name], m > 0 {
                                    Rectangle().fill(color(name))
                                        .frame(height: max(2, 150 * CGFloat(m) / CGFloat(peak)))
                                        .help("\(name) · \(UdhaFormat.hours(m))")
                                }
                            }
                        }
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .background(UdhaTheme.fill.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(spacing: 0) {
                            Text("\(day.string(from: d.date)) \(date.string(from: d.date))")
                                .font(UdhaTheme.text(11.5, .semibold))
                                .foregroundStyle(UdhaTheme.secondary)
                            if let f = d.first, let l = d.last {
                                Mono("\(span.string(from: f))–\(span.string(from: l))", size: 9.5, color: UdhaTheme.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .udhaCard()
        }
    }

    // MARK: - Clients

    private func clients(_ w: TimeWeek) -> some View {
        let top = max(1, w.clients.first?.minutes ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            UdhaSectionHead(title: "By client")
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    header("Client", nil)
                    header("Hours", 230)
                    header("Meetings", 70, trailing: true)
                    header("Prompts", 60, trailing: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(UdhaTheme.fill)
                ForEach(Array(w.clients.enumerated()), id: \.element.id) { index, c in
                    HStack(spacing: 14) {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 2).fill(color(c.name)).frame(width: 4, height: 22)
                            Text(c.name)
                                .font(UdhaTheme.text(13, .semibold))
                                .foregroundStyle(c.name == TimeWeek.unassigned ? UdhaTheme.warn : UdhaTheme.label)
                            if c.org != "—" { UdhaPill(c.org, size: 10.5, height: 18) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            UdhaBar(fraction: Double(c.minutes) / Double(top), color: color(c.name), height: 6)
                            Text(UdhaFormat.hours(c.minutes))
                                .font(UdhaTheme.text(14, .bold)).monospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                            Text(percent(c.minutes, of: w.minutes))
                                .font(UdhaTheme.text(11.5, .regular)).monospacedDigit()
                                .foregroundStyle(UdhaTheme.tertiary)
                                .frame(width: 34, alignment: .trailing)
                        }
                        .frame(width: 230)
                        Text(c.meetingMinutes > 0 ? UdhaFormat.hours(c.meetingMinutes) : "—")
                            .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                            .foregroundStyle(UdhaTheme.secondary)
                            .frame(width: 70, alignment: .trailing)
                        Text(c.prompts > 0 ? "\(c.prompts)" : "—")
                            .font(UdhaTheme.text(13, .medium)).monospacedDigit()
                            .foregroundStyle(UdhaTheme.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) { if index > 0 { HRule(color: UdhaTheme.hairline) } }
                }
            }
            .udhaCard()
            .udhaRounded(UdhaTheme.cardRadius)
        }
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
