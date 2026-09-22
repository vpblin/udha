import SwiftUI
import AppKit

// MARK: - Buttons

/// The button treatments in the design. All 6pt corners; the only difference
/// is the fill.
enum UdhaButtonKind {
    /// Neutral fill. The default.
    case ghost
    /// Solid accent. One per view, on the action that matters.
    case primary
    /// Solid accent too — kept as a name for call sites that meant "commit".
    case dark
    /// No fill until hovered. Toolbar-ish affordances.
    case bare
    /// Red tint with red text. Destructive.
    case danger
}

struct UdhaButtonStyle: ButtonStyle {
    var kind: UdhaButtonKind = .ghost
    var height: CGFloat = 28
    var hPadding: CGFloat = 11
    /// Square icon buttons drop the horizontal padding and pin width to height.
    var square: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        // Hover state lives in a nested View, not in the style itself:
        // `makeBody` is not a View body, so `@State` declared on a ButtonStyle
        // has no identity to attach to and never reliably updates.
        StyledLabel(style: self, configuration: configuration)
    }

    private struct StyledLabel: View {
        let style: UdhaButtonStyle
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(UdhaTheme.text(12, style.kind == .primary || style.kind == .dark || style.kind == .danger
                                     ? .semibold : .medium))
                .foregroundStyle(style.foreground)
                .padding(.horizontal, style.square ? 0 : style.hPadding)
                .frame(height: style.height)
                .frame(width: style.square ? style.height : nil)
                .background(
                    RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous)
                        .fill(style.background(hovering: hovering, pressed: configuration.isPressed))
                )
                .brightness(style.kind == .primary || style.kind == .dark
                            ? (configuration.isPressed ? -0.06 : (hovering ? 0.06 : 0)) : 0)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous))
                .onHover { hovering = $0 }
                .animation(UdhaTheme.quick, value: hovering)
        }
    }

    fileprivate var foreground: Color {
        switch kind {
        case .primary, .dark: return UdhaTheme.onAccent
        case .danger:         return UdhaTheme.badInk
        case .ghost, .bare:   return UdhaTheme.label
        }
    }

    fileprivate func background(hovering: Bool, pressed: Bool) -> Color {
        switch kind {
        case .primary, .dark:
            return UdhaTheme.accent
        case .ghost:
            return (hovering || pressed) ? UdhaTheme.fillStrong : UdhaTheme.fill
        case .bare:
            return (hovering || pressed) ? UdhaTheme.fill : .clear
        case .danger:
            return UdhaTheme.badTint.opacity(hovering || pressed ? 1.3 : 1)
        }
    }
}

extension View {
    func udhaButton(
        _ kind: UdhaButtonKind = .ghost,
        height: CGFloat = 28,
        hPadding: CGFloat = 11,
        square: Bool = false
    ) -> some View {
        buttonStyle(UdhaButtonStyle(kind: kind, height: height, hPadding: hPadding, square: square))
    }
}

/// Label + optional SF Symbol, laid out the way every button in the design is.
struct UdhaLabel: View {
    let title: String
    var icon: String? = nil
    var iconSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
            }
            if !title.isEmpty { Text(title) }
        }
    }
}

/// The full-width action under a list column's search field ("New agent",
/// "Record meeting", "New folder"): a 30pt button with the label leading.
struct UdhaListAction: View {
    let title: String
    var icon: String? = nil
    var kind: UdhaButtonKind = .ghost
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            UdhaLabel(title: title, icon: icon, iconSize: 13)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .udhaButton(kind, height: 30, hPadding: 10)
        .disabled(disabled)
    }
}

