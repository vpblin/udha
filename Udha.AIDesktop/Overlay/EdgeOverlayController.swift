import AppKit
import SwiftUI
import Combine

@MainActor
final class EdgeOverlayController: NSObject {
    private weak var core: AppCore?
    private var panel: EdgeOverlayPanel?
    private var hostingView: EdgeOverlayHostingView<EdgeOverlayHost>?
    private var screenObserver: NSObjectProtocol?
    private let state = EdgeOverlayState()
    private var configCancellable: AnyCancellable?
    private var driverCancellable: AnyCancellable?
    private var driverPinned = false
    private var renameCancellable: AnyCancellable?
    private var expansionCancellable: AnyCancellable?
    private var releaseCancellable: AnyCancellable?
    private var keyResignObserver: NSObjectProtocol?
    private var hoverWatchdog: Timer?
    /// When the cursor was first seen off the panel while bloomed. Drives the
    /// grace period before a stale key-focus gate is force-released.
    private var cursorLeftPanelAt: Date?
    /// How long the bloom tolerates a key-focus gate held by a panel that isn't
    /// key, with the cursor off it. Long enough that a legitimate field taking
    /// focus is never cut short, short enough that a latch isn't a dead end.
    private static let staleKeyFocusGrace: TimeInterval = 2.0
    /// Set by the minimize button. Suppresses `present()` until `reveal()`
    /// is called (e.g. from a Dock-icon reopen). Runtime-only — not persisted,
    /// so an app relaunch always brings the overlay back.
    private var isMinimized: Bool = false

    init(core: AppCore) {
        self.core = core
        super.init()
        present()
        observeScreens()
        observeConfig()
        observeRename()
        observeKeyResign()
        observeKeyFocusRelease()
        observeExpansion()
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = keyResignObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func present() {
        guard let core else { Log.app.error("overlay.present: core is nil"); return }
        if !core.config.config.overlay.enabled || isMinimized {
            Log.app.info("overlay.present: skipped (enabled=\(core.config.config.overlay.enabled) minimized=\(isMinimized))")
            dismiss()
            return
        }
        guard let screen = targetScreen() else {
            Log.app.error("overlay.present: no screen available")
            return
        }
        let panelFrame = panelFrame(for: screen)
        Log.app.info("overlay.present: edge=\(core.config.config.overlay.edge.rawValue) screen=\(screen.localizedName) frame=\(NSStringFromRect(panelFrame))")
        let panel = self.panel ?? EdgeOverlayPanel(contentRect: panelFrame)
        panel.setFrame(panelFrame, display: false)

        let host = EdgeOverlayHost(
            core: core,
            config: core.config,
            stateStore: core.stateStore,
            state: state,
            panelSize: panelFrame.size,
            onMinimize: { [weak self] in self?.minimize() }
        )
        let hosting = hostingView ?? EdgeOverlayHostingView(rootView: host)
        hosting.rootView = host
        hosting.frame = NSRect(origin: .zero, size: panelFrame.size)
        hosting.interactiveRectProvider = { [weak self] in
            self?.currentInteractiveRect(panelSize: panelFrame.size) ?? .zero
        }

        panel.contentView = hosting
        panel.orderFrontRegardless()
        panel.level = .statusBar

        self.panel = panel
        self.hostingView = hosting
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    /// Hide the overlay entirely until `reveal()` is called. The bloom is also
    /// collapsed so a later `present()` doesn't flash open mid-air.
    func minimize() {
        isMinimized = true
        state.bloomPending = false
        state.isExpanded = false
        dismiss()
    }

    /// Bring the overlay back after a minimize. Called from the Dock-icon
    /// reopen handler in AppDelegate.
    func reveal() {
        guard isMinimized else {
            // Not minimized — still re-present so a stale panel reorders to front.
            present()
            return
        }
        isMinimized = false
        present()
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.present() }
        }
    }

