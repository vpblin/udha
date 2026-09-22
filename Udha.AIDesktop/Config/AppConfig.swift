import Foundation

struct SessionConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var label: String
    var directory: String
    var command: String = "claude"
    var args: [String] = SessionConfig.defaultClaudeArgs
    var env: [String: String] = [:]

    /// Default args for a freshly-created Claude session. `acceptEdits`
    /// auto-applies file edits but still prompts before riskier actions — the
    /// chosen default for sessions Udha spawns. `bypass`
    /// (`--dangerously-skip-permissions`) stays available as an explicit
    /// per-session choice in the permission-mode picker.
    static let defaultClaudeArgs = ClaudePermissionMode.acceptEdits.args

    /// When cloning a session (duplicate, agent run), bring Claude sessions up
    /// to the current default: append `acceptEdits` if it's a `claude` command
    /// that doesn't already pin a permission mode. Sessions that predate the
    /// default — or their clones — get upgraded; an explicit user choice
    /// (`--permission-mode plan`, etc.) is left untouched.
    static func normalizedClaudeArgs(command: String, args: [String]) -> [String] {
        guard command == "claude",
              !args.contains("--permission-mode"),
              !args.contains("--dangerously-skip-permissions") else { return args }
        return args + defaultClaudeArgs
    }

    /// Which assistant this session runs, or nil for a plain shell command.
    /// Derived from `command` rather than stored alongside it: the command is
    /// what tmux actually launches and what every session already on disk
    /// carries, so a second field could only ever disagree with it.
    var tool: SessionTool? { SessionTool.detect(command: command) }

    var priority: SessionPriority = .normal
    var enabled: Bool = true
    /// When this session was launched from an agent, the agent's display name.
    /// `nil` for ordinary sessions.
    var agentName: String? = nil
    /// The session this one was launched from (agent runs nest under their
    /// originating project session in the sidebar). `nil` for top-level sessions.
    var parentSessionID: UUID? = nil
    /// The git branch this session's worktree is checked out on, when Udha
    /// created that worktree. Stored rather than derived from the directory:
    /// the `-wt/` path convention folds `/` to `-`, so a branch like
    /// `udha/cov-a3f2` cannot be recovered from its own path. `nil` for
    /// ordinary sessions, which fall back to the path derivation.
    var branch: String? = nil
    /// The folder this session is filed in, one of `AppConfig.sessionFolders`
    /// on this machine. `nil` = loose. Folder ids never cross machines.
    var folderID: UUID? = nil
    /// Tucked away everywhere in the UI until "Unhide all". Optional rather
    /// than `Bool = false` on purpose: synthesized `Decodable` throws on a
    /// missing key regardless of the default, and `ConfigStore`'s tolerant
    /// merge only fills defaults inside dictionaries, never inside the
    /// `sessions` array — a non-optional key here would fail every session
    /// entry written before it existed and reset the whole config. `nil` and
    /// `false` mean the same thing.
    var hidden: Bool? = nil
    /// The `CLAUDE_CONFIG_DIR` this session was last launched under, when its
    /// tree has more than one login (`ClaudeAccount.alternates`). Written at
    /// spawn and on every account rotation, so a reattach after a restart
    /// knows which login the live process is on. Optional for the same reason
    /// `hidden` is. nil = whatever `ClaudeAccount.configDir(for:)` says.
    var account: String? = nil
}

/// The coding assistant a session runs.
///
/// The raw value *is* the binary, so a tool is detected from the command a
/// session already stores — nothing to migrate, and a hand-typed command
/// (`npm test`, `htop`) simply has no tool and gets no permission picker.
enum SessionTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case qwen

    var id: String { rawValue }
    var command: String { rawValue }

    /// What to call it on screen. `codex` is the CLI you sign into with a
    /// ChatGPT account, and ChatGPT is the name on that account. `qwen` is Qwen
    /// Code pointed at a model on the box's own GPU, so it is named after the
    /// model rather than an account — there is no account.
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "ChatGPT"
        case .qwen:   return "Qwen"
        }
    }

    /// True when the session talks to a model running on the machine itself.
    /// Nothing it does needs an internet connection, and nothing it says costs
    /// anything — which is why a Qwen session reports no spend.
    var isLocal: Bool { self == .qwen }

    static func detect(command: String) -> SessionTool? {
        SessionTool(rawValue: command.trimmingCharacters(in: .whitespaces))
    }

    /// Launch flags for a permission/approval mode named by its raw value.
    /// An unknown or absent name falls back to the tool's default posture, so
    /// an older client that sends nothing keeps behaving exactly as it did.
    func args(permission raw: String?) -> [String] {
        switch self {
        case .claude:
            return (raw.flatMap(ClaudePermissionMode.init(rawValue:)) ?? .acceptEdits).args
        case .codex:
            return (raw.flatMap(CodexApprovalMode.init(rawValue:)) ?? .workspaceWrite).args
        case .qwen:
            return (raw.flatMap(QwenApprovalMode.init(rawValue:)) ?? .autoEdit).args
        }
    }
}

