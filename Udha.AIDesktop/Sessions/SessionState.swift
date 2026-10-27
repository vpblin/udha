import Foundation

enum SessionState: String, Codable, Hashable, Sendable {
    case starting
    case idle
    case working
    case needsInput
    case errored
    case completed
    case exited
    case crashed
}

/// Fine-grained view of what a session is doing *right now*, orthogonal to
/// `SessionState`.
///
/// `SessionState` stays exactly as it was — the voice engine, tool handlers,
/// menu bar and mobile bridge all switch on it, and widening that enum would
/// silently change their behaviour. `SessionPhase` is additive and read only by
/// the overlay and sidebar, which is where "what is this session actually
/// doing" needs to be legible.
///
/// The distinction that matters most: `.idle` (nothing has happened) vs
/// `.awaitingReply` (Claude finished its turn and the ball is in your court).
/// Both used to render as a flat "Idle", which hid a dozen finished sessions.
enum SessionPhase: String, Codable, Hashable, Sendable {
    case starting
    case thinking          // model is reasoning, no tool call on screen yet
    case planning          // plan mode on and streaming
    case usingTool         // a tool is running; `phaseDetail` says which
    case awaitingApproval  // permission / plan / workspace-trust dialog on screen
    case awaitingReply     // turn ended — waiting on the user
    case idle              // nothing in flight, no turn to review
    case finished          // exited or crashed

    /// Phases where the session is blocked on the user. Drives the pulse and
    /// the attention colours in the overlay.
    var needsAttention: Bool {
        self == .awaitingApproval || self == .awaitingReply
    }
}

struct PendingPrompt: Hashable, Sendable {
    enum Style: String, Hashable, Sendable {
        case yesNo        // y/n
        case numbered     // 1/2/3
        case enterToContinue
        case freeform
    }
    var text: String
    var style: Style
    var isDestructive: Bool
    var detectedAt: Date
}

struct SpokenRecord: Hashable, Sendable {
    var text: String
    var at: Date
}

struct SessionSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    var label: String
    var directory: String
    var state: SessionState
    var stateEnteredAt: Date
    var currentActivity: String?
    var pendingPrompt: PendingPrompt?
    var lastErrorMessage: String?
    var lastSpoken: SpokenRecord?
    var priority: SessionPriority
    var exitCode: Int32?
    /// Display name of the agent that launched this session, if any.
    var agentName: String? = nil
    /// The session this one was launched from, if it's an agent run.
    var parentSessionID: UUID? = nil
    /// Git branch of this session's worktree, when Udha created it. See
    /// `SessionConfig.branch` for why this is stored rather than path-derived.
    var branch: String? = nil
    /// Which assistant is answering in this session — `nil` for a plain shell
    /// command, and for rows from a host too old to say.
    var tool: SessionTool? = nil
    /// The tmux session this runs in, as the host named it at spawn. Carried
    /// rather than derived: `rename` changes the label and leaves the tmux
    /// name alone, so deriving it from the *current* label answered every
    /// attach on a renamed session with `can't find session`. nil for rows
    /// from a host too old to send it — see `tmuxTarget`.
    var tmuxName: String? = nil
    /// The tmux window is pinned to a manual grid — a phone attached and sized
    /// it to its own screen. Normally undone when the phone detaches; when it
    /// isn't (the phone dropped off the relay mid-look), this is how the
    /// desktop knows to offer a release.
    var sizePinned: Bool = false

    // MARK: - Fine-grained status (overlay + sidebar only)

    var phase: SessionPhase = .starting
    /// Human-readable elaboration on `phase`: "Editing TmuxSession.swift",
    /// "Running npm test", "thinking with xhigh effort".
    var phaseDetail: String? = nil
    var phaseEnteredAt: Date = Date()
    /// Subagents currently running under this session.
    var subagentCount: Int = 0
    /// Context window used, 0–100. Only available via the statusLine sidecar.
    var contextPercent: Int? = nil
    /// Session spend in whole cents. Deliberately *not* a raw Double: the
    /// statusLine feed reports a drifting float every few seconds, and
    /// `SessionStateStore.update` de-dupes by equality — storing the float
    /// would invalidate every observer on every tick.
    var costCents: Int? = nil

    /// Which model this session is talking to, as the agent names it
    /// ("Opus 5", "Fable 5.1"). Only sessions reporting through the status
    /// sidecar have one; everything else leaves it nil rather than guessing.
    var model: String? = nil
    /// Which Claude login this session runs under, as the short name of its
    /// config dir ("work-2"). Only set for trees with a login pool
    /// (`ClaudeAccount.alternates`) — a session on the one and only login has
    /// nothing to say here.
    var account: String? = nil

    /// Text of the last question Claude asked before ending its turn, shown on
    /// the card so an `awaitingReply` session says what it wants.
    var attentionState = SessionAttentionState()
    var supportsAttentionEvents = true
    var lastQuestion: String? = nil
    /// The choices on the dialog currently covering this pane, if any. Carried
    /// to remote clients so a phone can press the right digit instead of being
    /// limited to "1" and Escape.
    var dialogOptions: [PaneReading.DialogOption] = []
    /// The machine this session runs on: nil = this Mac; otherwise the remote
    /// host's name (e.g. "devbox"). Set by `RemoteHostClient` when it decodes
    /// a row from that host, so local and remote sessions share one store.
    var hostName: String? = nil
    /// The folder this session is filed in on its own machine (see
    /// `SessionFolder`). nil = loose; an id the store no longer knows reads
    /// as loose too, so a folder deleted mid-delta never strands a row.
    var folderID: UUID? = nil
    /// Tucked away everywhere in the UI. Still supervised — only the lists,
    /// counts and announcements skip it. Both of these take part in the
    /// synthesized equality the store de-dupes on, which is wanted: a flip is
    /// a real change worth a delta, a same-value write is a no-op.
    var hidden: Bool = false

    /// The generic classifier must update the phase consumed by the UI too.
    /// Claude's richer hook/pane phases bypass this coarse mapping.
    mutating func applyClassifiedState(_ newState: SessionState, activity: String? = nil) {
        let wasWorking = state == .working
        if state != newState {
            state = newState
            stateEnteredAt = Date()
        }
        let next: SessionPhase
        switch newState {
        case .starting: next = .starting
        case .working: next = .usingTool
        case .needsInput: next = .awaitingApproval
        case .idle:
            next = tool == .codex || wasWorking || phase == .awaitingReply ? .awaitingReply : .idle
        case .completed: next = .awaitingReply
        case .exited, .crashed: next = .finished
        case .errored: next = .idle
        }
        setPhase(next, detail: activity)
        currentActivity = activity
        if newState != .needsInput { pendingPrompt = nil }
    }

    /// Move to `phase`, restamping `phaseEnteredAt` only on a real change so
    /// the "Ready 7m" clock doesn't reset on every 2s poll.
    mutating func setPhase(_ new: SessionPhase, detail: String?) {
        if phase != new {
            phase = new
            phaseEnteredAt = Date()
        }
        phaseDetail = detail
    }
}
