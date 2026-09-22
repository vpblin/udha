import SwiftUI
import AppKit

/// The edge overlay: a flat ink strip pressed against the screen wall that
/// blooms into a 272pt panel of session pills.
///
/// The strip is a tick chart, not decoration — one mark per session, tall and
/// red when it wants you, medium when it's working, a stub when it's quiet. You
/// read the whole desk from the corner of your eye without the panel ever
/// opening.
struct EdgeOverlayView: View {
    let core: AppCore
    @Binding var isExpanded: Bool
    @Bindable var config: ConfigStore
    @Bindable var stateStore: SessionStateStore
    let panelSize: CGSize
    /// Fired when the cursor enters (true) or leaves (false) the active hover
    /// region — the 1pt edge strip while collapsed, the bloom card while open.
    /// Wired at sub-view granularity so the tracking area is sized to the strip
    /// rather than to the whole panel rect.
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// Fired when a pill's inline rename field opens (true) / closes (false).
    var onRenamingChanged: (Bool) -> Void = { _ in }
    /// Same contract, for the search field. Two callbacks rather than one flag
    /// because the host ORs them: a rename closing as search opens must not
    /// slam the key gate shut under the field that just took focus.
    var onSearchFocusChanged: (Bool) -> Void = { _ in }
    var onMinimize: () -> Void = {}

    @Environment(\.openWindow) private var openWindow

    @State private var sessionPendingRemoval: SessionSnapshot?
    @State private var dragTargetID: UUID?
    /// The folder row a pill is being dragged over, so it can ring.
    @State private var folderDropTarget: UUID?
    /// Inline folder rename, the same two-step the pill's rename uses.
    @State private var renamingFolderID: UUID?
    @State private var folderDraft = ""
    @FocusState private var folderRenameFocused: Bool
    /// A folder just created from a pill's menu, whose row opens for naming
    /// the moment the store lists it (a box echoes it a beat later).
    @State private var pendingFolderRename: UUID?
    @State private var searchText = ""
    @State private var isSearchFieldLive = false
    @FocusState private var searchFieldFocused: Bool

    private let bloomWidth: CGFloat = 272

    private var edge: OverlayEdge { config.config.overlay.edge }
    private var stripWidth: CGFloat { CGFloat(config.config.overlay.triggerWidth) }
    private var staleAfter: Double { config.config.staleAfterSeconds }
    /// Hidden sessions are out of sight here too: no tick, no pill, no count.
    private var sessions: [SessionSnapshot] { stateStore.visible }

    private var waitingCount: Int {
        sessions.filter { $0.attention(staleAfter: staleAfter) == .needsYou }.count
    }
    private var hasAttention: Bool { waitingCount > 0 }

    /// What the bloomed list renders. The header count and the strip ticks
    /// deliberately keep reading `sessions` — a filter is a view onto the list,
    /// not a claim that the hidden sessions stopped existing.
    private var visibleSessions: [SessionSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter { matches($0, query: query) }
    }

    /// Substring match across everything a pill shows, so whatever you can read
    /// is also what you can type to find it.
    private func matches(_ snap: SessionSnapshot, query: String) -> Bool {
        let status = snap.statusPresentation(staleAfter: staleAfter)
        let fields: [String?] = [
            snap.label, snap.directory, snap.agentName,
            snap.phaseDetail, snap.currentActivity, status.label, status.detail,
        ]
        return fields.contains { $0?.lowercased().contains(query) == true }
    }

