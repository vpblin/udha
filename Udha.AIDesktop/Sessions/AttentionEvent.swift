import Foundation

/// Shared wire contract. Dates are Unix seconds so the two clients and relay agree.
struct AttentionEvent: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case decision, approval, blocked, review, completed
        var needsAction: Bool { self == .decision || self == .approval || self == .blocked }
        var label: String {
            switch self {
            case .decision: return "Decision needed"
            case .approval: return "Approval needed"
            case .blocked: return "Blocked"
            case .review: return "Ready for review"
            case .completed: return "Completed"
            }
        }
        var actionLabel: String {
            switch self {
            case .decision: return "Reply"
            case .approval, .review: return "Review"
            case .blocked, .completed: return "Open session"
            }
        }
    }
    enum State: String, Codable, Sendable { case open, resolved, dismissed }
    var id: String
    var turnID: String
    var kind: Kind
    var summary: String
    var detail: String?
    var url: String?
    var createdAt: Double
    var state: State = .open
    var snoozedUntil: Double? = nil
    var source: String = "agent"
    var visible: Bool { state == .open && (snoozedUntil ?? 0) <= Date().timeIntervalSince1970 }
    var safeURL: URL? {
        guard let url, let value = URL(string: url),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host != nil else { return nil }
        return value
    }
}

struct SessionAttentionState: Codable, Hashable, Sendable {
    var events: [AttentionEvent] = []
    var turnID: String = "" // Assigned at the next explicit turn boundary.
    var turnStartedAt: Double = 0
    var notifyWhenDone = false
    var notifyReviews = false
    var notifyCompletions = false
    var watchSawWork = false
    var awaitingWorkAfterInput = false
    var processedCommands: [String] = []

    var visibleEvents: [AttentionEvent] { events.filter(\.visible) }

    mutating func beginTurn(at time: Double = Date().timeIntervalSince1970) {
        turnID = UUID().uuidString
        turnStartedAt = time
        awaitingWorkAfterInput = true
        for i in events.indices where events[i].state == .open {
            // Review artifacts and completed work remain until acknowledged.
            if events[i].kind.needsAction { events[i].state = .resolved }
        }
        if notifyWhenDone { watchSawWork = true }
    }

    @discardableResult
    mutating func add(kind: AttentionEvent.Kind, summary: String, detail: String? = nil,
                      url: String? = nil, id: String = UUID().uuidString,
                      source: String = "agent", at time: Double = Date().timeIntervalSince1970) -> AttentionEvent? {
        guard !events.contains(where: { $0.id == id }) else { return nil }
        let summary = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        guard !summary.isEmpty else { return nil }
        // Retries with a fresh request ID must not produce duplicate alerts.
        guard !events.contains(where: { $0.turnID == turnID && $0.kind == kind && $0.summary == summary && $0.state != .resolved }) else { return nil }
        let event = AttentionEvent(id: id, turnID: turnID, kind: kind, summary: summary,
                                   detail: detail.map { String($0.prefix(2000)) }, url: url,
                                   createdAt: time, source: source)
        events.append(event)
        // Preserve unresolved requests, with a bounded archive.
        let closed = events.filter { $0.state != .open }.suffix(50)
        events = Array(closed) + events.filter { $0.state == .open }.suffix(100)
        return event
    }

    mutating func resolve(source: String) {
        for i in events.indices where events[i].source == source && events[i].state != .resolved {
            events[i].state = .resolved
        }
    }

    mutating func complete(summary: String, at time: Double = Date().timeIntervalSince1970) -> AttentionEvent? {
        guard notifyWhenDone, watchSawWork else { return nil }
        notifyWhenDone = false
        watchSawWork = false
        return add(kind: .completed, summary: summary, source: "watch", at: time)
    }
}