/// Approval posture for a ChatGPT (Codex CLI) session — the same four rungs the
/// Claude picker offers, expressed with Codex's two orthogonal knobs: `--sandbox`
/// says what the agent may touch, `--ask-for-approval` says when it stops to ask.
enum CodexApprovalMode: String, CaseIterable, Identifiable {
    case workspaceWrite
    case ask
    case readOnly
    case bypass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workspaceWrite: return "Edit in workspace (default)"
        case .ask:            return "Ask each time"
        case .readOnly:       return "Read only — no changes"
        case .bypass:         return "Bypass all — never ask ⚠"
        }
    }

    var detail: String {
        switch self {
        case .workspaceWrite: return "Writes inside the project without asking; asks to step outside it."
        case .ask:            return "Sandboxed to reading; asks before every write or command."
        case .readOnly:       return "Reads and plans only, and never stops to ask."
        case .bypass:         return "No sandbox and no approvals. Use with care."
        }
    }

    var args: [String] {
        switch self {
        case .workspaceWrite: return ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        case .ask:            return ["--sandbox", "read-only", "--ask-for-approval", "on-request"]
        case .readOnly:       return ["--sandbox", "read-only", "--ask-for-approval", "never"]
        case .bypass:         return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }

    /// Best-effort reverse mapping so the picker can preselect from saved args.
    static func from(args: [String]) -> CodexApprovalMode {
        if args.contains("--dangerously-bypass-approvals-and-sandbox") { return .bypass }
        let sandbox = args.firstIndex(of: "--sandbox").map { $0 + 1 < args.count ? args[$0 + 1] : "" }
        let approval = args.firstIndex(of: "--ask-for-approval").map { $0 + 1 < args.count ? args[$0 + 1] : "" }
        if sandbox == "read-only" { return approval == "never" ? .readOnly : .ask }
        return .workspaceWrite
    }
}

/// Approval posture for a Qwen Code session — the same four rungs again, this
/// time on Qwen's single `--approval-mode` knob. The model answering is on the
/// box's own GPU (Ollama, `~/.qwen/.env`), so this picker is the *only* thing
/// standing between the session and the disk: there is no vendor-side refusal
/// behind it the way there is for the other two.
enum QwenApprovalMode: String, CaseIterable, Identifiable {
    case autoEdit
    case ask
    case plan
    case yolo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoEdit: return "Accept edits (default)"
        case .ask:      return "Ask each time"
        case .plan:     return "Plan only — no changes"
        case .yolo:     return "Bypass all — never ask ⚠"
        }
    }

    var detail: String {
        switch self {
        case .autoEdit: return "Auto-applies file edits; still prompts before running commands."
        case .ask:      return "Prompts for every edit and every command."
        case .plan:     return "Reads and plans only, and changes nothing."
        case .yolo:     return "Runs every command and edit with no prompts. Use with care."
        }
    }

    var args: [String] {
        switch self {
        case .autoEdit: return ["--approval-mode", "auto-edit"]
        case .ask:      return ["--approval-mode", "default"]
        case .plan:     return ["--approval-mode", "plan"]
        case .yolo:     return ["--approval-mode", "yolo"]
        }
    }

    /// Best-effort reverse mapping so the picker can preselect from saved args.
    static func from(args: [String]) -> QwenApprovalMode {
        guard let i = args.firstIndex(of: "--approval-mode"), i + 1 < args.count else {
            return args.contains("--yolo") || args.contains("-y") ? .yolo : .autoEdit
        }
        switch args[i + 1] {
        case "plan":    return .plan
        case "default": return .ask
        case "yolo":    return .yolo
        default:        return .autoEdit
        }
    }
}