    private func observeConfig() {
        // Re-present on config changes that affect geometry (edge / trigger width / enabled).
        configCancellable = NotificationCenter.default
            .publisher(for: .udhaOverlayConfigChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.present() }
            }
        // The UI driver (`-UDHAUIDriver 1`) can bloom or collapse the overlay
        // without a pointer, for screenshots and self-tests.
        driverCancellable = NotificationCenter.default
            .publisher(for: .udhaOverlayDriverBloom)
            .sink { [weak self] note in
                let open = (note.object as? Bool) ?? true
                Task { @MainActor in
                    guard let self else { return }
                    // Pinned open until the driver collapses it: the cursor
                    // watchdog would otherwise close it within a beat.
                    self.driverPinned = open
                    withAnimation(OverlayTheme.bloomSpring) { self.state.isExpanded = open }
                }
            }
    }

    /// While a text field in the bloom is active (inline rename, header search)
    /// the panel must be able to become key; the rest of the time it must never
    /// steal key from the frontmost app. The panel is non-activating, so this
    /// grabs keyboard focus without activating Udha or switching apps.
    private func observeRename() {
        renameCancellable = NotificationCenter.default
            .publisher(for: .udhaOverlayKeyFocusActive)
            .sink { [weak self] note in
                let active = (note.userInfo?["active"] as? Bool) ?? false
                Task { @MainActor in
                    guard let self, let panel = self.panel else { return }
                    panel.allowsKeyFocus = active
                    if active {
                        panel.makeKey()
                    } else if panel.isKeyWindow {
                        panel.resignKey()
                    }
                }
            }
    }

    /// The key-focus gate is a hard veto on collapse, so anything that leaves
    /// it standing wedges the bloom open with no way out — and SwiftUI's
    /// `@FocusState` does *not* report focus loss when the panel merely stops
    /// being key (clicking into another app mid-search, a session's Terminal
    /// window coming forward). Losing key means the field can't be typed into
    /// any more, so that is exactly the moment to drop the gate.
    private func observeKeyResign() {
        keyResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let resigned = (note.object as? NSWindow).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self, let panel = self.panel,
                      resigned == ObjectIdentifier(panel) else { return }
                self.releaseKeyFocusGate(reason: "panel resigned key")
            }
        }
    }

    /// Anything may demand that every editor in the bloom close — Escape
    /// reaching the panel, the watchdog below, a field backing out. Mirror it
    /// into our own state so the veto drops even when the view that owned the
    /// field is already gone.
    private func observeKeyFocusRelease() {
        releaseCancellable = NotificationCenter.default
            .publisher(for: .udhaOverlayReleaseKeyFocus)
            .sink { [weak self] _ in
                Task { @MainActor in self?.clearKeyFocusState() }
            }
    }

    private func clearKeyFocusState() {
        state.isRenaming = false
        state.isSearching = false
        state.keyFocusRaisedAt = nil
        panel?.allowsKeyFocus = false
    }

    /// Drop the gate and tell the bloom's fields to stop editing.
    private func releaseKeyFocusGate(reason: String) {
        guard state.holdsKeyboardFocus else { return }
        Log.app.info("overlay: releasing key-focus gate (\(reason))")
        clearKeyFocusState()
        NotificationCenter.default.post(name: .udhaOverlayReleaseKeyFocus, object: nil)
    }

    /// Collapse is normally driven by the hover-exit phase of
    /// `.onContinuousHover` on the bloom. That event is not guaranteed to
    /// arrive: a drag session swallows tracking-area exits, raising another
    /// app's window mid-hover can drop it, and the rename gate below
    /// deliberately ignores the one exit that mattered. Any missed exit wedges
    /// the bloom open permanently, because nothing else ever re-evaluates.
    ///
    /// So while expanded, sample where the cursor actually is and collapse once
    /// it is provably off the panel. The event path stays the fast path; this
    /// only ever fires for exits that path missed.
    private func observeExpansion() {
        expansionCancellable = state.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                Task { @MainActor in
                    guard let self else { return }
                    if expanded { self.startHoverWatchdog() } else { self.stopHoverWatchdog() }
                }
            }
    }

    private func startHoverWatchdog() {
        guard hoverWatchdog == nil else { return }
        cursorLeftPanelAt = nil
        // Default run-loop mode on purpose: it stays quiet during the modal
        // tracking loops of a drag or a scroll — moments when the cursor may
        // legitimately be off-panel — and resumes the instant they end.
        hoverWatchdog = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collapseIfCursorEscaped() }
        }
    }

    private func stopHoverWatchdog() {
        hoverWatchdog?.invalidate()
        hoverWatchdog = nil
        cursorLeftPanelAt = nil
    }

    private func collapseIfCursorEscaped() {
        guard state.isExpanded, let panel else { stopHoverWatchdog(); return }
        guard !driverPinned else { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else {
            cursorLeftPanelAt = nil
            return
        }
        if cursorLeftPanelAt == nil { cursorLeftPanelAt = Date() }

        if state.holdsKeyboardFocus {
            // An open text field owns the bloom until it closes — you can be
            // typing with the mouse parked anywhere. But only while the panel
            // actually *is* key. A gate still standing after the panel lost key
            // is a latch: the field can't be typed into, can't be escaped, and
            // nothing on the event path clears it, so the bloom stays pinned
            // open forever. Give it a beat, then take it away.
            guard !panel.isKeyWindow else { return }
            let raised = max(cursorLeftPanelAt ?? .distantPast,
                             state.keyFocusRaisedAt ?? .distantPast)
            guard Date().timeIntervalSince(raised) > Self.staleKeyFocusGrace else { return }
            releaseKeyFocusGate(reason: "held by a panel that isn't key, cursor off panel")
        }

        Log.app.info("overlay: collapsing via cursor watchdog (missed hover-exit)")
        withAnimation(OverlayTheme.bloomSpring) { state.isExpanded = false }
        cursorLeftPanelAt = nil
    }

    /// The display the panel pins to. A configured display wins; if it isn't
    /// attached (unplugged, Sidecar disconnected) fall back to the active one
    /// rather than leaving the overlay on a screen that no longer exists.
    private func targetScreen() -> NSScreen? {
        if let wanted = core?.config.config.overlay.displayID,
           let match = NSScreen.screens.first(where: { $0.udhaDisplayID == wanted }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let width: CGFloat = 300
        let visible = screen.visibleFrame
        guard let edge = core?.config.config.overlay.edge else {
            return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        }
        switch edge {
        case .right:
            return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
        case .left:
            return NSRect(x: visible.minX, y: visible.minY, width: width, height: visible.height)
        }
    }

    private func currentInteractiveRect(panelSize: CGSize) -> CGRect {
        let edge = core?.config.config.overlay.edge ?? .right
        // Hit zone is a single point flush with the absolute screen edge — the
        // cursor must be pressed against the wall, so mouse travel near the
        // right side doesn't accidentally cover windows. A dwell timer in
        // EdgeOverlayHost further filters out brushing motions through this strip.
        let trigger: CGFloat = 1
        if state.isExpanded {
            // Whole panel is interactive when bloomed — the vertical stack uses all of it.
            return CGRect(origin: .zero, size: panelSize)
        } else {
            switch edge {
            case .right:
                return CGRect(x: panelSize.width - trigger, y: 0, width: trigger, height: panelSize.height)
            case .left:
                return CGRect(x: 0, y: 0, width: trigger, height: panelSize.height)
            }
        }
    }
}

/// Shared expansion state — the NSHostingView reads this synchronously for hit-testing
/// while SwiftUI uses it as the source of truth for bloom animation.
@MainActor
final class EdgeOverlayState: ObservableObject {
    @Published var isExpanded: Bool = false
    /// Set true while a dwell timer is queued to bloom. Clearing it cancels
    /// the pending bloom — used when the cursor leaves the edge before the
    /// dwell elapses (i.e. a brushing motion past the strip).
    var bloomPending: Bool = false
    /// Set true while a session tile's inline rename field is open. Blocks the
    /// hover-out collapse so the bloom can't vanish mid-edit (typing doesn't
    /// count as hover, and the field grabbing key focus can drop the hover).
    var isRenaming: Bool = false
    /// Set true while the header search field holds keyboard focus. Same
    /// consequences as `isRenaming`.
    var isSearching: Bool = false
    /// Whether anything in the bloom currently owns a text field. The panel may
    /// become key only while this holds, and the hover-out collapse is blocked
    /// for the duration. It's the OR of both owners rather than a single flag so
    /// that one field closing as another opens doesn't shut the gate on the one
    /// that just took focus.
    var holdsKeyboardFocus: Bool { isRenaming || isSearching }
    /// When the gate above was raised, cleared when it drops. The collapse
    /// watchdog needs it so a gate raised while the cursor is already off the
    /// panel still gets its full grace before being force-released.
    var keyFocusRaisedAt: Date?
}

struct EdgeOverlayHost: View {
    let core: AppCore
    @Bindable var config: ConfigStore
    @Bindable var stateStore: SessionStateStore
    @ObservedObject var state: EdgeOverlayState
    let panelSize: CGSize
    let onMinimize: () -> Void
    @State private var collapseTask: DispatchWorkItem?

    var body: some View {
        // Hover handling is delegated to EdgeOverlayView, which attaches the
        // tracking area to either the 1pt edge strip (collapsed) or the bloom
        // stack (expanded). Applying it at this level would install a tracking
        // area on the full 300pt panel, which fires regardless of hitTest —
        // so the overlay would bloom for any cursor inside the panel rect.
        EdgeOverlayView(
            core: core,
            isExpanded: Binding(
                get: { state.isExpanded },
                set: { state.isExpanded = $0 }
            ),
            config: config,
            stateStore: stateStore,
            panelSize: panelSize,
            onHoverChanged: handleHoverChange,
            onRenamingChanged: handleRenamingChange,
            onSearchFocusChanged: handleSearchFocusChange,
            onMinimize: onMinimize
        )
    }

    private func handleRenamingChange(_ active: Bool) {
        state.isRenaming = active
        syncKeyboardFocus()
    }

    private func handleSearchFocusChange(_ active: Bool) {
        state.isSearching = active
        syncKeyboardFocus()
    }

    /// The controller owns the NSPanel and flips its key-focus capability.
    /// Always posts the OR of both text-field owners — see `holdsKeyboardFocus`.
    private func syncKeyboardFocus() {
        state.keyFocusRaisedAt = state.holdsKeyboardFocus ? (state.keyFocusRaisedAt ?? Date()) : nil
        NotificationCenter.default.post(
            name: .udhaOverlayKeyFocusActive,
            object: nil,
            userInfo: ["active": state.holdsKeyboardFocus]
        )
    }

    private func handleHoverChange(_ active: Bool) {
        if active {
            collapseTask?.cancel()
            collapseTask = nil
            guard !state.isExpanded, !state.bloomPending else { return }
            // Dwell — the cursor must remain pressed against the edge for
            // a beat before bloom. A brush past the 1pt strip fires .active
            // then .ended in <50ms, so the bloom never commits.
            state.bloomPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                guard state.bloomPending else { return }
                state.bloomPending = false
                withAnimation(OverlayTheme.bloomSpring) { state.isExpanded = true }
            }
        } else {
            // Cancel any pending dwell — the cursor left before it could commit.
            state.bloomPending = false
            // Never collapse out from under an open text field.
            guard !state.holdsKeyboardFocus else { return }
            // Debounce — hit-testing along the visible crescent can momentarily drop
            // outside the interactive rect mid-movement; don't flicker closed for that.
            collapseTask?.cancel()
            let work = DispatchWorkItem {
                withAnimation(OverlayTheme.bloomSpring) { state.isExpanded = false }
            }
            collapseTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }
}

extension NSScreen {
    /// `CGDirectDisplayID` for this screen — the only stable-ish handle AppKit
    /// exposes for "which physical monitor". Persisted in `OverlayConfig.displayID`.
    var udhaDisplayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension Notification.Name {
    static let udhaOverlayConfigChanged = Notification.Name("udha.overlayConfigChanged")
    /// `object` is a Bool: true blooms the overlay, false collapses it. Dev only.
    static let udhaOverlayDriverBloom = Notification.Name("udha.overlayDriverBloom")
    static let udhaOverlayKeyFocusActive = Notification.Name("udha.overlayKeyFocusActive")
    /// Broadcast demand that every text field in the bloom stop editing.
    static let udhaOverlayReleaseKeyFocus = Notification.Name("udha.overlayReleaseKeyFocus")
}
