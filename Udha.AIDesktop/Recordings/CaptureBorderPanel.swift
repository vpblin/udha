import AppKit
import SwiftUI

/// The red guides drawn on the desktop around whatever is about to be — or is
/// being — recorded.
///
/// Each guide is the region that actually reaches a master: the screen is
/// aspect-filled, so on a 32:9 display the wide master keeps a centre slice and
/// the vertical one keeps a narrower slice still. Drawing both means the crop is
/// something you arrange your windows inside, rather than something you discover
/// when you watch the file back. Widest guide first; anything outside the
/// outermost one is not in any master.
///
/// **The outline is four thin strips, never a panel over the target.** A single
/// window covering the recorded area was a real bug, not a hypothetical one: a
/// full-cover panel puts the target window into `NSWindowOcclusionState`
/// occluded, the app below stops drawing, and ScreenCaptureKit records a
/// perfectly black movie. The strips also mean that even if the capture filter
/// ever failed to exclude them, the damage would be a hairline at the edge
/// rather than a black frame.
@MainActor
final class CaptureBorderController {
    static let shared = CaptureBorderController()

    enum Style {
        /// Hovering a row in the picker — heavier, because it is answering
        /// "which screen is this?" from across the desk.
        case preview
        /// Rolling.
        case recording

        var lineWidth: CGFloat { self == .preview ? 6 : 4 }
    }

    private struct Guide {
        var target: ScreenCaptureTarget
        var crops: [CompositorLayout.CropGuide]
        var style: Style
    }

    private var recording: Guide?
    private var preview: Guide?

    /// Where the guides sit on the target, normalised (0…1, y from the bottom,
    /// matching both AppKit and Core Image). Dragging any edge moves this, and
    /// `RecordingCenter` copies it onto the recording so a re-render months
    /// later reproduces the same crop.
    private(set) var cropCentre = CGPoint(x: 0.5, y: 0.5)
    /// How much of the largest possible crop to keep. Dragging a corner changes
    /// it; the aspect is fixed, so one scalar is the whole of "resize".
    private(set) var cropScale: CGFloat = 1
    /// True while the picker is open: the strips take mouse events and get a
    /// wider grab area. Off during a take, when they must be click-through.
    private var isAdjustable = false
    private var adjustingTarget: ScreenCaptureTarget?
    /// One entry per drawn rectangle; each is the four strips of one outline.
    private var outlines: [OutlineWindows] = []
    private var follow: Timer?
    private var screenObserver: NSObjectProtocol?

    /// Window numbers of every strip on screen, for the capture filter to
    /// exclude. Cheap to over-supply: a window id that isn't in the shareable
    /// list is simply not matched.
    var windowIDs: [CGWindowID] {
        outlines.flatMap(\.windowIDs)
            + (countdownPanel.windowNumber > 0 ? [CGWindowID(countdownPanel.windowNumber)] : [])
    }

    // MARK: - Picker preview

    func showPreview(_ target: ScreenCaptureTarget, guides: [CompositorLayout.CropGuide], adjustable: Bool = false) {
        // A different target starts from the middle again — a crop dragged to
        // the left of one screen means nothing on the next.
        if adjustingTarget != target {
            adjustingTarget = target
            cropCentre = CGPoint(x: 0.5, y: 0.5)
            cropScale = 1
        }
        isAdjustable = adjustable
        preview = Guide(target: target, crops: guides, style: .preview)
        rebuild()
    }

    func clearPreview() {
        guard preview != nil else { return }
        preview = nil
        isAdjustable = false
        rebuild()
    }

    /// Called by the strips as they are dragged. `delta` is in screen points.
    fileprivate func nudge(by delta: CGSize) {
        guard let bounds = active.flatMap({ Self.bounds(for: $0.target) }),
              bounds.width > 0, bounds.height > 0 else { return }
        cropCentre = CGPoint(
            x: min(1, max(0, cropCentre.x + delta.width / bounds.width)),
            y: min(1, max(0, cropCentre.y + delta.height / bounds.height))
        )
        rebuild()
    }

