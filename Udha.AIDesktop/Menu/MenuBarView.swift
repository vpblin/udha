import SwiftUI

struct MenuBarStatusView: View {
    let inputLock: InputLockManager
    @Bindable var stateStore: SessionStateStore
    var meetings: MeetingCenter? = nil

    var body: some View {
        HStack(spacing: 6) {
            if meetings?.live != nil {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red)
            }
            if inputLock.isEngaged || inputLock.lastFailure != nil {
                Image(systemName: inputLock.lastFailure == nil ? "lock.fill" : "lock.open.trianglebadge.exclamationmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(inputLock.lastFailure == nil ? Color.primary : Color.red)
            } else {
                Circle()
                    .fill(iconColor)
                    .frame(width: 10, height: 10)
            }
            Text(statusText).font(.system(size: 11, weight: .medium))
        }
    }

    // Hidden sessions are out of sight here too — counts and list alike.
    private var needsCount: Int { stateStore.visible.filter { $0.state == .needsInput }.count }
    private var errorCount: Int { stateStore.visible.filter { $0.state == .errored }.count }
    private var activeCount: Int { stateStore.visible.filter { $0.state != .exited && $0.state != .crashed }.count }

    private var iconColor: Color {
        if errorCount > 0 { return .orange }
        if needsCount > 0 { return .yellow }
        if activeCount > 0 { return .green }
        return .secondary
    }

    private var statusText: String {
        if inputLock.lastFailure != nil { return "lock failed" }
        if inputLock.isEngaged { return "locked" }
        if needsCount > 0 { return "\(needsCount) waiting" }
        if errorCount > 0 { return "\(errorCount) err" }
        return "Udha"
    }
}

struct MenuBarContent: View {
    let core: AppCore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            Button {
                core.inputLock.lock(source: .menu)
            } label: {
                HStack {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .frame(width: 10)
                        .foregroundStyle(.secondary)
                    Text("Lock keyboard & mouse")
                    Spacer()
                    if core.config.config.inputLock.lockHotkeyEnabled {
                        Text(core.config.config.inputLock.lockHotkey.displayString)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .disabled(!core.config.config.inputLock.enabled || core.inputLock.isEngaged)
            .help(core.config.config.inputLock.enabled
                  ? "Keyboard and mouse go dead until you unlock with Touch ID or your password."
                  : "Enable the input lock in Settings → Lock first.")

            if let live = core.meetings.live {
                HStack {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Recording · \(UdhaFormat.clock(live.recorder.activeDuration))")
                            .font(.system(size: 12).monospacedDigit())
                    }
                    Spacer()
                    Button("Stop") {
                        Task { await core.meetings.stop() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    openMeetings()
                    Task { await core.meetings.start(mode: .standard) }
                } label: {
                    HStack {
                        Image(systemName: "record.circle")
                            .font(.system(size: 10))
                            .frame(width: 10)
                            .foregroundStyle(.secondary)
                        Text("Record meeting")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            Button {
                openMeetings()
            } label: {
                HStack {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 10))
                        .frame(width: 10)
                        .foregroundStyle(.secondary)
                    Text("Meetings…")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            if let failure = core.inputLock.lastFailure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Text(failure.message)
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { core.inputLock.clearFailure() }
                        .buttonStyle(.plain).font(.caption)
                }
                .padding(.vertical, 2)
            }

            Divider()

            ForEach(core.stateStore.visible) { snap in
                HStack {
                    Circle().fill(color(for: snap.state)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(snap.label).font(.system(size: 12))
                        Text(snap.state.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") {
                        core.sessionManager.showSession(id: snap.id)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }

            let recents = core.config.recentDirectoriesForDisplay
            if !recents.isEmpty {
                Divider()
                Text("Recent projects").font(.caption2).foregroundStyle(.secondary)
                ForEach(recents, id: \.self) { dir in
                    Button {
                        spawnRecent(dir)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.caption2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((dir as NSString).lastPathComponent).font(.system(size: 12))
                                Text(shortPath(dir)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(dir)
                }
            }

            Divider()
            Button("Show Udha Window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(10)
        .frame(minWidth: 300)
    }

    /// Meetings live inside the main window now, as a sidebar section — open
    /// the window and ask it to switch. The window may not exist yet on a
    /// hide-on-launch start, hence openWindow before the notification.
    private func openMeetings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .udhaRequestMeetings, object: nil)
        }
    }

    private func spawnRecent(_ dir: String) {
        let base = (dir as NSString).lastPathComponent
        let label = core.sessionManager.availableLabel(base)
        let cfg = SessionConfig(label: label, directory: dir, command: "claude", args: SessionConfig.defaultClaudeArgs)
        core.config.mutate { $0.sessions.append(cfg) }
        core.config.recordRecentDirectory(dir)
        do {
            _ = try core.sessionManager.spawn(sessionConfig: cfg)
        } catch {
            Log.app.error("menu-bar recent spawn failed for \(dir): \(error.localizedDescription)")
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .working: return .blue
        case .needsInput: return .yellow
        case .errored: return .red
        case .completed: return .green
        case .idle, .starting: return .gray
        case .exited, .crashed: return .secondary
        }
    }
}
