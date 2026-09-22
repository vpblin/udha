import AppKit
import SwiftUI

/// Owns the lock-badge panels — one per attached display by default, because
/// the "you are locked" signal must be wherever the person is looking; a
/// single `.canJoinAllSpaces` panel still lives on exactly one display.
/// Owned by `InputLockManager`, so unlock structurally cannot forget to
/// dismiss it.
@MainActor
final class LockChipController {
    private unowned let manager: InputLockManager
    private let config: ConfigStore
    private var panels: [LockChipPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var isPresented = false

    private static let chipSize = NSSize(width: 260, height: 64)

    init(manager: InputLockManager, config: ConfigStore) {
        self.manager = manager
        self.config = config
    }

    func present() {
        isPresented = true
        rebuildPanels()
        if screenObserver == nil {
            // Critical while locked: unplugging the only monitor showing the
            // chip must not strand the user with no explanation.
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
        for p in panels { p.orderOut(nil) }
        panels = []
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    private func rebuildPanels() {
        for p in panels { p.orderOut(nil) }
        panels = []

        let wanted = targetScreens()
        for screen in wanted {
            let panel = LockChipPanel(contentRect: NSRect(origin: .zero, size: Self.chipSize))
            let host = NSHostingView(rootView: LockChipView(manager: manager))
            host.frame = NSRect(origin: .zero, size: Self.chipSize)
            panel.contentView = host
            panel.setFrame(frame(on: screen), display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        guard let wantedID = config.config.inputLock.chipDisplayID else { return all }
        let match = all.filter { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == wantedID
        }
        // A stored ID that isn't attached falls back to all displays — same
        // tolerance as OverlayConfig.displayID.
        return match.isEmpty ? all : match
    }

    /// Top corner opposite the edge overlay, so the two HUDs never collide.
    /// visibleFrame already excludes the menu bar.
    private func frame(on screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        let size = Self.chipSize
        let insetX: CGFloat = 16
        let insetY: CGFloat = 12
        let x: CGFloat
        switch config.config.overlay.edge {
        case .right: x = v.minX + insetX                    // overlay right → chip top-left
        case .left: x = v.maxX - size.width - insetX        // overlay left → chip top-right
        }
        let y = v.maxY - size.height - insetY
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