    /// Called by the corner handles. Takes the pointer in screen coordinates
    /// and answers with the scale that puts the corner under it.
    ///
    /// Measured from the centre rather than accumulated from deltas, so the
    /// handle tracks the pointer exactly instead of drifting away from it over
    /// a long drag.
    fileprivate func resize(towards location: NSPoint) {
        guard let guide = active, let bounds = Self.bounds(for: guide.target),
              let primary = guide.crops.first else { return }
        let full = CompositorLayout.cropRegion(of: bounds, aspect: primary.aspect, centre: cropCentre, scale: 1)
        guard full.width > 0, full.height > 0 else { return }
        let centreX = bounds.minX + cropCentre.x * bounds.width
        let centreY = bounds.minY + cropCentre.y * bounds.height
        let reachX = abs(location.x - centreX) / (full.width / 2)
        let reachY = abs(location.y - centreY) / (full.height / 2)
        cropScale = min(1, max(CompositorLayout.minimumCropScale, max(reachX, reachY)))
        rebuild()
    }

    // MARK: - Countdown

    /// Counts down on the target, then returns. The guides go up first, so the
    /// last seconds before it rolls are spent looking at the frame you are
    /// about to record rather than at a number in a corner.
    ///
    /// Deliberately finishes *before* capture starts, which is what makes the
    /// numerals impossible to film — there is nothing recording yet.
    func runCountdown(from seconds: Int, on target: ScreenCaptureTarget?,
                      guides: [CompositorLayout.CropGuide],
                      tick: @MainActor (Int) -> Void) async {
        guard seconds > 0 else { return }
        if let target { showRecording(target, guides: guides) }
        defer { countdownPanel.orderOut(nil) }

        // A camera-only take has no target to centre on, so the count lands on
        // whichever screen the user is looking at.
        let stage = target.flatMap { Self.bounds(for: $0) } ?? NSScreen.main?.frame

        for remaining in stride(from: seconds, through: 1, by: -1) {
            tick(remaining)
            if let bounds = stage {
                countdownPanel.show(remaining, centredIn: bounds)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
        }
    }

    private let countdownPanel = CaptureCountdownPanel()

    // MARK: - Recording

    func showRecording(_ target: ScreenCaptureTarget, guides: [CompositorLayout.CropGuide]) {
        isAdjustable = false
        recording = Guide(target: target, crops: guides, style: .recording)
        rebuild()
        startFollowing()
    }

    func hideRecording() {
        guard recording != nil else { return }
        recording = nil
        rebuild()
    }

    // MARK: - Drawing

    /// The preview wins while the picker is open — it is the thing under the
    /// pointer, and two guides at once would be noise.
    private var active: Guide? { preview ?? recording }

    private func rebuild() {
        guard let guide = active, let bounds = Self.bounds(for: guide.target) else {
            outlines.forEach { $0.dismiss() }
            outlines = []
            if recording == nil { stopFollowing() }
            return
        }

        let crops = Self.crops(guide.crops, in: bounds)
        while outlines.count > crops.count {
            outlines.removeLast().dismiss()
        }
        while outlines.count < crops.count {
            outlines.append(OutlineWindows())
        }
        for (index, crop) in crops.enumerated() {
            // The outermost guide carries the full weight; an inner one is
            // drawn thinner so the two never read as the same boundary. The
            // weight alone doesn't say *which is which*, though, so each rect
            // is tagged with the master it feeds.
            let width = index == 0 ? guide.style.lineWidth : max(2, guide.style.lineWidth - 2)
            outlines[index].place(
                rect: crop.rect,
                lineWidth: width,
                label: crop.label,
                labelRow: index,
                draggable: isAdjustable,
                // Corners on the outer rectangle only: one scale drives both,
                // and two sets of handles would just be something else to
                // mis-grab.
                resizable: isAdjustable && index == 0,
                clampedTo: bounds
            )
        }
    }

    /// One rect per crop, all centred on the target. With none at all (nothing
    /// being rendered), the target's own bounds are outlined instead, so the
    /// guide never silently disappears.
    private static func crops(
        _ guides: [CompositorLayout.CropGuide], in bounds: NSRect
    ) -> [(rect: NSRect, label: String)] {
        guard !guides.isEmpty else { return [(bounds, "RECORDING")] }
        return guides.map {
            (
                CompositorLayout.cropRegion(
                    of: bounds, aspect: $0.aspect,
                    centre: shared_.cropCentre, scale: shared_.cropScale
                ),
                $0.label
            )
        }
    }

    /// `crops` is static so it can be reasoned about on its own; this is the
    /// one thing it needs from the live controller.
    private static var shared_: CaptureBorderController { .shared }

    /// Exposed for the strips, which live outside the controller.
    fileprivate static var controller: CaptureBorderController { .shared }

    private func startFollowing() {
        guard follow == nil else { return }
        // A window target moves and resizes; a display target can be
        // rearranged out from under us.
        follow = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    private func stopFollowing() {
        follow?.invalidate()
        follow = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    // MARK: - Geometry

    /// Screen coordinates for a capture target, in AppKit's space.
    static func bounds(for target: ScreenCaptureTarget) -> NSRect? {
        switch target {
        case .display(let id):
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }?.frame
        case .window(let id):
            guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
                  let bounds = info.first?[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return flipped(rect)
        }
    }

    /// CoreGraphics window bounds are top-left origin against the primary
    /// display; AppKit frames are bottom-left origin. Flipping about the
    /// primary screen's top edge is the conversion — using the screen the
    /// window happens to be on would be wrong on a multi-display desk.
    private static func flipped(_ rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return NSRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// The four strips making up one rectangle.
@MainActor
private final class OutlineWindows {
    private let panels: [CaptureBorderPanel]
    private let corners: [CaptureCornerPanel]
    private let tag = CaptureTagPanel()

    init() {
        panels = (0..<4).map { _ in CaptureBorderPanel() }
        corners = (0..<4).map { _ in CaptureCornerPanel() }
    }

    var windowIDs: [CGWindowID] {
        (panels.map { $0 as NSPanel } + corners.map { $0 as NSPanel } + [tag])
            .compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil }
    }

    /// Strips straddle the rectangle's edges and are kept inside `clamp`, so a
    /// guide flush with a screen edge is still visible. Straddling means at
    /// most half a line width overlaps the recorded region — enough to be
    /// excluded from the capture, never enough to occlude a window.
    func place(rect: NSRect, lineWidth w: CGFloat, label: String, labelRow: Int,
               draggable: Bool, resizable: Bool = false, clampedTo clamp: NSRect) {
        // A 4pt line is not a grab target. While the picker is open the strips
        // are widened into a grab band with the line drawn down its middle, so
        // the edge can be caught without pixel-hunting; during a take they go
        // back to the hairline, click-through version.
        let thickness = draggable ? max(w, 16) : w
        let half = thickness / 2
        let frames = [
            NSRect(x: rect.minX - half, y: rect.maxY - half, width: rect.width + thickness, height: thickness),
            NSRect(x: rect.minX - half, y: rect.minY - half, width: rect.width + thickness, height: thickness),
            NSRect(x: rect.minX - half, y: rect.minY - half, width: thickness, height: rect.height + thickness),
            NSRect(x: rect.maxX - half, y: rect.minY - half, width: thickness, height: rect.height + thickness),
        ]
        for (index, (panel, frame)) in zip(panels, frames).enumerated() {
            panel.configure(lineWidth: w, horizontal: index < 2, draggable: draggable)
            panel.setFrame(Self.clamp(frame, into: clamp), display: false)
            panel.orderFrontRegardless()
        }

        if resizable {
            let side = CaptureCornerPanel.side
            let half = side / 2
            let spots = [
                NSPoint(x: rect.minX, y: rect.maxY),
                NSPoint(x: rect.maxX, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.minY),
            ]
            for (corner, spot) in zip(corners, spots) {
                corner.setFrame(
                    Self.clamp(
                        NSRect(x: spot.x - half, y: spot.y - half, width: side, height: side),
                        into: clamp
                    ),
                    display: false
                )
                corner.orderFrontRegardless()
            }
        } else {
            corners.forEach { $0.orderOut(nil) }
        }

        // Inside the top-left corner of its own rect, stepped down by row so
        // two guides of nearly the same shape still label themselves legibly
        // rather than printing on top of each other.
        let size = tag.fit(label: label)
        let origin = NSPoint(
            x: rect.minX + w,
            y: rect.maxY - w - size.height - CGFloat(labelRow) * (size.height + 4)
        )
        tag.setFrame(Self.clamp(NSRect(origin: origin, size: size), into: clamp), display: false)
        tag.orderFrontRegardless()
    }

    private static func clamp(_ frame: NSRect, into bounds: NSRect) -> NSRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, bounds.minX), bounds.maxX - f.width)
        f.origin.y = min(max(f.origin.y, bounds.minY), bounds.maxY - f.height)
        return f
    }

    func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        corners.forEach { $0.orderOut(nil) }
        tag.orderOut(nil)
    }
}

