# Accurate per-session status for Udha

> **Historical design note.** This is the plan that produced the classification pipeline, kept for the reasoning
> and the measurements behind it. It is not a description of the code as it stands: some symbols named here were
> renamed, and the voice subsystem it refers to (`ProactiveVoiceEngine`, `ToolHandlers`, `ContextFeed`) was
> removed. [architecture.md → Classification](architecture.md#classification) is the current reference.

## Context

The overlay's status does not match what the coding sessions are actually doing. In the
reported screenshot the `Udha.AIDesktop` card read `Running · Running 2 shell com…` while
that session was in **plan mode, thinking**, and twelve other sessions read a flat `Idle`
when they had in fact finished their turn and were waiting on a reply.

The goal: at a glance, know which sessions are coding, which need input, and which are done
and ready for review.

## What I verified first (not assumptions)

Run against the 14 live tmux sessions and a throwaway probe session:

1. **Root cause of the bad status is the log-pipe classification path.**
   `SessionManager.handleOutput` classifies `RingBuffer` lines coming from `tmux pipe-pane`.
   For a TUI like Claude Code that stream is a mangled redraw torrent — ANSI-stripped it reads
   `✻thinking with xhigh effort✢a72577…`. Critically, the footer never survives in it, so
   `ClaudePaneReader`'s idle-veto (`idleInputFooterMarker`) **can never match on this path**,
   leaving it structurally biased toward false `needsInput`. It also captures the user's own
   shell commands, so grepping for a regex like `[y/n]` in a pane flips that session to
   "needs input". `~/Library/Logs/Udha.AI/udha.log` shows the consequence — 8 flaps in 60s:
   `Udha.AIDesktop needsInput → working → needsInput → working …`
   The `capture-pane` path (`handleSnapshot`) sees clean, correctly-vetoed text.

2. **The pane bottom already carries everything asked for.** The prototype reader — since vendored into the
   repository as `scripts/verify-status.py` — run over all 14 sessions produced:
   ```
   udha-udhaaidesktop-fb4a2fbc   PLANNING           10m 27s · ↓ 38.4k tokens
   udha-dsahboard-complete-4291   WORKING            1m 6s · ↓ 2.6k tokens
   udha-scholar-health-cb94130d   READY FOR REVIEW   turn ended after 45s
   udha-ads-51d8c046              READY FOR REVIEW   turn ended after 36m 38s
   udha-dsahboard-complete-2      UNSENT DRAFT       Use whatever model cl…
   … 12 of 14 "Idle" sessions are actually READY FOR REVIEW
   ```

3. **The "unsent draft" bug does not exist — my earlier diagnosis was wrong.**
   `capture-pane -pe` shows those `❯ yes, do the swap and merge the decision logs` lines are
   wrapped in `ESC[2m` (ANSI **dim**) — they are Claude Code *ghost suggestions*, not typed
   text. I replayed `TmuxSession.sendInput`'s exact sequence (`send-keys -l` then an immediate
   `send-keys Enter`) against a live session and **it submitted correctly**. There is no Enter
   race and no settle delay is needed. That approved work item is dropped.
   The reader must still tell the two apart: one genuine (non-dim) draft exists right now in
   `dsahboard-complete-2`, so dim-detection is required or every idle session misreads.

