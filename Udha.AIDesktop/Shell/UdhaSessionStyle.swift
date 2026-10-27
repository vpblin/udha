import SwiftUI

/// How a session renders in the HIG palette.
///
/// `SessionStatusPresentation` still owns the *words* — this maps them onto
/// the design's four chips: red when it is on you, accent while it works,
/// green when it has finished and is ready, amber once that has gone stale.
struct UdhaSessionStyle {
    /// Colour of the state dot.
    var mark: Color
    /// The state as *text* — the darkened / lightened ink of the same hue.
    var stateText: Color
    /// The chip's tinted ground.
    var tint: Color
    /// Filled dot = something is happening or wants you; hollow = it isn't.
    var filled: Bool
    /// The dot pings (expanding ring) — the session is live or on you.
    var pulses: Bool
    /// Three dots animate after the state word — the model is typing.
    var live: Bool
    var label: String
    var detail: String?

    init(snapshot: SessionSnapshot, staleAfter: Double) {
        let p = snapshot.statusPresentation(staleAfter: staleAfter)
        let attention = snapshot.attention(staleAfter: staleAfter)
        label = p.label
        detail = p.detail

        switch attention {
        case .needsYou:
            mark = UdhaTheme.bad
            stateText = UdhaTheme.badInk
            tint = UdhaTheme.badTint
            filled = true
            pulses = true
            live = false

        case .working:
            mark = UdhaTheme.accent
            stateText = UdhaTheme.accentInk
            tint = UdhaTheme.accentTint
            filled = true
            pulses = snapshot.phase == .thinking || snapshot.state == .starting
            live = true

        case .quiet:
            pulses = false
            live = false
            switch p.label {
            case "Done", "Ready":
                mark = UdhaTheme.good
                stateText = UdhaTheme.goodInk
                tint = UdhaTheme.goodTint
                filled = true
            case "Stale":
                mark = UdhaTheme.warn
                stateText = UdhaTheme.warnInk
                tint = UdhaTheme.warnTint
                filled = true
            case "Starting":
                mark = UdhaTheme.accent
                stateText = UdhaTheme.accentInk
                tint = UdhaTheme.accentTint
                filled = true
            default:
                mark = UdhaTheme.tertiary
                stateText = UdhaTheme.secondary
                tint = UdhaTheme.fill
                filled = false
            }
        }
    }

    /// The chip the Machines table and the board both draw.
    var chip: UdhaStateChip {
        UdhaStateChip(text: label, dot: mark, ink: stateText, tint: tint, live: live)
    }
}

/// The shared list-column row: a rounded card that slides right on hover, an
/// optional state mark, then whatever the row wants to say. Selected rows sit
/// on the card ground with an accent ring.
struct SidebarRow<Content: View>: View {
    var selected: Bool
    /// Selection ring turns red when the row is one that wants you.
    var accent: Bool = false
    var mark: AnyView? = nil
    var onTap: () -> Void
    /// When set, the row is draggable (carrying this string). Drag requires a
    /// non-Button row — a Button swallows the drag gesture on macOS — so a
    /// draggable row uses a tap gesture instead.
    var dragItem: String? = nil
    @ViewBuilder var content: Content

    @State private var hovering = false

    private var rowBody: some View {
        HStack(alignment: .top, spacing: 9) {
            if let mark { mark.padding(.top, 5) }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous))
    }

    var body: some View {
        Group {
            if let dragItem {
                rowBody
                    .onTapGesture(perform: onTap)
                    .draggable(dragItem)
            } else {
                Button(action: onTap) { rowBody }
                    .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous)
                .fill(selected ? UdhaTheme.card : (hovering ? UdhaTheme.fill : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UdhaTheme.rowRadius, style: .continuous)
                .strokeBorder(selected ? (accent ? UdhaTheme.bad : UdhaTheme.accent) : .clear, lineWidth: 1.5)
        )
        .shadow(color: UdhaTheme.cardShadow.opacity(selected ? 1 : (hovering ? 1.6 : 0)),
                radius: selected ? 4 : (hovering ? 8 : 0), y: selected ? 2 : (hovering ? 4 : 0))
        .offset(x: hovering && !selected && UdhaTheme.motion ? 3 : 0)
        .onHover { hovering = $0 }
        .animation(UdhaTheme.lift, value: hovering)
    }
}
