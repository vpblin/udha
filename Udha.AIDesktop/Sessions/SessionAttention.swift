import Foundation

/// Which of the three sidebar groups a session belongs in.
///
/// The split is by *who the ball is with*, not by `SessionState`: a session
/// that ended its turn with a question is waiting on you, while one that ended
/// its turn with nothing to say is simply quiet. Both are `.awaitingReply`.
enum SessionAttention: Int, CaseIterable {
    case needsYou = 0
    case working  = 1
    case quiet    = 2

    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working:  return "Working"
        case .quiet:    return "Quiet"
        }
    }

    /// Stable string for the mobile wire protocol. Deliberately not the `Int`
    /// rawValue: reordering these cases would silently repaint every remote
    /// client's board.
    var wireValue: String {
        switch self {
        case .needsYou: return "needsYou"
        case .working:  return "working"
        case .quiet:    return "quiet"
        }
    }
}

extension SessionSnapshot {
    /// Has an `awaitingReply` turn been sitting unanswered past the threshold?
    ///
    /// One derivation shared by the overlay label ("Ready" vs "Stale"), the
    /// sidebar grouping, and the mobile wire row. These each re-derived it
    /// inline, so a change to the rule reached some surfaces and not others.
    func isStale(staleAfter: Double) -> Bool {
        guard phase == .awaitingReply else { return false }
        return Date().timeIntervalSince(phaseEnteredAt) >= staleAfter
    }

    func attention(staleAfter: Double = 1800) -> SessionAttention {
        if attentionState.visibleEvents.contains(where: { $0.kind.needsAction }) { return .needsYou }
        switch state {
        case .errored, .crashed: return .needsYou
        case .exited:            return .quiet
        default: break
        }
        switch phase {
        case .awaitingApproval:
            return .needsYou
        case .awaitingReply:
            // Asked something and hasn't been ignored past the stale mark →
            // still yours to answer. Silent or long-abandoned turns go quiet
            // so the top group stays short enough to actually act on.
            let hasQuestion = !supportsAttentionEvents && (!(lastQuestion?.isEmpty ?? true) || pendingPrompt != nil)
            return (hasQuestion && !isStale(staleAfter: staleAfter)) ? .needsYou : .quiet
        case .thinking, .planning, .usingTool, .starting:
            return .working
        case .idle, .finished:
            return .quiet
        }
    }

    /// What the blocked banner calls this: the kind of thing being waited on.
    var blockedKind: String? {
        if let event = attentionState.visibleEvents.first(where: { $0.kind.needsAction }) { return event.kind.label }
        if state == .errored || state == .crashed { return "This session errored" }
        switch phase {
        case .awaitingApproval: return "Claude needs your approval"
        case .awaitingReply:
            guard !supportsAttentionEvents, !(lastQuestion?.isEmpty ?? true) || pendingPrompt != nil else { return nil }
            return "Claude asked you a question"
        default: return nil
        }
    }

    /// The text shown in the blocked banner's body.
    var blockedText: String? {
        if let event = attentionState.visibleEvents.first(where: { $0.kind.needsAction }) { return event.summary }
        if let prompt = pendingPrompt?.text, !prompt.isEmpty { return prompt }
        if let q = lastQuestion, !q.isEmpty { return q }
        if state == .errored || state == .crashed { return lastErrorMessage }
        return nil
    }
}
