import AppKit
import SwiftUI

/// Owns the full-screen privacy curtains — one per attached display, always
/// every display (a curtain that covers only one monitor hides nothing).
/// Owned by `InputLockManager`, like `LockChipController`, so unlock
/// structurally cannot forget to drop the curtain.
@MainActor
final class LockCurtainController {
    private unowned let manager: InputLockManager
    private var panels: [LockCurtainPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var isPresented = false
    private var loweredForAuth = false

    init(manager: InputLockManager) {
        self.manager = manager
    }

    func present() {
        isPresented = true
        rebuildPanels()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isPresented else { return }
                    self.rebuildPanels()
                }
            }
        }
    }

    func dismiss() {
        isPresented = false
        loweredForAuth = false
        for p in panels { p.orderOut(nil) }
        panels = []
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    /// While the LocalAuthentication dialog is up, drop below `.modalPanel` so
    /// the system prompt renders above the curtain (app content stays hidden —
    /// only windows between level 7 and the dialog could peek, briefly).
    func setAuthPresentation(lowered: Bool) {
        loweredForAuth = lowered
        let level = lowered ? LockCurtainPanel.authLevel : LockCurtainPanel.lockedLevel
        for p in panels { p.level = level }
    }

    private func rebuildPanels() {
        for p in panels { p.orderOut(nil) }
        panels = []
        for screen in NSScreen.screens {
            let panel = LockCurtainPanel(contentRect: screen.frame)
            let host = NSHostingView(rootView: LockCurtainView(manager: manager))
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            panel.contentView = host
            panel.setFrame(screen.frame, display: true) // full frame, menu bar included
            panel.level = loweredForAuth ? LockCurtainPanel.authLevel : LockCurtainPanel.lockedLevel
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}