/// One strip: never captured, above everything, and click-through unless the
/// picker is open and the guides are being positioned.
final class CaptureBorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let stripe = CaptureStripeView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = stripe
        // Deliberately NOT `isFloatingPanel`: it overrides the level, which put
        // the guides under ordinary app windows.
        //
        // The first of two defences against filming our own indicator; the
        // second is the window-id exclusion in the capture filter.
        sharingType = .none
    }

    func configure(lineWidth: CGFloat, horizontal: Bool, draggable: Bool) {
        ignoresMouseEvents = !draggable
        stripe.lineWidth = lineWidth
        stripe.horizontal = horizontal
        stripe.draggable = draggable
        stripe.needsDisplay = true
    }
}

/// Draws the red line down the middle of its band and turns a drag on that band
/// into a move of the whole crop.
private final class CaptureStripeView: NSView {
    var lineWidth: CGFloat = 4
    var horizontal = true
    var draggable = false

    /// Udha red, the same accent the overlay's "wants you" tick uses.
    private static let red = NSColor(srgbRed: 0.925, green: 0.188, blue: 0.075, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        Self.red.setFill()
        let line = horizontal
            ? NSRect(x: 0, y: (bounds.height - lineWidth) / 2, width: bounds.width, height: lineWidth)
            : NSRect(x: (bounds.width - lineWidth) / 2, y: 0, width: lineWidth, height: bounds.height)
        line.fill()
    }