/// Permission posture for a Claude session, surfaced as a dropdown when
/// starting a session. Each case maps to the CLI flags Claude is launched with.
enum ClaudePermissionMode: String, CaseIterable, Identifiable {
    case acceptEdits
    case ask
    case plan
    case bypass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .acceptEdits: return "Accept edits (default)"
        case .ask:         return "Ask each time"
        case .plan:        return "Plan only — no changes"
        case .bypass:      return "Bypass all — never ask ⚠"
        }
    }

    var detail: String {
        switch self {
        case .acceptEdits: return "Auto-applies file edits; still prompts for riskier actions."
        case .ask:         return "Claude prompts for every action (standard behavior)."
        case .plan:        return "Claude plans only and makes no changes."
        case .bypass:      return "Runs every command and edit with no prompts. Use with care."
        }
    }

    var args: [String] {
        switch self {
        case .acceptEdits: return ["--permission-mode", "acceptEdits"]
        case .ask:         return ["--permission-mode", "default"]
        case .plan:        return ["--permission-mode", "plan"]
        case .bypass:      return ["--dangerously-skip-permissions"]
        }
    }

    /// Best-effort reverse mapping so the picker can preselect from saved args.
    static func from(args: [String]) -> ClaudePermissionMode {
        if args.contains("--dangerously-skip-permissions") { return .bypass }
        if let i = args.firstIndex(of: "--permission-mode"), i + 1 < args.count {
            switch args[i + 1] {
            case "plan": return .plan
            case "default": return .ask
            default: return .acceptEdits
            }
        }
        return .acceptEdits
    }
}


enum PushToTalkMode: String, Codable, Hashable {
    case hold
    case toggle
}

struct HotkeyBinding: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier bits (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000)

    static let `default` = HotkeyBinding(keyCode: 49, modifiers: 0x100 | 0x200) // ⌘⇧Space

    /// ⌃⌥⌘L. Deliberately a three-modifier chord: this one kills your keyboard
    /// and mouse until you authenticate, so it must be impossible to hit by
    /// accident and collide with nothing. Avoids ⌃⌘Q (macOS lock screen).
    static let lockDefault = HotkeyBinding(keyCode: 37, modifiers: 0x1000 | 0x800 | 0x100) // kVK_ANSI_L
}

struct NotificationsConfig: Codable, Hashable {
    var perSessionCooldownSec: Int = 15
    var globalCooldownSec: Int = 3
    var quietHoursStart: String = "22:00"
    var quietHoursEnd: String = "08:00"
    var quietHoursAllowUrgency: NotificationUrgency = .high
    var suppressFocusedSession: Bool = false
    var destructiveKeywords: [String] = [
        "drop", "delete", "deploy", "production", "rm -rf", "force push",
        "truncate", "format", "destroy", "purge"
    ]
    var maxDailyTTSCharacters: Int = 50_000
}

enum NotificationUrgency: String, Codable, Hashable {
    case low, normal, high
}

struct OverlayConfig: Codable, Hashable {
    var enabled: Bool = true
    var edge: OverlayEdge = .right
    /// Which display the overlay pins to, as a `CGDirectDisplayID`. `nil` means
    /// "follow the active display" — the historical behaviour. A stored ID that
    /// isn't attached right now falls back to the active display, so unplugging
    /// a monitor doesn't strand the overlay off-screen.
    var displayID: UInt32? = nil
    var labelMode: OverlayLabelMode = .onHover
    var triggerWidth: Double = 14
    var hideMainWindowOnLaunch: Bool = false
}

enum OverlayEdge: String, Codable, Hashable { case left, right }
enum OverlayLabelMode: String, Codable, Hashable { case onHover, always, never }

struct SlackWorkspaceRecord: Codable, Hashable, Identifiable {
    var teamID: String
    var teamName: String
    var teamDomain: String
    var userID: String
    var userName: String
    var addedAt: Date = Date()
    var enabled: Bool = true

    var id: String { teamID }
    var keychainAccount: String { "slack_token_\(teamID)" }
}

struct SlackConfig: Codable, Hashable {
    var workspaces: [SlackWorkspaceRecord] = []
    var pollIntervalSec: Int = 20
    var announceDMs: Bool = true
    var announceMentions: Bool = true
    var announceAllChannelMessages: Bool = false
}

struct AwakeConfig: Codable, Hashable {
    var keepSystemAwake: Bool = false
    var keepDisplayAwake: Bool = false
}

