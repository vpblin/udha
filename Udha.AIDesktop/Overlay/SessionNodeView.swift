import SwiftUI

/// One session pill in the bloomed overlay: selection bar, state mark, name and
/// state, and a six-bar output meter.
///
/// Clicking brings the session's Terminal window forward. Hover only highlights
/// — hover-to-focus was removed because it yanked windows around whenever the
/// mouse merely crossed the bloom.
struct SessionNodeView: View {
    let snapshot: SessionSnapshot
    let selected: Bool
    let labelMode: OverlayLabelMode
    /// Seconds an `awaitingReply` session waits before it reads as "Stale".
    var staleAfter: Double = 1800
    /// Pre-computed bar heights; the owner reads the ring buffer once per pill.
    let meter: [CGFloat]
    let onClick: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    let onRename: (String) -> Void
    let onRenamingChanged: (Bool) -> Void
    /// The folders this session's machine keeps, when it can keep any — nil
    /// for a box whose agent predates folders, which takes the folder items
    /// out of the menu exactly as the board does.
    var folders: [SessionFolder]? = nil
    var onMoveToFolder: (UUID?) -> Void = { _ in }
    var onNewFolder: () -> Void = {}
    var onHide: () -> Void = {}

    @State private var hovering = false
    @State private var isEditingLabel = false
    @State private var labelDraft = ""
    @FocusState private var labelFieldFocused: Bool

    private var style: UdhaSessionStyle {
        UdhaSessionStyle(snapshot: snapshot, staleAfter: staleAfter)
    }

    private var wantsYou: Bool {
        snapshot.attention(staleAfter: staleAfter) == .needsYou
    }

    var body: some View {
        let s = style
        HStack(alignment: .top, spacing: 8) {
            PingDot(color: s.mark, size: 7, active: s.pulses)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isEditingLabel {
                        TextField("", text: $labelDraft)
                            .textFieldStyle(.plain)
                            .font(UdhaTheme.text(12, .semibold))
                            .foregroundStyle(UdhaTheme.ink)
                            .focused($labelFieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                            .onChange(of: labelFieldFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                    } else if labelMode != .never {
                        Text(snapshot.label)
                            .font(UdhaTheme.text(12, .semibold))
                            .foregroundStyle(UdhaTheme.ink)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Mono(UdhaFormat.duration(since: snapshot.phaseEnteredAt), size: 10, color: UdhaTheme.tertiary)
                }

                HStack(spacing: 6) {
                    Text(s.label)
                        .font(UdhaTheme.text(11, .semibold))
                        .foregroundStyle(s.stateText)
                        .lineLimit(1)
                    if let host = snapshot.hostName {
                        // Which machine this pill lives on, now that both show.
                        // On the second line, where it costs the name nothing.
                        Text(host)
                            .font(UdhaTheme.text(10, .regular))
                            .foregroundStyle(UdhaTheme.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            BarMeter(heights: meter,
                     color: wantsYou ? UdhaTheme.bad : UdhaTheme.tertiary.opacity(0.6),
                     maxHeight: 20)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? UdhaTheme.card : (hovering ? UdhaTheme.fill : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? (wantsYou ? UdhaTheme.bad : UdhaTheme.accent) : .clear, lineWidth: 1.5)
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // While the rename field is open, a stray tap must not showSession —
        // raising the Terminal window would steal key focus from the field.
        .onTapGesture { if !isEditingLabel { onClick() } }
        // A pill can vanish mid-edit (session removed, scrolled out of the
        // LazyVStack). Without this the rename gate stays latched and the
        // overlay can never collapse again.
        .onDisappear { cancelRename() }
        // Same release broadcast the search field honours. Commit rather than
        // cancel: it fires when focus has gone elsewhere, which is the click-
        // away gesture, and that already commits via `labelFieldFocused`.
        .onReceive(NotificationCenter.default.publisher(for: .udhaOverlayReleaseKeyFocus)) { _ in
            commitRename()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.label), \(s.label)")
        .contextMenu {
            Button("Open in Terminal", action: onClick)
            Button("Rename…") { beginRename() }
            Button("Duplicate", action: onDuplicate)
            if let folders {
                Menu("Move to folder…") {
                    ForEach(folders) { folder in
                        Button { onMoveToFolder(folder.id) } label: {
                            if folder.id == snapshot.folderID {
                                Label(folder.name, systemImage: "checkmark")
                            } else {
                                Text(folder.name)
                            }
                        }
                    }
                    if snapshot.folderID != nil {
                        if !folders.isEmpty { Divider() }
                        Button("Remove from folder") { onMoveToFolder(nil) }
                    }
                    Divider()
                    Button("New folder…", action: onNewFolder)
                }
                Button("Hide", action: onHide)
            }
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
        .animation(UdhaTheme.quick, value: hovering)
    }

    // MARK: - Rename

    /// Same two-step as the overlay's search field: the panel is
    /// non-activating, so the key gate has to open before first responder can
    /// be requested.
    private func beginRename() {
        labelDraft = snapshot.label
        isEditingLabel = true
        onRenamingChanged(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            labelFieldFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if isEditingLabel, !labelFieldFocused { cancelRename() }
            }
        }
    }

    private func commitRename() {
        guard isEditingLabel else { return }
        let trimmed = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingLabel = false
        labelFieldFocused = false
        onRenamingChanged(false)
        guard !trimmed.isEmpty, trimmed != snapshot.label else { return }
        onRename(trimmed)
    }

    private func cancelRename() {
        guard isEditingLabel else { return }
        isEditingLabel = false
        labelFieldFocused = false
        onRenamingChanged(false)
    }
}