    override func resetCursorRects() {
        // Says "this can be moved" before the click, which is the only
        // affordance a bare line has.
        addCursorRect(bounds, cursor: draggable ? .openHand : .arrow)
    }

    /// The panel never becomes key, so AppKit would otherwise swallow the first
    /// click to activate the app — the same first-mouse problem the edge
    /// overlay has.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        guard draggable else { return }
        // Deltas rather than absolute positions: the strip moves under the
        // pointer as the crop follows it, so anything absolute would chase
        // itself.
        MainActor.assumeIsolated {
            CaptureBorderController.shared.nudge(
                by: CGSize(width: event.deltaX, height: -event.deltaY)
            )
        }
    }
}


/// The little red tag naming which master a guide belongs to.
final class CaptureTagPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        sharingType = .none
    }

    /// Sets the text and answers how big the tag wants to be.
    @discardableResult
    func fit(label: String) -> NSSize {
        let view = NSHostingView(rootView: CaptureTagView(label: label))
        contentView = view
        return view.fittingSize
    }
}

private struct CaptureTagView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(UdhaTheme.mono(10, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(UdhaTheme.bad)
    }
}


/// The 3 · 2 · 1 block.
final class CaptureCountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private static let side: CGFloat = 220

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        sharingType = .none
    }

    func show(_ value: Int, centredIn bounds: NSRect) {
        contentView = NSHostingView(rootView: CaptureCountdownView(value: value))
        setFrame(
            NSRect(
                x: bounds.midX - Self.side / 2,
                y: bounds.midY - Self.side / 2,
                width: Self.side,
                height: Self.side
            ),
            display: true
        )
        orderFrontRegardless()
    }
}

private struct CaptureCountdownView: View {
    let value: Int

    var body: some View {
        ZStack {
            Rectangle().fill(Color(hex: 0x1D1D1F))
            Text("\(value)")
                .font(UdhaTheme.mono(120, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay(Rectangle().stroke(UdhaTheme.bad, lineWidth: 4))
    }
}


/// A corner handle. Dragging one scales the crop about its centre, keeping the
/// aspect — which is what lets a full-screen recording lose the menu bar and
/// the Dock without the masters changing shape.
final class CaptureCornerPanel: NSPanel {
    static let side: CGFloat = 18

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        sharingType = .none
        contentView = CaptureCornerView()
    }
}

private final class CaptureCornerView: NSView {
    private static let red = NSColor(srgbRed: 0.925, green: 0.188, blue: 0.075, alpha: 1)
    private static let paper = NSColor(srgbRed: 0.953, green: 0.949, blue: 0.949, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        Self.red.setFill()
        bounds.fill()
        Self.paper.setFill()
        bounds.insetBy(dx: 5, dy: 5).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        MainActor.assumeIsolated {
            // Screen coordinates: the handle is chasing the pointer across the
            // whole desktop, not within its own 18pt window.
            CaptureBorderController.shared.resize(towards: NSEvent.mouseLocation)
        }
    }
}
