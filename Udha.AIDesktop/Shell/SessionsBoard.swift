import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The list column of the Sessions section: one group per machine Udha
/// supervises — a header card with the machine's name, its link and its
/// vitals, then a card per session — and drag-and-drop between groups to hand
/// a session off.
///
/// Machines are groups rather than a switch because both machines' sessions
/// live in one store and are supervised at once — a picker would imply you are
/// only ever looking at one box. Dropping a card on a group is the same
/// handoff the context menu performs; the group is just where you'd aim.
struct SessionsBoard: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    /// The machine id a drag is currently hovering, so the group can ring.
    @State private var dropTarget: String?
    @State private var pending: PendingHandoff?
    /// Filters the groups. Same matching rules as the overlay's search, so
    /// whatever a card shows you is also what you can type to find it.
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The card a reorder drag is hovering, so it can draw the insertion rule.
    @State private var reorderTargetID: UUID?
    /// The folder row a drag is hovering, so it can ring.
    @State private var folderDropTarget: UUID?
    @State private var folderDropAfter = false
    @State private var draggingFolder = false
    /// Inline folder rename: which row, the draft, and its focus.
    @State private var renamingFolderID: UUID?
    @State private var folderDraft = ""
    @FocusState private var folderRenameFocused: Bool
    /// A folder just created whose row should open in rename mode the moment
    /// it exists — immediately for this Mac, after the host's echo for a box.
    @State private var pendingFolderRename: UUID?

    struct PendingHandoff: Identifiable {
        let id = UUID()
        var sessions: [SessionSnapshot]
        var host: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HRule()

            VStack(spacing: 8) {
                UdhaSearchField(placeholder: "Filter sessions…", text: $query, focus: $searchFocused) {
                    openTopMatch()
                }
                newFolderAction
                // Only while a multi-selection is live: it is the only place
                // the bulk hand-off is offered.
                if !shell.sessionMulti.isEmpty { multiBar }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            handoffBanner
            createFailureBanner

            ScrollView {
                LazyVStack(spacing: 10, pinnedViews: [.sectionHeaders]) {
                    if query.isEmpty { AttentionInbox(core: core, shell: shell) }
                    ForEach(machines) { machine in
                        Section {
                            groupBody(machine)
                        } header: {
                            dropGroup(machine) { groupHeader(machine) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            let hidden = core.stateStore.hiddenCounts
            if hidden.folders > 0 || hidden.sessions > 0 { hiddenBar(hidden) }
        }
        .frame(width: UdhaTheme.boardWidth)
        .udhaChrome(.sidebar, tint: UdhaTheme.list)
        // The group headers carry each machine's ping/CPU/tmux, so the board
        // is a stats reader like the Machines section is.
        .onAppear {
            core.machines.addViewer("board")
            // A request raised while another section was showing (⌘K from
            // Meetings) is already set when the board mounts, so `onChange`
            // below never sees it change.
            consumeNewFolderRequest()
        }
        .onDisappear { core.machines.removeViewer("board") }
        .sheet(item: $pending) { plan in
            SessionHandoffSheet(core: core, shell: shell, plan: plan) { pending = nil }
        }
        // A new folder opens in rename mode as soon as its row exists. On this
        // Mac that is at once; on a box it is when the host echoes the list.
        .task(id: pendingFolderRename) { startPendingRename() }
        .onChange(of: allFolderIDs) { _, _ in startPendingRename() }
        .onChange(of: shell.newFolderRequest) { _, _ in consumeNewFolderRequest() }
    }

    private func consumeNewFolderRequest() {
        guard let req = shell.newFolderRequest else { return }
        shell.newFolderRequest = nil
        newFolder(on: req.host)
    }

    // MARK: - Data

    private var machines: [MachineSummary] { MachineDirectory.summaries(core: core) }

    private var stale: Double { core.config.config.staleAfterSeconds }

    /// Where a bulk hand-off would send the selection. Only local sessions can
    /// move, so a selection of purely remote rows offers nothing.
    private var bulkTarget: String? {
        let locals = shell.sessionMulti
            .compactMap { core.stateStore.snapshot(id: $0) }
            .filter { $0.hostName == nil }
        guard !locals.isEmpty else { return nil }
        return core.remoteHostClient.onlineHosts.sorted().first
    }

    // MARK: - Header + search

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Sessions")
                .font(UdhaTheme.text(15, .bold))
                .tracking(-0.15)
                .foregroundStyle(UdhaTheme.label)
            Text(hint)
                .font(UdhaTheme.text(11.5, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var hint: String {
        var w = 0, k = 0
        for snap in core.stateStore.visible {
            switch snap.attention(staleAfter: stale) {
            case .needsYou: w += 1
            case .working:  k += 1
            case .quiet:    break
            }
        }
        if core.stateStore.visible.isEmpty { return "" }
        return "\(w) waiting · \(k) working"
    }

    // MARK: - Folders

    /// The folders shown for a machine: its list minus the hidden ones.
    private func folders(_ m: MachineSummary) -> [SessionFolder] {
        core.stateStore.folders(host: m.host).filter { !$0.hidden }
    }

    /// Every folder id on the board, in order — what the pending-rename hook
    /// watches for a new row to appear.
    private var allFolderIDs: [UUID] {
        machines.flatMap { core.stateStore.folders(host: $0.host).map(\.id) }
    }

    private func members(of folder: SessionFolder, in m: MachineSummary) -> [SessionSnapshot] {
        visible(m).filter { $0.folderID == folder.id }
    }

    /// Filed nowhere, or filed in a folder this machine no longer has.
    private func loose(_ m: MachineSummary) -> [SessionSnapshot] {
        let known = Set(core.stateStore.folders(host: m.host).map(\.id))
        return visible(m).filter { $0.folderID.map { !known.contains($0) } ?? true }
    }

    /// Collapsed is view state on this Mac; a search overrides it so a match
    /// inside a folded folder is never invisible.
    private func isExpanded(_ folder: SessionFolder) -> Bool {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return !core.config.config.collapsedFolderIDs.contains(folder.id.uuidString)
    }

    private func toggle(_ folder: SessionFolder) {
        let key = folder.id.uuidString
        withAnimation(UdhaTheme.quick) {
            core.config.mutate { cfg in
                if let i = cfg.collapsedFolderIDs.firstIndex(of: key) { cfg.collapsedFolderIDs.remove(at: i) }
                else { cfg.collapsedFolderIDs.append(key) }
            }
        }
    }

    /// Whether folder actions are offered for a machine: this Mac always, a
    /// box only once its agent speaks `folders`.
    private func supportsFolders(_ host: String?) -> Bool {
        host == nil || !core.remoteHostClient.hostFoldersUnsupported
    }

    /// A row carries `account` only when its folder has several Claude logins
    /// to move between — and a box's agent has to be new enough to do it.
    private func supportsAccounts(_ snap: SessionSnapshot) -> Bool {
        snap.account != nil && (snap.hostName == nil || !core.remoteHostClient.hostAccountsUnsupported)
    }

    /// The machine "New folder" acts on when there is only one to choose
    /// from; with a box paired the button asks instead of guessing.
    private var newFolderHost: String? {
        shell.selectedSessionID.flatMap { core.stateStore.snapshot(id: $0) }?.hostName
    }

    @ViewBuilder
    private var newFolderAction: some View {
        let hosts = machines.filter { $0.online }
        if hosts.count > 1 {
            // Folders are per machine, so the button says which one: a menu
            // with a row per box, the one that cannot keep folders yet saying
            // why in place of doing nothing.
            Menu {
                ForEach(hosts) { m in
                    let supported = supportsFolders(m.host)
                    Button {
                        newFolder(on: m.host)
                    } label: {
                        Text(supported ? "On \(m.name)" : "On \(m.name) — agent needs a rebuild")
                    }
                    .disabled(!supported)
                }
            } label: {
                UdhaLabel(title: "New folder", icon: "folder.badge.plus", iconSize: 13)
                    .foregroundStyle(UdhaTheme.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous).fill(UdhaTheme.fill))
            .font(UdhaTheme.text(12.5, .medium))
            .help("Folders are per machine — pick which one")
        } else {
            let host = newFolderHost
            let supported = supportsFolders(host)
            UdhaListAction(title: "New folder", icon: "folder.badge.plus", kind: .ghost, disabled: !supported) {
                newFolder(on: host)
            }
            .help(supported ? "New folder on \(host ?? "this Mac")" : "\(host ?? "This machine")'s agent needs a rebuild before it can keep folders")
        }
    }

    /// Create a folder at the top of `host`'s list and open it for naming.
    /// The id is minted here so the row can be found the moment it lands.
    private func newFolder(on host: String?) {
        let id = UUID()
        pendingFolderRename = id
        core.sessionManager.createFolder(id: id, name: "New folder", host: host)
    }

    private func startPendingRename() {
        guard let id = pendingFolderRename, allFolderIDs.contains(id) else { return }
        pendingFolderRename = nil
        beginFolderRename(id)
    }

    /// Focus is grabbed on the next runloop tick, after the field is placed.
    private func beginFolderRename(_ id: UUID) {
        guard let folder = machines.lazy.compactMap({ core.stateStore.folder(id: id, host: $0.host) }).first else { return }
        folderDraft = folder.name
        renamingFolderID = id
        DispatchQueue.main.async { folderRenameFocused = true }
    }

    private func commitFolderRename(_ folder: SessionFolder, host: String?) {
        guard renamingFolderID == folder.id else { return }
        let text = folderDraft.trimmingCharacters(in: .whitespaces)
        renamingFolderID = nil
        folderRenameFocused = false
        guard !text.isEmpty, text != folder.name else { return }
        core.sessionManager.renameFolder(id: folder.id, to: text, host: host)
        shell.say("Renamed folder to \(text)")
    }

    private func cancelFolderRename() {
        renamingFolderID = nil
        folderRenameFocused = false
    }

    /// Hide a session, and never leave the detail pane sitting on it.
    private func hide(_ snap: SessionSnapshot) {
        core.sessionManager.setHidden(sessionID: snap.id, hidden: true)
        reanchorSelection(awayFrom: [snap.id])
        shell.say("Hid \(snap.label)")
    }

    private func hideFolder(_ folder: SessionFolder, in m: MachineSummary) {
        core.sessionManager.setFolderHidden(id: folder.id, hidden: true, host: m.host)
        reanchorSelection(awayFrom: Set(members(of: folder, in: m).map(\.id)))
        shell.say("Hid \(folder.name)")
    }

    private func reanchorSelection(awayFrom ids: Set<UUID>) {
        guard let sel = shell.selectedSessionID, ids.contains(sel) else { return }
        shell.selectedSessionID = core.stateStore.visible.first { !ids.contains($0.id) }?.id
    }

    /// "N folders and M sessions hidden · Unhide all", pinned under the list.
    private func hiddenBar(_ counts: (folders: Int, sessions: Int)) -> some View {
        let parts = [
            counts.folders > 0 ? "\(counts.folders) \(counts.folders == 1 ? "folder" : "folders")" : nil,
            counts.sessions > 0 ? "\(counts.sessions) \(counts.sessions == 1 ? "session" : "sessions")" : nil,
        ].compactMap { $0 }
        return HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UdhaTheme.secondary)
            Text(parts.joined(separator: " and ") + " hidden")
                .font(UdhaTheme.text(11.5))
                .foregroundStyle(UdhaTheme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Unhide all") { unhideAll() }
                .udhaButton(.bare, height: 20, hPadding: 4)
                .foregroundStyle(UdhaTheme.accentInk)
                .font(UdhaTheme.text(11.5, .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 7)
        .overlay(alignment: .top) { HRule() }
    }

    /// Every machine's — the footer is column-wide.
    private func unhideAll() {
        for m in machines where supportsFolders(m.host) {
            core.sessionManager.unhideAll(host: m.host)
        }
        shell.say("Unhid everything")
    }

    /// The machine's sessions with the filter applied. A machine whose every
    /// session is filtered out keeps its group and header — the count is still
    /// true, and a group vanishing mid-type reads as the box going offline.
    private func visible(_ m: MachineSummary) -> [SessionSnapshot] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return m.sessions }
        return m.sessions.filter { matches($0, query: q) }
    }

    /// Substring match across everything a card shows, plus the directory.
    private func matches(_ snap: SessionSnapshot, query q: String) -> Bool {
        let status = snap.statusPresentation(staleAfter: stale)
        let fields: [String?] = [
            snap.label, snap.directory, snap.agentName, snap.hostName, snap.tool?.rawValue, snap.tool?.label,
            snap.phaseDetail, snap.currentActivity, status.label, status.detail, snap.model,
        ]
        return fields.contains { $0?.lowercased().contains(q) == true }
    }

    /// Enter selects the first match, so a search can end without the mouse.
    private func openTopMatch() {
        guard let first = machines.lazy.compactMap({ visible($0).first }).first else { return }
        shell.select(session: first.id)
    }

    // MARK: - Multi-select bar

    /// Accent-tinted while a multi-selection is live — how many are picked
    /// and what will happen to them.
    private var multiBar: some View {
        let multi = shell.sessionMulti
        return HStack(spacing: 8) {
            Text("\(multi.count) selected")
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.accentInk)
            Text("drag any one to move the set")
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.accentInk.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Clear") { shell.sessionMulti = [] }
                .udhaButton(.bare, height: 24, hPadding: 7)
            if let host = bulkTarget {
                Button("Hand off to \(host)") { request(Array(multi), to: host) }
                    .udhaButton(.primary, height: 24, hPadding: 9)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UdhaTheme.accentTint))
    }

    /// The live handoff, while one is running. Sits under the search rather
    /// than in a group because it is about a session that is leaving one and
    /// arriving in the other.
    @ViewBuilder private var handoffBanner: some View {
        switch core.handoffState {
        case .idle:
            EmptyView()
        case .staging(let label):
            strip("Moving \(label) — syncing files and the Claude transcript…", mono: true)
        case .done(let label):
            strip("Moved \(label). Resumed on the box.", mono: false)
                .task { try? await Task.sleep(nanoseconds: 4_000_000_000); core.clearHandoffState() }
        case .failed(let message):
            Button { core.clearHandoffState() } label: { strip(message, mono: false, error: true) }
                .buttonStyle(.plain)
        }
    }

    /// A create that the host refused — a missing `codex`, a git failure, a
    /// path that isn't there. Same strip as the handoff, since it is the same
    /// kind of news about the same group.
    @ViewBuilder private var createFailureBanner: some View {
        if let message = core.remoteHostClient.createFailure {
            Button { core.remoteHostClient.clearCreateFailure() } label: {
                strip(message, mono: false, error: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func strip(_ text: String, mono: Bool, error: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "arrow.right.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(text).font(mono ? UdhaTheme.mono(11) : UdhaTheme.text(11.5, .medium)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(error ? UdhaTheme.badInk : UdhaTheme.accentInk)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(error ? UdhaTheme.badTint : UdhaTheme.accentTint))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Group

    /// The machine's header card: live dot, name, count, its link as a pill,
    /// the attention counts and vitals, and the tmux socket it runs on.
    private func groupHeader(_ m: MachineSummary) -> some View {
        let targeted = dropTarget == m.id
        let needs = m.sessions.filter { $0.attention(staleAfter: stale) == .needsYou }.count
        let working = m.sessions.filter { $0.attention(staleAfter: stale) == .working }.count
        let quiet = m.sessions.count - needs - working
        let meta = [needs > 0 ? "\(needs) waiting · \(working) working" : "\(working) working · \(quiet) quiet",
                    vitals(m)].filter { !$0.isEmpty }.joined(separator: " · ")

        // The design's strip, not a card: icon, the machine's name as a caps
        // eyebrow, a 5pt breathing dot, the link as plain text, the count at
        // the right; then the attention counts and vitals with the tmux
        // socket ending the line. Full column width, a 1.5pt rule beneath.
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: m.host == nil ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UdhaTheme.secondary)
                    .frame(width: 14)
                Text(m.name.uppercased())
                    .font(UdhaTheme.text(10.5, .bold))
                    .tracking(0.75)
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                Pulsing(active: m.online, period: 2.6, scale: 1.5, dimTo: 0.5) {
                    Circle().fill(m.online ? UdhaTheme.good : UdhaTheme.bad).frame(width: 5, height: 5)
                }
                Text(boardStatus(m))
                    .font(UdhaTheme.text(10.5))
                    .foregroundStyle(statusInk(m))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(m.sessions.count)")
                    .font(UdhaTheme.text(10.5))
                    .monospacedDigit()
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meta)
                    .font(UdhaTheme.text(10.5))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if let stats = m.stats, !stats.tmuxNote.isEmpty {
                    // The tail of the path is the part that tells sockets apart.
                    Mono(stats.tmuxNote, size: 10, color: UdhaTheme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(targeted ? UdhaTheme.accentTint : UdhaTheme.list)
        // The pinned header scrolls over the cards; an opaque ground keeps
        // them from showing through the translucent list tint.
        .background(UdhaTheme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(targeted ? UdhaTheme.accent : UdhaTheme.fillStrong)
                .frame(height: 1.5)
        }
        // Bleed to the column's edges: the list is inset 10pt, the strip is not.
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onTapGesture { connect(m) }
        .contextMenu {
            Button("New folder on \(m.name)") { newFolder(on: m.host) }
                .disabled(!supportsFolders(m.host))
            if m.host != nil, !m.connected {
                Button("Connect") { connect(m) }
            }
        }
        .help(m.host == nil ? "This Mac" : (m.connected ? "Connected" : "Click to connect"))
        .animation(UdhaTheme.quick, value: targeted)
    }

    /// Clicking a machine's header connects this desktop to it. It used to
    /// toggle, and a double-click — the reflex when a column looks empty —
    /// paired and unpaired within a second, leaving the box "disconnected" by
    /// choice with its sessions gone and the folder picker stuck on Loading.
    /// Disconnecting is deliberate: the button in the Machines pane.
    private func connect(_ m: MachineSummary) {
        guard let host = m.host else { return }
        if m.connected {
            return
        } else if m.online {
            core.selectHost(host)
            shell.say("Connecting to \(host)…")
        } else {
            shell.select(machine: host)
        }
    }

    @ViewBuilder
    private func groupBody(_ m: MachineSummary) -> some View {
        VStack(spacing: 4) {
            // Folders first, then the loose cards — each in the store's own
            // order. Sessions used to be bucketed Needs you / Working / Quiet,
            // which meant a card jumped to a different part of the group every
            // time its phase changed — and Claude changes phase every few
            // seconds. The card's own dot, colour and status line already say
            // what state it is in; a folder is the one grouping you chose.
            ForEach(folders(m)) { folder in
                let rows = members(of: folder, in: m)
                // A search hides folders that hold no match; without one every
                // folder stays, empty or not, so it can be dropped into.
                if query.trimmingCharacters(in: .whitespaces).isEmpty || !rows.isEmpty {
                    folderRow(folder, rows: rows, in: m)
                    if isExpanded(folder) {
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle().fill(UdhaTheme.separator).frame(width: 1.5)
                            VStack(spacing: 4) {
                                ForEach(rows) { card($0) }
                                if rows.isEmpty {
                                    Text("Drop sessions here")
                                        .font(UdhaTheme.text(11))
                                        .foregroundStyle(UdhaTheme.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .contentShape(Rectangle())
                                        .dropDestination(for: String.self) { items, _ in
                                            drop(items, onFolder: folder, in: m)
                                        }
                                }
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.top, 2)
                    }
                }
            }
            if !folders(m).isEmpty {
                Text("Unfiled sessions · Drop here to remove from folder")
                    .font(UdhaTheme.text(10.5))
                    .foregroundStyle(UdhaTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 8)
                    .background(UdhaTheme.fill, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, on: m)
                    }
            }
            ForEach(loose(m)) { card($0) }

            if m.sessions.isEmpty {
                dropGroup(m) { emptyGroup(m) }
            }
            else if visible(m).isEmpty { noMatches }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func folderRow(_ folder: SessionFolder, rows: [SessionSnapshot], in m: MachineSummary) -> some View {
        SessionFolderRow(
            folder: folder,
            count: rows.count,
            needsYou: rows.filter { $0.attention(staleAfter: stale) == .needsYou }.count,
            expanded: isExpanded(folder),
            renaming: renamingFolderID == folder.id,
            draft: $folderDraft,
            focus: $folderRenameFocused,
            dropTargeted: folderDropTarget == folder.id,
            onToggle: { toggle(folder) },
            onCommitRename: { commitFolderRename(folder, host: m.host) },
            onCancelRename: cancelFolderRename
        )
        .frame(height: 34)
        .contentShape(Rectangle())
        .overlay(alignment: folderDropAfter ? .bottom : .top) {
            if folderDropTarget == folder.id && draggingFolder {
                Rectangle().fill(UdhaTheme.accent).frame(height: 2)
                    .allowsHitTesting(false)
            }
        }
        // Folders drag to resort, like cards; the payload is prefixed so a
        // folder dropped on a card or a machine is never read as sessions.
        .onDrag {
            draggingFolder = true
            return NSItemProvider(object: Self.folderPayload(folder.id) as NSString)
        }
        .onDrop(of: [UTType.text], delegate: FolderDropDelegate(
            targeted: { point in
                if let point {
                    folderDropTarget = folder.id
                    folderDropAfter = point.y >= 17
                } else if folderDropTarget == folder.id {
                    folderDropTarget = nil
                }
            },
            perform: { items, after in
                drop(items, onFolder: folder, in: m, after: after)
            }
        ))
        .contextMenu { folderMenu(folder, in: m) }
    }

    private static let folderPrefix = "folder:"
    private static func folderPayload(_ id: UUID) -> String { folderPrefix + id.uuidString }
    /// The folder ids in a drag, if it carries folders rather than sessions.
    private static func folderIDs(in items: [String]) -> [UUID] {
        items.filter { $0.hasPrefix(folderPrefix) }
            .compactMap { UUID(uuidString: String($0.dropFirst(folderPrefix.count))) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: SessionFolder, in m: MachineSummary) -> some View {
        Button("Rename folder") { beginFolderRename(folder.id) }
        Button("New session here") {
            shell.newSessionSeed = UdhaShellModel.NewSessionSeed(host: m.host, folderID: folder.id)
            shell.newSessionOpen = true
        }
        Button(isExpanded(folder) ? "Collapse" : "Expand") { toggle(folder) }
        Button("Hide folder") { hideFolder(folder, in: m) }
        Divider()
        Button("Ungroup") {
            core.sessionManager.deleteFolder(id: folder.id, host: m.host)
            shell.say("Ungrouped \(folder.name)")
        }
    }

    /// Folder drags insert on the indicated edge; session drags file into
    /// the folder. Membership stays on the session's own machine.
    private func drop(_ items: [String], onFolder folder: SessionFolder, in m: MachineSummary, after: Bool = false) -> Bool {
        let folderIDs = Self.folderIDs(in: items)
        if let moving = folderIDs.first {
            guard core.stateStore.folder(id: moving, host: m.host) != nil, moving != folder.id else { return false }
            withAnimation(UdhaTheme.quick) {
                core.sessionManager.reorderFolder(movingID: moving, before: folder.id, host: m.host, after: after)
            }
            return true
        }
        let ids = items
            .flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
        let dragged = ids.compactMap { core.stateStore.snapshot(id: $0) }
        guard !dragged.isEmpty else { return false }
        if dragged.allSatisfy({ $0.hostName == m.host }) {
            guard supportsFolders(m.host) else { return false }
            withAnimation(UdhaTheme.quick) {
                for snap in dragged where snap.folderID != folder.id {
                    core.sessionManager.setFolder(sessionID: snap.id, folderID: folder.id)
                }
            }
            core.config.mutate { $0.collapsedFolderIDs.removeAll { $0 == folder.id.uuidString } }
            return true
        }
        shell.say("Move sessions to a folder on their own machine; use the machine header to hand off")
        return false
    }

    /// Filtered to nothing. Says so rather than showing an empty group, which
    /// would read as the machine having no sessions.
    private var noMatches: some View {
        Text("No session here matches “\(query)”")
            .font(UdhaTheme.text(11.5, .regular))
            .foregroundStyle(UdhaTheme.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func emptyGroup(_ m: MachineSummary) -> some View {
        let text: String = {
            if let note = m.offlineNote { return note }
            // Every session here is hidden, not absent — say so, or the group
            // reads as an empty machine with sessions still running on it.
            if core.stateStore.all.contains(where: { $0.hostName == m.host }) {
                return "Everything here is hidden. Unhide all brings it back."
            }
            if m.host == nil { return "Nothing running on this Mac. ⌘N starts one." }
            return "Nothing running here. Drag a session across and Udha will resume it in the same repo on this machine."
        }()
        Text(text)
            .font(UdhaTheme.text(11.5, .regular))
            .foregroundStyle(UdhaTheme.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 16)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(UdhaTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    // MARK: - Card

    private func card(_ snap: SessionSnapshot) -> some View {
        let style = UdhaSessionStyle(snapshot: snap, staleAfter: stale)
        let selected = shell.selectedSessionID == snap.id
        let inMulti = shell.sessionMulti.contains(snap.id)
        let wantsYou = snap.attention(staleAfter: stale) == .needsYou

        return SessionCardView(
            snapshot: snap,
            style: style,
            selected: selected,
            inMulti: inMulti,
            wantsYou: wantsYou,
            reorderTarget: reorderTargetID == snap.id
        )
        // Every card drags, including remote ones: a drop on a card in the
        // *same* group reorders, and that is worth more on the box's fifteen
        // rows than on the Mac's three. A Button swallows the drag gesture on
        // macOS, so the card carries a tap gesture instead.
        .onDrag {
            draggingFolder = false
            return NSItemProvider(object: payload(snap) as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, onCard: snap)
        } isTargeted: { over in
            if over { reorderTargetID = snap.id }
            else if reorderTargetID == snap.id { reorderTargetID = nil }
        }
        // Modifier flags are read at tap time rather than through
        // `TapGesture().modifiers(_:)`, which fires alongside the plain tap.
        .onTapGesture { tapped(snap) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snap.label), \(style.label)")
        .contextMenu { menu(snap) }
    }

    static func meta(_ s: SessionSnapshot) -> String {
        let ctx = s.contextPercent.map { "\($0)%" } ?? "—"
        return "\(ctx) · \(UdhaFormat.cents(s.costCents))"
    }

    private func tapped(_ snap: SessionSnapshot) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) || mods.contains(.command) {
            if shell.sessionMulti.contains(snap.id) { shell.sessionMulti.remove(snap.id) }
            else { shell.sessionMulti.insert(snap.id) }
            shell.selectedSessionID = snap.id
        } else {
            shell.sessionMulti = []
            shell.selectedSessionID = snap.id
        }
    }

    /// A card dropped on another card. Within one machine that is a reorder;
    /// across machines it is the hand-off the group would have done.
    ///
    /// The card has to decide, because a `dropDestination` that declines does
    /// **not** fall through to its parent — returning false here would swallow
    /// a hand-off aimed at a remote group and silently do nothing.
    private func drop(_ items: [String], onCard target: SessionSnapshot) -> Bool {
        reorderTargetID = nil
        let ids = items
            .flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty, !ids.contains(target.id) else { return false }

        let dragged = ids.compactMap { core.stateStore.snapshot(id: $0) }
        guard !dragged.isEmpty else { return false }
        // Same machine → reorder. Order is a property of the list you are
        // looking at, so mixing machines in one drag is never a reorder.
        if dragged.allSatisfy({ $0.hostName == target.hostName }) {
            withAnimation(UdhaTheme.quick) {
                for id in ids {
                    core.sessionManager.reorder(movingID: id, before: target.id)
                }
                // Landing between a folder's cards files you there; landing
                // among the loose ones takes you out.
                if supportsFolders(target.hostName) {
                    for snap in dragged where snap.folderID != target.folderID {
                        core.sessionManager.setFolder(sessionID: snap.id, folderID: target.folderID)
                    }
                }
            }
            return true
        }
        if target.folderID != nil {
            shell.say("Use the machine header to hand off; folders stay on their own machine")
            return false
        }
        return handleDrop(items, on: MachineDirectory.summary(core: core, host: target.hostName))
    }

    /// A drag carries the whole multi-selection when the grabbed card is part
    /// of it, otherwise just that card.
    private func payload(_ snap: SessionSnapshot) -> String {
        if shell.sessionMulti.contains(snap.id), shell.sessionMulti.count > 1 {
            return core.stateStore.all.filter { shell.sessionMulti.contains($0.id) && $0.hostName == snap.hostName }
                .map { $0.id.uuidString }.joined(separator: ",")
        }
        return snap.id.uuidString
    }

    @ViewBuilder
    private func menu(_ snap: SessionSnapshot) -> some View {
        Button("Rename") {
            shell.select(session: snap.id)
            shell.renameSelectedSession = true
        }
        Button("Open in Terminal") { core.sessionManager.showSession(id: snap.id) }
        Button("Duplicate") { _ = core.sessionManager.duplicate(sessionID: snap.id) }
        if supportsAccounts(snap) {
            Button("Switch Claude login") { core.sessionManager.rotateAccount(id: snap.id) }
        }
        if supportsFolders(snap.hostName) {
            Menu("Move to folder…") {
                let list = core.stateStore.folders(host: snap.hostName)
                ForEach(list) { folder in
                    Button {
                        core.sessionManager.setFolder(sessionID: snap.id, folderID: folder.id)
                    } label: {
                        if folder.id == snap.folderID {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
                if snap.folderID != nil {
                    if !list.isEmpty { Divider() }
                    Button("Remove from folder") { core.sessionManager.setFolder(sessionID: snap.id, folderID: nil) }
                }
                Divider()
                Button("New folder…") {
                    let id = UUID()
                    pendingFolderRename = id
                    core.sessionManager.createFolder(id: id, name: "New folder", host: snap.hostName)
                    core.sessionManager.setFolder(sessionID: snap.id, folderID: id)
                }
            }
            Button("Hide") { hide(snap) }
        }
        if snap.hostName == nil, !core.remoteHostClient.onlineHosts.isEmpty {
            Divider()
            ForEach(core.remoteHostClient.onlineHosts.sorted(), id: \.self) { host in
                Button("Move to \(host)") { request([snap.id], to: host) }
            }
        }
        Divider()
        Button("Terminate") { core.sessionManager.terminateSession(id: snap.id) }
        Button("Remove", role: .destructive) { core.sessionManager.removeSession(id: snap.id) }
    }

    // MARK: - Handoff

    private func request(_ ids: [UUID], to host: String) {
        let snaps = ids
            .compactMap { core.stateStore.snapshot(id: $0) }
            .filter { $0.hostName == nil }
        guard !snaps.isEmpty else {
            shell.say("Only sessions on this Mac can be handed off")
            return
        }
        pending = PendingHandoff(sessions: snaps, host: host)
    }

    private func handleDrop(_ items: [String], on machine: MachineSummary) -> Bool {
        dropTarget = nil
        // A folder dropped on a machine goes nowhere; folders are per machine.
        guard Self.folderIDs(in: items).isEmpty else { return false }
        let dragged = items.flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
            .compactMap { core.stateStore.snapshot(id: $0) }
        guard !dragged.isEmpty else { return false }
        if dragged.allSatisfy({ $0.hostName == machine.host }) {
            guard supportsFolders(machine.host) else { return false }
            for snap in dragged {
                core.sessionManager.setFolder(sessionID: snap.id, folderID: nil)
            }
            return true
        }
        // Handing a session *back* to this Mac is not wired yet — the stage
        // step only knows how to push over SSH — so the Mac group takes no
        // drops rather than accepting one and silently doing nothing.
        guard machine.host != nil else {
            shell.say("Moving a session back to this Mac isn't wired up yet")
            return false
        }
        guard machine.online else {
            shell.say("\(machine.name) is offline")
            return false
        }
        let ids = items
            .flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else { return false }
        request(ids, to: machine.host!)
        return true
    }

    private func setDropTarget(_ id: String, over: Bool) {
        if over { dropTarget = id }
        else if dropTarget == id { dropTarget = nil }
    }

    // MARK: - Machine text

    private func boardStatus(_ m: MachineSummary) -> String {
        if m.host == nil { return "Active · overlay here" }
        if m.connected { return "Connected" }
        if m.online { return "Online · not connected" }
        return "Offline"
    }

    /// Plain tertiary text for the two everyday states; the two that want a
    /// click keep their warning colours.
    private func statusInk(_ m: MachineSummary) -> Color {
        if !m.online { return UdhaTheme.badInk }
        if m.host == nil || m.connected { return UdhaTheme.tertiary }
        return UdhaTheme.warnInk
    }

    /// `113 ms · CPU 18%` — the numbers that say whether a box can take more
    /// work. A field that has not been read yet is left out rather than
    /// rendered as a dash: the keepalive needs half a minute to measure an
    /// RTT, and a leading "—" reads as a broken link.
    private func vitals(_ m: MachineSummary) -> String {
        var parts: [String] = []
        if m.latency != "—" { parts.append(m.latency) }
        if let cpu = m.stats?.cpuPercent { parts.append("CPU \(Int(cpu.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    /// Machine targets live on the header and empty placeholder. Wrapping
    /// the entire group would overlap its folder and card drop destinations.
    private func dropGroup<V: View>(_ machine: MachineSummary,
                                    @ViewBuilder _ content: () -> V) -> some View {
        content()
            .dropDestination(for: String.self) { items, _ in
                handleDrop(items, on: machine)
            } isTargeted: { over in
                setDropTarget(machine.id, over: over)
            }
    }
}

// MARK: - Card view

/// One session on the board: name and model, then the state as a dot and a
/// word (pinging when live), then the line the turn ended on. Selected cards
/// sit on the card ground with an accent ring; the rest lift on hover.
private struct SessionCardView: View {
    let snapshot: SessionSnapshot
    let style: UdhaSessionStyle
    let selected: Bool
    let inMulti: Bool
    let wantsYou: Bool
    let reorderTarget: Bool

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.label)
                    .font(UdhaTheme.text(12.5, .semibold))
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                if snapshot.agentName != nil {
                    Text("✦").font(UdhaTheme.text(10, .regular)).foregroundStyle(UdhaTheme.accentInk)
                }
                Spacer(minLength: 4)
                // Which model this session is on. A ChatGPT or Qwen session
                // reports no model — it says which assistant instead.
                if let right = snapshot.model ?? snapshot.tool.flatMap({ $0 == .claude ? nil : $0.label }) {
                    Text(right)
                        .font(UdhaTheme.text(10.5, .regular))
                        .foregroundStyle(UdhaTheme.secondary)
                        .lineLimit(1)
                }
                // Which login, for a folder with several — the thing that
                // changes when a usage limit moves the session.
                if let account = snapshot.account {
                    Mono(account, size: 9.5)
                        .foregroundStyle(UdhaTheme.tertiary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                PingDot(color: style.mark, size: 6, active: style.pulses)
                Text(style.label)
                    .font(UdhaTheme.text(11, .semibold))
                    .foregroundStyle(style.stateText)
                    .lineLimit(1)
                if style.live { WorkingDots(color: style.mark) }
            }
            if let detail = style.detail, !detail.isEmpty {
                // One line, and its space is kept even when the text is
                // short: Claude's status line changes every couple of
                // seconds, and a card whose height flips with it makes the
                // whole list jitter. Two reserved lines were tried and made
                // every card a row taller than it reads — reverted on request.
                Text(detail)
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(wantsYou ? UdhaTheme.badInk : UdhaTheme.secondary)
                    .lineLimit(1, reservesSpace: true)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? UdhaTheme.card : (inMulti ? UdhaTheme.accentTint : UdhaTheme.fill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? (wantsYou ? UdhaTheme.bad : UdhaTheme.accent) : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: .top) {
            if reorderTarget {
                Capsule().fill(UdhaTheme.accent).frame(height: 2).offset(y: -3)
            }
        }
        // Radius 0 when the card is neither selected nor hovered: a blur pass
        // on thirty resting cards is the difference between a list that
        // scrolls and one that stutters.
        .shadow(color: UdhaTheme.cardShadow.opacity(selected ? 1 : (hovering ? 2 : 0)),
                radius: selected ? 4 : (hovering ? 9 : 0), y: selected ? 2 : (hovering ? 5 : 0))
        .offset(y: hovering && !selected && UdhaTheme.motion ? -2 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .animation(UdhaTheme.lift, value: hovering)
        .animation(UdhaTheme.quick, value: selected)
    }
}

// MARK: - Confirm sheet

/// What a hand-off actually does, before it happens. The transcript copy is the
/// part worth spelling out: the conversation moves, it isn't restarted.
struct SessionHandoffSheet: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel
    let plan: SessionsBoard.PendingHandoff
    var dismiss: () -> Void

    private var many: Bool { plan.sessions.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(many ? "Hand off \(plan.sessions.count) sessions"
                          : "Hand off \(plan.sessions[0].label)")
                    .font(UdhaTheme.text(17, .bold))
                    .foregroundStyle(UdhaTheme.label)
                Spacer(minLength: 8)
                UdhaPill("This Mac  →  \(plan.host)", mono: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            HRule()

            VStack(alignment: .leading, spacing: 0) {
                Text("Udha rsyncs the working tree and the Claude transcript to \(plan.host), closes the session here, and resumes the same conversation there with `claude --resume`. Files and transcript land before the Mac session closes, so the chat is never lost.")
                    .font(UdhaTheme.text(13, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)

                VStack(spacing: 0) {
                    ForEach(plan.sessions) { snap in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(snap.label)
                                .font(UdhaTheme.text(12.5, .semibold))
                                .foregroundStyle(UdhaTheme.label)
                            Mono(UdhaFormat.tildePath(snap.directory), size: 11)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(note(snap))
                                .font(UdhaTheme.text(11, .regular))
                                .foregroundStyle(UdhaTheme.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
                    }
                }
                .udhaCard()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Text("The tmux window is killed here once the files are staged on \(plan.host).")
                    .font(UdhaTheme.text(11, .regular))
                    .foregroundStyle(UdhaTheme.secondary)
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .udhaButton(.ghost, height: 30, hPadding: 14)
                Button(many ? "Hand off \(plan.sessions.count) →" : "Hand off →") { commit() }
                    .udhaButton(.primary, height: 30, hPadding: 14)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 560)
        .frame(minHeight: 260)
        .background(UdhaTheme.canvas)
    }

    /// A mid-turn session is worth flagging: the handoff waits for nothing, so
    /// whatever Claude is part-way through is what gets resumed on the box.
    private func note(_ snap: SessionSnapshot) -> String {
        switch snap.attention(staleAfter: core.config.config.staleAfterSeconds) {
        case .working:  return "mid-turn — resumes there"
        case .needsYou: return "waiting on you"
        case .quiet:    return "idle · safe to move"
        }
    }

    private func commit() {
        for snap in plan.sessions {
            core.handoffSession(snap.id, toHost: plan.host)
        }
        shell.sessionMulti = []
        shell.say(many ? "Moving \(plan.sessions.count) sessions to \(plan.host)"
                       : "Moving \(plan.sessions[0].label) to \(plan.host)")
        dismiss()
    }
}


/// Use the native drop delegate for folder rows so the insertion edge follows
/// the pointer, and decode the provider before changing the observable list.
private struct FolderDropDelegate: DropDelegate {
    var targeted: (CGPoint?) -> Void
    var perform: ([String], Bool) -> Bool

    func dropEntered(info: DropInfo) { targeted(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        targeted(info.location)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { targeted(nil) }
    func validateDrop(info: DropInfo) -> Bool {
        info.itemProviders(for: [UTType.text]).contains { $0.canLoadObject(ofClass: NSString.self) }
    }
    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.text])
            .filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !providers.isEmpty else { return false }
        let after = info.location.y >= 17
        targeted(nil)
        Task { @MainActor in
            var items: [String] = []
            for provider in providers {
                let value: String? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                        continuation.resume(returning: value as? String)
                    }
                }
                if let value { items.append(value) }
            }
            _ = perform(items, after)
        }
        return true
    }
}