/// A 28×26 icon-only button in the chrome: no fill until hovered.
struct UdhaIconButton: View {
    let symbol: String
    var size: CGFloat = 15
    var tint: Color = UdhaTheme.secondary
    var help: String = ""
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hovering ? UdhaTheme.label : tint)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous)
                        .fill(hovering ? UdhaTheme.fill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Rules

/// A horizontal hairline. The design's rules are 0.5pt.
struct HRule: View {
    var color: Color = UdhaTheme.separator
    var thickness: CGFloat = 0.5
    var body: some View {
        Rectangle().fill(color).frame(height: thickness)
    }
}

struct VRule: View {
    var color: Color = UdhaTheme.separator
    var thickness: CGFloat = 0.5
    var body: some View {
        Rectangle().fill(color).frame(width: thickness)
    }
}

// MARK: - Cards + surfaces

/// The card: white (or dark-grey) ground, 12pt corners, a 0.5pt ring and two
/// soft shadows. Everything in a detail pane sits in one.
struct UdhaCardModifier: ViewModifier {
    var radius: CGFloat = UdhaTheme.cardRadius
    var fill: Color = UdhaTheme.card
    /// Lift on hover — the design's `translateY(-3px)` + deeper shadow.
    var hoverLift: Bool = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(UdhaTheme.separator.opacity(0.7), lineWidth: 0.5)
                    )
            )
            .shadow(color: UdhaTheme.cardShadow.opacity(hoverLift && hovering ? 2.4 : 1),
                    radius: hoverLift && hovering ? 14 : 6, y: hoverLift && hovering ? 8 : 3)
            .shadow(color: UdhaTheme.cardShadow.opacity(0.6), radius: 1, y: 1)
            .offset(y: hoverLift && hovering && UdhaTheme.motion ? -3 : 0)
            .onHover { if hoverLift { hovering = $0 } }
            .animation(UdhaTheme.lift, value: hovering)
    }
}

extension View {
    /// Wraps the view in the design's card.
    func udhaCard(radius: CGFloat = UdhaTheme.cardRadius, fill: Color = UdhaTheme.card,
                  hoverLift: Bool = false) -> some View {
        modifier(UdhaCardModifier(radius: radius, fill: fill, hoverLift: hoverLift))
    }

    /// A rounded neutral well — the ground under a search field, a code block.
    func udhaWell(radius: CGFloat = UdhaTheme.rowRadius, fill: Color = UdhaTheme.fill) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
    }

    /// The design's hairline ring around a control.
    func udhaOutline(radius: CGFloat = UdhaTheme.controlRadius,
                     color: Color = UdhaTheme.separator, width: CGFloat = 0.5) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: width))
    }

    /// Clips to the design's radius.
    func udhaRounded(_ radius: CGFloat = UdhaTheme.rowRadius) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// AppKit vibrancy under the chrome — the title bar, sidebar, list column and
/// status bar all blur whatever is behind the window, the way Finder's
/// sidebar does. A tint is drawn over it so the design's translucent surface
/// colours still read.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// Vibrancy with the design's tint over it.
    ///
    /// Deliberately does **not** ignore the safe area: a view that touches the
    /// window's toolbar region would otherwise grow into it, and the sidebar's
    /// vibrancy ended up painted over the traffic lights and the title.
    func udhaChrome(_ material: NSVisualEffectView.Material = .headerView, tint: Color = UdhaTheme.chrome) -> some View {
        background(
            ZStack {
                VisualEffectBackground(material: material)
                tint
            }
        )
    }
}

// MARK: - Typographic atoms

/// The small heading above a group. Sentence case, semibold, secondary.
struct Eyebrow: View {
    let text: String
    var color: Color = UdhaTheme.secondary
    var size: CGFloat = 11
    var tracking: CGFloat = 0

    init(_ text: String, color: Color = UdhaTheme.secondary, size: CGFloat = 11, tracking: CGFloat = 0) {
        self.text = text
        self.color = color
        self.size = size
        self.tracking = tracking
    }

    var body: some View {
        Text(text)
            .font(UdhaTheme.eyebrow(size))
            .foregroundStyle(color)
    }
}

/// Monospace metadata: times, paths, counts, key hints.
struct Mono: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = UdhaTheme.secondary
    var tracking: CGFloat = 0

    init(_ text: String, size: CGFloat = 11, color: Color = UdhaTheme.secondary, tracking: CGFloat = 0) {
        self.text = text
        self.size = size
        self.color = color
        self.tracking = tracking
    }

    var body: some View {
        Text(text)
            .font(UdhaTheme.mono(size))
            .foregroundStyle(color)
    }
}

/// A pill: tinted ground, tinted text, 999pt corners. Badges, tags, models.
struct UdhaPill: View {
    let text: String
    var fg: Color = UdhaTheme.secondary
    var bg: Color = UdhaTheme.fill
    var size: CGFloat = 11
    var height: CGFloat = 20
    var mono: Bool = false