/// Settings for the input lock: keyboard + mouse dead (event tap), screen on,
/// Touch ID / password to unlock. A hotel-room deterrent, not kiosk mode —
/// macOS keeps ⌃⌘Q and the power button regardless.
struct InputLockConfig: Codable, Hashable {
    /// Master switch. When false: no hotkey registered, no idle timer, lock() refuses.
    var enabled: Bool = false
    var lockHotkey: HotkeyBinding = .lockDefault
    var lockHotkeyEnabled: Bool = true
    /// 0 = off. Minutes with no keyboard or mouse activity before the lock engages.
    var autoLockMinutes: Int = 0
    var showChip: Bool = true
    /// nil = show the lock badge on every attached display.
    var chipDisplayID: UInt32? = nil
    /// Frosted-blur curtain over every display while locked. Hides screen
    /// content from snoopers (window shapes still faintly show — it's a blur,
    /// not a black-out). The curtain carries the lock messaging, so the chip
    /// stays hidden while it's up.
    var hideScreen: Bool = true
    /// Let the tap release input after `passwordFallbackGraceSeconds` so the
    /// macOS password sheet can be typed into. OFF means Touch ID only — on a
    /// Mac without Touch ID that makes the lock unrecoverable short of killing
    /// Udha from another machine, so the UI warns when biometry is unavailable.
    var allowPasswordFallback: Bool = true
    var passwordFallbackGraceSeconds: Int = 4
    var passwordFallbackWindowSeconds: Int = 30
    /// Lock even while another app holds Secure Keyboard Entry. The keyboard
    /// stays live in that case (taps can't see it); the badge says so.
    var allowLockWithSecureInput: Bool = false
}

/// A model on your own hardware, reached over Ollama's API: what translates
/// meeting transcripts and video captions. Defaults to an Ollama on this
/// machine; point it at whatever box on your network has the GPU (the same
/// one that can transcribe meetings for free). Nothing here is billed and the
/// text never leaves your network. config.json only, like `sttBaseURL`.
/// Who writes the meeting notes.
enum NotesProvider: String, Codable, Hashable, CaseIterable {
    case claude, local
}

struct LocalModelConfig: Codable, Hashable {
    var baseURL: String = "http://localhost:11434"
    var model: String = "qwen3.8:27b"
    /// The context window every local call asks for — translation, live
    /// items, the write-up. One value on purpose: Ollama keeps a model loaded
    /// for one `num_ctx`, and two callers asking for different sizes make it
    /// reload the model (tens of seconds) on every switch. 64k fits a
    /// two-hour transcript and leaves the 5090 room for whisper; a longer
    /// transcript escalates for that one call.
    var contextTokens: Int = 65536
}

/// Settings for the meeting recorder (Granola-style call capture + AI notes).
/// Capture/STT knobs feed the audio pipeline; the LLM knobs feed the live
/// note/diagram engine. Recording never depends on the LLM being configured.
struct MeetingsConfig: Codable, Hashable {
    // Capture / transcription
    var keepAudioRecordings: Bool = true
    var sttModelID: String = "scribe_v1"
    /// Speech-to-text endpoint. Default = ElevenLabs Scribe; point at a local
    /// GPU Whisper server (e.g. http://your-gpu-box:8770) to transcribe for free.
    var sttBaseURL: String = "https://api.elevenlabs.io"
    var sttChunkSeconds: Int = 45
    var sttMinChunkSeconds: Int = 15
    /// Chunks whose peak RMS stays below this % of Int16 full scale are treated
    /// as silence and never uploaded to STT.
    var sttSilenceRMSPercent: Double = 0.5
    var diarizeSystemAudio: Bool = true
    /// "" → fall back to the system default input.
    var inputDeviceUID: String = ""
    /// "" = let ElevenLabs auto-detect the language.
    var languageCode: String = ""

    /// Language *name* shown beside each transcript line ("" = off). The
    /// engine is `AppConfig.localModel`.
    var translateTo: String = ""

    // Auto-detection: record when another app holds the microphone (a call),
    // stop when it has been released this long.
    /// Off by default. Watching the microphone to decide a call has started
    /// guesses wrong often enough to be worse than useless — Udha's own screen
    /// recorder, a Continuity Camera and macOS's own capture daemon all read as
    /// "someone is on a call" — and a meeting that records itself while you are
    /// dictating a message is a surprise, not a convenience. Turn it on from
    /// Settings → Meetings, or ⌘K, if you want it.
    var autoRecordMeetings: Bool = false
    /// On, and independent of auto-start. Starting on a guess is a surprise;
    /// *stopping* when the call it was recording has plainly ended is a safety
    /// net — the failure it prevents is a meeting you started by hand and
    /// forgot, recording for hours.
    ///
    /// It only ever fires on a meeting that looked like a call: some other app
    /// must have been holding the microphone while it ran. A recording made at
    /// a table, where nothing else ever takes the mic, is never touched.
    var autoStopMeetings: Bool = true
    var autoStopAfterQuietSec: Int = 45

