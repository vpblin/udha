import SwiftUI

/// ⌘K. Everything Udha can do, filtered as you type, grouped by area.
///
/// The list is rebuilt from live state on every keystroke, so each row's hint
/// names the thing it will act on — "asana-reporter · edit asana_sync.py"
/// rather than "approves a pending prompt". Rows that can't run right now stay
/// listed and say why, because a palette that hides half its entries stops
/// being a reliable answer to "what can this thing do".
struct UdhaCommandPalette: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel

    @FocusState private var focused: Bool
    @State private var shown = false

    private var registry: UdhaCommandRegistry {
        UdhaCommandRegistry(core: core, shell: shell, openWindow: { _ in })
    }

    private var all: [UdhaCommand] { registry.commands() }

    private var matches: [UdhaCommand] {
        let q = shell.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.haystack.contains(q) }
    }

    /// Header rows interleaved with commands, so the group label is part of the
    /// same scroll rather than a sticky overlay.
    private enum Entry: Identifiable {
        case header(String)
        case command(UdhaCommand, index: Int)
        var id: String {
            switch self {
            case .header(let g): return "h-" + g
            case .command(let c, _): return "c-" + c.id
            }
        }
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        var lastGroup: String?
        for (i, c) in matches.enumerated() {
            if c.group != lastGroup {
                out.append(.header(c.group))
                lastGroup = c.group
            }
            out.append(.command(c, index: i))
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .top) {
            UdhaTheme.scrim
                .ignoresSafeArea()
                .onTapGesture { shell.paletteOpen = false }

            VStack(spacing: 0) {
                field
                HRule()
                results
                HRule()
                footer
            }
            .frame(width: 660)
            .frame(maxHeight: 520)
            .background(
                ZStack {
                    VisualEffectBackground(material: .popover, blending: .withinWindow)
                    UdhaTheme.chrome
                }
            )
            .udhaRounded(14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(UdhaTheme.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.36), radius: 40, y: 22)
            .padding(.top, 104)
            .scaleEffect(shown ? 1 : 0.965, anchor: .top)
            .offset(y: shown ? 0 : -14)
            .opacity(shown ? 1 : 0)
            .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.28), value: shown)
            .onExitCommand { shell.paletteOpen = false }

            // Arrow keys as real shortcuts rather than `.onKeyPress` on the
            // field: a focused TextField consumes ↑/↓ for caret movement, so
            // the key-press handler never sees them.
            Group {
                Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .onAppear {
            focused = true
            shown = true
        }
    }

    private var field: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UdhaTheme.secondary)
            TextField("Type a command or search anything", text: $shell.paletteQuery)
                .textFieldStyle(.plain)
                .font(UdhaTheme.text(17, .regular))
                .foregroundStyle(UdhaTheme.label)
                .focused($focused)
                .onChange(of: shell.paletteQuery) { _, _ in shell.paletteCursor = 0 }
                .onSubmit { runCursor() }
            UdhaKeyHint("esc")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if matches.isEmpty {
                        Text("Nothing matches that. Try “meeting”, “session”, “lock”, “iphone”.")
                            .font(UdhaTheme.text(13.5, .regular))
                            .foregroundStyle(UdhaTheme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 24)
                    }
                    ForEach(entries) { entry in
                        switch entry {
                        case .header(let group):
                            Text(group)
                                .font(UdhaTheme.text(11, .semibold))
                                .tracking(0.2)
                                .foregroundStyle(UdhaTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 6)

                        case .command(let command, let index):
                            row(command, index: index)
                                .id(index)
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: shell.paletteCursor) { _, cursor in
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(cursor, anchor: .center) }
            }
        }
    }

    private func row(_ command: UdhaCommand, index: Int) -> some View {
        let on = index == shell.paletteCursor
        return Button { run(command) } label: {
            HStack(spacing: 11) {
                Image(systemName: command.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(on ? UdhaTheme.accent : UdhaTheme.secondary)
                Text(command.label)
                    .font(UdhaTheme.text(13.5, .medium))
                    .foregroundStyle(on ? UdhaTheme.accentInk : UdhaTheme.label)
                    .fixedSize()
                Text(command.hint)
                    .font(UdhaTheme.text(12, .regular))
                    .foregroundStyle(on ? UdhaTheme.accentInk.opacity(0.75) : UdhaTheme.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !command.keys.isEmpty {
                    UdhaKeyHint(command.keys)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(on ? UdhaTheme.accentTint : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(command.enabled ? 1 : 0.45)
        .offset(x: on ? 3 : 0)
        .animation(UdhaTheme.quick, value: on)
        .onHover { if $0 { shell.paletteCursor = index } }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↑↓ to move")
            Text("↵ to run")
            Spacer()
            Text("\(matches.count) of \(all.count)")
                .monospacedDigit()
            Text("⌘K anywhere")
        }
        .font(UdhaTheme.text(11, .regular))
        .foregroundStyle(UdhaTheme.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Behaviour

    private func move(_ delta: Int) {
        let n = matches.count
        guard n > 0 else { return }
        shell.paletteCursor = (shell.paletteCursor + delta + n) % n
    }

    private func runCursor() {
        guard shell.paletteCursor < matches.count else { return }
        run(matches[shell.paletteCursor])
    }

    private func run(_ command: UdhaCommand) {
        guard command.enabled else {
            shell.say(command.hint)
            return
        }
        shell.paletteOpen = false
        command.run()
    }
}
