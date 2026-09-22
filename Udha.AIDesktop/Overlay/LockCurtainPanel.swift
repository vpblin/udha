import AppKit

/// Full-screen privacy curtain shown while the input lock is engaged: frosted
/// blur over everything on the display. Click-through (the mouse is dead while
/// locked, and during password fallback clicks must reach the auth dialog).
///
/// Two levels, switched by `LockCurtainController`:
/// - locked: `.screenSaver` — covers app windows, notification banners, menu bar.
/// - authenticating: just below `.modalPanel` — app content stays hidden but the
///   LocalAuthentication dialog (a system panel) renders above the curtain, so
///   the Touch ID prompt / password sheet is visible and clickable.
final class LockCurtainPanel: NSPanel {
    static let lockedLevel: NSWindow.Level = .screenSaver
    static let authLevel = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue - 1)

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = Self.lockedLevel
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false          // the blur view composits behind-window content
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        self.isFloatingPanel = true
        self.appearance = NSAppearance(named: .darkAqua) // consistent dark frost
    }
}