    init(_ text: String, fg: Color = UdhaTheme.secondary, bg: Color = UdhaTheme.fill,
         size: CGFloat = 11, height: CGFloat = 20, mono: Bool = false) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.size = size
        self.height = height
        self.mono = mono
    }

    var body: some View {
        Text(text)
            .font(mono ? UdhaTheme.mono(size, weight: .medium) : UdhaTheme.text(size, .semibold))
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(Capsule().fill(bg))
    }
}

/// A small square tag — "Rec", "Mapped", "Built in" — 3pt corners, 9.5pt caps.
struct UdhaTag: View {
    let text: String
    var fg: Color = UdhaTheme.secondary
    var bg: Color = UdhaTheme.fill

    init(_ text: String, fg: Color = UdhaTheme.secondary, bg: Color = UdhaTheme.fill) {
        self.text = text
        self.fg = fg
        self.bg = bg
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.2)
            .foregroundStyle(fg)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(bg))
    }
}

/// The key hint on the right of a palette row: mono on a fill.
struct UdhaKeyHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(UdhaTheme.mono(11))
            .foregroundStyle(UdhaTheme.secondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(UdhaTheme.fill))
    }
}

// MARK: - Session state mark

/// The dot that carries a session's state: colour for the state, a soft ring
/// behind it, and a ping when it wants you.
struct StateMark: View {
    let color: Color
    var size: CGFloat = 8
    var filled: Bool = true
    var pulses: Bool = false

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(filled ? color : .clear)
            .frame(width: size, height: size)
            .overlay {
                if !filled { Circle().stroke(color, lineWidth: 1.5) }
            }
            .background(Circle().fill(color.opacity(0.18)).padding(-3))
            .opacity(pulses && dim ? 0.35 : 1)
            // Scoped to this view. A `withAnimation(.repeatForever)` fired
            // from `onAppear` leaks into whatever else lays out in that
            // transaction — inside a scroll view that is the scroll offset,
            // and the whole list bounces forever.
            .animation(pulses ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = pulses }
            .onChange(of: pulses) { _, on in dim = on }
    }
}

/// A dot with an expanding ring — the design's `ping` — for a session that
/// is live: starting, thinking, or waiting on you.
struct PingDot: View {
    let color: Color
    var size: CGFloat = 6
    var active: Bool = true
    @State private var expand = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(expand ? 3.2 : 1)
                    .opacity(expand ? 0 : 0.6)
                    .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 1.9).repeatForever(autoreverses: false),
                               value: expand)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { expand = active }
        .onChange(of: active) { _, on in expand = on }
    }
}

/// Three dots fading in sequence — "something is happening". Driven by a
/// timeline rather than a timer, so a card scrolled out of a lazy list leaves
/// nothing ticking behind it.
struct WorkingDots: View {
    var color: Color = UdhaTheme.accent
    var size: CGFloat = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color).frame(width: size, height: size)
                        .opacity(phase == i ? 1 : 0.25)
                }
            }
        }
    }
}

/// The state chip: a dot and a word on a tinted capsule.
struct UdhaStateChip: View {
    let text: String
    let dot: Color
    let ink: Color
    let tint: Color
    var live: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(UdhaTheme.text(11, .semibold)).foregroundStyle(ink)
            if live { WorkingDots(color: dot) }
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 20)
        .background(Capsule().fill(tint))
    }
}

/// A view that pulses its content the way the design's `recpulse` keyframe
/// does. The animation is scoped to the content — see `StateMark`.
struct Pulsing<Content: View>: View {
    var active: Bool = true
    var period: Double = 1.6
    /// How far it swells at the peak (1 = opacity only). The design's
    /// `livedot` breathes to 1.5× while dimming to half.
    var scale: CGFloat = 1
    var dimTo: Double = 0.35
    @ViewBuilder var content: Content
    @State private var dim = false

    var body: some View {
        content
            .opacity(active && dim ? dimTo : 1)
            .scaleEffect(active && dim ? scale : 1)
            .animation(active ? .easeInOut(duration: period / 2).repeatForever(autoreverses: true) : .default,
                       value: dim)
            .onAppear { dim = active }
            .onChange(of: active) { _, on in dim = on }
    }
}

/// The four little bars that wave beside "Stop meeting" while recording.
struct WaveBars: View {
    var color: Color = UdhaTheme.bad
    var active: Bool = true

