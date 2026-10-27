import SwiftUI
import AppKit
import CoreText

/// The Udha visual language, ported from `Udha HIG.dc.html`: the macOS Human
/// Interface Guidelines idiom. System font, translucent chrome over a blurred
/// desktop, cards with a soft shadow on a flat canvas, 6–12pt corners, one
/// tinted accent for selection and primary actions, and green / amber / red
/// for good / warn / bad.
///
/// Every colour here is **adaptive**: it resolves against the effective
/// appearance of the view it is drawn in, so the same token is right in
/// light and dark. The appearance itself is a setting (`UdhaAppearance`) —
/// follow the system, or pin light or dark — and so is the accent
/// (`UdhaAccent`). Both are applied by `UdhaTheme.apply(config:)`.
enum UdhaTheme {

    // MARK: - Appearance + accent (settings)

    /// The accent the palette is currently built with. Set from config at
    /// launch and whenever the setting changes; the root view re-keys itself
    /// on `revision` so every colour is re-read.
    static private(set) var accentChoice: UdhaAccent = .blue
    static private(set) var revision = 0
    /// Whether rows slide and cards lift on hover. A setting, because a
    /// window that moves under the pointer is not to everyone's taste.
    static private(set) var motion = true

    static func apply(config: AppConfig) {
        accentChoice = config.appearance.accent
        motion = config.appearance.motion
        revision &+= 1
        NSApp?.appearance = config.appearance.mode.nsAppearance
    }

    // MARK: - Surfaces

    /// The page. Cards sit on this.
    static let canvas    = adaptive(0xF2F2F4, 0x1B1B1D)
    /// A card, a field, a popover.
    static let card      = adaptive(0xFFFFFF, 0x2A2A2C)
    /// Tint drawn over the title bar / status bar vibrancy.
    static let chrome    = adaptive(0xF6F6F8, 0x2A2A2D, 0.82, 0.80)
    /// Tint drawn over the nav sidebar's vibrancy.
    static let sidebar   = adaptive(0xF0F0F3, 0x222224, 0.70, 0.64)
    /// Tint drawn over the list column's vibrancy.
    static let list      = adaptive(0xFAFAFB, 0x262629, 0.86, 0.72)
    /// Neutral fill: hovered rows, ghost buttons, inset wells.
    static let fill       = adaptive(0x787880, 0x787880, 0.10, 0.22)
    static let fillStrong = adaptive(0x787880, 0x787880, 0.18, 0.36)
    /// Selected-row ground when the row is not the accent.
    static let sel        = adaptive(0x787880, 0x000000, 0.20, 0.30)

    // MARK: - Text

    static let label     = adaptive(0x1D1D1F, 0xF5F5F7)
    static let secondary = adaptive(0x64646A, 0xA6A6AC)
    static let tertiary  = adaptive(0x5D5D62, 0xA3A3A9)
    /// Code and machine-emitted text on a fill.
    static let inkCode   = adaptive(0x2B2B2E, 0xE7E7EA)

    // MARK: - Lines

    /// The 0.5pt rule between regions.
    static let separator = adaptive(0x000000, 0xFFFFFF, 0.10, 0.12)
    /// The 0.5pt rule between rows inside a card.
    static let hairline  = adaptive(0x000000, 0xFFFFFF, 0.06, 0.08)

    // MARK: - Accent

    static var accent: Color      { accentChoice.accent }
    static var accentTint: Color  { accentChoice.tint }
    /// Accent as *text* on the canvas — darkened / lightened for contrast.
    static var accentInk: Color   { accentChoice.ink }
    static var onAccent: Color    { accentChoice.onAccent }
    static var onAccentDim: Color { accentChoice.onAccentDim }

    // MARK: - Semantic

    static let good     = adaptive(0x1C8B3A, 0x45D669)
    static let goodTint = adaptive(0x1C8B3A, 0x45D669, 0.13, 0.16)
    static let goodInk  = adaptive(0x14702E, 0x6FE089)
    static let warn     = adaptive(0x9A5B00, 0xFFB340)
    static let warnTint = adaptive(0x9A5B00, 0xFFB340, 0.13, 0.16)
    static let warnInk  = adaptive(0x7D4A00, 0xFFC46B)
    static let bad      = adaptive(0xCF2A20, 0xFF6961)
    static let badTint  = adaptive(0xCF2A20, 0xFF6961, 0.12, 0.16)
    static let badInk   = adaptive(0x9C1E16, 0xFF9A94)

    /// Scrim behind a modal.
    static let scrim = adaptive(0x08080A, 0x08080A, 0.34, 0.50)

    // MARK: - Legacy names
    //
    // The previous (Swiss) palette's vocabulary, mapped onto this one so the
    // views that still speak it re-theme without being touched. New code
    // should use the names above.

    static var paper: Color       { canvas }
    static var panel: Color       { fill }
    static var rowSelected: Color { sel }
    static var rowHover: Color    { fill }
    static var field: Color       { card }
    static var ink: Color         { label }
    static var inkSoft: Color     { label.opacity(0.86) }
    static var muted: Color       { secondary }
    static var muted2: Color      { tertiary }
    static var faint: Color       { tertiary.opacity(0.8) }
    static var line: Color        { separator }
    static var red: Color         { bad }
    static var redPressed: Color  { bad }
    static var redInk: Color      { badInk }
    static var redWash: Color     { badTint }
    static var ruleHeavy: Color   { separator }
    static var ruleStrong: Color  { separator }
    static var rule: Color        { separator }
    static var ruleSoft: Color    { hairline }
    static var ruleFaint: Color   { hairline }
    static var hoverWash: Color   { fill }

    // MARK: - Metrics

