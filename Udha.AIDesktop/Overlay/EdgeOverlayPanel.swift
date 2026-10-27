import AppKit
import SwiftUI

/// A borderless, non-activating panel pinned to the right/left edge of a screen.
/// Always floats on top. Mouse events outside the interactive mask pass through
/// to windows underneath.
final class EdgeOverlayPanel: NSPanel {
    /// The inline rename field needs real keyboard focus, but at any other
    /// time the panel must never steal key from the frontmost app. Toggled by
    /// EdgeOverlayController while a rename is active. Being a
    /// `.nonactivatingPanel`, becoming key doesn't activate Udha itself.
    var allowsKeyFocus = false
    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .none
    }

    /// Escape must always be able to get out of the bloom. While a text field
    /// in the bloom holds first responder it handles Escape itself; once the
    /// field has quietly lost first responder — the very state that used to pin
    /// the bloom open — the chain ends here instead, so release every editor.
    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .udhaOverlayReleaseKeyFocus, object: nil)
    }
}

/// Hosts the SwiftUI overlay and controls hit-testing so the empty parts of
/// the panel don't eat mouse events.
final class EdgeOverlayHostingView<Content: View>: NSHostingView<Content> {
    /// A closure that returns the current interactive rect in view coordinates.
    /// Points outside this rect pass through to the window below.
    var interactiveRectProvider: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let rect = interactiveRectProvider()
        guard rect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// The overlay's panel is never key — `canBecomeKey` is false except during
    /// an inline rename — so AppKit treats *every* click on it as a "first
    /// mouse" and swallows it to activate the window instead of delivering it.
    /// That's what made tiles need a double-click: the first click was eaten,
    /// the second landed. The overlay is a click-through HUD over whatever app
    /// you're actually in, so it should always act on the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