    private let phases: [(CGFloat, CGFloat)] = [(4, 13), (10, 3), (6, 12), (12, 5)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let tick = active ? Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) : 0
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 2, height: (tick + i) % 2 == 0 ? phases[i].0 : phases[i].1)
                        .animation(.easeInOut(duration: 0.4), value: tick)
                }
            }
            .frame(height: 14)
            .opacity(0.75)
        }
    }
}

// MARK: - Meter

/// The little bar-chart of recent output volume that sits on overlay pills and
/// the live-meeting header. Heights are already log-scaled by the caller.
struct BarMeter: View {
    let heights: [CGFloat]
    var color: Color = UdhaTheme.tertiary
    var barWidth: CGFloat = 2.5
    var maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: barWidth, height: max(2, min(h, maxHeight)))
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
    }
}

/// A horizontal progress / level bar, 6pt tall, rounded.
struct UdhaBar: View {
    var fraction: Double
    var color: Color = UdhaTheme.accent
    var height: CGFloat = 6
    var track: Color = UdhaTheme.fill

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    .animation(.easeInOut(duration: 0.6), value: fraction)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Form controls

/// 4pt-radius checkbox — accent fill with a white tick when on, a hairline
/// ring on a fill when off.
struct UdhaCheckbox: View {
    @Binding var isOn: Bool
    var size: CGFloat = 16
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isOn ? UdhaTheme.accent : UdhaTheme.fill)
                .frame(width: size, height: size)
                .overlay {
                    if !isOn {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(UdhaTheme.separator, lineWidth: 1)
                    }
                }
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.58, weight: .bold))
                        .foregroundStyle(UdhaTheme.onAccent)
                        .opacity(isOn ? 1 : 0)
                }
                // Required: when off, the checkmark is `opacity(0)`, so without
                // this the only hit-testable geometry would be the fill's edge.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(UdhaTheme.quick, value: isOn)
    }
}

/// A macOS-style switch, for settings rows.
struct UdhaSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(UdhaTheme.accent)
    }
}

/// The design's segmented control: a fill track, the active segment lifted
/// as a card.
struct UdhaSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let active = opt.value == selection
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(UdhaTheme.text(12, .medium))
                        .foregroundStyle(active ? UdhaTheme.label : UdhaTheme.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(active ? UdhaTheme.card : .clear)
                                .shadow(color: .black.opacity(active ? 0.10 : 0), radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UdhaTheme.fill))
        .animation(UdhaTheme.quick, value: selection)
    }
}

/// A dropdown: fill ground, value on the left, chevron pinned right. Wraps a
/// real `Menu` so keyboard + accessibility behave.
struct UdhaSelect<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var minWidth: CGFloat = 220
    @State private var hovering = false

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? "—"
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button(opt.label) { selection = opt.value }
            }
        } label: {
            HStack(spacing: 10) {
                Text(currentLabel)
                    .font(UdhaTheme.text(12.5, .medium))
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UdhaTheme.secondary)
            }
            .padding(.horizontal, 9)
            .frame(minWidth: minWidth, maxWidth: minWidth, alignment: .leading)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: UdhaTheme.controlRadius, style: .continuous)
                    .fill(hovering ? UdhaTheme.fillStrong : UdhaTheme.fill)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// Text field on a card ground with an inset hairline — the design's input.
struct UdhaField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 30
    var mono: Bool = false
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? UdhaTheme.mono(12) : UdhaTheme.text(13, .regular))
            .foregroundStyle(UdhaTheme.label)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous)
                    .fill(UdhaTheme.card)
            )
            .udhaOutline(radius: UdhaTheme.rowRadius)
            .onSubmit { onSubmit?() }
    }
}

/// The search box at the top of a list column.
struct UdhaSearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UdhaTheme.secondary)
            Group {
                if let focus {
                    TextField(placeholder, text: $text).focused(focus)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(UdhaTheme.text(12, .regular))
            .foregroundStyle(UdhaTheme.label)
            .onSubmit { onSubmit?() }
            .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(UdhaTheme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UdhaTheme.fill))
        .udhaOutline(radius: 7)
    }
}