    static let titleBarHeight: CGFloat  = 52
    static let statusBarHeight: CGFloat = 28
    /// The nav sidebar: six sections, the palette button, lock and settings.
    static let navWidth: CGFloat        = 194
    /// The list column beside it — the sessions board, or a section's list.
    static let boardWidth: CGFloat      = 320
    static let sidebarWidth: CGFloat    = navWidth + boardWidth
    /// Horizontal gutter of every detail pane.
    static let contentInset: CGFloat    = 22
    /// The gap between cards in a pane.
    static let cardGap: CGFloat         = 14
    static let cardRadius: CGFloat      = 12
    static let controlRadius: CGFloat   = 6
    static let rowRadius: CGFloat       = 8

    /// The card's lift: a 0.5pt ring and two soft shadows, per the design.
    static let cardShadow: Color = adaptive(0x000000, 0x000000, 0.05, 0.5)

    // MARK: - Type

    /// SF Pro at the design's sizes. `weight` maps onto the system weights.
    static func text(_ size: CGFloat, _ weight: UdhaWeight = .regular) -> Font {
        .system(size: size, weight: weight.systemWeight)
    }

    /// Monospace: numerals, paths, timestamps, tmux output, keyboard shortcuts.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The small label above a group. Sentence case now, not tracked caps.
    static func eyebrow(_ size: CGFloat = 11) -> Font {
        text(size, .semibold)
    }

    // MARK: - Motion

    /// Everything that isn't a bloom.
    static let quick = Animation.easeOut(duration: 0.18)
    /// Cards lifting, rows sliding, the palette opening.
    static let lift  = Animation.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.22)
    static let bloom = Animation.spring(response: 0.28, dampingFraction: 0.86)

    // MARK: - Setup

    /// Called once at launch, before any view is built.
    static func bootstrap(config: AppConfig) {
        registerBundledFonts()
        apply(config: config)
    }

    private static var fontsRegistered = false

    /// The UI is set in the system font now, but the bundled Archivo faces
    /// still carry the captions burned into recordings (`CaptionRenderer`),
    /// so they are registered with Core Text as before.
    static func registerBundledFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("Archivo") {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                Log.app.debug("font register skipped \(url.lastPathComponent)")
            }
        }
    }

    // MARK: - Colour construction

    /// A colour that resolves per appearance: `light` under Aqua, `dark`
    /// under Dark Aqua. Alpha can differ between the two — the design's
    /// translucent fills are heavier in the dark theme.
    static func adaptive(_ light: UInt32, _ dark: UInt32,
                         _ lightAlpha: CGFloat = 1, _ darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// Weights by name, as the previous design system spelled them. Kept so
/// call sites read the same; each maps onto the closest SF weight.
enum UdhaWeight {
    case regular    // 400 — body
    case medium     // 500 — inactive nav, secondary buttons
    case semibold   // 600 — row titles, button labels
    case bold       // 700
    case extraBold  // headings — SF has no 640, bold is the closest that reads as one

    var systemWeight: Font.Weight {
        switch self {
        case .regular:   return .regular
        case .medium:    return .medium
        case .semibold:  return .semibold
        case .bold:      return .bold
        case .extraBold: return .bold
        }
    }
}

// MARK: - Appearance settings (the Mac side)
//
// The Codable types live in `AppConfig.swift`, which the Linux agent shares;
// everything that needs AppKit or SwiftUI is here.

extension UdhaAppearanceMode {
    var label: String {
        switch self {
        case .system: return "Match the Mac"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Nil = follow the system, which is what AppKit does when `NSApp.appearance`
    /// is unset.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

extension UdhaAccent {
    var label: String { rawValue.capitalized }

    var accent: Color {
        switch self {
        case .blue:     return UdhaTheme.adaptive(0x0069D9, 0x4DA2FF)
        case .purple:   return UdhaTheme.adaptive(0x7B3FBF, 0xC08CF5)
        case .green:    return UdhaTheme.adaptive(0x1C8B3A, 0x45D669)
        case .graphite: return UdhaTheme.adaptive(0x4A4A4F, 0xCFCFD4)
        }
    }

    var tint: Color {
        switch self {
        case .blue:     return UdhaTheme.adaptive(0x0069D9, 0x4DA2FF, 0.12, 0.18)
        case .purple:   return UdhaTheme.adaptive(0x7B3FBF, 0xC08CF5, 0.13, 0.18)
        case .green:    return UdhaTheme.adaptive(0x1C8B3A, 0x45D669, 0.13, 0.18)
        case .graphite: return UdhaTheme.adaptive(0x4A4A4F, 0xCFCFD4, 0.12, 0.18)
        }
    }

    var ink: Color {
        switch self {
        case .blue:     return UdhaTheme.adaptive(0x0058B8, 0x8EC2FF)
        case .purple:   return UdhaTheme.adaptive(0x5E2A99, 0xD9B8FA)
        case .green:    return UdhaTheme.adaptive(0x14702E, 0x6FE089)
        case .graphite: return UdhaTheme.adaptive(0x3A3A3F, 0xDCDCE0)
        }
    }

    /// Text on a solid accent: white in light, near-black in dark (the dark
    /// accents are pastel).
    var onAccent: Color    { UdhaTheme.adaptive(0xFFFFFF, 0x0D1117) }
    var onAccentDim: Color { UdhaTheme.adaptive(0xFFFFFF, 0x0D1117, 0.86, 0.72) }
}

extension Color {
    /// `Color(hex: 0xEC3013)` — the design file speaks hex, so the palette does too.
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >>  8) & 0xFF) / 255,
            blue:    CGFloat( hex        & 0xFF) / 255,
            alpha:   alpha
        )
    }
}