    // Live intelligence (Claude)
    var liveUpdatesEnabled: Bool = true
    var liveUpdateIntervalSec: Int = 60
    var liveModel: String = "claude-haiku-4-5"
    /// Which model writes notes, action items, the process map and the
    /// "ask about this call" answers: the Anthropic API, or the local model
    /// on the box (`AppConfig.localModel`, Ollama). The local one costs
    /// nothing and never leaves the tailnet.
    var notesProvider: NotesProvider = .claude
    /// With `notesProvider == .claude`: use the local model instead when
    /// Claude cannot be called — no key, or the API account out of credit —
    /// rather than leaving the meeting "Needs summary".
    var fallbackToLocal: Bool = true
    var finalModel: String = "claude-sonnet-5"
    var maxLiveCallsPerMeeting: Int = 60

    /// Name a recording after the Apple Calendar event it overlaps, and keep
    /// who was invited. Reads every account Calendar.app syncs, locally, with
    /// no sign-in of its own.
    var useCalendarTitles: Bool = true
}

extension AppConfig {
    /// The microphone the video recorder will actually open: its own choice
    /// first, then the one Meetings uses, then the system default.
    ///
    /// Lives here so the picker can name the device the fallback lands on
    /// instead of saying "System default" and hoping.
    var effectiveRecordingMicUID: String? {
        for uid in [recordings.micDeviceUID, meetings.inputDeviceUID] where !uid.isEmpty {
            return uid
        }
        return nil
    }
}

/// Full stops and commas are typographic scaffolding for paragraphs, and a
/// caption is not a paragraph — it is three words on screen for a second and a
/// half, where the cut itself already does the work the comma was doing. Marks
/// that carry *tone* are a different matter, so `.reduced` keeps question and
/// exclamation marks and drops the rest.
enum CaptionPunctuation: String, Codable, Hashable, Sendable, CaseIterable {
    /// Exactly what the transcriber returned.
    case full
    /// No full stops, commas, semicolons, colons or ellipses. Tone survives.
    case reduced
    /// Nothing but words — including question and exclamation marks.
    case none

    var label: String {
        switch self {
        case .full: return "Keep it all"
        case .reduced: return "Drop . and ,"
        case .none: return "No punctuation"
        }
    }

    /// Characters stripped when they *end* a word, which is where sentence
    /// punctuation lives. Marks inside a word are left alone, so contractions
    /// and hyphenated names survive every level.
    private var trailing: Set<Character> {
        switch self {
        case .full: return []
        case .reduced: return [".", ",", ";", ":", "…"]
        case .none: return [".", ",", ";", ":", "…", "!", "?"]
        }
    }

    /// Quotation marks read as noise in a caption at any level below `.full`,
    /// wherever they sit.
    private var stripQuotes: Bool { self != .full }

