import SwiftUI

struct AttentionInbox: View {
    let core: AppCore
    @Bindable var shell: UdhaShellModel
    var sessionID: UUID? = nil
    @State private var expanded = true
    @State private var showAll = false
    @Environment(\.openURL) private var openURL

    private struct Item: Identifiable {
        let snapshot: SessionSnapshot
        let event: AttentionEvent
        var id: String { snapshot.id.uuidString + event.id }
    }
    private var items: [Item] {
        core.stateStore.visible.filter { sessionID == nil || $0.id == sessionID }.flatMap { snap in
            // Completion receipts belong with their session, not in the global
            // queue of things the user still needs to act on.
            snap.attentionState.visibleEvents
                .filter { sessionID != nil || $0.kind != .completed }
                .map { Item(snapshot: snap, event: $0) }
        }.sorted {
            if $0.event.kind.needsAction != $1.event.kind.needsAction { return $0.event.kind.needsAction }
            return $0.event.createdAt > $1.event.createdAt
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if !items.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(items.prefix(showAll ? 100 : 3))) { item in
                            entry(item)
                        }
                        if items.count > 3 { Button(showAll ? "Show less" : "Show all \(items.count)") { showAll.toggle() } }
                    }.padding(.top, 8)
                } label: {
                    let needs = items.filter { $0.event.kind.needsAction }.count
                    let reviews = items.filter { $0.event.kind == .review }.count
                    let completed = items.filter { $0.event.kind == .completed }.count
                    Text([
                        needs > 0 ? "\(needs) \(needs == 1 ? "needs" : "need") you" : nil,
                        reviews > 0 ? "\(reviews) to review" : nil,
                        completed > 0 ? "\(completed) completed" : nil
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(10)
                .udhaCard()
            }
        }
    }
    private func entry(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.event.kind.label).font(.caption.weight(.semibold))
                    .foregroundStyle(item.event.kind.needsAction ? UdhaTheme.warn : UdhaTheme.secondary)
                Spacer()
                Menu {
                    Button("Snooze 15 minutes") { change(item, "snooze") }
                    Button("Dismiss") { change(item, "dismiss") }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                Button { change(item, "dismiss") } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(UdhaTheme.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss this notification")
                .accessibilityLabel("Dismiss \(item.event.kind.label): \(item.event.summary)")
            }
            if sessionID == nil { Text(item.snapshot.label).font(.caption).foregroundStyle(UdhaTheme.secondary) }
            Text(item.event.summary).font(.subheadline).lineLimit(3)
            if sessionID != nil, let detail = item.event.detail {
                Text(detail).font(.caption).foregroundStyle(UdhaTheme.secondary).lineLimit(4)
            }
            HStack {
                Button(item.event.safeURL == nil ? item.event.kind.actionLabel : "Open preview") {
                    guard let current = core.stateStore.snapshot(id: item.snapshot.id)?.attentionState.events.first(where: { $0.id == item.event.id }), current.visible else { return }
                    if let url = current.safeURL { openURL(url) } else { shell.select(session: item.snapshot.id) }
                }.buttonStyle(.link)
                Spacer()
                Text(Date(timeIntervalSince1970: item.event.createdAt), style: .relative)
                    .font(.caption2).foregroundStyle(UdhaTheme.secondary)
            }
        }
    }
    private func change(_ item: Item, _ action: String) {
        if !core.sessionManager.changeAttention(id: item.snapshot.id, action: action, eventID: item.event.id) {
            shell.say("This attention item is no longer open.")
        }
    }
}