    var body: some View {
        ZStack(alignment: edge == .right ? .trailing : .leading) {
            // `Color.clear` is hit-testable by default, which would make the
            // whole panel catch hovers and defeat the edge trigger.
            Color.clear.allowsHitTesting(false)

            if isExpanded {
                bloomCard
                    .transition(.opacity.combined(with: .move(edge: edge == .right ? .trailing : .leading)))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: onHoverChanged(true)
                        case .ended:  onHoverChanged(false)
                        }
                    }
            } else {
                restingStrip
                    .allowsHitTesting(false)
                    .transition(.opacity)

                // The only hit-testable thing while collapsed: a 1pt strip
                // flush with the screen edge. Combined with the dwell timer in
                // EdgeOverlayHost, the overlay only blooms when the cursor is
                // pressed into the wall.
                Color.clear
                    .frame(width: 1, height: panelSize.height)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: onHoverChanged(true)
                        case .ended:  onHoverChanged(false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: edge == .right ? .trailing : .leading)
            }
        }
        .frame(width: panelSize.width, height: panelSize.height,
               alignment: edge == .right ? .trailing : .leading)
        .animation(UdhaTheme.bloom, value: isExpanded)
        .confirmationDialog(
            "Remove \(sessionPendingRemoval?.label ?? "session")?",
            isPresented: Binding(
                get: { sessionPendingRemoval != nil },
                set: { if !$0 { sessionPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: sessionPendingRemoval
        ) { snap in
            Button("Remove", role: .destructive) { core.sessionManager.removeSession(id: snap.id) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This stops the tmux session and deletes the project from your config.")
        }
        // Every bloom starts from an unfiltered list. A query that survived the
        // collapse would silently hide sessions the next time it opens.
        .onChange(of: isExpanded) { _, expanded in
            guard !expanded else { return }
            endSearch(clearText: true)
            searchText = ""
        }
        // Escape reaching the panel, the panel losing key, the collapse
        // watchdog: whoever asked, stop editing. This is the path that
        // un-wedges a bloom whose search field silently stopped being first
        // responder — SwiftUI never reports that, so nothing else can.
        .onReceive(NotificationCenter.default.publisher(for: .udhaOverlayReleaseKeyFocus)) { _ in
            endSearch(clearText: true)
            searchText = ""
        }
    }

    // MARK: - Resting strip

    private var restingStrip: some View {
        ZStack {
            Rectangle().fill(OverlayTheme.strip)
            VStack(spacing: 6) {
                ForEach(sessions) { snap in
                    tick(for: snap)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(width: stripWidth, height: panelSize.height)
        .frame(maxWidth: .infinity, alignment: edge == .right ? .trailing : .leading)
    }

    @ViewBuilder
    private func tick(for snap: SessionSnapshot) -> some View {
        let width = max(4, min(stripWidth - 6, 6))
        switch snap.attention(staleAfter: staleAfter) {
        case .needsYou:
            Pulsing { Capsule().fill(UdhaTheme.bad).frame(width: width, height: 14) }
        case .working:
            Capsule().fill(UdhaTheme.accent).frame(width: width, height: 10)
        case .quiet:
            Capsule().fill(Color.white.opacity(0.45)).frame(width: width, height: 4)
        }
    }

    // MARK: - Bloom

    private var bloomCard: some View {
        VStack(spacing: 0) {
            header
            if isSearchFieldLive || !searchText.isEmpty { searchRow }
            pillList
            footer
        }
        .frame(width: bloomWidth)
        .background(
            ZStack {
                VisualEffectBackground(material: .popover, blending: .behindWindow)
                UdhaTheme.canvas.opacity(0.9)
            }
        )
        .udhaRounded(12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(UdhaTheme.separator, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.28), radius: 22, x: edge == .right ? -6 : 6, y: 10)
        .padding(.vertical, 8)
        .padding(edge == .right ? .leading : .trailing, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Pulsing(active: hasAttention) {
                Circle()
                    .fill(hasAttention ? UdhaTheme.bad : UdhaTheme.good)
                    .frame(width: 8, height: 8)
            }
            Text(headline)
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.label)
            Spacer(minLength: 4)
            stripButton("magnifyingglass", help: "Search sessions") { beginSearch() }
            stripButton("plus", help: "New session") { openNewSession() }
            stripButton("gearshape", help: "Settings") { openSettings() }
            stripButton("eye.slash", help: "Hide the overlay until the Dock icon is clicked",
                        action: onMinimize)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(UdhaTheme.fill)
        .overlay(alignment: .bottom) { HRule(color: UdhaTheme.hairline) }
    }

    private var headline: String {
        if waitingCount > 0 { return "\(waitingCount) waiting" }
        let working = sessions.filter { $0.attention(staleAfter: staleAfter) == .working }.count
        if working > 0 { return "\(working) working" }
        if sessions.isEmpty { return "no sessions" }
        return "\(sessions.count) quiet"
    }

    private func stripButton(
        _ glyph: String, tint: Color = UdhaTheme.secondary, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(base: .clear, hover: UdhaTheme.fillStrong, radius: 5)
        .help(help)
    }

    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UdhaTheme.muted)
            if isSearchFieldLive {
                TextField("", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(UdhaTheme.text(12, .regular))
                    .foregroundStyle(UdhaTheme.ink)
                    .focused($searchFieldFocused)
                    .onSubmit { openTopMatch() }
                    .onExitCommand { clearSearch() }
                    .onChange(of: searchFieldFocused) { _, focused in
                        // Clicking a pill drops first responder. Release the key
                        // gate but keep the query: clearing it here would reflow
                        // the list between mouse-down and mouse-up, and the click
                        // would land on whichever pill slid under the cursor.
                        if !focused { endSearch(clearText: false) }
                    }
            } else {
                Text(searchText)
                    .font(UdhaTheme.text(12, .regular))
                    .foregroundStyle(UdhaTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(UdhaTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(UdhaTheme.field)
        .contentShape(Rectangle())
        .onTapGesture { beginSearch() }
        .overlay(alignment: .bottom) { HRule(color: UdhaTheme.ruleSoft) }
    }

    /// The same list the Sessions board shows, read from the corner of your
    /// eye: one group per machine, that machine's folders first (collapsed
    /// the same way — `collapsedFolderIDs` is shared, so folding a folder
    /// here folds it there), then the loose sessions, all in the store's own
    /// order. A machine header only appears once more than one machine has
    /// something to show; on a Mac-only desk it would say nothing.
    private var pillList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                let shown = shownMachines
                ForEach(shown) { m in
                    if shown.count > 1 { machineRow(m) }
                    ForEach(folders(m)) { folder in
                        let rows = members(of: folder, in: m)
                        // A search hides folders holding no match; without one
                        // every folder stays, empty or not, to be dropped into.
                        if !isFiltering || !rows.isEmpty {
                            folderRow(folder, rows: rows, in: m)
                            if isExpanded(folder) {
                                ForEach(rows) { pill($0, filed: true) }
                                if rows.isEmpty { emptyFolderRow(folder, in: m) }
                            }
                        }
                    }
                    ForEach(loose(m)) { pill($0, filed: false) }
                }

                if visibleSessions.isEmpty { emptyState }
            }
        }
        .frame(maxHeight: listMaxHeight)
        // A folder created from a pill's menu opens for naming as soon as its
        // row exists — immediately on the Mac, on the echo for a box.
        .onChange(of: allFolderIDs) { _, _ in startPendingRename() }
        .task(id: pendingFolderRename) { startPendingRename() }
    }

    private func pill(_ snap: SessionSnapshot, filed: Bool) -> some View {
        let isDropTarget = dragTargetID == snap.id
        return SessionNodeView(
            snapshot: snap,
            selected: stateStore.focusedSessionID == snap.id,
            labelMode: config.config.overlay.labelMode,
            staleAfter: staleAfter,
            meter: meterBars(for: snap),
            onClick: {
                core.sessionManager.showSession(id: snap.id)
                NotificationCenter.default.post(name: .udhaFocusSession, object: snap.id)
            },
            onDuplicate: { _ = core.sessionManager.duplicate(sessionID: snap.id) },
            onRemove: { sessionPendingRemoval = snap },
            onRename: { core.sessionManager.rename(sessionID: snap.id, to: $0) },
            onRenamingChanged: onRenamingChanged,
            folders: supportsFolders(snap.hostName) ? stateStore.folders(host: snap.hostName) : nil,
            onMoveToFolder: { core.sessionManager.setFolder(sessionID: snap.id, folderID: $0) },
            onNewFolder: { newFolder(filing: snap) },
            onHide: { core.sessionManager.setHidden(sessionID: snap.id, hidden: true) }
        )
        // A filed pill sits under its folder row behind the same rule the
        // board draws down the side of a folder's cards.
        .padding(.leading, filed ? 12 : 0)
        .overlay(alignment: .leading) {
            if filed {
                Rectangle().fill(UdhaTheme.separator).frame(width: 1.5)
                    .padding(.leading, 12).padding(.vertical, 2)
            }
        }
        .padding(.top, isDropTarget ? 3 : 0)
        .overlay(alignment: .top) {
            if isDropTarget { Capsule().fill(UdhaTheme.accent).frame(height: 2) }
        }
        .draggable(snap.id.uuidString) { dragPreview(for: snap) }
        .dropDestination(for: String.self) { items, _ in
            drop(items, onPill: snap)
        } isTargeted: { targeted in
            if targeted { dragTargetID = snap.id }
            else if dragTargetID == snap.id { dragTargetID = nil }
        }
    }

    /// A pill dropped on another pill: a reorder on the same machine, and —
    /// as on the board — landing among a folder's pills files you there,
    /// landing among the loose ones takes you out. Mixing machines is never a
    /// reorder; the board hands off there, the overlay declines.
    private func drop(_ items: [String], onPill target: SessionSnapshot) -> Bool {
        dragTargetID = nil
        guard let raw = items.first,
              let droppedID = UUID(uuidString: raw),
              droppedID != target.id,
              let dragged = stateStore.snapshot(id: droppedID),
              dragged.hostName == target.hostName else { return false }
        withAnimation(UdhaTheme.quick) {
            core.sessionManager.reorder(movingID: droppedID, before: target.id)
            if supportsFolders(target.hostName), dragged.folderID != target.folderID {
                core.sessionManager.setFolder(sessionID: droppedID, folderID: target.folderID)
            }
        }
        return true
    }

    // MARK: - Machines + folders

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// This Mac first, then every box the account has paired with — the
    /// board's order, from the same directory, so the two never disagree.
    private var machines: [MachineSummary] { MachineDirectory.summaries(core: core) }

    /// Machines with a row to show. A box that is off with nothing filed
    /// earns a column on the board but not a header here, where every point
    /// of height is a pill.
    private var shownMachines: [MachineSummary] {
        machines.filter { !visible($0).isEmpty || (!isFiltering && !folders($0).isEmpty) }
    }

    private func visible(_ m: MachineSummary) -> [SessionSnapshot] {
        visibleSessions.filter { $0.hostName == m.host }
    }

    /// The folders shown for a machine: its list minus the hidden ones.
    private func folders(_ m: MachineSummary) -> [SessionFolder] {
        stateStore.folders(host: m.host).filter { !$0.hidden }
    }

    private var allFolderIDs: [UUID] {
        machines.flatMap { stateStore.folders(host: $0.host).map(\.id) }
    }

    private func members(of folder: SessionFolder, in m: MachineSummary) -> [SessionSnapshot] {
        visible(m).filter { $0.folderID == folder.id }
    }

    /// Filed nowhere, or filed in a folder this machine no longer has.
    private func loose(_ m: MachineSummary) -> [SessionSnapshot] {
        let known = Set(stateStore.folders(host: m.host).map(\.id))
        return visible(m).filter { $0.folderID.map { !known.contains($0) } ?? true }
    }

    /// Collapsed is the board's view state, shared; a search overrides it so
    /// a match inside a folded folder is never invisible.
    private func isExpanded(_ folder: SessionFolder) -> Bool {
        if isFiltering { return true }
        return !config.config.collapsedFolderIDs.contains(folder.id.uuidString)
    }

    private func toggle(_ folder: SessionFolder) {
        let key = folder.id.uuidString
        withAnimation(UdhaTheme.quick) {
            config.mutate { cfg in
                if let i = cfg.collapsedFolderIDs.firstIndex(of: key) { cfg.collapsedFolderIDs.remove(at: i) }
                else { cfg.collapsedFolderIDs.append(key) }
            }
        }
    }

    /// This Mac always; a box only once its agent speaks `folders`.
    private func supportsFolders(_ host: String?) -> Bool {
        host == nil || !core.remoteHostClient.hostFoldersUnsupported
    }

    /// The machine strip: icon, name as an eyebrow, a live dot, then how
    /// many want you and how many there are. Dropping a pill here takes it
    /// out of its folder, as the board's "Unfiled sessions" strip does.
    private func machineRow(_ m: MachineSummary) -> some View {
        let rows = visible(m)
        let needs = rows.filter { $0.attention(staleAfter: staleAfter) == .needsYou }.count
        return HStack(spacing: 6) {
            Image(systemName: m.host == nil ? "laptopcomputer" : "server.rack")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(UdhaTheme.secondary)
                .frame(width: 12)
            Text(m.name.uppercased())
                .font(UdhaTheme.text(10, .bold))
                .tracking(0.4)
                .foregroundStyle(UdhaTheme.secondary)
                .lineLimit(1)
            Circle()
                .fill(m.online ? UdhaTheme.good : UdhaTheme.tertiary)
                .frame(width: 5, height: 5)
            Spacer(minLength: 4)
            if needs > 0 {
                UdhaPill("\(needs) waiting", fg: UdhaTheme.badInk, bg: UdhaTheme.badTint, size: 10, height: 16)
            }
            Text("\(rows.count)")
                .font(UdhaTheme.text(10.5))
                .monospacedDigit()
                .foregroundStyle(UdhaTheme.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            unfile(items, on: m)
        }
    }

    private func folderRow(_ folder: SessionFolder, rows: [SessionSnapshot], in m: MachineSummary) -> some View {
        SessionFolderRow(
            folder: folder,
            count: rows.count,
            needsYou: rows.filter { $0.attention(staleAfter: staleAfter) == .needsYou }.count,
            expanded: isExpanded(folder),
            renaming: renamingFolderID == folder.id,
            draft: $folderDraft,
            focus: $folderRenameFocused,
            dropTargeted: folderDropTarget == folder.id,
            onToggle: { toggle(folder) },
            onCommitRename: { commitFolderRename(folder, host: m.host) },
            onCancelRename: cancelFolderRename
        )
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .dropDestination(for: String.self) { items, _ in
            folderDropTarget = nil
            return file(items, into: folder, on: m)
        } isTargeted: { targeted in
            if targeted { folderDropTarget = folder.id }
            else if folderDropTarget == folder.id { folderDropTarget = nil }
        }
        // The row can leave the LazyVStack mid-rename (folder ungrouped from
        // the board, scrolled away); the key gate must not stay latched.
        .onDisappear { if renamingFolderID == folder.id { cancelFolderRename() } }
        .onReceive(NotificationCenter.default.publisher(for: .udhaOverlayReleaseKeyFocus)) { _ in
            if renamingFolderID == folder.id { commitFolderRename(folder, host: m.host) }
        }
        .contextMenu { folderMenu(folder, in: m) }
    }

    /// An open folder with nothing in it, so there is still somewhere to drop.
    private func emptyFolderRow(_ folder: SessionFolder, in m: MachineSummary) -> some View {
        Text("Drop sessions here")
            .font(UdhaTheme.text(11))
            .foregroundStyle(UdhaTheme.secondary)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.leading, 30)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                file(items, into: folder, on: m)
            }
    }

    @ViewBuilder
    private func folderMenu(_ folder: SessionFolder, in m: MachineSummary) -> some View {
        Button("Rename folder") { beginFolderRename(folder.id) }
        Button(isExpanded(folder) ? "Collapse" : "Expand") { toggle(folder) }
        Button("Hide folder") { core.sessionManager.setFolderHidden(id: folder.id, hidden: true, host: m.host) }
        Divider()
        Button("Ungroup") { core.sessionManager.deleteFolder(id: folder.id, host: m.host) }
    }

    /// Pills dropped on a folder file into it. Membership stays on the
    /// session's own machine, so a pill from another box is declined.
    private func file(_ items: [String], into folder: SessionFolder, on m: MachineSummary) -> Bool {
        let dragged = items
            .flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
            .compactMap { stateStore.snapshot(id: $0) }
        guard !dragged.isEmpty, dragged.allSatisfy({ $0.hostName == m.host }),
              supportsFolders(m.host) else { return false }
        withAnimation(UdhaTheme.quick) {
            for snap in dragged where snap.folderID != folder.id {
                core.sessionManager.setFolder(sessionID: snap.id, folderID: folder.id)
            }
        }
        config.mutate { $0.collapsedFolderIDs.removeAll { $0 == folder.id.uuidString } }
        return true
    }

    private func unfile(_ items: [String], on m: MachineSummary) -> Bool {
        let dragged = items
            .flatMap { $0.split(separator: ",") }
            .compactMap { UUID(uuidString: String($0)) }
            .compactMap { stateStore.snapshot(id: $0) }
        guard !dragged.isEmpty, dragged.allSatisfy({ $0.hostName == m.host }),
              supportsFolders(m.host) else { return false }
        withAnimation(UdhaTheme.quick) {
            for snap in dragged where snap.folderID != nil {
                core.sessionManager.setFolder(sessionID: snap.id, folderID: nil)
            }
        }
        return true
    }

    /// "New folder…" from a pill's menu: make it on that pill's machine, file
    /// the pill in it, and open the row for naming once it is listed.
    private func newFolder(filing snap: SessionSnapshot) {
        let id = UUID()
        pendingFolderRename = id
        core.sessionManager.createFolder(id: id, name: "New folder", host: snap.hostName)
        core.sessionManager.setFolder(sessionID: snap.id, folderID: id)
    }

    private func startPendingRename() {
        guard let id = pendingFolderRename, allFolderIDs.contains(id) else { return }
        pendingFolderRename = nil
        beginFolderRename(id)
    }

    /// Same two-step as the pill's rename: the panel is non-activating, so
    /// the key gate opens first and focus is asked for after, with a bail-out
    /// so a grab that never lands can't pin the bloom open.
    private func beginFolderRename(_ id: UUID) {
        guard let folder = machines.lazy.compactMap({ stateStore.folder(id: id, host: $0.host) }).first else { return }
        folderDraft = folder.name
        renamingFolderID = id
        onRenamingChanged(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            folderRenameFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if renamingFolderID == id, !folderRenameFocused { cancelFolderRename() }
            }
        }
    }

    private func commitFolderRename(_ folder: SessionFolder, host: String?) {
        guard renamingFolderID == folder.id else { return }
        let text = folderDraft.trimmingCharacters(in: .whitespaces)
        renamingFolderID = nil
        folderRenameFocused = false
        onRenamingChanged(false)
        guard !text.isEmpty, text != folder.name else { return }
        core.sessionManager.renameFolder(id: folder.id, to: text, host: host)
    }

    private func cancelFolderRename() {
        guard renamingFolderID != nil else { return }
        renamingFolderID = nil
        folderRenameFocused = false
        onRenamingChanged(false)
    }

    private func unhideAll() {
        for m in machines where supportsFolders(m.host) {
            core.sessionManager.unhideAll(host: m.host)
        }
    }

    /// How tall the pill list may grow. Everything the panel isn't using for
    /// chrome, so a full desk of sessions is one glance rather than a scroll —
    /// the whole point of the overlay is not having to hunt.
    private var listMaxHeight: CGFloat {
        let chrome: CGFloat = 34 /* header */ + 30 /* footer */ + 4 /* rules */
            + (isSearchFieldLive || !searchText.isEmpty ? 27 : 0)
        let margins: CGFloat = 48
        return max(120, panelSize.height - chrome - margins)
    }

    private var emptyState: some View {
        let filtering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text(filtering ? "No match" : "No sessions yet")
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.ink)
            Text(filtering
                 ? "\(sessions.count) session\(sessions.count == 1 ? "" : "s") hidden by the filter."
                 : "Hit + to start one.")
                .font(UdhaTheme.text(11, .regular))
                .foregroundStyle(UdhaTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 18)
    }

    /// The board's "N folders and M sessions hidden · Unhide all" line takes
    /// the footer over while anything is hidden — the overlay drops hidden
    /// sessions from its ticks too, so this is where you learn why a session
    /// you know is running isn't here.
    private var footer: some View {
        let hidden = stateStore.hiddenCounts
        return HStack(spacing: 10) {
            if hidden.folders > 0 || hidden.sessions > 0 {
                let parts = [
                    hidden.folders > 0 ? "\(hidden.folders) \(hidden.folders == 1 ? "folder" : "folders")" : nil,
                    hidden.sessions > 0 ? "\(hidden.sessions) \(hidden.sessions == 1 ? "session" : "sessions")" : nil,
                ].compactMap { $0 }
                Mono(parts.joined(separator: " and ") + " hidden", size: 9.5)
                Spacer()
                Button("Unhide all") { unhideAll() }
                    .buttonStyle(.plain)
                    .font(UdhaTheme.text(10, .semibold))
                    .foregroundStyle(UdhaTheme.accentInk)
            } else {
                Mono("click = focus terminal", size: 9.5)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { HRule(color: UdhaTheme.ruleSoft) }
    }

    private func dragPreview(for snap: SessionSnapshot) -> some View {
        let style = UdhaSessionStyle(snapshot: snap, staleAfter: staleAfter)
        return HStack(spacing: 8) {
            StateMark(color: style.mark, filled: style.filled)
            Text(snap.label)
                .font(UdhaTheme.text(12, .semibold))
                .foregroundStyle(UdhaTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .udhaCard(radius: 8)
    }

    /// Six log-scaled bars off the tail of the session's output. A real signal
    /// (how much it's emitting) rather than a decorative waveform — a silent
    /// session shows stubs, a streaming one shows a full block.
    private func meterBars(for snap: SessionSnapshot) -> [CGFloat] {
        guard let lines = core.sessionManager.buffer(for: snap.id)?.recent(lines: 6),
              !lines.isEmpty else {
            return Array(repeating: 2, count: 6)
        }
        var bars = lines.suffix(6).map { line -> CGFloat in
            let n = Double(line.count)
            guard n > 0 else { return 2 }
            return CGFloat(min(20, 3 + 5 * log2(n + 1)))
        }
        while bars.count < 6 { bars.insert(2, at: 0) }
        return bars
    }

    // MARK: - Search plumbing

    /// The panel is a `.nonactivatingPanel` that refuses to become key, so a
    /// click can never hand a text field first responder on its own. The gate
    /// has to be opened first and focus requested after — the same two-step the
    /// inline rename uses, which is also why the field is only materialized
    /// once editing starts.
    private func beginSearch() {
        guard !isSearchFieldLive else { return }
        isSearchFieldLive = true
        onSearchFocusChanged(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            searchFieldFocused = true
            // If the field never took focus, the focus-lost path can't fire and
            // nothing would release the key gate — the bloom would stay pinned
            // open forever. Back out rather than latch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if isSearchFieldLive, !searchFieldFocused { endSearch(clearText: false) }
            }
        }
    }

    private func endSearch(clearText: Bool) {
        guard isSearchFieldLive else { return }
        isSearchFieldLive = false
        searchFieldFocused = false
        onSearchFocusChanged(false)
        if clearText { searchText = "" }
    }

    private func clearSearch() {
        endSearch(clearText: true)
        searchText = ""
    }

    /// Enter opens the top match's Terminal window — type three letters, hit
    /// return, you're in the right session without touching the mouse.
    private func openTopMatch() {
        guard let top = visibleSessions.first else { return }
        clearSearch()
        core.sessionManager.showSession(id: top.id)
    }

    // MARK: - Window plumbing

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func openNewSession() {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .udhaRequestNewSession, object: nil)
        }
    }

    private func openSettings() {
        openMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .udhaRequestSettings, object: nil)
        }
    }
}

extension Notification.Name {
    static let udhaRequestNewSession = Notification.Name("udha.requestNewSession")
    static let udhaRequestSettings   = Notification.Name("udha.requestSettings")
}
