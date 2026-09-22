import SwiftUI
import Foundation

enum OverlayTheme {
    /// The resting strip flush with the screen edge: near-black in both
    /// appearances — it sits over whatever is on screen, so it must not follow
    /// the label colour and turn white in dark mode.
    static let strip = UdhaTheme.adaptive(0x1D1D1F, 0x3A3A3E)

    // Opaque dark panel palette — Raycast/Arc-style. Fixed (not adaptive) so
    // contrast is predictable regardless of what's showing behind the panel.
    static let panelBG      = Color(red: 0.106, green: 0.106, blue: 0.117)    // #1B1B1E
    static let cardBG       = Color(red: 0.149, green: 0.149, blue: 0.165)    // #26262A
    static let cardBGHover  = Color(red: 0.180, green: 0.180, blue: 0.196)    // #2E2E32

    // Legacy aliases kept so other call-sites don't break. Map to the new palette.
    static let obsidianCore = cardBG
    static let obsidianRim  = cardBGHover
    static let obsidianEdge = panelBG

    // Accent — vivid SF orange, used for brand + needs-input.
    static let amber        = Color(red: 1.00, green: 0.584, blue: 0.00)      // systemOrange-ish
    static let amberGlow    = Color(red: 1.00, green: 0.521, blue: 0.184)

    // Semantic signal colors — bright enough to pop on the dark panel.
    static let stateWorking    = Color(red: 0.369, green: 0.651, blue: 1.00)  // systemBlue
    static let stateNeedsInput = Color(red: 1.00,  green: 0.584, blue: 0.00)  // systemOrange
    static let stateErrored    = Color(red: 1.00,  green: 0.373, blue: 0.333) // systemRed
    static let stateCompleted  = Color(red: 0.298, green: 0.850, blue: 0.392) // systemGreen
    static let stateIdle       = Color(red: 0.557, green: 0.557, blue: 0.580) // systemGray
    // "Finished its turn, waiting on you" needs to be distinguishable from
    // "nothing is happening" at a glance — sharing idle's grey is what made a
    // dozen finished sessions invisible. Teal reads as settled-but-live, which
    // is neither the blue of working nor the orange of blocked.
    static let stateReady      = Color(red: 0.220, green: 0.800, blue: 0.750)
    // Same signal gone cold: desaturated, so a long-ignored session recedes.
    static let stateStale      = Color(red: 0.451, green: 0.604, blue: 0.596)
    // Plan mode — violet, distinct from ordinary work.
    static let statePlanning   = Color(red: 0.663, green: 0.545, blue: 1.000)

    // Separators tuned for the dark panel.
    static let hairline       = Color.white.opacity(0.06)
    static let hairlineStrong = Color.white.opacity(0.14)
    static let innerShadow    = Color.black.opacity(0.35)

    // Spring used everywhere — single cohesive motion language.
    static let bloomSpring = Animation.interpolatingSpring(
        mass: 0.9, stiffness: 170, damping: 18, initialVelocity: 0.2
    )
    static let nodeSpring  = Animation.interpolatingSpring(
        mass: 0.6, stiffness: 220, damping: 16
    )
    static let quickEase   = Animation.easeOut(duration: 0.18)

    // Typography — rounded mono for numeric state, rounded sans for labels.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension SessionState {
    var signalColor: Color {
        switch self {
        case .working:              return OverlayTheme.stateWorking
        case .needsInput:           return OverlayTheme.stateNeedsInput
        case .errored, .crashed:    return OverlayTheme.stateErrored
        case .completed:            return OverlayTheme.stateCompleted
        case .starting, .idle:      return OverlayTheme.stateIdle
        case .exited:               return OverlayTheme.stateIdle.opacity(0.5)
        }
    }

    var glyph: String {
        switch self {
        case .working:     return "waveform"
        case .needsInput:  return "questionmark"
        case .errored:     return "exclamationmark"
        case .crashed:     return "bolt.slash"
        case .completed:   return "checkmark"
        case .starting:    return "circle.dotted"
        case .idle:        return "circle"
        case .exited:      return "power"
        }
    }

    var wantsPulse: Bool {
        self == .needsInput || self == .errored
    }
}

// Geometry helpers for the arc layout.
struct OverlayGeometry {
    let edge: OverlayEdge
    let panelSize: CGSize
    let nodeCount: Int

    /// Center point of the arc, on the side of the edge.
    var arcCenter: CGPoint {
        let y = panelSize.height / 2
        let x: CGFloat = edge == .right ? panelSize.width : 0
        return CGPoint(x: x, y: y)
    }

    /// Radius at which session nodes are placed.
    /// Grows aggressively with session count so the pills don't overlap at
    /// high counts. Capped so the widest card still fits horizontally AND
    /// the top/bottom cards don't run off the screen vertically.
    var nodeRadius: CGFloat {
        let base: CGFloat = 230
        let extra: CGFloat = CGFloat(max(0, nodeCount - 3)) * 18
        // Card needs ~124pt of horizontal clearance from the panel's inner edge;
        // at angle π the card's left edge = panelWidth - R - 124. Keep ≥16pt margin.
        let widthCeiling = panelSize.width - 140
        // Vertically, top/bottom pills sit at y = arcCenter.y ± R. Keep ~65pt
        // of margin (half card height + breathing room) so they aren't clipped.
        let heightCeiling = panelSize.height / 2 - 65
        let hardCap: CGFloat = 300
        return min(base + extra, min(widthCeiling, heightCeiling, hardCap))
    }

    /// Arc spread (radians). Base 62°, up to a full 180° once there are ~7 sessions.
    var arcSpread: Double {
        let base = Double.pi * 0.62
        let extra = Double.pi * 0.12 * Double(max(0, nodeCount - 3))
        return min(base + extra, Double.pi)
    }

    /// Angle (radians) for node at index — opens inward from the edge.
    func angle(for index: Int) -> Double {
        let n = max(nodeCount, 1)
        if n == 1 { return edge == .right ? .pi : 0 }
        let spread = arcSpread
        let t = Double(index) / Double(max(n - 1, 1))
        let offset = -spread / 2 + spread * t
        // Inward direction is π (left) for right edge, 0 (right) for left edge.
        let inward: Double = edge == .right ? .pi : 0
        return inward + offset
    }

    func position(for index: Int, radius: CGFloat) -> CGPoint {
        let a = angle(for: index)
        let dx = CGFloat(Foundation.cos(a)) * radius
        let dy = CGFloat(Foundation.sin(a)) * radius
        return CGPoint(x: arcCenter.x + dx, y: arcCenter.y + dy)
    }
}