    /// The same rule across a whole caption line, for restripping cues that
    /// were transcribed under a different setting.
    func apply(toLine line: String) -> String {
        line.split(whereSeparator: \.isWhitespace)
            .map { apply(to: String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func apply(to word: String) -> String {
        guard self != .full else { return word }
        var out = word
        if stripQuotes {
            out.removeAll { "\"“”«»".contains($0) }
        }
        while let last = out.last, trailing.contains(last) {
            out.removeLast()
        }
        // A word that was nothing but punctuation is dropped by the caller.
        return out
    }
}

/// Settings for the video recorder (Loom-style screen demos: capture → burn
/// captions → upload → share a branded link).
///
/// Capture knobs feed the two capture sources; composition knobs feed the
/// compositor. Recording and rendering work with no network credentials at
/// all — only publishing needs them.
struct RecordingsConfig: Codable, Hashable {
    // Capture
    var frameRate: Int = 30
    var includeCamera: Bool = true
    var includeMic: Bool = true
    var captureSystemAudio: Bool = true
    /// A demo without the pointer is useless, so this defaults on.
    var showsCursor: Bool = true
    /// Seconds counted down on screen before capture begins. 0 disables it.
    /// Three is enough to get your hands back on the keyboard and to let a
    /// Continuity Camera finish waking up.
    var countdownSeconds: Int = 3
    /// "" → first available camera.
    var cameraDeviceUID: String = ""
    /// "" → fall back to meetings.inputDeviceUID, then the default.
    var micDeviceUID: String = ""

    // Composition — both masters are produced by default, per the "one wide,
    // one vertical" split between the branded page and social re-uploads.
    var renderLandscape: Bool = true
    var renderPortrait: Bool = true
    /// How much of the frame the camera panel takes: the left third of a wide
    /// master, the top third of a vertical one. Not a bubble — the presenter is
    /// a column of the layout, and the screen gets the rest undisturbed.
    var cameraBandFraction: Double = 1.0 / 3.0

    // Captions
    /// Burned into the frames rather than shipped as a sidecar track, because
    /// these videos get re-uploaded to social platforms where a separate VTT
    /// does not travel with the file.
    var burnCaptions: Bool = true
    var captionMaxWords: Int = 6
    /// Burned captions default to dropping full stops and commas: a caption is
    /// three words on screen for a second, and the cut does what the comma was
    /// for. Question and exclamation marks stay, because those carry tone.
    var captionPunctuation: CaptionPunctuation = .reduced
    /// Caption block height as a fraction of the output height, measured from
    /// the bottom. Kept above the ~15% that TikTok and Reels cover with their
    /// own UI.
    var captionSafeAreaFraction: Double = 0.18
    /// "" = let ElevenLabs auto-detect the language.
    var captionLanguageCode: String = ""
    /// Burn the captions in this language *name* instead of the one spoken
    /// ("" = as spoken). Transcription stays in the spoken language for the
    /// timings; the track is translated on `AppConfig.localModel` and kept
    /// beside the original as `captions.<code>.json`.
    var captionTranslateTo: String = ""

    // Sharing. Nothing is configured out of the box: publishing a recording
    // needs a share backend you run yourself, and both values below are empty
    // until you fill them in under Settings → Advanced.
    //
    // They are two *different* origins on purpose, and conflating them is a
    // real trap. If the page origin is a single-page app that does not proxy
    // the API, posting an upload request at `https://<page-origin>/api/...`
    // quietly returns the SPA's index.html with a 200 — a success status for a
    // response that is not the API's. Keep the API base separate from the link
    // base even when they share a domain.
    /// Where the Mac app uploads a published video. Empty = publishing is
    /// off; point it at your own share backend (Settings → Advanced).
    var shareAPIBaseURL: String = ""
    /// The origin share links are shown as, e.g. `https://share.example.com`.
    /// Empty = no link is built and the Videos pane says so; a recording can
    /// still be uploaded, it just has nothing public to point at.
    var shareLinkBaseURL: String = ""
}

struct MobileBridgeConfig: Codable, Hashable {
    var enabled: Bool = false
    var instanceName: String = ""
    /// Your relay server (`wss://…`). The relay protocol is spoken by
    /// `RelayClient` / `RemoteHostClient`; the server itself is not part of
    /// this repository. Empty = the bridge never opens a socket.
    var relayURL: String = ""
    /// The Auth0 tenant that issues tokens for that relay, the *native*
    /// (PKCE, no secret) application id, and the relay API's identifier.
    /// All three are yours to fill in — nothing is baked in.
    var auth0Domain: String = ""
    var auth0ClientID: String = ""
    var auth0Audience: String = ""

    /// Whether there is enough here to attempt a sign-in or a connection.
    var isConfigured: Bool {
        !relayURL.isEmpty && !auth0Domain.isEmpty && !auth0ClientID.isEmpty
    }
    /// Every machine this account has been seen paired with, newest first.
    ///
    /// The relay only ever reports who is online *now*, so without this a box
    /// that is switched off simply vanishes from the Machines list — which is
    /// exactly when you most want to see it, and be told why it is not there.
    var knownHosts: [String] = []
}

/// Prefilled values for the New Session sheet. Saved so the sheet opens on the
/// setup you actually use rather than an empty form every time.
struct NewSessionDefaults: Codable, Hashable {
    var command: String = "claude"
    /// Empty = last used directory, then ~/projects.
    var directory: String = ""
    var permissionRaw: String = ClaudePermissionMode.acceptEdits.rawValue

    var codexApprovalRaw: String = CodexApprovalMode.workspaceWrite.rawValue
    var qwenApprovalRaw: String = QwenApprovalMode.autoEdit.rawValue

    var permission: ClaudePermissionMode {
        get { ClaudePermissionMode(rawValue: permissionRaw) ?? .acceptEdits }
        set { permissionRaw = newValue.rawValue }
    }

    var codexApproval: CodexApprovalMode {
        get { CodexApprovalMode(rawValue: codexApprovalRaw) ?? .workspaceWrite }
        set { codexApprovalRaw = newValue.rawValue }
    }

    var qwenApproval: QwenApprovalMode {
        get { QwenApprovalMode(rawValue: qwenApprovalRaw) ?? .autoEdit }
        set { qwenApprovalRaw = newValue.rawValue }
    }

    /// The assistant the sheet opens on. Stored as the command, so a saved
    /// default of `npm run dev` still opens on that command with no assistant.
    var tool: SessionTool? {
        get { SessionTool.detect(command: command) }
        set { if let newValue { command = newValue.command } }
    }
}

struct AppConfig: Codable, Hashable {
    var version: Int = 4
    var sessions: [SessionConfig] = []
    /// This machine's session folders, in display order. Owned here the way a
    /// session's label is: the supervising machine persists and publishes
    /// them, every client edits them through the bridge's folder verbs.
    var sessionFolders: [SessionFolder] = []
    /// Folders collapsed in this app's list column. View state, so it stays
    /// on this Mac and never rides the wire — collapsing a folder on the desk
    /// must not collapse it on the iPad.
    var collapsedFolderIDs: [String] = []
    var notifications: NotificationsConfig = NotificationsConfig()
    var overlay: OverlayConfig = OverlayConfig()
    var slack: SlackConfig = SlackConfig()
    var mobileBridge: MobileBridgeConfig = MobileBridgeConfig()
    var awake: AwakeConfig = AwakeConfig()
    var inputLock: InputLockConfig = InputLockConfig()
    var meetings: MeetingsConfig = MeetingsConfig()
    var localModel: LocalModelConfig = LocalModelConfig()
    var recordings: RecordingsConfig = RecordingsConfig()
    var recentDirectories: [String] = []
    var hasCompletedFirstRun: Bool = false

    /// Light / dark / follow the Mac, the accent, and the ambient glow.
    var appearance: AppearanceConfig = AppearanceConfig()

    /// Launch Claude sessions with Udha's hook + statusLine settings file so
    /// they report their own status (exact tool names, unambiguous turn ends,
    /// context-window usage) instead of it being read off the pane. Applies to
    /// sessions spawned from now on; the pane reader covers everything else.
    var statusSidecarEnabled: Bool = true
    /// How long an `awaitingReply` session sits before it reads as "Stale"
    /// rather than "Ready".
    var staleAfterSeconds: Double = 1800

    /// One-tap snippets pushed to paired mobile clients. Editable here; the
    /// clients render them read-only.
    var quickCommands: [QuickCommand] = QuickCommand.defaults

    var newSession: NewSessionDefaults = NewSessionDefaults()

    /// On launch, reattach to the Terminal window a live tmux session is
    /// already showing instead of opening a second one. Off means every
    /// restored session gets a fresh window — occasionally what you want after
    /// the window list has drifted out of sync.
    var reclaimTerminalWindows: Bool = true

    /// Draw a live terminal for the selected session inside Udha's own window,
    /// instead of only offering to open one in Terminal/iTerm2.
    ///
    /// Off by default. macOS cannot host another app's window inside yours, so
    /// this is Udha rendering its own emulator (SwiftTerm) attached as a second
    /// tmux client — see `EmbeddedTerminal.swift`. "Open in Terminal" keeps
    /// working either way, and both can be attached at once.
    /// Collapses the sidebar's list column to just the nav rail. Sessions are
    /// named after real clients, so the list is the one part of the window that
    /// cannot be shown on a projector — and on a small screen it is 452pt that
    /// the pane itself wants back. Persisted, because both reasons outlive a
    /// launch.
    var hideSessionList: Bool = false
    var embeddedTerminal: Bool = false

    /// Write DEBUG-level lines to ~/Library/Logs/Udha.AI/udha.log. Off by
    /// default: the pane reader and hook feed are chatty enough to bury the
    /// INFO lines you actually read when something breaks.
    var verboseLogging: Bool = false

    /// Directory trees that run Claude under a login other than the default.
    var claudeAccounts: [ClaudeAccount] = ClaudeAccount.defaults
    /// Moving a session to another login when its own hits a usage limit.
    var accountFailover: AccountFailoverConfig = AccountFailoverConfig()
}

// MARK: - Account failover

/// How sessions move between the logins of a `ClaudeAccount` pool.
struct AccountFailoverConfig: Codable, Hashable {
    /// Rotate a session to the next login the moment its pane shows Claude's
    /// "Usage limit reached · continuing automatically at …" notice. Off, the
    /// session waits for the reset the way Claude does on its own.
    var enabled: Bool = true
    /// Start every new session on the login with the most headroom, rather
    /// than always on the primary.
    var startOnLeastUsed: Bool = true
    /// How often to ask claude.ai how full each idle login is (the running ones
    /// report through their own status line). 0 turns the probe off.
    var usageProbeIntervalSeconds: Double = 300
    /// What the moved session is told, so it picks the task back up instead of
    /// greeting you. Mirrors the line Claude uses for its own auto-continue.
    var continuationPrompt: String = "This session moved to a different Claude login because the previous one reached its usage limit. Continue the task you were working on; do not repeat work that is already complete."
}


// MARK: - Appearance

/// Which appearance the window renders in. The AppKit mapping lives on the
/// Mac side (`UdhaTheme.swift`); this file is shared with the Linux agent.
enum UdhaAppearanceMode: String, Codable, CaseIterable, Hashable {
    case system, light, dark
}

/// The four accents the design offers. Colours live on the Mac side.
enum UdhaAccent: String, Codable, CaseIterable, Hashable {
    case blue, purple, green, graphite
}

/// The appearance block of `AppConfig`.
struct AppearanceConfig: Codable, Hashable {
    var mode: UdhaAppearanceMode = .system
    var accent: UdhaAccent = .blue
    /// Slow drifting colour behind the content. Cheap (no blur), and off is
    /// one click away for a projector.
    var ambientGlow: Bool = true
    /// Lift cards and slide rows on hover. Off makes the window sit still.
    var motion: Bool = true
}

// MARK: - Claude accounts

/// A second Claude Code login, scoped to a directory tree.
///
/// Claude keeps everything user-level under `CLAUDE_CONFIG_DIR` (default
/// `~/.claude`): credentials, settings, `.claude.json`, plugins, the global
/// CLAUDE.md. Pointing a session at a different directory therefore runs it as
/// a different account. A directory matching no entry keeps the default login.
///
/// The account dir has to be logged in once by hand — the first session there
/// will show Claude's own sign-in flow.
struct ClaudeAccount: Codable, Hashable, Identifiable {
    /// Directory tree this account owns. `~`-relative or absolute.
    var pathPrefix: String
    /// The `CLAUDE_CONFIG_DIR` to launch with. `~`-relative or absolute.
    var configDir: String
    /// Further config dirs signed in to *other* logins for the same tree.
    /// Together with `configDir` they form the pool a session's login is
    /// chosen from, and moved within when one of them hits its usage limit
    /// (see `SessionManager.rotateAccount`). Optional so entries written
    /// before this field existed still decode.
    var alternates: [String]? = nil

    var id: String { pathPrefix }

    /// Every login this tree can run under, primary first, tilde-expanded.
    var pool: [String] {
        var seen = Set<String>()
        return ([configDir] + (alternates ?? [])).map(Self.normalized).filter { seen.insert($0).inserted }
    }

    /// The account owning `directory`, if any — same longest-prefix rule as
    /// `configDir(for:accounts:)`.
    static func account(for directory: String, accounts: [ClaudeAccount]) -> ClaudeAccount? {
        let dir = normalized(directory)
        return accounts
            .filter { account in
                let prefix = normalized(account.pathPrefix)
                return !prefix.isEmpty && (dir == prefix || dir.hasPrefix(prefix + "/"))
            }
            .max { normalized($0.pathPrefix).count < normalized($1.pathPrefix).count }
    }

    /// None out of the box. Example: `ClaudeAccount(pathPrefix: "~/projects/work",
    /// configDir: "~/.claude-work")` runs everything under that tree as a
    /// second login.
    static let defaults: [ClaudeAccount] = []

    /// The config dir a session in `directory` should launch with, or nil for
    /// the default account. Longest prefix wins, so a nested tree can carve
    /// itself out of a broader one.
    static func configDir(for directory: String, accounts: [ClaudeAccount]) -> String? {
        account(for: directory, accounts: accounts).map { normalized($0.configDir) }
    }

    /// Tilde expanded, trailing slashes dropped — so the prefix test compares
    /// path components rather than raw strings.
    static func normalized(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        return expanded
    }
}


// MARK: - Quick commands

/// A snippet a mobile client can fire at a session with one tap. Either literal
/// `text` (submitted as a prompt) or raw tmux `keys`, never both.
struct QuickCommand: Codable, Hashable, Identifiable {
    var label: String
    var text: String? = nil
    var keys: [String]? = nil
    /// Renders in red on the client and is worth a second thought.
    var isDestructive: Bool = false

    var id: String { label }

    static let defaults: [QuickCommand] = [
        QuickCommand(label: "Continue", text: "continue"),
        QuickCommand(label: "Run tests", text: "Run the tests and show output"),
        QuickCommand(label: "/compact", text: "/compact"),
        QuickCommand(label: "Commit", text: "Commit and summarize"),
        QuickCommand(label: "Plan mode", keys: ["BTab"]),
    ]

    var wireValue: [String: Any] {
        var out: [String: Any] = ["label": label, "isDestructive": isDestructive]
        if let text { out["text"] = text }
        if let keys { out["keys"] = keys }
        return out
    }
}
