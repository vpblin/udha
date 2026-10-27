import SwiftUI

/// One folder in a machine's column of the Sessions board — the design's
/// 28pt row: chevron · folder glyph · name · count · "N needs you". A click
/// folds it; the name turns into a text field while it is being renamed.
///
/// Not a `Button`: the row is also a drop target for cards and the anchor of a
/// context menu, and neither survives inside one — the same reason the
/// session card underneath uses a tap gesture.
struct SessionFolderRow: View {
    let folder: SessionFolder
    /// Visible members, after search.
    let count: Int
    /// Members that want you right now; 0 hides the pill.
    let needsYou: Int
    let expanded: Bool
    let renaming: Bool
    @Binding var draft: String
    var focus: FocusState<Bool>.Binding
    /// A card is being dragged over this row.
    var dropTargeted = false
    let onToggle: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(UdhaTheme.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .animation(UdhaTheme.quick, value: expanded)
                .frame(width: 12)
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UdhaTheme.accent)
            if renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(UdhaTheme.text(12.5, .semibold))
                    .foregroundStyle(UdhaTheme.label)
                    .focused(focus)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    // Blur commits, the way the pane's title field does — a
                    // half-typed name is still the name you meant.
                    .onChange(of: focus.wrappedValue) { _, on in if !on { onCommitRename() } }
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(UdhaTheme.card))
                    .udhaOutline(radius: 4, color: UdhaTheme.accent, width: 1.5)
            } else {
                Text(folder.name)
                    .font(UdhaTheme.text(12.5, .semibold))
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if needsYou > 0 {
                UdhaPill("\(needsYou) needs you", fg: UdhaTheme.badInk, bg: UdhaTheme.badTint, size: 10, height: 16)
            }
            Text("\(count)")
                .font(UdhaTheme.text(11))
                .monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .frame(minHeight: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverBackground(base: expanded ? UdhaTheme.fill : .clear, hover: UdhaTheme.fillStrong, radius: 7)
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(UdhaTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .opacity(dropTargeted ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { onToggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(count) sessions" + (needsYou > 0 ? ", \(needsYou) need you" : ""))
        .accessibilityAddTraits(.isButton)
    }
}