/// The slider: a rounded track, an accent run, a round knob.
struct UdhaSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var width: CGFloat = 240
    var onCommit: (() -> Void)? = nil

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(UdhaTheme.fillStrong).frame(width: width, height: 4)
            Capsule().fill(UdhaTheme.accent).frame(width: width * fraction, height: 4)
            Circle()
                .fill(UdhaTheme.card)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                .overlay(Circle().strokeBorder(UdhaTheme.separator, lineWidth: 0.5))
                .offset(x: width * fraction - 8)
        }
        .frame(width: width, height: 16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = (g.location.x / width).clamped(to: 0...1)
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in onCommit?() }
        )
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}

// MARK: - Hover tracking

/// `.hoverBackground(base:hover:)` — hover state without a `@State` in every
/// call site, and without `.onContinuousHover`'s phase bookkeeping. Rounded.
struct HoverBackground: ViewModifier {
    var base: Color
    var hover: Color
    var radius: CGFloat = UdhaTheme.rowRadius
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hovering ? hover : base))
            .onHover { hovering = $0 }
            .animation(UdhaTheme.quick, value: hovering)
    }
}

extension View {
    func hoverBackground(base: Color = .clear, hover: Color = UdhaTheme.fill,
                         radius: CGFloat = UdhaTheme.rowRadius) -> some View {
        modifier(HoverBackground(base: base, hover: hover, radius: radius))
    }
}

/// The design's row hover: slide right 3pt and lift with a shadow. Honours the
/// motion setting — off, the row just tints.
struct HoverSlide: ViewModifier {
    var dx: CGFloat = 3
    var dy: CGFloat = 0
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .offset(x: hovering && UdhaTheme.motion ? dx : 0, y: hovering && UdhaTheme.motion ? dy : 0)
            .onHover { hovering = $0 }
            .animation(UdhaTheme.lift, value: hovering)
    }
}

extension View {
    func hoverSlide(dx: CGFloat = 3, dy: CGFloat = 0) -> some View {
        modifier(HoverSlide(dx: dx, dy: dy))
    }
}

// MARK: - Scrolling

/// Thin overlay scrollbars everywhere.
extension View {
    func udhaScroll() -> some View {
        scrollIndicators(.automatic)
            .scrollContentBackground(.hidden)
    }
}

// MARK: - Section chrome inside a pane

/// "Resources        /proc · hwmon" — an h2 with a mono note on the right.
struct UdhaSectionHead: View {
    let title: String
    var note: String? = nil
    var noteColor: Color = UdhaTheme.secondary
    var noteIsMono: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(UdhaTheme.text(15, .semibold))
                .tracking(-0.15)
                .foregroundStyle(UdhaTheme.label)
            Spacer(minLength: 8)
            if let note, !note.isEmpty {
                if noteIsMono {
                    Mono(note, size: 11, color: noteColor).lineLimit(1)
                } else {
                    Text(note).font(UdhaTheme.text(11.5, .medium)).foregroundStyle(noteColor).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// The h1 of a detail pane, with an optional line under it.
struct UdhaPaneTitle: View {
    let title: String
    var subtitle: String? = nil
    var subtitleMono: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(UdhaTheme.text(22, .bold))
                .tracking(-0.3)
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                if subtitleMono {
                    Mono(subtitle, size: 11.5).lineLimit(1)
                } else {
                    Text(subtitle).font(UdhaTheme.text(12, .regular)).foregroundStyle(UdhaTheme.secondary).lineLimit(2)
                }
            }
        }
    }
}

/// The centred "nothing here" state of a pane.
struct UdhaEmptyState: View {
    let title: String
    let text: String
    var action: (title: String, icon: String?, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(UdhaTheme.text(20, .bold))
                .tracking(-0.2)
                .foregroundStyle(UdhaTheme.label)
            Text(text)
                .font(UdhaTheme.text(13, .regular))
                .foregroundStyle(UdhaTheme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)
            if let action {
                Button(action: action.run) {
                    UdhaLabel(title: action.title, icon: action.icon)
                }
                .udhaButton(.primary, height: 30, hPadding: 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Ambient glow

/// Slow drifting colour under the content — the design's aurora, without the
/// blur filter: two radial gradients are already soft, so they cost nothing.
struct AmbientGlow: View {
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                blob(UdhaTheme.accent, size: 720)
                    .offset(x: drift ? geo.size.width * 0.18 : -geo.size.width * 0.02,
                            y: drift ? -240 : -300)
                blob(UdhaTheme.good, size: 620)
                    .offset(x: drift ? geo.size.width * 0.42 : geo.size.width * 0.66,
                            y: drift ? -180 : -260)
                blob(UdhaTheme.accent, size: 680)
                    .offset(x: drift ? geo.size.width * 0.30 : geo.size.width * 0.50,
                            y: geo.size.height - (drift ? 120 : 200))
            }
            .opacity(0.16)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 26).repeatForever(autoreverses: true), value: drift)
            .onAppear { drift = true }
        }
        .clipped()
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.9), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

