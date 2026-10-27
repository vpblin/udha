import SwiftUI

/// How a session's status reads in the UI.
///
/// One derivation shared by the overlay card and the sidebar row. They used to
/// compute this separately — the overlay mapped `SessionState` to prose while
/// the sidebar printed the raw enum name — so the same session could read
/// "Running" in one place and "working" in the other.
struct SessionStatusPresentation {
    /// Headline verb: "Thinking", "Ready", "Needs approval".
    var label: String
    /// Optional elaboration: "Editing TmuxSession.swift", the question asked.
    var detail: String?
    var color: Color
    /// Attention states pulse; steady ones don't.
    var pulses: Bool
}

extension SessionSnapshot {

    /// `staleAfter` comes from config so "Ready" vs "Stale" is tunable.
    func statusPresentation(staleAfter: Double = 1800) -> SessionStatusPresentation {
        // Terminal states are about the process, not the conversation, so they
        // win over any phase left over from when it was alive.
        switch state {
        case .crashed:
            return .init(label: "Crashed", detail: lastErrorMessage, color: OverlayTheme.stateErrored, pulses: true)
        case .exited:
            let code = exitCode.map { $0 == 0 ? "clean" : "code \($0)" }
            return .init(label: "Exited", detail: code, color: OverlayTheme.stateIdle.opacity(0.6), pulses: false)
        case .errored:
            return .init(label: "Error", detail: lastErrorMessage, color: OverlayTheme.stateErrored, pulses: true)
        default:
            break
        }

        if let event = attentionState.visibleEvents.first(where: { $0.kind.needsAction }) {
            return .init(label: event.kind.label, detail: event.summary, color: OverlayTheme.stateNeedsInput, pulses: true)
        }
        switch phase {
        case .starting:
            return .init(label: "Starting", detail: nil, color: OverlayTheme.stateIdle, pulses: false)

        case .thinking:
            return .init(label: "Thinking", detail: phaseDetail ?? subagentNote,
                         color: OverlayTheme.stateWorking, pulses: false)

        case .planning:
            return .init(label: "Planning", detail: phaseDetail ?? subagentNote,
                         color: OverlayTheme.statePlanning, pulses: false)

        case .usingTool:
            // The tool phrase already reads as a verb ("Editing Foo.swift"), so
            // it becomes the headline rather than being prefixed with "Running".
            return .init(label: phaseDetail ?? "Working", detail: subagentNote,
                         color: OverlayTheme.stateWorking, pulses: false)

        case .awaitingApproval:
            // Codex queues a question the same way it queues an approval; the
            // prompt's style is the only thing that tells them apart.
            return .init(label: pendingPrompt?.style == .freeform ? "Needs an answer" : "Needs approval",
                         detail: pendingPrompt?.text.firstLine ?? phaseDetail,
                         color: OverlayTheme.stateNeedsInput, pulses: true)

        case .awaitingReply:
            let stale = isStale(staleAfter: staleAfter)
            return .init(
                label: stale ? "Stale" : "Ready",
                // What it wants beats how long it took.
                detail: supportsAttentionEvents ? phaseDetail : (lastQuestion ?? phaseDetail),
                color: stale ? OverlayTheme.stateStale : OverlayTheme.stateReady,
                pulses: false
            )

        case .idle:
            return .init(label: "Idle", detail: nil, color: OverlayTheme.stateIdle, pulses: false)

        case .finished:
            return .init(label: "Done", detail: nil, color: OverlayTheme.stateCompleted, pulses: false)
        }
    }

    private var subagentNote: String? {
        guard subagentCount > 0 else { return nil }
        return subagentCount == 1 ? "1 subagent" : "\(subagentCount) subagents"
    }

    /// `ctx 62%` chip text, when the sidecar has reported it.
    var contextChip: String? {
        contextPercent.map { "ctx \($0)%" }
    }

    var contextChipColor: Color {
        switch contextPercent ?? 0 {
        case 90...:  return OverlayTheme.stateErrored
        case 80..<90: return OverlayTheme.amber
        default:      return Color.white.opacity(0.45)
        }
    }
}

private extension String {
    var firstLine: String? {
        components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
    }
}