4. **The hooks + statusLine sidecar works end-to-end** (Claude Code v2.1.217).
   Spawning `UDHA_SESSION_ID=… claude --settings <udha.json>` in tmux produced, in order:
   `UserPromptSubmit → PreToolUse{tool_name:"Read", tool_input.file_path} → PostToolUse → Stop`,
   appended as JSONL by a 4-line `sh` hook script. `--settings` **merges** with
   `~/.claude/settings.json` (highest precedence) — the user has no `hooks`/`statusLine` keys
   today, so this is purely additive. statusLine delivered `context_window.used_percentage: 5`,
   `cost.total_cost_usd`, `total_lines_added/removed`, `model`, `effort`, `rate_limits`, plus
   `session_id` and `transcript_path` for free — so `--session-id` is unnecessary.
   **Caveat found by testing:** a directory Claude has never run in shows a *workspace trust*
   dialog before anything starts, and the binary confirms hooks **and** statusLine are dead
   until trust is accepted ("Skipping StatusLine command execution - workspace trust not
   accepted") — so the sidecar cannot observe the trust dialog itself. Only the pane reader
   can, and must classify it as `awaitingApproval` rather than hanging on it.

## Design

Two tracks, per the chosen approach.

### Track A — replace the pane classifier (covers every session, including running ones)

New `Sessions/ClaudePaneReader.swift`. Input: `capture-pane -pe` output (**switch to `-pe`** —
`TmuxSession.capturePaneLines` currently passes `-p`, and the dim marker is the only way to
separate a ghost suggestion from a real draft; `handleSnapshot` must keep ANSI-stripping the
lines it forwards to the fallback classifier). It anchors on the **last footer line** and
reads, relative to it, a `PaneReading`. Footer anchor must match *any* of
`shift+tab to cycle` / `? for shortcuts` / `esc to interrupt` — all 16 live sessions happen to
show `shift+tab to cycle` because every one pins a permission mode, but a session in default
*ask* mode paints only `? for shortcuts`, so a single-marker anchor misreads it as non-Claude
(hole found while double-checking the prototype).

| Signal | Source |
| --- | --- |
| is a Claude TUI at all | footer present → else fall back to today's generic rules |
| streaming vs not | `esc to interrupt` in footer |
| plan mode | `⏸ plan mode on` |
| permission mode | `⏵⏵ bypass permissions on` / `⏵ accept edits on` |
| thinking vs tool | spinner line `✻ Verb… (40s · ↓2.7k · thinking with xhigh effort)` |
| turn duration | spinner past-tense `✻ Brewed for 3m 51s` |
| current tool | last `⏺ Tool(args)` line |
| subagents | `◯ name  detail  1m 6s · ↓36.1k tokens` lines below the footer |
| dialog / trust prompt | `esc to cancel` / `Enter to confirm` near footer |
| real draft vs ghost | `❯` line between the rules above the footer; `ESC[2m` ⇒ ghost, ignore |

Spinner verbs are randomized (`Cooked`/`Brewed`/`Gallivanting`) — match the *shape*, never a
verb list.

**Latch on the edge, don't rely on the line staying visible.** Testing showed `gameu` misread
as `IDLE` because its `✻ Cooked for 4m 9s` line had scrolled out of the window. Since
`capture-pane` already polls every 2s, `SessionManager` should observe the
`streaming → not-streaming` transition and stamp `turnEndedAt` itself, using the spinner line
only as a nicety for the duration text. Require **two consecutive** non-streaming captures
(~4s) before latching `awaitingReply` — a capture landing mid-repaint can transiently miss
`esc to interrupt`, and a one-frame glitch must not stamp a false turn end.

**Fix the classification path split:** when `PaneReading.isClaudeTUI` is true, the pane is
authoritative — drop the `lastOutputAt < 3s ⇒ .working` heuristic and the 3s `quietTransition`
timer for that session, since both exist only to paper over the unusable pipe stream. Keep
both for non-Claude commands. `OutputClassifier` keeps its current regex role for those.

### Track B — hooks + statusLine sidecar (new sessions)

New `Sessions/ClaudeStatusSidecar.swift`:

- Writes, once, `~/Library/Application Support/Udha.AI/hooks/udha-hook.sh`,
  `udha-statusline.sh` and `sidecar-settings.json` (the working versions are in the
  scratchpad). Hook script is dependency-free: `{ tr -d '\r\n'; echo; } >> "$dir/$id.jsonl"`.
  The statusline script must **overwrite** its file (write temp + `mv`), not append — each
  payload is ~5KB and updates fire on every assistant message plus the refresh timer, so an
  append-only file grows to megabytes over a long session; only the latest snapshot matters.
- Registers `UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SubagentStart,
  SubagentStop, SessionEnd` plus `statusLine` with `refreshInterval: 3`. All eight event
  names and the statusLine schema were verified against the installed 2.1.217 binary:
  `refreshInterval` is **seconds**, `min(1)`, "Re-run the status line command every N seconds
  in addition to event-driven updates".
- `TmuxSession.start()` builds `shellCommand` at line 73 — prepend
  `UDHA_SESSION_ID=<uuid> UDHA_STATUS_DIR=/tmp/udha/status` and, when `command == "claude"`,
  append `--settings <path>`. **Inject at launch only; do not persist into `SessionConfig.args`**,
  so toggling the feature never rewrites saved configs. While here, actually apply
  `SessionConfig.env`, which is declared (`AppConfig.swift:9`) but never used.
- Tails `/tmp/udha/status/<uuid>.jsonl` reusing the existing `tail -F` pattern in
  `TmuxSession.startTailing`, and maps events onto the same `SessionPhase`, overriding the
  pane reading when present. Tool detail comes from `tool_input`
  (Edit/Write → `Editing <basename>`, Bash → `Running <cmd>`, Task → `Delegating to <type>`).

### Status model

**Do not add cases to `SessionState`.** Keeping it as-is means `ProactiveVoiceEngine`,
`ToolHandlers`, `MenuBarView`, `MobileBridge` and `ContextFeed` are untouched and their
behaviour cannot regress — matching the "overlay + sidebar only" scope. Add alongside it in
`Sessions/SessionState.swift`:

```swift
enum SessionPhase: String, Codable, Hashable, Sendable {
    case starting, thinking, planning, usingTool
    case awaitingApproval    // permission / plan / trust dialog on screen
    case awaitingReply       // turn ended — ball is in your court
    case idle, finished
}
```

and on `SessionSnapshot`: `phase`, `phaseDetail: String?`, `phaseEnteredAt: Date`,
`subagentCount: Int`, `contextPercent: Int?`, `costUSD: Double?`. Quantize `costUSD` to cents
before storing — `SessionStateStore.update` skips no-op writes by equality, and a raw float
that drifts on every 3s statusLine tick would invalidate the whole UI per session per tick.
"Stale" is **derived**, not a case: `awaitingReply` older than a configurable threshold
(default 30m) renders `Stale 2h` instead of `Ready 7m`.

### Presentation

One shared source of truth so the overlay and sidebar can't drift — a
`SessionSnapshot.statusPresentation` extension returning `(label, detail, color)`, consumed by
both `Overlay/SessionNodeView.swift:317` (`stateLabel`/`activityText`) and
`App/RootView.swift:262-276` (`color`/`stateLabel`, which today just prints
`state.rawValue`). `OverlayTheme` gains phase colors; `awaitingReply` needs its own colour
rather than sharing idle's grey, or "done" and "nothing happening" stay
indistinguishable. Context % renders as a small trailing `ctx 62%` chip, amber >80, red >90 —
this also closes the "no real context % stat" item in CLAUDE.md's known rough edges.

## Files

- **New:** `Sessions/ClaudePaneReader.swift`, `Sessions/ClaudeStatusSidecar.swift`, and
  `scripts/verify-status.py` — the prototype reader vendored into the repo (the scratchpad
  copy dies with this session) so the differential check below stays runnable
- **Changed:** `Sessions/SessionState.swift` (phase fields), `Sessions/SessionManager.swift`
  (`runClassifier`/`handleOutput`/`quietTransition` + sidecar events + turn-end latch),
  `Sessions/TmuxSession.swift` (`-pe` capture, env + `--settings` injection, sidecar tail),
  `Sessions/OutputClassifier.swift` (scope down to non-Claude), `Overlay/SessionNodeView.swift`,
  `Overlay/OverlayTheme.swift`, the main window view (now `Shell/UdhaRootView.swift`),
  `Config/AppConfig.swift` (sidecar toggle + stale threshold), and the settings UI (now
  `Shell/UdhaSettingsSheet.swift`)
- **Not changed:** `TmuxSession.sendInput` — see finding 3.

## Verification

1. `xcodebuild` then `./run.sh` — never `open` the old bundle, it reuses the stale binary.
2. **Differential check against ground truth.** Re-run the prototype
   (`scripts/verify-status.py`) across `tmux ls` and compare its verdict to what the app shows for
   every session. `udhaaidesktop` must read *Planning*, `dsahboard-complete-42914fac`
   *Working*, and the ~12 finished ones *Ready for review* with their turn durations —
   not `Idle`.
3. **Flap check:** `grep classify ~/Library/Logs/Udha.AI/udha.log` after 10 idle minutes. The
   `needsInput → working → needsInput` oscillation must be gone. (Log lines carry no dates —
   anchor on line numbers, not timestamps.)
4. **Ghost vs draft:** confirm no session reports a draft except `dsahboard-complete-2`, whose
   non-dim `Use whatever model cl…` must still be reported.
5. **Sidecar:** spawn a fresh session from the app, then
   `tail -f /tmp/udha/status/<uuid>.jsonl` — expect
   `UserPromptSubmit → PreToolUse → PostToolUse → Stop`, and a `ctx %` chip on the card.
6. **Non-Claude regression:** spawn a plain shell session and confirm the old generic
   classifier still drives it.
7. Verify overlay rendering via `CGWindowList`, not `screencapture` (returns wallpaper only).
