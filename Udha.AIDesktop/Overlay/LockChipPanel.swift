import AppKit
import SwiftUI

/// The "input is locked" badge's window: borderless, non-activating, fully
/// click-through. Deliberately NOT content inside `EdgeOverlayPanel` — that
/// panel only reveals itself on hover-bloom, and hover is impossible while the
/// lock's tap swallows mouse-moved events before any window sees them.
final class LockChipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above .statusBar and full-screen apps; must be visible wherever the
        // user is looking, whatever they were running.
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        // Fully click-through: the mouse is dead anyway, and this must never
        // sit between the user and the LocalAuthentication dialog.
        self.ignoresMouseEvents = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        self.isFloatingPanel = true
    }
}