// MARK: - Formatting helpers

enum UdhaFormat {
    /// "4m", "1h 20m", "6h" — the compact age used on every row.
    static func duration(since date: Date, now: Date = Date()) -> String {
        elapsed(now.timeIntervalSince(date))
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "12:41" — the elapsed clock on a live recording.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// `$4.06` from whole cents.
    static func cents(_ cents: Int?) -> String {
        guard let cents else { return "—" }
        return String(format: "$%.2f", Double(cents) / 100)
    }

    /// `~/projects/foo` — home-relative so paths fit on one line.
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }

    /// "Aug 21" for anything older than today, "9:41" for today.
    static func shortWhen(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeOfDay(date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f.string(from: date)
    }

    /// "4m ago", or "never" when there is nothing to age.
    static func agoText(_ date: Date?) -> String {
        guard let date else { return "never" }
        return "\(duration(since: date)) ago"
    }

    /// "6d 04h" — the long form used for uptimes, where minutes are noise.
    static func uptime(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let days = s / 86_400, hours = (s % 86_400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return String(format: "%dd %02dh", days, hours) }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Storage-style bytes: "1.8 TB", "13.6 GB", "912 MB". Decimal units,
    /// because that is what `df`, `free` and every spec sheet quote.
    static func bytes(_ value: UInt64, decimals: Int? = nil) -> String {
        let v = Double(value)
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "kB")]
        for (scale, suffix) in units where v >= scale {
            let scaled = v / scale
            let places = decimals ?? (scaled >= 100 ? 0 : 1)
            return String(format: "%.\(places)f %@", scaled, suffix)
        }
        return "\(value) B"
    }

    /// "3.4 MB/s" — throughput, which reads better without a unit gap.
    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        return bytes(UInt64(bytesPerSecond)) + "/s"
    }

    /// "34%" from a 0–100 reading, "—" when the collector saw nothing.
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// "46 °C", or "—".
    static func celsius(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f °C", value)
    }

    /// "10:32:15" — the status bar's clock.
    static func wallClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

/// A title that turns into a field when you double-click it.
///
/// Double-click rather than single: a heading is not a control, and a single
/// click landing in an edit field every time you brush past a title is the kind
/// of helpfulness that costs you a rename you never asked for. Double-click is
/// also what the Finder trained everyone to expect for renaming a label.
///
/// The text is selected the moment the field opens, so typing replaces the old
/// name rather than appending to it. Return commits, Escape abandons, and
/// clicking away commits, because losing an edit to a stray click is worse
/// than an accidental save you can simply redo.
struct UdhaEditableTitle: View {
    let text: String
    var font: Font = UdhaTheme.text(22, .bold)
    var tracking: CGFloat = -0.3
    var color: Color = UdhaTheme.label
    var onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .tracking(tracking)
                    .foregroundStyle(UdhaTheme.label)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                    .onChange(of: focused) { _, hasFocus in
                        if !hasFocus, isEditing { commit() }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UdhaTheme.card))
                    .udhaOutline(radius: 7, color: UdhaTheme.accent, width: 1.5)
            } else {
                Text(text)
                    .font(font)
                    .tracking(tracking)
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing() }
                    .help("Double-click to rename")
            }
        }
        // A different subject means a different name: leave any half-typed edit
        // behind rather than carrying it onto something else.
        .onChange(of: text) { _, _ in
            if isEditing { isEditing = false }
        }
    }

    private func beginEditing() {
        draft = text
        isEditing = true
        focused = true
        // After the field exists and has first responder — selecting before
        // that lands on nothing.
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commit() {
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name is not a rename, it is a lost recording in the sidebar.
        guard !trimmed.isEmpty, trimmed != text else { return }
        onCommit(trimmed)
    }
}
